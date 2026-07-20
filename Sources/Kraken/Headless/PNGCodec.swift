import Foundation
import CZlib

enum PNGCodec {

    struct Image {
        let width: Int
        let height: Int
        var rgba: [UInt8]
    }

    static func decode(_ data: Data) -> Image? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 8, [UInt8](data.prefix(8)) == signature else { return nil }

        var width = 0, height = 0, colorType = -1
        var idat = Data()
        var offset = 8
        let bytes = [UInt8](data)

        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                       | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard offset + 8 + length + 4 <= bytes.count else { return nil }
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) ?? ""
            let payload = offset + 8

            switch type {
            case "IHDR":
                guard length >= 13 else { return nil }
                width = Int(bytes[payload]) << 24 | Int(bytes[payload + 1]) << 16
                      | Int(bytes[payload + 2]) << 8 | Int(bytes[payload + 3])
                height = Int(bytes[payload + 4]) << 24 | Int(bytes[payload + 5]) << 16
                       | Int(bytes[payload + 6]) << 8 | Int(bytes[payload + 7])
                let bitDepth = bytes[payload + 8]
                colorType = Int(bytes[payload + 9])
                let interlace = bytes[payload + 12]
                guard bitDepth == 8, colorType == 2 || colorType == 6, interlace == 0 else {
                    return nil
                }
            case "IDAT":
                idat.append(contentsOf: bytes[payload..<payload + length])
            case "IEND":
                offset = bytes.count
                continue
            default:
                break
            }
            offset = payload + length + 4
        }

        guard width > 0, height > 0, width <= 8192, height <= 8192, !idat.isEmpty else { return nil }
        let channels = colorType == 6 ? 4 : 3
        let stride = width * channels
        let expected = height * (stride + 1)
        guard let raw = inflate(idat, expected: expected), raw.count == expected else { return nil }

        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var previous = [UInt8](repeating: 0, count: stride)
        var current = [UInt8](repeating: 0, count: stride)

        for row in 0..<height {
            let rowStart = row * (stride + 1)
            let filter = raw[rowStart]
            for i in 0..<stride {
                let x = Int(raw[rowStart + 1 + i])
                let a = i >= channels ? Int(current[i - channels]) : 0
                let b = Int(previous[i])
                let c = i >= channels ? Int(previous[i - channels]) : 0
                let value: Int
                switch filter {
                case 0: value = x
                case 1: value = x + a
                case 2: value = x + b
                case 3: value = x + (a + b) / 2
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    value = x + (pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
                default: return nil
                }
                current[i] = UInt8(value & 0xFF)
            }
            let out = row * width * 4
            if channels == 4 {
                rgba.replaceSubrange(out..<out + stride, with: current)
            } else {
                for pixel in 0..<width {
                    rgba[out + pixel * 4] = current[pixel * 3]
                    rgba[out + pixel * 4 + 1] = current[pixel * 3 + 1]
                    rgba[out + pixel * 4 + 2] = current[pixel * 3 + 2]
                }
            }
            swap(&previous, &current)
        }
        return Image(width: width, height: height, rgba: rgba)
    }

    static func encodeRegion(_ image: Image, x: Int, y: Int, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0,
              x >= 0, y >= 0, x + width <= image.width, y + height <= image.height else { return nil }
        let stride = width * 4
        var filtered = [UInt8](repeating: 0, count: height * (stride + 1))

        image.rgba.withUnsafeBufferPointer { source in
            for row in 0..<height {
                let src = ((y + row) * image.width + x) * 4
                let dst = row * (stride + 1)
                filtered[dst] = 1
                for i in 0..<stride {
                    let value = source[src + i]
                    let left = i >= 4 ? source[src + i - 4] : 0
                    filtered[dst + 1 + i] = value &- left
                }
            }
        }

        guard let compressed = deflate(filtered) else { return nil }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        appendUInt32(&ihdr, UInt32(width))
        appendUInt32(&ihdr, UInt32(height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        appendChunk(&png, type: "IHDR", payload: ihdr)
        appendChunk(&png, type: "IDAT", payload: compressed)
        appendChunk(&png, type: "IEND", payload: Data())
        return png
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
                                 UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private static func appendChunk(_ png: inout Data, type: String, payload: Data) {
        appendUInt32(&png, UInt32(payload.count))
        var body = Data(type.utf8)
        body.append(payload)
        png.append(body)
        var crc = crc32(0, nil, 0)
        body.withUnsafeBytes { buffer in
            crc = crc32(crc, buffer.bindMemory(to: UInt8.self).baseAddress, uInt(body.count))
        }
        appendUInt32(&png, UInt32(truncatingIfNeeded: crc))
    }

    private static func inflate(_ input: Data, expected: Int) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: expected)
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var status: Int32 = Z_OK
        input.withUnsafeBytes { (inputBuffer: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = UnsafeMutablePointer(
                    mutating: inputBuffer.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(expected)
                status = CZlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || (status == Z_OK && stream.avail_out == 0) else { return nil }
        return output
    }

    private static func deflate(_ input: [UInt8]) -> Data? {
        var bound = 0
        var stream = z_stream()
        guard deflateInit_(&stream, 4, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }
        bound = Int(deflateBound(&stream, uLong(input.count)))

        var output = [UInt8](repeating: 0, count: bound)
        var status: Int32 = Z_OK
        var produced = 0
        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = UnsafeMutablePointer(mutating: inputBuffer.baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(bound)
                status = CZlib.deflate(&stream, Z_FINISH)
                produced = bound - Int(stream.avail_out)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        return Data(output.prefix(produced))
    }
}
