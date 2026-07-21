import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct HTTPRequest {
    let method: String
    let path: String
    let version: String
    let headers: [String: String]
    let peerIP: String

    var cookies: [String: String] {
        HTTPCookies.parse(headers["cookie"] ?? "")
    }

    var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.lowercased().contains("websocket") == true
    }
}

struct HTTPResponse {
    var status: String
    var body: Data
    var contentType: String
    var extraHeaders: [String: String] = [:]
    var setCookies: [String] = []
    var bodyFile: URL?

    static func text(_ status: String, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(message.utf8), contentType: "text/plain")
    }
}

enum HTTPCookies {
    static func parse(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            if !name.isEmpty { result[name] = value }
        }
        return result
    }
}

final class HeadlessHTTPServer {

    var accessControl: ((String) -> Bool)?
    var handler: ((HTTPRequest) -> HTTPResponse)?
    var webSocketUpgrade: ((Int32, HTTPRequest) -> Void)?

    private var listener: TCPListener?

    func start(port: UInt16) throws {
        let listener = try TCPListener(port: port)
        listener.startAccepting { [weak self] fd, peerIP in
            let server = self
            Thread.detachNewThread {
                server?.handle(fd, peerIP: peerIP)
                close(fd)
            }
        }
        self.listener = listener
    }

    private func handle(_ fd: Int32, peerIP: String) {
        if let accessControl, !accessControl(peerIP) {
            _ = respond(fd, HTTPResponse.text("403 Forbidden", "forbidden"), keepAlive: false)
            return
        }

        setReadTimeout(fd, seconds: 15)
        let headerEnd = Data("\r\n\r\n".utf8)
        var buffer = Data()

        while true {
            while buffer.range(of: headerEnd) == nil {
                guard buffer.count < 1_000_000, let chunk = SocketIO.readSome(fd) else { return }
                buffer.append(chunk)
            }
            guard let boundary = buffer.range(of: headerEnd) else { return }
            let head = buffer.subdata(in: 0..<boundary.upperBound)
            buffer.removeSubrange(0..<boundary.upperBound)

            guard let request = parse(head, peerIP: peerIP) else {
                _ = respond(fd, HTTPResponse.text("400 Bad Request", "bad request"), keepAlive: false)
                return
            }

            if request.isWebSocketUpgrade, let webSocketUpgrade {
                // The WebSocket read loop manages its own liveness; a receive
                // timeout would kill idle-but-healthy clients.
                setReadTimeout(fd, seconds: 0)
                webSocketUpgrade(fd, request)
                return
            }

            // No endpoint takes a body; a request with one would leave the body
            // bytes to be misparsed as the next request, so close instead.
            let hasBody = (Int(request.headers["content-length"] ?? "") ?? 0) > 0
                || request.headers["transfer-encoding"] != nil
            let wantsClose = request.headers["connection"]?.lowercased().contains("close") == true
            let keepAlive = !wantsClose && !hasBody && request.version == "HTTP/1.1"

            let response = handler?(request) ?? HTTPResponse.text("404 Not Found", "not found")
            guard respond(fd, response, keepAlive: keepAlive), keepAlive else { return }
        }
    }

    private func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval()
        tv.tv_sec = seconds
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func parse(_ buffer: Data, peerIP: String) -> HTTPRequest? {
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        let method = parts[0]
        let rawPath = parts[1].components(separatedBy: "?").first ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath
        let version = parts.count >= 3 ? parts[2] : "HTTP/1.0"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequest(method: method, path: path, version: version,
                           headers: headers, peerIP: peerIP)
    }

    private func respond(_ fd: Int32, _ response: HTTPResponse, keepAlive: Bool) -> Bool {
        var fileHandle: FileHandle?
        var contentLength = response.body.count
        if let url = response.bodyFile {
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil else {
                return respond(fd, HTTPResponse.text("404 Not Found", "not found"),
                               keepAlive: keepAlive)
            }
            fileHandle = handle
            contentLength = Int(size)
        }
        defer { try? fileHandle?.close() }

        var headers = [
            "HTTP/1.1 \(response.status)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(contentLength)",
            "Connection: \(keepAlive ? "keep-alive" : "close")"
        ]
        if response.extraHeaders["Cache-Control"] == nil {
            headers.append("Cache-Control: no-store")
        }
        for (key, value) in response.extraHeaders {
            headers.append("\(key): \(value)")
        }
        for cookie in response.setCookies {
            headers.append("Set-Cookie: \(cookie)")
        }
        var data = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        guard let fileHandle else {
            data.append(response.body)
            return SocketIO.writeAll(fd, data)
        }

        guard SocketIO.writeAll(fd, data) else { return false }
        var remaining = contentLength
        while remaining > 0 {
            guard let chunk = try? fileHandle.read(upToCount: min(262_144, remaining)),
                  !chunk.isEmpty,
                  SocketIO.writeAll(fd, chunk) else { return false }
            remaining -= chunk.count
        }
        return true
    }
}
