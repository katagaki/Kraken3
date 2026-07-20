import Foundation

enum NetworkACL {

    static func normalized(_ ip: String) -> String {
        var value = ip.lowercased()
        if let percent = value.firstIndex(of: "%") {
            value = String(value[..<percent])
        }
        if value.hasPrefix("::ffff:"), value.contains(".") {
            value = String(value.dropFirst("::ffff:".count))
        }
        return value
    }

    private static func ipv4Octets(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let octet = Int(part), (0...255).contains(octet) else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func isLinkLocalIPv6(_ value: String) -> Bool {
        return value.hasPrefix("fe8") || value.hasPrefix("fe9")
            || value.hasPrefix("fea") || value.hasPrefix("feb")
    }

    static func isPrivate(_ rawIP: String) -> Bool {
        let ip = normalized(rawIP)
        if ip.isEmpty { return false }
        if ip == "::1" { return true }
        if isLinkLocalIPv6(ip) { return true }
        if ip.hasPrefix("fc") || ip.hasPrefix("fd") { return true }

        if let o = ipv4Octets(ip) {
            if o[0] == 127 { return true }
            if o[0] == 10 { return true }
            if o[0] == 172 && (16...31).contains(o[1]) { return true }
            if o[0] == 192 && o[1] == 168 { return true }
            if o[0] == 169 && o[1] == 254 { return true }
            if o[0] == 100 && (64...127).contains(o[1]) { return true }
        }
        return false
    }

    static func isAllowedClient(_ rawIP: String) -> Bool {
        let ip = normalized(rawIP)
        if ip.isEmpty { return false }
        return isPrivate(ip)
    }

    static func isBlockedDestination(_ rawIP: String) -> Bool {
        let ip = normalized(rawIP)
        if ip.isEmpty { return true }
        if isPrivate(ip) { return true }
        if ip == "::" { return true }
        if let o = ipv4Octets(ip), o[0] == 0 { return true }
        return false
    }
}
