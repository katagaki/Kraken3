import Foundation

final class BrowserSession {

    private final class HeadlessTab {
        let targetId: String
        var sessionId: String?
        var title = ""
        var url = ""
        var loading = false
        var canGoBack = false
        var canGoForward = false
        var navError: [String: String]?
        var mainFrameId: String?
        var lastGoodURL: String?
        var escaping = false

        var hideFrames: Bool { navError != nil || escaping }

        init(targetId: String) { self.targetId = targetId }
    }

    // Serializes all session state; CDP events, control messages, and the
    // downloads store all run on it so nothing here needs the main queue.
    private let queue = DispatchQueue(label: "kraken.session")
    private let cdp: CDPConnection
    private let downloads: HeadlessDownloads
    private let homepage: String
    private let acceptLanguage: String
    private let maxTabs: Int
    private var paused = false

    var onState: (([String: Any]) -> Void)?
    var onDownloads: (([String: Any]) -> Void)?
    var onFrame: ((Data) -> Void)?
    var onPicker: (([String: Any]) -> Void)?
    var onCopyText: (([String: Any]) -> Void)?
    var onTabsPersist: (([String], Int) -> Void)?
    var onProcessExit: (() -> Void)?

    private var tabs: [HeadlessTab] = []
    private var activeTabID: String?
    private var discoveryStarted = false
    private let restoreTabs: [String]
    private let restoreActiveIndex: Int
    private var lastTabsKey = ""

    private var frameOwner: [String: String] = [:]
    private var pickerSession: String?

    private var viewportWidth: Double = 1280
    private var viewportHeight: Double = 800
    private var devicePixelRatio: Double = 1
    private var colorScheme = "light"
    private let streamer = FrameStreamer()

    private static let desktopUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"
    private static let mobileUserAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"

    private var isMobileViewport: Bool { min(viewportWidth, viewportHeight) <= 700 }
    private var currentUserAgent: String { isMobileViewport ? Self.mobileUserAgent : Self.desktopUserAgent }
    // Integer scale keeps screencast and captureScreenshot dimensions identical,
    // which partial-frame compositing on the client relies on.
    private var snapshotScale: Double { min(max(devicePixelRatio.rounded(), 1), 2) }
    private var activeTab: HeadlessTab? { tabs.first { $0.targetId == activeTabID } }

    var processID: pid_t { cdp.processID }

    init(chromiumPath: String, homepage: String, profileDir: URL, downloadsDir: URL,
         acceptLanguage rawAcceptLanguage: String?,
         extraArguments: [String] = [], maxTabs: Int = 8,
         restoreTabs: [String] = [], restoreActiveIndex: Int = 0) throws {
        self.homepage = homepage
        self.maxTabs = max(maxTabs, 1)
        self.restoreTabs = restoreTabs
        self.restoreActiveIndex = restoreActiveIndex
        let trimmed = rawAcceptLanguage?.trimmingCharacters(in: .whitespaces)
        let value = (trimmed?.isEmpty == false) ? trimmed! : "en-US,en"
        self.acceptLanguage = value
        self.downloads = HeadlessDownloads(directory: downloadsDir, queue: queue)

        cdp = try CDPConnection(chromiumPath: chromiumPath, arguments: [
            "--headless=new",
            "--remote-debugging-pipe",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-crash-reporter",
            "--hide-scrollbars",
            "--mute-audio",
            "--user-data-dir=\(profileDir.path)",
            "--window-size=1280,800"
        ] + extraArguments + [
            "about:blank"
        ], queue: queue)

        cdp.onEvent = { [weak self] method, params, sessionId in
            self?.handleEvent(method, params, sessionId)
        }
        cdp.onExit = { [weak self] status in
            fputs("Kraken: a session's Chromium exited (status \(status))\n", stderr)
            self?.onProcessExit?()
        }

        downloads.onChange = { [weak self] in self?.broadcastDownloads() }

        streamer.onSend = { [weak self] data in self?.onFrame?(data) }
        streamer.onScreencastConfigChange = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.paused, let tab = self.activeTab, let sessionId = tab.sessionId else { return }
                self.cdp.send("Page.stopScreencast", sessionId: sessionId)
                self.startScreencast(tab)
            }
        }

        cdp.send("Browser.setDownloadBehavior", [
            "behavior": "allowAndName",
            "downloadPath": downloadsDir.path,
            "eventsEnabled": true
        ])
        cdp.send("Target.getTargets") { [weak self] result in
            guard let self else { return }
            let infos = result["targetInfos"] as? [[String: Any]] ?? []
            let initialPage = infos.first { ($0["type"] as? String) == "page" }
                .flatMap { $0["targetId"] as? String }

            // The active tab is restored last so it ends up on top after discovery adoption.
            var restoreList = self.restoreTabs.filter { !$0.isEmpty && $0 != "about:blank" }
            if self.restoreTabs.indices.contains(self.restoreActiveIndex) {
                let activeURL = self.restoreTabs[self.restoreActiveIndex]
                if let index = restoreList.firstIndex(of: activeURL) {
                    restoreList.append(restoreList.remove(at: index))
                }
            }

            if let targetId = initialPage {
                self.adoptTarget(targetId, activate: true,
                                 navigateTo: restoreList.first ?? self.homepage)
            } else if restoreList.isEmpty {
                self.newTab()
            }
            self.cdp.send("Target.setDiscoverTargets", ["discover": true])
            self.discoveryStarted = true
            for url in restoreList.dropFirst(initialPage == nil ? 0 : 1) {
                self.cdp.send("Target.createTarget", ["url": url])
            }
        }
    }

    func syncNewClient() {
        queue.async {
            let wasPaused = self.paused
            self.paused = false
            if wasPaused, let tab = self.activeTab {
                self.startScreencast(tab)
            }
            self.broadcastState()
            self.broadcastDownloads()
            self.streamer.syncClient()
        }
    }

    func clientsGone() {
        queue.async {
            guard !self.paused else { return }
            self.paused = true
            if let sessionId = self.activeTab?.sessionId {
                self.cdp.send("Page.stopScreencast", sessionId: sessionId)
            }
        }
    }

    func shutdown() {
        cdp.terminate()
    }

    func entries() -> [DownloadEntry] { queue.sync { downloads.entries() } }
    func fileURL(named name: String) -> URL? { queue.sync { downloads.fileURL(named: name) } }
    func deleteFile(named name: String) -> Bool { queue.sync { downloads.deleteFile(named: name) } }

    private func newTab() {
        guard tabs.count < maxTabs,
              let url = Navigation.destinationURL(for: homepage) else { return }
        cdp.send("Target.createTarget", ["url": url.absoluteString])
    }

    private func adoptTarget(_ targetId: String, activate: Bool, navigateTo: String?) {
        guard !tabs.contains(where: { $0.targetId == targetId }) else { return }
        guard tabs.count < maxTabs else {
            cdp.send("Target.closeTarget", ["targetId": targetId])
            return
        }
        let tab = HeadlessTab(targetId: targetId)
        tabs.append(tab)
        if activate || activeTabID == nil {
            activeTabID = tab.targetId
            streamer.reset()
        }
        cdp.send("Target.attachToTarget", ["targetId": targetId, "flatten": true]) { [weak self] result in
            guard let self, let sessionId = result["sessionId"] as? String else { return }
            tab.sessionId = sessionId
            self.cdp.send("Page.enable", sessionId: sessionId)
            self.cdp.send("Page.getFrameTree", sessionId: sessionId) { result in
                let frameTree = result["frameTree"] as? [String: Any]
                let frame = frameTree?["frame"] as? [String: Any]
                tab.mainFrameId = frame?["id"] as? String ?? tab.mainFrameId
            }
            self.installPickerHooks(sessionId: sessionId)
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

    private func installPickerHooks(sessionId: String) {
        cdp.send("Fetch.enable", [
            "patterns": [["urlPattern": "*", "resourceType": "Document", "requestStage": "Request"]]
        ], sessionId: sessionId)
        cdp.send("Runtime.enable", sessionId: sessionId)
        cdp.send("Runtime.addBinding", ["name": "__krakenPicker"], sessionId: sessionId)
        cdp.send("Page.addScriptToEvaluateOnNewDocument",
                 ["source": InputScript.source], sessionId: sessionId)
        cdp.send("Runtime.evaluate", ["expression": InputScript.source], sessionId: sessionId)
        cdp.send("Target.setAutoAttach",
                 ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true],
                 sessionId: sessionId)
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
        streamer.reset()
        cdp.send("Target.activateTarget", ["targetId": id])
        startScreencast(tab)
        broadcastState()
    }

    private func configureSession(_ tab: HeadlessTab, reload: Bool) {
        guard let sessionId = tab.sessionId else { return }
        cdp.send("Emulation.setDeviceMetricsOverride", [
            "width": Int(viewportWidth),
            "height": Int(viewportHeight),
            "deviceScaleFactor": snapshotScale,
            "mobile": isMobileViewport
        ], sessionId: sessionId)
        cdp.send("Emulation.setUserAgentOverride",
                 ["userAgent": currentUserAgent, "acceptLanguage": acceptLanguage], sessionId: sessionId)
        applyColorScheme(tab)
        if reload {
            cdp.send("Page.reload", sessionId: sessionId)
        }
    }

    private func applyColorScheme(_ tab: HeadlessTab) {
        guard let sessionId = tab.sessionId else { return }
        cdp.send("Emulation.setEmulatedMedia",
                 ["media": "", "features": [["name": "prefers-color-scheme", "value": colorScheme]]],
                 sessionId: sessionId)
    }

    private func startScreencast(_ tab: HeadlessTab) {
        guard !paused, let sessionId = tab.sessionId else { return }
        cdp.send("Page.startScreencast", [
            "format": streamer.screencastFormat,
            "quality": streamer.screencastQuality,
            "maxWidth": Int(viewportWidth * snapshotScale),
            "maxHeight": Int(viewportHeight * snapshotScale),
            "everyNthFrame": 1
        ], sessionId: sessionId)
    }

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
                streamer.reset()
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
            guard let tab = activeTab, sessionId == tab.sessionId,
                  !tab.hideFrames,
                  let base64 = params["data"] as? String,
                  let frame = Data(base64Encoded: base64) else { return }
            streamer.ingest(frame)

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

        case "Page.frameNavigated":
            guard let tab = tabs.first(where: { $0.sessionId == sessionId }),
                  let frame = params["frame"] as? [String: Any],
                  frame["parentId"] == nil else { return }
            tab.mainFrameId = frame["id"] as? String ?? tab.mainFrameId
            fputs("KDBG frameNavigated url=\(frame["url"] as? String ?? "") unreachable=\(frame["unreachableUrl"] as? String ?? "-") escaping=\(tab.escaping) navError=\(tab.navError?["url"] ?? "-")\n", stderr)
            if let unreachable = frame["unreachableUrl"] as? String, !unreachable.isEmpty {
                if tab.navError == nil {
                    tab.navError = ["url": unreachable, "code": ""]
                }
                tab.escaping = false
                escapeErrorPage(tab, failedURL: unreachable)
            } else if tab.escaping {
                tab.escaping = false
            } else {
                tab.navError = nil
            }
            broadcastState()

        case "Fetch.requestPaused":
            guard let sessionId, let requestId = params["requestId"] as? String else { return }
            let urlString = (params["request"] as? [String: Any])?["url"] as? String ?? ""
            let frameId = params["frameId"] as? String
            let rootSession = frameOwner[sessionId] ?? sessionId
            let tab = tabs.first { $0.sessionId == rootSession }
            guard let url = URL(string: urlString) else {
                cdp.send("Fetch.failRequest",
                         ["requestId": requestId, "errorReason": "BlockedByClient"],
                         sessionId: sessionId)
                return
            }
            URLFilter.evaluateURL(url) { [weak self] verdict in
                guard let self else { return }
                self.queue.async {
                    let isMainFrame = tab != nil && frameId != nil && frameId == tab?.mainFrameId
                    switch verdict {
                    case .allowed:
                        self.cdp.send("Fetch.continueRequest", ["requestId": requestId],
                                      sessionId: sessionId)
                    case .unresolvable:
                        if isMainFrame, let tab {
                            self.setNavError(tab, url: urlString, code: "ERR_NAME_NOT_RESOLVED")
                        }
                        self.cdp.send("Fetch.continueRequest", ["requestId": requestId],
                                      sessionId: sessionId)
                    case .blocked, .invalid:
                        if isMainFrame, let tab {
                            self.setNavError(tab, url: urlString, code: "BLOCKED")
                        }
                        self.cdp.send("Fetch.failRequest",
                                      ["requestId": requestId, "errorReason": "BlockedByClient"],
                                      sessionId: sessionId)
                    }
                }
            }

        case "Target.attachedToTarget":
            guard let childSession = params["sessionId"] as? String,
                  let info = params["targetInfo"] as? [String: Any],
                  (info["type"] as? String) == "iframe" else { return }
            let root = sessionId.flatMap { frameOwner[$0] } ?? sessionId
            frameOwner[childSession] = root
            cdp.send("Page.enable", sessionId: childSession)
            installPickerHooks(sessionId: childSession)

        case "Target.detachedFromTarget":
            if let childSession = params["sessionId"] as? String {
                frameOwner.removeValue(forKey: childSession)
            }

        case "Runtime.bindingCalled":
            guard let sessionId, isActiveTabSession(sessionId),
                  (params["name"] as? String) == "__krakenPicker",
                  let payload = params["payload"] as? String,
                  let data = payload.data(using: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            pickerSession = sessionId
            object["type"] = "picker"
            onPicker?(object)

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

    private func broadcastState() {
        let active = activeTab
        let tabList: [[String: Any]] = tabs.map { tab in
            ["id": tab.targetId,
             "title": tab.title,
             "url": tab.url,
             "active": tab.targetId == activeTabID]
        }
        var state: [String: Any] = [
            "type": "state",
            "url": active?.url ?? "",
            "title": active?.title ?? "",
            "loading": active?.loading ?? false,
            "progress": (active?.loading ?? false) ? 0.7 : 1,
            "canGoBack": active?.canGoBack ?? false,
            "canGoForward": active?.canGoForward ?? false,
            "tabs": tabList
        ]
        if let navError = active?.navError {
            state["navError"] = navError
        }
        onState?(state)

        let urls = tabs.map(\.url)
        let activeIndex = tabs.firstIndex { $0.targetId == activeTabID } ?? 0
        let key = urls.joined(separator: "|") + "#\(activeIndex)"
        if key != lastTabsKey {
            lastTabsKey = key
            onTabsPersist?(urls, activeIndex)
        }
    }

    private func broadcastDownloads() {
        let items: [[String: Any]] = downloads.entries().map {
            ["id": $0.id, "name": $0.name, "size": $0.size, "received": $0.received,
             "progress": $0.progress, "done": $0.done, "failed": $0.failed]
        }
        onDownloads?(["type": "downloads", "items": items])
    }

    func handleControlMessage(_ message: [String: Any]) {
        queue.async { self.processControlMessage(message) }
    }

    private func processControlMessage(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "frameack":
            if let seq = doubleValue(message["seq"]) {
                streamer.ack(Int(seq))
            }
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
        case "dragstart":
            if let x = doubleValue(message["x"]), let y = doubleValue(message["y"]) {
                sendMouse("mousePressed", normalizedX: x, normalizedY: y, buttons: 1, clickCount: 1)
            }
        case "dragmove":
            if let x = doubleValue(message["x"]), let y = doubleValue(message["y"]) {
                sendMouse("mouseMoved", normalizedX: x, normalizedY: y, buttons: 1, clickCount: 0)
            }
        case "dragend":
            if let x = doubleValue(message["x"]), let y = doubleValue(message["y"]) {
                sendMouse("mouseReleased", normalizedX: x, normalizedY: y, buttons: 0, clickCount: 1)
            }
        case "key":
            if let key = message["key"] as? String {
                injectKey(key)
            }
        case "text":
            if let value = message["value"] as? String, let sessionId = activeTab?.sessionId {
                cdp.send("Input.insertText", ["text": value], sessionId: sessionId)
            }
        case "copytext":
            if let x = doubleValue(message["x"]), let y = doubleValue(message["y"]),
               let sessionId = activeTab?.sessionId {
                cdp.send("Runtime.evaluate", [
                    "expression": "window.__kraken ? window.__kraken.textAt(\(x), \(y)) : ''",
                    "returnByValue": true
                ], sessionId: sessionId) { [weak self] result in
                    let value = ((result["result"] as? [String: Any])?["value"] as? String) ?? ""
                    self?.onCopyText?(["type": "copytext", "text": value])
                }
            }
        case "pickresult":
            var payload = message
            payload.removeValue(forKey: "type")
            let target = pickerSession ?? activeTab?.sessionId
            pickerSession = nil
            if let target {
                callHelper("setPicker", [payload], sessionId: target)
            }
        case "viewport":
            if let width = doubleValue(message["width"]), let height = doubleValue(message["height"]) {
                applyViewport(width: width, height: height,
                              devicePixelRatio: doubleValue(message["dpr"]) ?? 1)
            }
        case "colorscheme":
            if let value = message["value"] as? String, value == "dark" || value == "light" {
                colorScheme = value
                for tab in tabs { applyColorScheme(tab) }
            }
        case "navigate":
            if let raw = message["url"] as? String, let tabID = activeTabID {
                URLFilter.evaluate(raw) { [weak self] verdict in
                    guard let self else { return }
                    self.queue.async {
                        guard let tab = self.tabs.first(where: { $0.targetId == tabID }) else { return }
                        switch verdict {
                        case .allowed(let url):
                            tab.navError = nil
                            if let sessionId = tab.sessionId {
                                self.navigate(tab, to: url, sessionId: sessionId)
                            }
                        case .unresolvable(let url):
                            self.setNavError(tab, url: url.absoluteString, code: "ERR_NAME_NOT_RESOLVED")
                        case .blocked(let url):
                            self.setNavError(tab, url: url.absoluteString, code: "BLOCKED")
                        case .invalid:
                            break
                        }
                    }
                }
            }
        case "dismisserror":
            if let tab = activeTab, tab.navError != nil {
                tab.navError = nil
                broadcastState()
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
            clearNavError()
            evaluate("history.back()")
        case "forward":
            clearNavError()
            evaluate("history.forward()")
        case "reload":
            if let tab = activeTab, let sessionId = tab.sessionId {
                clearNavError()
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

    private func navigate(_ tab: HeadlessTab, to url: URL, sessionId: String) {
        cdp.send("Page.navigate", ["url": url.absoluteString], sessionId: sessionId) { [weak self] result in
            guard let self,
                  let errorText = result["errorText"] as? String, !errorText.isEmpty,
                  errorText != "net::ERR_ABORTED" else { return }
            let code = errorText.hasPrefix("net::") ? String(errorText.dropFirst(5)) : errorText
            self.setNavError(tab, url: url.absoluteString, code: code)
        }
    }

    private func setNavError(_ tab: HeadlessTab, url: String, code: String) {
        tab.navError = ["url": url, "code": code]
        broadcastState()
    }

    private func escapeErrorPage(_ tab: HeadlessTab, failedURL: String) {
        guard let sessionId = tab.sessionId, !tab.escaping else { return }
        tab.escaping = true
        cdp.send("Page.getNavigationHistory", sessionId: sessionId) { [weak self] result in
            guard let self else { return }
            if let index = result["currentIndex"] as? Int,
               let entries = result["entries"] as? [[String: Any]] {
                fputs("KDBG escape failed=\(failedURL) index=\(index) entries=\(entries.map { $0["url"] as? String ?? "?" })\n", stderr)
                var target = index
                while entries.indices.contains(target),
                      (entries[target]["url"] as? String) == failedURL { target -= 1 }
                if entries.indices.contains(target),
                   let entryId = entries[target]["id"] as? Int {
                    fputs("KDBG escape -> entry \(target) \(entries[target]["url"] as? String ?? "?")\n", stderr)
                    self.cdp.send("Page.navigateToHistoryEntry", ["entryId": entryId],
                                  sessionId: sessionId)
                    return
                }
            }
            fputs("KDBG escape -> about:blank fallback\n", stderr)
            self.cdp.send("Page.navigate", ["url": "about:blank"], sessionId: sessionId)
        }
    }

    private func clearNavError() {
        guard let tab = activeTab, tab.navError != nil else { return }
        tab.navError = nil
        broadcastState()
    }

    private func applyViewport(width: Double, height: Double, devicePixelRatio: Double) {
        let previousUserAgent = currentUserAgent
        viewportWidth = max(width, 320)
        viewportHeight = max(height, 320)
        self.devicePixelRatio = devicePixelRatio
        let userAgentChanged = currentUserAgent != previousUserAgent
        for tab in tabs {
            configureSession(tab, reload: userAgentChanged)
        }
        streamer.setExpectedDims([
            (Int(viewportWidth), Int(viewportHeight)),
            (Int(viewportWidth * snapshotScale), Int(viewportHeight * snapshotScale))
        ])
        streamer.reset()
        if let tab = activeTab, let sessionId = tab.sessionId {
            cdp.send("Page.stopScreencast", sessionId: sessionId)
            startScreencast(tab)
        }
    }

    private func injectTap(normalizedX: Double, normalizedY: Double) {
        sendMouse("mousePressed", normalizedX: normalizedX, normalizedY: normalizedY, buttons: 1, clickCount: 1)
        sendMouse("mouseReleased", normalizedX: normalizedX, normalizedY: normalizedY, buttons: 0, clickCount: 1)
    }

    private func sendMouse(_ type: String, normalizedX: Double, normalizedY: Double,
                           buttons: Int, clickCount: Int) {
        guard let sessionId = activeTab?.sessionId else { return }
        var params: [String: Any] = [
            "type": type,
            "x": min(max(normalizedX, 0), 1) * viewportWidth,
            "y": min(max(normalizedY, 0), 1) * viewportHeight,
            "button": "left",
            "buttons": buttons
        ]
        if clickCount > 0 { params["clickCount"] = clickCount }
        cdp.send("Input.dispatchMouseEvent", params, sessionId: sessionId)
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
        guard let sessionId = activeTab?.sessionId else { return }
        callHelper(function, arguments, sessionId: sessionId)
    }

    private func callHelper(_ function: String, _ arguments: [Any], sessionId: String) {
        guard let argsData = try? JSONSerialization.data(withJSONObject: arguments),
              let args = String(data: argsData, encoding: .utf8) else { return }
        cdp.send("Runtime.evaluate",
                 ["expression": "window.__kraken && window.__kraken.\(function).apply(null, \(args));"],
                 sessionId: sessionId)
    }

    private func isActiveTabSession(_ session: String) -> Bool {
        guard let active = activeTab?.sessionId else { return false }
        return session == active || frameOwner[session] == active
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

}
