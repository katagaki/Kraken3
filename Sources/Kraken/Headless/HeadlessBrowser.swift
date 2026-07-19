import Foundation

final class HeadlessBrowser {

    private final class HeadlessTab {
        let targetId: String
        var sessionId: String?
        var title = ""
        var url = ""
        var loading = false
        var canGoBack = false
        var canGoForward = false

        init(targetId: String) { self.targetId = targetId }
    }

    private let cdp: CDPConnection
    private let httpServer = HeadlessHTTPServer()
    private let socketServer = HeadlessWebSocketServer()
    private let downloads = HeadlessDownloads()
    private let homepage: String

    private var tabs: [HeadlessTab] = []
    private var activeTabID: String?
    private var discoveryStarted = false

    private var viewportWidth: Double = 1280
    private var viewportHeight: Double = 800
    private var devicePixelRatio: Double = 1
    private var lastFrame: Data?

    private static let desktopUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private static let mobileUserAgent = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"

    // Judge by the smaller dimension so rotating a phone to landscape doesn't
    // flip the user agent to desktop and force a reload of every tab.
    private var isMobileViewport: Bool { min(viewportWidth, viewportHeight) <= 700 }
    private var currentUserAgent: String { isMobileViewport ? Self.mobileUserAgent : Self.desktopUserAgent }
    private var snapshotScale: Double { min(max(devicePixelRatio, 1), 2) }
    private var activeTab: HeadlessTab? { tabs.first { $0.targetId == activeTabID } }

    init(chromiumPath: String, homepage: String, httpPort: UInt16, wsPort: UInt16) throws {
        self.homepage = homepage

        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("kraken-chromium").path
        cdp = try CDPConnection(chromiumPath: chromiumPath, arguments: [
            "--headless",
            "--remote-debugging-pipe",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-crash-reporter",
            "--hide-scrollbars",
            "--mute-audio",
            "--user-data-dir=\(profile)",
            "--window-size=1280,800",
            "about:blank"
        ])

        cdp.onEvent = { [weak self] method, params, sessionId in
            self?.handleEvent(method, params, sessionId)
        }
        cdp.onExit = { status in
            fputs("Kraken: Chromium exited (status \(status)), shutting down\n", stderr)
            exit(1)
        }

        downloads.onChange = { [weak self] in self?.broadcastDownloads() }

        httpServer.entriesProvider = { [weak self] in self?.downloads.entries() ?? [] }
        httpServer.fileURLProvider = { [weak self] name in self?.downloads.fileURL(named: name) }
        httpServer.deleteHandler = { [weak self] name in self?.downloads.deleteFile(named: name) ?? false }

        socketServer.onMessage = { [weak self] message in self?.handleControlMessage(message) }
        socketServer.onClientConnected = { [weak self] in
            guard let self else { return }
            self.broadcastState()
            self.broadcastDownloads()
            if let frame = self.lastFrame {
                self.socketServer.broadcastFrame(frame)
            }
        }

        try httpServer.start(port: httpPort)
        try socketServer.start(port: wsPort)

        cdp.send("Browser.setDownloadBehavior", [
            "behavior": "allowAndName",
            "downloadPath": Paths.downloadsDirectory.path,
            "eventsEnabled": true
        ])
        cdp.send("Target.getTargets") { [weak self] result in
            guard let self else { return }
            let infos = result["targetInfos"] as? [[String: Any]] ?? []
            if let page = infos.first(where: { ($0["type"] as? String) == "page" }),
               let targetId = page["targetId"] as? String {
                self.adoptTarget(targetId, activate: true, navigateTo: self.homepage)
            } else {
                self.newTab()
            }
            self.cdp.send("Target.setDiscoverTargets", ["discover": true])
            self.discoveryStarted = true
        }
    }

    // MARK: - Tabs

    private func newTab() {
        guard let url = Navigation.destinationURL(for: homepage) else { return }
        cdp.send("Target.createTarget", ["url": url.absoluteString])
    }

    private func adoptTarget(_ targetId: String, activate: Bool, navigateTo: String?) {
        guard !tabs.contains(where: { $0.targetId == targetId }) else { return }
        let tab = HeadlessTab(targetId: targetId)
        tabs.append(tab)
        if activate || activeTabID == nil {
            activeTabID = tab.targetId
            lastFrame = nil
        }
        cdp.send("Target.attachToTarget", ["targetId": targetId, "flatten": true]) { [weak self] result in
            guard let self, let sessionId = result["sessionId"] as? String else { return }
            tab.sessionId = sessionId
            self.cdp.send("Page.enable", sessionId: sessionId)
            self.cdp.send("Page.addScriptToEvaluateOnNewDocument",
                          ["source": InputScript.source], sessionId: sessionId)
            self.configureSession(tab, reload: false)
            if let destination = navigateTo, let url = Navigation.destinationURL(for: destination) {
                self.cdp.send("Page.navigate", ["url": url.absoluteString], sessionId: sessionId)
            }
            if tab.targetId == self.activeTabID {
                self.startScreencast(tab)
            }
            self.broadcastState()
        }
        broadcastState()
    }

    private func closeTab(id: String) {
        guard tabs.contains(where: { $0.targetId == id }) else { return }
        cdp.send("Target.closeTarget", ["targetId": id])
    }

    private func switchTab(id: String) {
        guard id != activeTabID, let tab = tabs.first(where: { $0.targetId == id }) else { return }
        if let old = activeTab, let oldSession = old.sessionId {
            cdp.send("Page.stopScreencast", sessionId: oldSession)
        }
        activeTabID = id
        lastFrame = nil
        cdp.send("Target.activateTarget", ["targetId": id])
        startScreencast(tab)
        broadcastState()
    }

    // MARK: - Session configuration

    private func configureSession(_ tab: HeadlessTab, reload: Bool) {
        guard let sessionId = tab.sessionId else { return }
        cdp.send("Emulation.setDeviceMetricsOverride", [
            "width": Int(viewportWidth),
            "height": Int(viewportHeight),
            "deviceScaleFactor": snapshotScale,
            "mobile": isMobileViewport
        ], sessionId: sessionId)
        cdp.send("Emulation.setUserAgentOverride", ["userAgent": currentUserAgent], sessionId: sessionId)
        if reload {
            cdp.send("Page.reload", sessionId: sessionId)
        }
    }

    private func startScreencast(_ tab: HeadlessTab) {
        guard let sessionId = tab.sessionId else { return }
        let maxDimension = 2048.0
        cdp.send("Page.startScreencast", [
            "format": "jpeg",
            "quality": 60,
            "maxWidth": Int(min(viewportWidth * snapshotScale, maxDimension)),
            "maxHeight": Int(min(viewportHeight * snapshotScale, maxDimension)),
            "everyNthFrame": 1
        ], sessionId: sessionId)
    }

    // MARK: - CDP events

    private func handleEvent(_ method: String, _ params: [String: Any], _ sessionId: String?) {
        switch method {
        case "Target.targetCreated":
            guard discoveryStarted,
                  let info = params["targetInfo"] as? [String: Any],
                  (info["type"] as? String) == "page",
                  let targetId = info["targetId"] as? String,
                  !(info["url"] as? String ?? "").hasPrefix("devtools://") else { return }
            adoptTarget(targetId, activate: true, navigateTo: nil)

        case "Target.targetInfoChanged":
            guard let info = params["targetInfo"] as? [String: Any],
                  let targetId = info["targetId"] as? String,
                  let tab = tabs.first(where: { $0.targetId == targetId }) else { return }
            tab.title = info["title"] as? String ?? tab.title
            tab.url = info["url"] as? String ?? tab.url
            broadcastState()

        case "Target.targetDestroyed":
            guard let targetId = params["targetId"] as? String,
                  let index = tabs.firstIndex(where: { $0.targetId == targetId }) else { return }
            tabs.remove(at: index)
            if activeTabID == targetId {
                activeTabID = tabs.indices.contains(index) ? tabs[index].targetId : tabs.last?.targetId
                lastFrame = nil
                if let tab = activeTab { startScreencast(tab) }
            }
            if tabs.isEmpty {
                newTab()
            } else {
                broadcastState()
            }

        case "Page.screencastFrame":
            guard let sessionId else { return }
            if let ackId = params["sessionId"] as? Int {
                cdp.send("Page.screencastFrameAck", ["sessionId": ackId], sessionId: sessionId)
            }
            guard sessionId == activeTab?.sessionId,
                  let base64 = params["data"] as? String,
                  let jpeg = Data(base64Encoded: base64),
                  jpeg != lastFrame else { return }
            lastFrame = jpeg
            socketServer.broadcastFrame(jpeg)

        case "Page.frameStartedLoading":
            guard let tab = tabs.first(where: { $0.sessionId == sessionId }) else { return }
            tab.loading = true
            broadcastState()

        case "Page.frameStoppedLoading":
            guard let tab = tabs.first(where: { $0.sessionId == sessionId }),
                  let sessionId else { return }
            tab.loading = false
            cdp.send("Page.getNavigationHistory", sessionId: sessionId) { [weak self] result in
                if let index = result["currentIndex"] as? Int,
                   let entries = result["entries"] as? [[String: Any]] {
                    tab.canGoBack = index > 0
                    tab.canGoForward = index < entries.count - 1
                }
                self?.broadcastState()
            }

        case "Browser.downloadWillBegin":
            guard let guid = params["guid"] as? String else { return }
            downloads.handleWillBegin(guid: guid,
                                      suggestedFilename: params["suggestedFilename"] as? String ?? "")

        case "Browser.downloadProgress":
            guard let guid = params["guid"] as? String else { return }
            downloads.handleProgress(guid: guid,
                                     total: Int64(doubleValue(params["totalBytes"]) ?? 0),
                                     received: Int64(doubleValue(params["receivedBytes"]) ?? 0),
                                     state: params["state"] as? String ?? "inProgress")

        default:
            break
        }
    }

    // MARK: - State broadcasts

    private func broadcastState() {
        let active = activeTab
        let tabList: [[String: Any]] = tabs.map { tab in
            ["id": tab.targetId,
             "title": tab.title,
             "url": tab.url,
             "active": tab.targetId == activeTabID]
        }
        socketServer.broadcastJSON([
            "type": "state",
            "url": active?.url ?? "",
            "title": active?.title ?? "",
            "loading": active?.loading ?? false,
            "progress": (active?.loading ?? false) ? 0.7 : 1,
            "canGoBack": active?.canGoBack ?? false,
            "canGoForward": active?.canGoForward ?? false,
            "tabs": tabList
        ])
    }

    private func broadcastDownloads() {
        let items: [[String: Any]] = downloads.entries().map {
            ["id": $0.id, "name": $0.name, "size": $0.size, "received": $0.received,
             "progress": $0.progress, "done": $0.done, "failed": $0.failed]
        }
        socketServer.broadcastJSON(["type": "downloads", "items": items])
    }

    // MARK: - Control messages

    private func handleControlMessage(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "tap":
            if let x = doubleValue(message["x"]), let y = doubleValue(message["y"]) {
                injectTap(normalizedX: x, normalizedY: y)
            }
        case "scroll":
            if let dx = doubleValue(message["dx"]), let dy = doubleValue(message["dy"]) {
                callHelper("scroll", [dx * viewportWidth,
                                      dy * viewportHeight,
                                      doubleValue(message["x"]) ?? -1,
                                      doubleValue(message["y"]) ?? -1])
            }
        case "key":
            if let key = message["key"] as? String {
                injectKey(key)
            }
        case "text":
            if let value = message["value"] as? String, let sessionId = activeTab?.sessionId {
                cdp.send("Input.insertText", ["text": value], sessionId: sessionId)
            }
        case "viewport":
            if let width = doubleValue(message["width"]), let height = doubleValue(message["height"]) {
                applyViewport(width: width, height: height,
                              devicePixelRatio: doubleValue(message["dpr"]) ?? 1)
            }
        case "navigate":
            if let raw = message["url"] as? String,
               let url = Navigation.destinationURL(for: raw),
               let sessionId = activeTab?.sessionId {
                cdp.send("Page.navigate", ["url": url.absoluteString], sessionId: sessionId)
            }
        case "newtab":
            newTab()
        case "closetab":
            if let id = message["id"] as? String {
                closeTab(id: id)
            }
        case "switchtab":
            if let id = message["id"] as? String {
                switchTab(id: id)
            }
        case "back":
            evaluate("history.back()")
        case "forward":
            evaluate("history.forward()")
        case "reload":
            if let sessionId = activeTab?.sessionId {
                cdp.send("Page.reload", sessionId: sessionId)
            }
        case "stop":
            if let sessionId = activeTab?.sessionId {
                cdp.send("Page.stopLoading", sessionId: sessionId)
            }
        default:
            break
        }
    }

    private func applyViewport(width: Double, height: Double, devicePixelRatio: Double) {
        let previousUserAgent = currentUserAgent
        viewportWidth = min(max(width, 320), 1600)
        viewportHeight = min(max(height, 320), 1600)
        self.devicePixelRatio = devicePixelRatio
        let userAgentChanged = currentUserAgent != previousUserAgent
        for tab in tabs {
            configureSession(tab, reload: userAgentChanged)
        }
        lastFrame = nil
        if let tab = activeTab, let sessionId = tab.sessionId {
            cdp.send("Page.stopScreencast", sessionId: sessionId)
            startScreencast(tab)
        }
    }

    // MARK: - Input

    private func injectTap(normalizedX: Double, normalizedY: Double) {
        guard let sessionId = activeTab?.sessionId else { return }
        let x = normalizedX * viewportWidth
        let y = normalizedY * viewportHeight
        cdp.send("Input.dispatchMouseEvent", [
            "type": "mousePressed", "x": x, "y": y,
            "button": "left", "buttons": 1, "clickCount": 1
        ], sessionId: sessionId)
        cdp.send("Input.dispatchMouseEvent", [
            "type": "mouseReleased", "x": x, "y": y,
            "button": "left", "buttons": 0, "clickCount": 1
        ], sessionId: sessionId)
    }

    private func injectKey(_ key: String) {
        guard let sessionId = activeTab?.sessionId else { return }
        let specials: [String: (vk: Int, text: String?)] = [
            "Enter": (13, "\r"), "Backspace": (8, nil), "Tab": (9, nil), "Escape": (27, nil),
            "ArrowLeft": (37, nil), "ArrowUp": (38, nil), "ArrowRight": (39, nil), "ArrowDown": (40, nil)
        ]
        if let special = specials[key] {
            var down: [String: Any] = [
                "type": "keyDown", "key": key, "code": key,
                "windowsVirtualKeyCode": special.vk, "nativeVirtualKeyCode": special.vk
            ]
            if let text = special.text {
                down["text"] = text
                down["unmodifiedText"] = text
            }
            cdp.send("Input.dispatchKeyEvent", down, sessionId: sessionId)
            cdp.send("Input.dispatchKeyEvent", [
                "type": "keyUp", "key": key, "code": key,
                "windowsVirtualKeyCode": special.vk
            ], sessionId: sessionId)
        } else if key.count == 1 {
            cdp.send("Input.dispatchKeyEvent", [
                "type": "keyDown", "key": key, "text": key, "unmodifiedText": key
            ], sessionId: sessionId)
            cdp.send("Input.dispatchKeyEvent", ["type": "keyUp", "key": key], sessionId: sessionId)
        }
    }

    private func evaluate(_ expression: String) {
        guard let sessionId = activeTab?.sessionId else { return }
        cdp.send("Runtime.evaluate", ["expression": expression], sessionId: sessionId)
    }

    private func callHelper(_ function: String, _ arguments: [Any]) {
        guard let argsData = try? JSONSerialization.data(withJSONObject: arguments),
              let args = String(data: argsData, encoding: .utf8) else { return }
        evaluate("window.__kraken && window.__kraken.\(function).apply(null, \(args));")
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}
