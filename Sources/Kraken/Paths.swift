import Foundation
#if canImport(Glibc)
import Glibc
#endif

enum Paths {
    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let interface = ptr?.pointee {
            defer { ptr = interface.ifa_next }
            guard let sa = interface.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET else { continue }
            #if os(Linux)
            let saLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            #else
            let saLength = socklen_t(sa.pointee.sa_len)
            #endif
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, saLength, &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: host)
                if address != "127.0.0.1" {
                    addresses.append(address)
                }
            }
        }

        func isTailscale(_ ip: String) -> Bool {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            return parts[0] == 100 && (64...127).contains(parts[1])
        }
        return addresses.sorted { isTailscale($0) && !isTailscale($1) }
    }
}
