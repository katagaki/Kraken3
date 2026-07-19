#if os(macOS)
import Foundation
import Network

final class HTTPServer {

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "kraken.http")
    private let downloadManager: DownloadManager

    init(downloadManager: DownloadManager) {
        self.downloadManager = downloadManager
    }

    func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection, buffer: Data())
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("Kraken: HTTP listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.handle(request: buffer, on: connection)
            } else if isComplete || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(request: Data, on connection: NWConnection) {
        guard let head = String(data: request, encoding: .utf8)?
                .components(separatedBy: "\r\n").first,
              case let parts = head.components(separatedBy: " "),
              parts.count >= 2 else {
            respond(connection, status: "400 Bad Request", body: Data("bad request".utf8), contentType: "text/plain")
            return
        }
        let method = parts[0]
        let rawPath = parts[1].components(separatedBy: "?").first ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            respond(connection, status: "200 OK", body: Data(controlPageHTML.utf8),
                    contentType: "text/html; charset=utf-8")

        case ("GET", "/files"):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let entries = self.downloadManager.entries()
                let body = (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
                self.queue.async {
                    self.respond(connection, status: "200 OK", body: body, contentType: "application/json")
                }
            }

        case ("GET", let p) where p.hasPrefix("/files/"):
            let name = String(p.dropFirst("/files/".count))
            if let url = downloadManager.fileURL(named: name),
               let body = try? Data(contentsOf: url) {
                respond(connection, status: "200 OK", body: body,
                        contentType: "application/octet-stream",
                        extraHeaders: ["Content-Disposition": "attachment; filename=\"\(name.replacingOccurrences(of: "\"", with: "_"))\""])
            } else {
                respond(connection, status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain")
            }

        case ("DELETE", let p) where p.hasPrefix("/files/"):
            let name = String(p.dropFirst("/files/".count))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ok = self.downloadManager.deleteFile(named: name)
                self.queue.async {
                    self.respond(connection, status: ok ? "200 OK" : "404 Not Found",
                                 body: Data(ok ? "deleted".utf8 : "not found".utf8), contentType: "text/plain")
                }
            }

        default:
            respond(connection, status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain")
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data,
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
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif
