import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class HeadlessHTTPServer {

    var entriesProvider: (() -> [DownloadEntry])?
    var fileURLProvider: ((String) -> URL?)?
    var deleteHandler: ((String) -> Bool)?

    private var listener: TCPListener?

    func start(port: UInt16) throws {
        let listener = try TCPListener(port: port)
        listener.startAccepting { [weak self] fd in
            Thread.detachNewThread {
                self?.handle(fd)
                close(fd)
            }
        }
        self.listener = listener
    }

    private func handle(_ fd: Int32) {
        var buffer = Data()
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard buffer.count < 1_000_000, let chunk = SocketIO.readSome(fd) else { return }
            buffer.append(chunk)
        }
        guard let head = String(data: buffer, encoding: .utf8)?
                .components(separatedBy: "\r\n").first,
              case let parts = head.components(separatedBy: " "),
              parts.count >= 2 else {
            respond(fd, status: "400 Bad Request", body: Data("bad request".utf8), contentType: "text/plain")
            return
        }
        let method = parts[0]
        let rawPath = parts[1].components(separatedBy: "?").first ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(fd, status: "200 OK", body: Data(controlPageHTML.utf8),
                    contentType: "text/html; charset=utf-8")

        case ("GET", "/files"):
            let entries = DispatchQueue.main.sync { entriesProvider?() ?? [] }
            let body = (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
            respond(fd, status: "200 OK", body: body, contentType: "application/json")

        case ("GET", let p) where p.hasPrefix("/files/"):
            let name = String(p.dropFirst("/files/".count))
            let url = DispatchQueue.main.sync { fileURLProvider?(name) }
            if let url, let body = try? Data(contentsOf: url) {
                respond(fd, status: "200 OK", body: body,
                        contentType: "application/octet-stream",
                        extraHeaders: ["Content-Disposition": "attachment; filename=\"\(name.replacingOccurrences(of: "\"", with: "_"))\""])
            } else {
                respond(fd, status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain")
            }

        case ("DELETE", let p) where p.hasPrefix("/files/"):
            let name = String(p.dropFirst("/files/".count))
            let ok = DispatchQueue.main.sync { deleteHandler?(name) ?? false }
            respond(fd, status: ok ? "200 OK" : "404 Not Found",
                    body: Data(ok ? "deleted".utf8 : "not found".utf8), contentType: "text/plain")

        default:
            respond(fd, status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain")
        }
    }

    private func respond(_ fd: Int32, status: String, body: Data,
                         contentType: String, extraHeaders: [String: String] = [:]) {
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close"
        ]
        for (key, value) in extraHeaders {
            headers.append("\(key): \(value)")
        }
        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)
        _ = SocketIO.writeAll(fd, response)
    }
}
