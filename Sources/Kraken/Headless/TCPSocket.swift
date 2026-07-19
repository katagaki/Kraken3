import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct SocketError: Error {
    let message: String
}

final class TCPListener {
    private let fd: Int32

    init(port: UInt16) throws {
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw SocketError(message: "socket() failed") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: 0)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw SocketError(message: "could not bind port \(port)")
        }
    }

    func startAccepting(_ handler: @escaping (Int32) -> Void) {
        let serverFD = fd
        Thread.detachNewThread {
            while true {
                let clientFD = accept(serverFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var yes: Int32 = 1
                setsockopt(clientFD, numericCast(IPPROTO_TCP), TCP_NODELAY,
                           &yes, socklen_t(MemoryLayout<Int32>.size))
                handler(clientFD)
            }
        }
    }
}

enum SocketIO {
    static func readSome(_ fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { return nil }
            if errno != EINTR { return nil }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = write(fd, base.advanced(by: sent), raw.count - sent)
                if count > 0 {
                    sent += count
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
    }
}
