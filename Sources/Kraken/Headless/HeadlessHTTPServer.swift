import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

struct HTTPRequest {
    let method: String
    let path: String
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
            respond(fd, HTTPResponse.text("403 Forbidden", "forbidden"))
            return
        }

        var buffer = Data()
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard buffer.count < 1_000_000, let chunk = SocketIO.readSome(fd) else { return }
            buffer.append(chunk)
        }
        guard let request = parse(buffer, peerIP: peerIP) else {
            respond(fd, HTTPResponse.text("400 Bad Request", "bad request"))
            return
        }

        if request.isWebSocketUpgrade, let webSocketUpgrade {
            webSocketUpgrade(fd, request)
            return
        }

        let response = handler?(request) ?? HTTPResponse.text("404 Not Found", "not found")
        respond(fd, response)
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

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequest(method: method, path: path, headers: headers, peerIP: peerIP)
    }

    private func respond(_ fd: Int32, _ response: HTTPResponse) {
        var headers = [
            "HTTP/1.1 \(response.status)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close"
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
        data.append(response.body)
        _ = SocketIO.writeAll(fd, data)
    }
}
