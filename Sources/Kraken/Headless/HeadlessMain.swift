import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private var headlessBrowser: HeadlessBrowser?

func runHeadless() {
    setlinebuf(stdout)
    signal(SIGPIPE, SIG_IGN)

    let environment = ProcessInfo.processInfo.environment
    let httpPort = environment["KRAKEN_HTTP_PORT"].flatMap { UInt16($0) } ?? 8080
    let wsPort = environment["KRAKEN_WS_PORT"].flatMap { UInt16($0) } ?? 8081
    let homepage = environment["KRAKEN_HOMEPAGE"].flatMap { $0.isEmpty ? nil : $0 }
        ?? "https://www.startpage.com"

    guard let chromiumPath = findChromium(override: environment["KRAKEN_CHROMIUM"]) else {
        fputs("Kraken: no Chromium binary found. Install chromium or set KRAKEN_CHROMIUM.\n", stderr)
        exit(1)
    }

    Paths.ensureDownloadsDirectory()

    do {
        headlessBrowser = try HeadlessBrowser(chromiumPath: chromiumPath,
                                              homepage: homepage,
                                              httpPort: httpPort,
                                              wsPort: wsPort)
    } catch {
        fputs("Kraken: failed to start: \(error)\n", stderr)
        exit(1)
    }

    print("Kraken is running (headless).")
    print("Downloads folder: \(Paths.downloadsDirectory.path)")
    print("Chromium: \(chromiumPath)")
    print("Homepage: \(homepage)")
    let addresses = Paths.localIPv4Addresses()
    for address in addresses {
        print("  Control page: http://\(address):\(httpPort)/")
    }
    if addresses.isEmpty {
        print("  Control page: http://localhost:\(httpPort)/")
    }
    print("  Inside a container, connect through the host's mapped ports (WebSocket stays on 8081).")

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
