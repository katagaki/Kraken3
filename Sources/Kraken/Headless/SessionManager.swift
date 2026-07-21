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
    let maxTabsPerSession: Int
    let minFreeMemoryMB: Int
    let rendererProcessLimit: Int
    let jsHeapMB: Int
}

final class SessionRecord {
    let id: String
    let browser: BrowserSession
    let dir: URL
    let pid: pid_t
    let acceptLanguage: String?
    var lastActive: Date
    var lastMetaWrite: Date
    var tabs: [String] = []
    var activeTabIndex = 0

    init(id: String, browser: BrowserSession, dir: URL, pid: pid_t,
         acceptLanguage: String?, now: Date) {
        self.id = id
        self.browser = browser
        self.dir = dir
        self.pid = pid
        self.acceptLanguage = acceptLanguage
        self.lastActive = now
        self.lastMetaWrite = .distantPast
    }
}

final class SessionManager {

    private let config: KrakenConfig

    private let lock = NSLock()

    private var sessions: [String: SessionRecord] = [:]
    private var pendingCreations = 0
    private var claimedSessionID: String?

    private var accessTokens: [String: (sid: String, expires: Date)] = [:]
    private var refreshTokens: [String: (sid: String, expires: Date)] = [:]

    private let accessTTL: TimeInterval
    private let refreshTTL: TimeInterval = 86_400
    private let grace: TimeInterval = 10

    var sendState: (String, [String: Any]) -> Void = { _, _ in }
    var sendDownloads: (String, [String: Any]) -> Void = { _, _ in }
    var sendPicker: (String, [String: Any]) -> Void = { _, _ in }
    var sendCopyText: (String, [String: Any]) -> Void = { _, _ in }
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
        lock.lock()
        let now = Date()
        pruneExpired(now)

        var auth: Auth?
        if let token = cookies["SessionToken"], let rec = accessTokens[token],
           rec.expires > now, let session = sessions[rec.sid] {
            let (access, refresh) = rotate(sid: rec.sid, oldAccess: token,
                                           oldRefresh: cookies["RefreshToken"], now: now)
            auth = Auth(record: session, access: access, refresh: refresh)
        } else if let token = cookies["RefreshToken"], let rec = refreshTokens[token],
                  rec.expires > now, let session = sessions[rec.sid] {
            let (access, refresh) = rotate(sid: rec.sid, oldAccess: cookies["SessionToken"],
                                           oldRefresh: token, now: now)
            auth = Auth(record: session, access: access, refresh: refresh)
        }
        lock.unlock()

        if let auth {
            writeTokens(auth.record, access: auth.access, refresh: auth.refresh, now: now)
        }
        return auth
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
        lock.lock()
        if config.singleUser,
           (claimedSessionID.map { sessions[$0] != nil } ?? false) || pendingCreations > 0 {
            lock.unlock()
            return .deniedSingleUser
        }
        if !config.singleUser, sessions.count + pendingCreations >= config.maxSessions {
            lock.unlock()
            return .deniedCapacity
        }
        pendingCreations += 1
        lock.unlock()

        func abandon() {
            lock.lock()
            pendingCreations -= 1
            lock.unlock()
        }

        if let availableMB = SystemMemory.availableMB(), availableMB < config.minFreeMemoryMB {
            abandon()
            fputs("Kraken: refusing new session, only \(availableMB)MB memory available\n", stderr)
            return .deniedCapacity
        }

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
            abandon()
            try? fm.removeItem(at: dir)
            if case .failure(let error) = made { return .failed("\(error)") }
            return .failed("unknown error")
        }

        let now = Date()
        let record = SessionRecord(id: id, browser: browser, dir: dir,
                                   pid: browser.processID,
                                   acceptLanguage: acceptLanguage, now: now)
        wire(record)

        lock.lock()
        pendingCreations -= 1
        sessions[id] = record
        if config.singleUser { claimedSessionID = id }
        let access = issueAccess(sid: id, now: now)
        let refresh = issueRefresh(sid: id, now: now)
        lock.unlock()

        writeMeta(record, now: now)
        writeTokens(record, access: access, refresh: refresh, now: now)
        return .created(Auth(record: record, access: access, refresh: refresh))
    }

    func restoreSessions() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: config.sessionsRoot.path) else { return }
        let now = Date()

        struct Candidate {
            let id: String
            let dir: URL
            let meta: [String: Any]
            let tokens: [String: Any]
            let lastActive: Date
        }
        var candidates: [Candidate] = []
        for name in names where !name.hasPrefix(".") {
            let dir = config.sessionsRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let metaData = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any],
                  let tokenData = try? Data(contentsOf: dir.appendingPathComponent("tokens.json")),
                  let tokens = (try? JSONSerialization.jsonObject(with: tokenData)) as? [String: Any],
                  let refreshExpires = tokens["refreshExpires"] as? Double,
                  refreshExpires > now.timeIntervalSince1970 else {
                try? fm.removeItem(at: dir)
                continue
            }
            let lastActive = Date(timeIntervalSince1970: (meta["lastActive"] as? Double) ?? 0)
            candidates.append(Candidate(id: name, dir: dir, meta: meta,
                                        tokens: tokens, lastActive: lastActive))
        }

        candidates.sort { $0.lastActive > $1.lastActive }
        let limit = config.singleUser ? 1 : config.maxSessions
        for dropped in candidates.dropFirst(limit) { try? fm.removeItem(at: dropped.dir) }

        for candidate in candidates.prefix(limit) {
            killStaleChromium(pid_t((candidate.meta["pid"] as? Int) ?? -1))
            let profileDir = candidate.dir.appendingPathComponent("profile")
            for lockFile in ["SingletonLock", "SingletonSocket", "SingletonCookie"] {
                try? fm.removeItem(at: profileDir.appendingPathComponent(lockFile))
            }

            let acceptLanguage = candidate.meta["acceptLanguage"] as? String
            let made = makeBrowser(profileDir: profileDir,
                                   downloadsDir: candidate.dir.appendingPathComponent("downloads"),
                                   acceptLanguage: acceptLanguage,
                                   restoreTabs: (candidate.meta["tabs"] as? [String]) ?? [],
                                   restoreActiveIndex: (candidate.meta["activeTab"] as? Int) ?? 0)
            guard case .success(let browser) = made else {
                fputs("Kraken: could not restore session \(candidate.id)\n", stderr)
                try? fm.removeItem(at: candidate.dir)
                continue
            }

            let record = SessionRecord(id: candidate.id, browser: browser, dir: candidate.dir,
                                       pid: browser.processID,
                                       acceptLanguage: acceptLanguage, now: now)
            record.tabs = (candidate.meta["tabs"] as? [String]) ?? []
            record.activeTabIndex = (candidate.meta["activeTab"] as? Int) ?? 0
            wire(record)

            lock.lock()
            sessions[candidate.id] = record
            if config.singleUser { claimedSessionID = candidate.id }
            if let access = candidate.tokens["access"] as? String,
               let expires = candidate.tokens["accessExpires"] as? Double {
                accessTokens[access] = (candidate.id, Date(timeIntervalSince1970: expires))
            }
            if let refresh = candidate.tokens["refresh"] as? String,
               let expires = candidate.tokens["refreshExpires"] as? Double {
                refreshTokens[refresh] = (candidate.id, Date(timeIntervalSince1970: expires))
            }
            lock.unlock()

            writeMeta(record, now: now)
            print("Kraken: restored session \(candidate.id)")
        }
    }

    private func killStaleChromium(_ pid: pid_t) {
        guard pid > 0, kill(pid, 0) == 0 else { return }
        // Only signal a PID we can confirm is a Chromium; PIDs may have been recycled.
        #if os(Linux)
        guard let cmdline = try? String(contentsOfFile: "/proc/\(pid)/cmdline", encoding: .utf8),
              cmdline.localizedCaseInsensitiveContains("chrom") else { return }
        kill(pid, SIGKILL)
        #endif
    }

    private func makeBrowser(profileDir: URL, downloadsDir: URL,
                             acceptLanguage: String?,
                             restoreTabs: [String] = [],
                             restoreActiveIndex: Int = 0) -> Result<BrowserSession, Error> {
        Result {
            try BrowserSession(chromiumPath: config.chromiumPath,
                               homepage: config.homepage,
                               profileDir: profileDir,
                               downloadsDir: downloadsDir,
                               acceptLanguage: acceptLanguage,
                               extraArguments: [
                                   "--renderer-process-limit=\(config.rendererProcessLimit)",
                                   "--js-flags=--max-old-space-size=\(config.jsHeapMB)"
                               ],
                               maxTabs: config.maxTabsPerSession,
                               restoreTabs: restoreTabs,
                               restoreActiveIndex: restoreActiveIndex)
        }
    }

    private func wire(_ record: SessionRecord) {
        let id = record.id
        record.browser.onState = { [weak self] json in self?.sendState(id, json) }
        record.browser.onDownloads = { [weak self] json in self?.sendDownloads(id, json) }
        record.browser.onFrame = { [weak self] data in self?.sendFrame(id, data) }
        record.browser.onPicker = { [weak self] json in self?.sendPicker(id, json) }
        record.browser.onCopyText = { [weak self] json in self?.sendCopyText(id, json) }
        record.browser.onTabsPersist = { [weak self, weak record] urls, activeIndex in
            guard let self, let record else { return }
            record.tabs = urls
            record.activeTabIndex = activeIndex
            self.writeMeta(record, now: record.lastActive)
        }
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
        record.browser.shutdown()
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
        var object: [String: Any] = ["pid": Int(record.pid),
                                     "lastActive": now.timeIntervalSince1970,
                                     "tabs": record.tabs,
                                     "activeTab": record.activeTabIndex]
        if let acceptLanguage = record.acceptLanguage {
            object["acceptLanguage"] = acceptLanguage
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: record.dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    private func writeTokens(_ record: SessionRecord, access: String, refresh: String, now: Date) {
        let object: [String: Any] = [
            "access": access,
            "accessExpires": now.addingTimeInterval(accessTTL).timeIntervalSince1970,
            "refresh": refresh,
            "refreshExpires": now.addingTimeInterval(refreshTTL).timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: record.dir.appendingPathComponent("tokens.json"), options: .atomic)
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
