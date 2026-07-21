import Foundation

enum SystemMemory {

    // nil means "unknown" (e.g. macOS dev builds); callers should treat that
    // as no memory pressure rather than refusing work.
    static func availableMB() -> Int? {
        #if os(Linux)
        guard let content = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else {
            return nil
        }
        for line in content.split(separator: "\n") where line.hasPrefix("MemAvailable:") {
            let fields = line.split(separator: " ").filter { !$0.isEmpty }
            if fields.count >= 2, let kb = Int(fields[1]) {
                return kb / 1024
            }
        }
        return nil
        #else
        return nil
        #endif
    }
}
