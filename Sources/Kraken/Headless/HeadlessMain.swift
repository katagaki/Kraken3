import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private var server: KrakenServer?

func runHeadless() {
    setlinebuf(stdout)
    signal(SIGPIPE, SIG_IGN)

    let environment = ProcessInfo.processInfo.environment

    func flag(_ name: String) -> Bool {
        guard let value = environment[name]?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }

    let httpPort = environment["KRAKEN_HTTP_PORT"].flatMap { UInt16($0) } ?? 8080
    let homepage = environment["KRAKEN_HOMEPAGE"].flatMap { $0.isEmpty ? nil : $0 }
        ?? "https://www.startpage.com"

    let sessionsRoot: URL = {
        if let override = environment["KRAKEN_SESSIONS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let preferred = URL(fileURLWithPath: "/data/sessions", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil {
            return preferred
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }()

    let singleUser = flag("KRAKEN_SINGLE_USER")
    let maxSessions = environment["KRAKEN_MAX_SESSIONS"].flatMap { Int($0) } ?? 10
    let ipACLEnabled = !flag("KRAKEN_DISABLE_IP_ACL")
    let sessionTimeout = environment["KRAKEN_SESSION_TIMEOUT"].flatMap { TimeInterval($0) } ?? 300

    guard let chromiumPath = findChromium(override: environment["KRAKEN_CHROMIUM"]) else {
        fputs("Kraken: no Chromium binary found. Install chromium or set KRAKEN_CHROMIUM.\n", stderr)
        exit(1)
    }

    try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

    let config = KrakenConfig(
        chromiumPath: chromiumPath,
        homepage: homepage,
        httpPort: httpPort,
        sessionsRoot: sessionsRoot,
        singleUser: singleUser,
        maxSessions: maxSessions,
        ipACLEnabled: ipACLEnabled,
        sessionTimeout: sessionTimeout
    )

    do {
        let kraken = KrakenServer(config: config)
        try kraken.start()
        server = kraken
    } catch {
        fputs("Kraken: failed to start: \(error)\n", stderr)
        exit(1)
    }

    print("Kraken is running (headless).")
    print("Mode: \(singleUser ? "single-user" : "multi-user (max \(maxSessions) sessions)")")
    print("Sessions folder: \(sessionsRoot.path)")
    print("Chromium: \(chromiumPath)")
    print("Homepage: \(homepage)")
    print("Client IP allowlist: \(ipACLEnabled ? "on (LAN/Tailscale/loopback only)" : "OFF")")
    let addresses = Paths.localIPv4Addresses()
    for address in addresses {
        print("  Control page: http://\(address):\(httpPort)/")
    }
    if addresses.isEmpty {
        print("  Control page: http://localhost:\(httpPort)/")
    }

    dispatchMain()
}

private func findChromium(override: String?) -> String? {
    let fm = FileManager.default
    if let override, !override.isEmpty {
        return fm.isExecutableFile(atPath: override) ? override : nil
    }
    let candidates = [
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/google-chrome",
        "/usr/lib/chromium/chromium"
    ]
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}
