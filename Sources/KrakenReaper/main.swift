import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let environment = ProcessInfo.processInfo.environment
let root = environment["KRAKEN_SESSIONS_DIR"]
    ?? (NSTemporaryDirectory() + "kraken-sessions")
let timeout = environment["KRAKEN_SESSION_TIMEOUT"].flatMap { TimeInterval($0) } ?? 300
let interval: UInt32 = 30

func log(_ message: String) {
    FileHandle.standardError.write(Data("kraken-reaper: \(message)\n".utf8))
}

func isDead(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return true }
    return kill(pid, 0) != 0 && errno == ESRCH
}

func sweep() {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: root) else { return }
    let now = Date().timeIntervalSince1970

    for name in names {
        let dir = (root as NSString).appendingPathComponent(name)
        let metaPath = (dir as NSString).appendingPathComponent("meta.json")

        guard let data = fm.contents(atPath: metaPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        let lastActive = (object["lastActive"] as? Double) ?? 0
        let pid = pid_t((object["pid"] as? Int) ?? -1)
        let idle = now - lastActive

        guard idle > timeout else { continue }

        if pid > 0 && !isDead(pid) {
            kill(pid, SIGTERM)
            usleep(500_000)
            if !isDead(pid) { kill(pid, SIGKILL) }
        }
        try? fm.removeItem(atPath: dir)
        log("removed session \(name) (idle \(Int(idle))s)")
    }
}

log("watching \(root), timeout \(Int(timeout))s")
while true {
    sweep()
    sleep(interval)
}
