import Foundation

final class KrakenServer {

    private let config: KrakenConfig
    private let sessions: SessionManager
    private let http = HeadlessHTTPServer()
    private let ws = HeadlessWebSocketServer()
    private var reaperProcess: Process?

    init(config: KrakenConfig) {
        self.config = config
        self.sessions = SessionManager(config: config)
    }

    func start() throws {
        sessions.sendState = { [weak self] sid, json in self?.ws.sendJSON(toSession: sid, json) }
        sessions.sendDownloads = { [weak self] sid, json in self?.ws.sendJSON(toSession: sid, json) }
        sessions.sendFrame = { [weak self] sid, data in self?.ws.sendFrame(toSession: sid, data) }
        sessions.closeClients = { [weak self] sid in self?.ws.closeSession(sid) }
        sessions.connectedSessions = { [weak self] in self?.ws.sessionsWithClients() ?? [] }

        let acl: (String) -> Bool = { [weak self] ip in self?.allowClient(ip) ?? false }
        http.accessControl = acl

        http.handler = { [weak self] request in
            self?.handleHTTP(request) ?? HTTPResponse.text("500 Internal Server Error", "no handler")
        }
        http.webSocketUpgrade = { [weak self] fd, request in self?.handleUpgrade(fd, request) }

        ws.onMessage = { [weak self] sid, json in
            guard let self else { return }
            self.sessions.touch(sid)
            self.sessions.browser(sid)?.handleControlMessage(json)
        }
        ws.onClientConnected = { [weak self] sid in
            self?.sessions.browser(sid)?.syncNewClient()
        }

        try http.start(port: config.httpPort)
        sessions.startHeartbeat()
        launchReaper()
    }

    private func allowClient(_ ip: String) -> Bool {
        guard config.ipACLEnabled else { return true }
        return NetworkACL.isAllowedClient(ip)
    }

    private func originMatchesHost(_ headers: [String: String]) -> Bool {
        guard let origin = headers["origin"], !origin.isEmpty else { return true }
        guard let originHost = URL(string: origin)?.host else { return false }
        let host = (headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
        return !host.isEmpty && originHost == host
    }

    private func handleUpgrade(_ fd: Int32, _ request: HTTPRequest) {
        guard originMatchesHost(request.headers),
              let key = request.headers["sec-websocket-key"],
              let sid = sessions.validateForWebSocket(request.cookies) else {
            _ = SocketIO.writeAll(fd, Data("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))
            return
        }
        ws.accept(fd: fd, key: key, sessionID: sid)
    }

    private func handleHTTP(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return serveControlPage(request)

        case ("GET", "/files"):
            guard let auth = sessions.authenticate(request.cookies) else { return unauthorized() }
            let entries = DispatchQueue.main.sync { auth.record.browser.entries() }
            let body = (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8)
            return authed(status: "200 OK", body: body, contentType: "application/json", auth: auth)

        case ("GET", let path) where path.hasPrefix("/files/"):
            guard let auth = sessions.authenticate(request.cookies) else { return unauthorized() }
            let name = String(path.dropFirst("/files/".count))
            let url = DispatchQueue.main.sync { auth.record.browser.fileURL(named: name) }
            guard let url, let body = try? Data(contentsOf: url) else {
                return authed(status: "404 Not Found", body: Data("not found".utf8),
                              contentType: "text/plain", auth: auth)
            }
            let safeName = Filenames.stripControl(name).replacingOccurrences(of: "\"", with: "_")
            var response = authed(status: "200 OK", body: body,
                                  contentType: "application/octet-stream", auth: auth)
            response.extraHeaders["Content-Disposition"] = "attachment; filename=\"\(safeName)\""
            return response

        case ("DELETE", let path) where path.hasPrefix("/files/"):
            guard originMatchesHost(request.headers) else {
                return HTTPResponse.text("403 Forbidden", "bad origin")
            }
            guard let auth = sessions.authenticate(request.cookies) else { return unauthorized() }
            let name = String(path.dropFirst("/files/".count))
            let ok = DispatchQueue.main.sync { auth.record.browser.deleteFile(named: name) }
            return authed(status: ok ? "200 OK" : "404 Not Found",
                          body: Data((ok ? "deleted" : "not found").utf8),
                          contentType: "text/plain", auth: auth)

        default:
            return HTTPResponse.text("404 Not Found", "not found")
        }
    }

    private func serveControlPage(_ request: HTTPRequest) -> HTTPResponse {
        if let auth = sessions.authenticate(request.cookies) {
            return authed(status: "200 OK", body: Data(controlPageHTML.utf8),
                          contentType: "text/html; charset=utf-8", auth: auth)
        }
        switch sessions.obtainForNewClient() {
        case .created(let auth):
            return authed(status: "200 OK", body: Data(controlPageHTML.utf8),
                          contentType: "text/html; charset=utf-8", auth: auth)
        case .deniedSingleUser:
            return HTTPResponse(status: "403 Forbidden",
                                body: Data(singleUserBusyHTML.utf8),
                                contentType: "text/html; charset=utf-8")
        case .deniedCapacity:
            return HTTPResponse.text("503 Service Unavailable",
                                     "Kraken is at capacity. Try again later.")
        case .failed(let message):
            fputs("Kraken: session creation failed: \(message)\n", stderr)
            return HTTPResponse.text("500 Internal Server Error", "could not start a browser session")
        }
    }

    private func unauthorized() -> HTTPResponse {
        HTTPResponse.text("401 Unauthorized", "unauthorized")
    }

    private func authed(status: String, body: Data, contentType: String, auth: SessionManager.Auth) -> HTTPResponse {
        HTTPResponse(status: status, body: body, contentType: contentType,
                     setCookies: [
                        cookie("SessionToken", auth.access, maxAge: 3600),
                        cookie("RefreshToken", auth.refresh, maxAge: 86_400)
                     ])
    }

    private func cookie(_ name: String, _ value: String, maxAge: Int) -> String {
        "\(name)=\(value); HttpOnly; SameSite=Lax; Path=/; Max-Age=\(maxAge)"
    }

    private func launchReaper() {
        let environment = ProcessInfo.processInfo.environment
        let exeDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "kraken")
            .deletingLastPathComponent().path
        let reaperPath = environment["KRAKEN_REAPER"] ?? (exeDir + "/kraken-reaper")
        guard FileManager.default.isExecutableFile(atPath: reaperPath) else {
            fputs("Kraken: reaper not found at \(reaperPath); idle sessions will not be reaped\n", stderr)
            return
        }
        var childEnv = environment
        childEnv["KRAKEN_SESSIONS_DIR"] = config.sessionsRoot.path
        childEnv["KRAKEN_SESSION_TIMEOUT"] = String(Int(config.sessionTimeout))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: reaperPath)
        process.environment = childEnv
        do {
            try process.run()
            reaperProcess = process
            print("Kraken: reaper started (\(reaperPath))")
        } catch {
            fputs("Kraken: failed to launch reaper: \(error)\n", stderr)
        }
    }
}

private let singleUserBusyHTML = """
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Kraken</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#161616;color:#f4f4f4;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center}
div{border-left:3px solid #fa4d56;padding:16px 20px;background:#262626;max-width:80%}</style></head>
<body><div>Kraken is running in single-user mode and is already in use by another client.</div></body></html>
"""
