import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

enum URLFilter {

    private static let queue = DispatchQueue(label: "kraken.urlfilter", attributes: .concurrent)

    private static let blockedHosts: Set<String> = [
        "localhost",
        "host.docker.internal",
        "gateway.docker.internal",
        "metadata.google.internal",
        "metadata",
        "instance-data",
        "kubernetes.default"
    ]

    enum Verdict {
        case allowed(URL)
        case unresolvable(URL)
        case blocked(URL)
        case invalid
    }

    static func evaluate(_ raw: String, completion: @escaping (Verdict) -> Void) {
        queue.async {
            guard let url = Navigation.destinationURL(for: raw) else {
                completion(.invalid)
                return
            }
            completion(verdict(for: url))
        }
    }

    static func evaluateURL(_ url: URL, completion: @escaping (Verdict) -> Void) {
        queue.async { completion(verdict(for: url)) }
    }

    static func verdict(for url: URL) -> Verdict {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return .blocked(url) }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return .invalid }

        if blockedHosts.contains(host) { return .blocked(url) }
        if host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") { return .blocked(url) }
        if host.allSatisfy({ $0.isNumber }) { return .blocked(url) }
        if host.hasSuffix(".") { host = String(host.dropLast()) }

        let addresses = resolve(host)
        guard !addresses.isEmpty else { return .unresolvable(url) }
        for address in addresses where NetworkACL.isBlockedDestination(address) {
            return .blocked(url)
        }
        return .allowed(url)
    }

    private static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = 0
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var pointer = result
        while let info = pointer?.pointee {
            defer { pointer = info.ai_next }
            guard let sa = info.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, info.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
        }
        return addresses
    }
}
