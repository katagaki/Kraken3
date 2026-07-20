import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct KrakenConfig {
    let chromiumPath: String
    let homepage: String
    let httpPort: UInt16
    let sessionsRoot: URL
    let singleUser: Bool
    let maxSessions: Int
    let ipACLEnabled: Bool
    let sessionTimeout: TimeInterval
}

final class SessionRecord {
    let id: String
    let browser: BrowserSession
    let dir: URL
    let pid: pid_t
    var lastActive: Date
    var lastMetaWrite: Date

    init(id: String, browser: BrowserSession, dir: URL, pid: pid_t, now: Date) {
        self.id = id
        self.browser = browser
        self.dir = dir
        self.pid = pid
        self.lastActive = now
        self.lastMetaWrite = .distantPast
    }
}

final class SessionManager {

    private let config: KrakenConfig

    private let lock = NSLock()
    private let createQueue = DispatchQueue(label: "kraken.sessions.create")

    private var sessions: [String: SessionRecord] = [:]
    private var claimedSessionID: String?

    private var accessTokens: [String: (sid: String, expires: Date)] = [:]
    private var refreshTokens: [String: (sid: String, expires: Date)] = [:]

    private let accessTTL: TimeInterval
    private let refreshTTL: TimeInterval = 86_400
    private let grace: TimeInterval = 10

    var sendState: (String, [String: Any]) -> Void = { _, _ in }
    var sendDownloads: (String, [String: Any]) -> Void = { _, _ in }
    var sendFrame: (String, Data) -> Void = { _, _ in }
    var closeClients: (String) -> Void = { _ in }
    var connectedSessions: () -> Set<String> = { [] }

    init(config: KrakenConfig) {
        self.config = config
        self.accessTTL = max(config.sessionTimeout * 3, 900)
    }

    func browser(_ sid: String) -> BrowserSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[sid]?.browser
    }

    struct Auth {
        let record: SessionRecord
        let access: String
        let refresh: String
    }

    func authenticate(_ cookies: [String: String]) -> Auth? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        pruneExpired(now)

        if let token = cookies["SessionToken"], let rec = accessTokens[token],
           rec.expires > now, let session = sessions[rec.sid] {
            let (access, refresh) = rotate(sid: rec.sid, oldAccess: token,
                                           oldRefresh: cookies["RefreshToken"], now: now)
            return Auth(record: session, access: access, refresh: refresh)
        }
        if let token = cookies["RefreshToken"], let rec = refreshTokens[token],
           rec.expires > now, let session = sessions[rec.sid] {
            let (access, refresh) = rotate(sid: rec.sid, oldAccess: cookies["SessionToken"],
                                           oldRefresh: token, now: now)
            return Auth(record: session, access: access, refresh: refresh)
        }
        return nil
    }

    func validateForWebSocket(_ cookies: [String: String]) -> String? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        pruneExpired(now)
        if let token = cookies["SessionToken"], let rec = accessTokens[token],
           rec.expires > now, sessions[rec.sid] != nil {
            return rec.sid
        }
        if let token = cookies["RefreshToken"], let rec = refreshTokens[token],
           rec.expires > now, sessions[rec.sid] != nil {
            return rec.sid
        }
        return nil
    }

    enum ObtainResult {
        case created(Auth)
        case deniedSingleUser
        case deniedCapacity
        case failed(String)
    }

    func obtainForNewClient(acceptLanguage: String?) -> ObtainResult {
        createQueue.sync {
            lock.lock()
            if config.singleUser, let claimed = claimedSessionID, sessions[claimed] != nil {
                lock.unlock()
                return .deniedSingleUser
            }
            if !config.singleUser, sessions.count >= config.maxSessions {
                lock.unlock()
                return .deniedCapacity
            }
            lock.unlock()

            let id = Self.randomID()
            let dir = config.sessionsRoot.appendingPathComponent(id)
            let profileDir = dir.appendingPathComponent("profile")
            let downloadsDir = dir.appendingPathComponent("downloads")
            let fm = FileManager.default
            try? fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

            let made = makeBrowser(profileDir: profileDir, downloadsDir: downloadsDir,
                                   acceptLanguage: acceptLanguage)
            guard case .success(let browser) = made else {
                try? fm.removeItem(at: dir)
                if case .failure(let error) = made { return .failed("\(error)") }
                return .failed("unknown error")
            }

            let now = Date()
            let record = SessionRecord(id: id, browser: browser, dir: dir,
                                       pid: browser.processID, now: now)
            wire(record)

            lock.lock()
            sessions[id] = record
            if config.singleUser { claimedSessionID = id }
            let access = issueAccess(sid: id, now: now)
            let refresh = issueRefresh(sid: id, now: now)
            lock.unlock()

            writeMeta(record, now: now)
            return .created(Auth(record: record, access: access, refresh: refresh))
        }
    }

    private func makeBrowser(profileDir: URL, downloadsDir: URL,
                             acceptLanguage: String?) -> Result<BrowserSession, Error> {
        func build() -> Result<BrowserSession, Error> {
            Result {
                try BrowserSession(chromiumPath: config.chromiumPath,
                                   homepage: config.homepage,
                                   profileDir: profileDir,
                                   downloadsDir: downloadsDir,
                                   acceptLanguage: acceptLanguage)
            }
        }
        if Thread.isMainThread { return build() }
        var result: Result<BrowserSession, Error>!
        DispatchQueue.main.sync { result = build() }
        return result
    }

    private func wire(_ record: SessionRecord) {
        let id = record.id
        record.browser.onState = { [weak self] json in self?.sendState(id, json) }
        record.browser.onDownloads = { [weak self] json in self?.sendDownloads(id, json) }
        record.browser.onFrame = { [weak self] data in self?.sendFrame(id, data) }
        record.browser.onProcessExit = { [weak self] in self?.remove(id) }
    }

    func touch(_ sid: String) {
        lock.lock()
        guard let record = sessions[sid] else { lock.unlock(); return }
        let now = Date()
        record.lastActive = now
        let due = now.timeIntervalSince(record.lastMetaWrite) > 5
        if due { record.lastMetaWrite = now }
        lock.unlock()
        if due { writeMeta(record, now: now) }
    }

    func remove(_ sid: String) {
        lock.lock()
        guard let record = sessions.removeValue(forKey: sid) else { lock.unlock(); return }
        accessTokens = accessTokens.filter { $0.value.sid != sid }
        refreshTokens = refreshTokens.filter { $0.value.sid != sid }
        if claimedSessionID == sid { claimedSessionID = nil }
        lock.unlock()

        closeClients(sid)
        DispatchQueue.main.async { record.browser.shutdown() }
        try? FileManager.default.removeItem(at: record.dir)
    }

    func startHeartbeat() {
        Thread.detachNewThread { [weak self] in
            while true {
                sleep(60)
                guard let self else { return }
                for sid in self.connectedSessions() { self.touch(sid) }
            }
        }
    }

    private func rotate(sid: String, oldAccess: String?, oldRefresh: String?,
                        now: Date) -> (access: String, refresh: String) {
        if let old = oldAccess, var rec = accessTokens[old] {
            rec.expires = min(rec.expires, now.addingTimeInterval(grace))
            accessTokens[old] = rec
        }
        if let old = oldRefresh, var rec = refreshTokens[old] {
            rec.expires = min(rec.expires, now.addingTimeInterval(grace))
            refreshTokens[old] = rec
        }
        return (issueAccess(sid: sid, now: now), issueRefresh(sid: sid, now: now))
    }

    private func issueAccess(sid: String, now: Date) -> String {
        let token = Self.randomToken()
        accessTokens[token] = (sid, now.addingTimeInterval(accessTTL))
        return token
    }

    private func issueRefresh(sid: String, now: Date) -> String {
        let token = Self.randomToken()
        refreshTokens[token] = (sid, now.addingTimeInterval(refreshTTL))
        return token
    }

    private func pruneExpired(_ now: Date) {
        accessTokens = accessTokens.filter { $0.value.expires > now }
        refreshTokens = refreshTokens.filter { $0.value.expires > now }
    }

    private func writeMeta(_ record: SessionRecord, now: Date) {
        let object: [String: Any] = ["pid": Int(record.pid),
                                     "lastActive": now.timeIntervalSince1970]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: record.dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func randomToken(_ bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        for i in 0..<bytes { data[i] = UInt8.random(in: 0...255) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<6 { bytes[i] = UInt8((milliseconds >> (8 * (5 - i))) & 0xFF) }
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        func hex(_ range: Range<Int>) -> String {
            bytes[range].map { String(format: "%02x", $0) }.joined()
        }
        return "\(hex(0..<4))-\(hex(4..<6))-\(hex(6..<8))-\(hex(8..<10))-\(hex(10..<16))"
    }
}
