import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Turns raw screencast frames into the wire protocol: in diff mode Chromium sends
// PNG frames that are decoded and diffed against the last delivered frame so only
// the changed rectangle goes out; sustained large diffs (video, scrolling) switch
// to plain JPEG streaming, and calm pages switch back. Frames are only sent while
// the client keeps up (per-frame acks); otherwise the newest frame waits in a
// one-slot mailbox.
final class FrameStreamer {

    var onSend: ((Data) -> Void)?
    var onScreencastConfigChange: (() -> Void)?

    private let queue = DispatchQueue(label: "kraken.framestream")
    private let stateLock = NSLock()

    private enum Mode { case diff, stream }
    private var mode: Mode = .diff
    private var prev: PNGCodec.Image?
    private var pendingLatest: Data?
    private var lastKickTime = Date.distantPast
    private var fullStreak = 0
    private var lastStreamPayload: Data?
    private var lastFrameTime = Date.distantPast
    private var streamEnteredAt = Date.distantPast
    private var calmCheckScheduled = false

    private var lastSentSeq: UInt32 = 0
    private var lastAckedSeq: UInt32 = 0

    private let qualityTiers = [70, 50, 35]
    private var qualityTier = 0
    private var lastDropTime = Date.distantPast
    private var dropWindowStart = Date.distantPast
    private var dropsInWindow = 0

    private var publishedFormat = "png"
    private var publishedQuality = 70
    private var expectedDims: [(width: Int, height: Int)] = []

    var screencastFormat: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return publishedFormat
    }

    var screencastQuality: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return publishedQuality
    }

    func ingest(_ data: Data) {
        queue.async { self.process(data) }
    }

    func ack(_ seq: Int) {
        queue.async {
            let value = UInt32(truncatingIfNeeded: seq)
            if value &- self.lastAckedSeq < 0x8000_0000 {
                self.lastAckedSeq = value
            }
            self.flushPending()
        }
    }

    func reset() {
        queue.async {
            self.prev = nil
            self.pendingLatest = nil
            self.fullStreak = 0
            self.lastStreamPayload = nil
            if self.mode == .stream {
                self.mode = .diff
                self.setPublished(format: "png")
            }
        }
    }

    func setExpectedDims(_ dims: [(width: Int, height: Int)]) {
        queue.async { self.expectedDims = dims }
    }

    func syncClient() {
        queue.async {
            self.prev = nil
            self.pendingLatest = nil
            self.lastStreamPayload = nil
            self.lastAckedSeq = self.lastSentSeq
            self.kickScreencast()
        }
    }

    private var blocked: Bool {
        lastSentSeq &- lastAckedSeq >= 3
    }

    private func process(_ data: Data) {
        lastFrameTime = Date()
        if blocked {
            registerDrop()
            pendingLatest = data
            return
        }
        if data.first == 0x89 {
            processDiff(data)
        } else {
            processStream(data)
        }
    }

    private func processDiff(_ data: Data) {
        guard let image = PNGCodec.decode(data) else {
            kickScreencast()
            return
        }
        // Chromium emits half-scale frames while a screencast restarts around a
        // viewport change; propagating those would shrink the client canvas.
        guard expectedDims.isEmpty || expectedDims.contains(where: {
            $0.width == image.width && $0.height == image.height
        }) else { return }
        guard let previous = prev, previous.width == image.width,
              previous.height == image.height else {
            sendFull(from: image)
            return
        }
        guard let box = diffBox(previous, image) else { return }

        if box.w * box.h * 2 > image.width * image.height {
            fullStreak += 1
            if fullStreak >= 4 { switchToStream() }
            sendFull(from: image)
            return
        }
        fullStreak = 0
        guard let tile = PNGCodec.encodeRegion(image, x: box.x, y: box.y,
                                               width: box.w, height: box.h) else {
            sendFull(from: image)
            return
        }
        prev = image
        send(kind: 2, x: box.x, y: box.y, w: box.w, h: box.h,
             fullW: image.width, fullH: image.height, payload: tile)
    }

    private func processStream(_ data: Data) {
        guard data != lastStreamPayload else { return }
        if !expectedDims.isEmpty, let dims = Self.jpegDimensions(data),
           !expectedDims.contains(where: { $0.width == dims.width && $0.height == dims.height }) {
            return
        }
        lastStreamPayload = data
        send(kind: 0, payload: data)
    }

    private static func jpegDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(65536))
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < bytes.count {
            guard bytes[i] == 0xFF else { i += 1; continue }
            let marker = bytes[i + 1]
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                let height = Int(bytes[i + 5]) << 8 | Int(bytes[i + 6])
                let width = Int(bytes[i + 7]) << 8 | Int(bytes[i + 8])
                return (width, height)
            }
            i += 2 + (Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]))
        }
        return nil
    }

    private func sendFull(from image: PNGCodec.Image) {
        guard let jpeg = JPEGEncoder.encode(width: image.width, height: image.height,
                                            rgba: image.rgba,
                                            quality: qualityTiers[qualityTier]) else { return }
        prev = image
        send(kind: 0, payload: jpeg)
    }

    private func kickScreencast() {
        // A screencast restart makes Chromium emit a fresh frame; rate-limited so
        // a page that keeps producing undecodable frames cannot cause a restart loop.
        let now = Date()
        guard now.timeIntervalSince(lastKickTime) > 1 else { return }
        lastKickTime = now
        onScreencastConfigChange?()
    }

    private func flushPending() {
        guard !blocked, let data = pendingLatest else { return }
        pendingLatest = nil
        if data.first == 0x89 {
            processDiff(data)
        } else {
            processStream(data)
        }
    }

    private func switchToStream() {
        mode = .stream
        fullStreak = 0
        lastStreamPayload = nil
        streamEnteredAt = Date()
        setPublished(format: "jpeg")
        scheduleCalmCheck()
    }

    private func switchToDiff() {
        mode = .diff
        prev = nil
        lastStreamPayload = nil
        setPublished(format: "png")
    }

    private func setPublished(format: String) {
        stateLock.lock()
        publishedFormat = format
        publishedQuality = qualityTiers[qualityTier]
        stateLock.unlock()
        onScreencastConfigChange?()
    }

    private func scheduleCalmCheck() {
        guard !calmCheckScheduled else { return }
        calmCheckScheduled = true
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.calmCheckScheduled = false
            guard self.mode == .stream else { return }
            let now = Date()
            // Small animations (a blinking caret) never leave a 1.5s gap, so also
            // probe diff mode periodically; heavy motion just re-enters stream.
            if now.timeIntervalSince(self.lastFrameTime) > 1.5
                || now.timeIntervalSince(self.streamEnteredAt) > 6 {
                self.switchToDiff()
            } else {
                self.scheduleCalmCheck()
            }
        }
    }

    private func registerDrop() {
        let now = Date()
        lastDropTime = now
        if now.timeIntervalSince(dropWindowStart) > 3 {
            dropWindowStart = now
            dropsInWindow = 0
        }
        dropsInWindow += 1
        if dropsInWindow > 8, qualityTier < qualityTiers.count - 1 {
            qualityTier += 1
            dropsInWindow = 0
            if mode == .stream { setPublished(format: "jpeg") }
        }
    }

    private func send(kind: UInt8, x: Int = 0, y: Int = 0, w: Int = 0, h: Int = 0,
                      fullW: Int = 0, fullH: Int = 0, payload: Data) {
        if qualityTier > 0, Date().timeIntervalSince(lastDropTime) > 10 {
            qualityTier -= 1
            if mode == .stream { setPublished(format: "jpeg") }
        }
        lastSentSeq &+= 1
        var message = Data([0x4B, 0x46, 1, kind])
        appendUInt32(&message, lastSentSeq)
        for value in [x, y, w, h, fullW, fullH] {
            let clamped = UInt16(clamping: value)
            message.append(UInt8(clamped >> 8))
            message.append(UInt8(clamped & 0xFF))
        }
        message.append(payload)
        onSend?(message)
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                                 UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private func diffBox(_ a: PNGCodec.Image,
                         _ b: PNGCodec.Image) -> (x: Int, y: Int, w: Int, h: Int)? {
        let stride = a.width * 4
        var top = -1
        var bottom = -1
        var minByte = stride
        var maxByte = -1

        a.rgba.withUnsafeBytes { rawA in
            b.rgba.withUnsafeBytes { rawB in
                guard let baseA = rawA.baseAddress, let baseB = rawB.baseAddress else { return }
                var row = 0
                while row < a.height {
                    if memcmp(baseA + row * stride, baseB + row * stride, stride) != 0 {
                        top = row
                        break
                    }
                    row += 1
                }
                guard top >= 0 else { return }
                row = a.height - 1
                while row >= top {
                    if memcmp(baseA + row * stride, baseB + row * stride, stride) != 0 {
                        bottom = row
                        break
                    }
                    row -= 1
                }

                let bytesA = baseA.assumingMemoryBound(to: UInt8.self)
                let bytesB = baseB.assumingMemoryBound(to: UInt8.self)
                for scanRow in top...bottom {
                    let offset = scanRow * stride
                    if memcmp(baseA + offset, baseB + offset, stride) == 0 { continue }
                    var i = 0
                    while i < minByte, bytesA[offset + i] == bytesB[offset + i] { i += 1 }
                    if i < minByte { minByte = i }
                    var j = stride - 1
                    while j > maxByte, bytesA[offset + j] == bytesB[offset + j] { j -= 1 }
                    if j > maxByte { maxByte = j }
                }
            }
        }

        guard top >= 0, bottom >= top, maxByte >= minByte else { return nil }
        let x = minByte / 4
        let endX = maxByte / 4
        return (x: x, y: top, w: endX - x + 1, h: bottom - top + 1)
    }
}
