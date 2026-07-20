#if os(macOS)
import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var hostWindow: NSWindow!
    private var controlPanel: ControlPanel!

    private let tabManager = TabManager()
    private let downloadManager = DownloadManager()
    private var httpServer: HTTPServer!
    private let socketServer = ControlSocketServer()

    private var frameTimer: Timer?
    private var snapshotInFlight = false
    private var lastFrame: Data?
    private var snapshotWidth: Double = 1024
    private var viewportSize = NSSize(width: 1280, height: 800)

    private let httpPort: UInt16 = 8080
    private let wsPort: UInt16 = 8081

    private static let homepageDefaultsKey = "KrakenHomepage"

    private static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    private static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"

    // Judge by the smaller dimension so rotating a phone to landscape doesn't
    // flip the user agent to desktop and force a reload of every tab.
    private var currentUserAgent: String {
        min(viewportSize.width, viewportSize.height) <= 700 ? Self.mobileUserAgent : Self.desktopUserAgent
    }

    private var homepage: String {
        get { UserDefaults.standard.string(forKey: Self.homepageDefaultsKey) ?? "https://www.startpage.com" }
        set { UserDefaults.standard.set(newValue, forKey: Self.homepageDefaultsKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.ensureDownloadsDirectory()
        setupHostWindow()
        setupTabManager()
        setupControlPanel()
        setupServers()
        startFrameLoop()

        let addresses = Paths.localIPv4Addresses()
        print("Kraken is running.")
        print("Downloads folder: \(Paths.downloadsDirectory.path)")
        for address in addresses {
            print("  Control page: http://\(address):\(httpPort)/")
        }
        if addresses.isEmpty {
            print("  No network interfaces found, control page on http://localhost:\(httpPort)/")
        }

        openHomepageTab()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Setup

    private func setupHostWindow() {
        // Window must be viewport-sized (WebKit only reliably paints what the window
        // backs) but hung mostly offscreen so it's invisible without being throttled.
        hostWindow = NSWindow(contentRect: NSRect(origin: .zero, size: viewportSize),
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        hostWindow.ignoresMouseEvents = true
        hostWindow.isExcludedFromWindowsMenu = true
        hostWindow.backgroundColor = .white
        hostWindow.hasShadow = false
        // Near-zero alpha keeps the window officially visible (so WebKit doesn't
        // throttle rendering) while showing nothing to the admin.
        hostWindow.alphaValue = 0.01
        hostWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        positionHostWindow()
        hostWindow.orderBack(nil)
    }

    private func positionHostWindow() {
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        hostWindow.setFrameOrigin(NSPoint(x: maxX - 2, y: minY))
    }

    private func setupTabManager() {
        tabManager.makeWebView = { [unowned self] configuration in
            makeWebView(configuration: configuration)
        }
        tabManager.onStateChange = { [weak self] in
            self?.broadcastState()
        }
    }

    private func makeWebView(configuration: WKWebViewConfiguration?) -> WKWebView {
        let config: WKWebViewConfiguration
        if let configuration {
            config = configuration
        } else {
            config = WKWebViewConfiguration()
            config.preferences.isElementFullscreenEnabled = true
            let userScript = WKUserScript(source: InputScript.source,
                                          injectionTime: .atDocumentStart,
                                          forMainFrameOnly: false)
            config.userContentController.addUserScript(userScript)
        }

        let webView = WKWebView(frame: NSRect(origin: .zero, size: viewportSize),
                                configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = currentUserAgent
        hostWindow.contentView?.addSubview(webView)
        return webView
    }

    private func setupControlPanel() {
        controlPanel = ControlPanel(downloadManager: downloadManager,
                                    addresses: Paths.localIPv4Addresses(),
                                    httpPort: httpPort,
                                    homepage: homepage)
        controlPanel.onHomepageChange = { [weak self] value in
            self?.homepage = value
        }
        controlPanel.window.makeKeyAndOrderFront(nil)
    }

    private func setupServers() {
        downloadManager.onChange = { [weak self] in
            self?.broadcastDownloads()
            self?.controlPanel?.refresh()
        }

        httpServer = HTTPServer(downloadManager: downloadManager)
        socketServer.onMessage = { [weak self] message in self?.handleControlMessage(message) }
        socketServer.onClientConnected = { [weak self] in
            self?.broadcastState()
            self?.broadcastDownloads()
            self?.lastFrame = nil  // force a fresh frame for the new client
        }

        do {
            try httpServer.start(port: httpPort)
            try socketServer.start(port: wsPort)
        } catch {
            NSLog("Kraken: failed to start servers: \(error)")
            NSApp.terminate(nil)
        }
    }

    // MARK: - Tabs

    @discardableResult
    private func openHomepageTab() -> Tab {
        let tab = tabManager.newTab()
        if let url = URL(string: homepage) {
            tab.webView.load(URLRequest(url: url))
        }
        lastFrame = nil
        return tab
    }

    // MARK: - Screen streaming

    private func startFrameLoop() {
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.captureFrame()
        }
    }

    private func captureFrame() {
        guard socketServer.clientCount > 0, !snapshotInFlight,
              let webView = tabManager.activeWebView else { return }
        snapshotInFlight = true

        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: snapshotWidth)
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotInFlight = false
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.55])
            else { return }
            if jpeg == self.lastFrame { return }  // skip identical frames
            self.lastFrame = jpeg
            self.socketServer.broadcastFrame(jpeg)
        }
    }

    // MARK: - State broadcasts

    private func broadcastState() {
        let active = tabManager.activeWebView
        let tabs: [[String: Any]] = tabManager.tabs.map { tab in
            ["id": tab.id,
             "title": tab.webView.title ?? "",
             "url": tab.webView.url?.absoluteString ?? "",
             "active": tab.id == tabManager.activeTabID]
        }
        socketServer.broadcastJSON([
            "type": "state",
            "url": active?.url?.absoluteString ?? "",
            "title": active?.title ?? "",
            "loading": active?.isLoading ?? false,
            "progress": active?.estimatedProgress ?? 0,
            "canGoBack": active?.canGoBack ?? false,
            "canGoForward": active?.canGoForward ?? false,
            "tabs": tabs
        ])
    }

    private func broadcastDownloads() {
        let entries = downloadManager.entries()
        let items: [[String: Any]] = entries.map {
            ["id": $0.id, "name": $0.name, "size": $0.size, "received": $0.received,
             "progress": $0.progress, "done": $0.done, "failed": $0.failed]
        }
        socketServer.broadcastJSON(["type": "downloads", "items": items])
    }

    // MARK: - Control messages

    private func handleControlMessage(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "tap":
            if let x = message["x"] as? Double, let y = message["y"] as? Double {
                injectClick(normalizedX: x, normalizedY: y)
            }
        case "scroll":
            if let dx = message["dx"] as? Double, let dy = message["dy"] as? Double {
                injectScroll(normalizedDX: dx, normalizedDY: dy,
                             atX: message["x"] as? Double ?? -1,
                             atY: message["y"] as? Double ?? -1)
            }
        case "dragstart":
            if let x = message["x"] as? Double, let y = message["y"] as? Double {
                callHelper("dragStart", [x, y])
            }
        case "dragmove":
            if let x = message["x"] as? Double, let y = message["y"] as? Double {
                callHelper("dragMove", [x, y])
            }
        case "dragend":
            if let x = message["x"] as? Double, let y = message["y"] as? Double {
                callHelper("dragEnd", [x, y])
            }
        case "key":
            if let key = message["key"] as? String {
                injectKey(key)
            }
        case "text":
            if let value = message["value"] as? String {
                injectText(value)
            }
        case "viewport":
            if let width = message["width"] as? Double, let height = message["height"] as? Double {
                let dpr = message["dpr"] as? Double ?? 1
                applyViewport(width: width, height: height, devicePixelRatio: dpr)
            }
        case "navigate":
            if let raw = message["url"] as? String {
                navigate(to: raw)
            }
        case "newtab":
            openHomepageTab()
        case "closetab":
            if let id = message["id"] as? String {
                tabManager.closeTab(id: id)
                if tabManager.tabs.isEmpty {
                    openHomepageTab()
                }
                lastFrame = nil
            }
        case "switchtab":
            if let id = message["id"] as? String {
                tabManager.switchTab(id: id)
                lastFrame = nil
            }
        case "back":
            tabManager.activeWebView?.goBack()
        case "forward":
            tabManager.activeWebView?.goForward()
        case "reload":
            tabManager.activeWebView?.reload()
        case "stop":
            tabManager.activeWebView?.stopLoading()
        default:
            break
        }
    }

    private func applyViewport(width: Double, height: Double, devicePixelRatio: Double) {
        let previousUserAgent = currentUserAgent
        let clampedWidth = min(max(width, 320), 1600)
        let clampedHeight = min(max(height, 320), 1600)
        viewportSize = NSSize(width: clampedWidth, height: clampedHeight)
        hostWindow.setContentSize(viewportSize)
        positionHostWindow()
        for tab in tabManager.tabs {
            tab.webView.frame = NSRect(origin: .zero, size: viewportSize)
        }
        if currentUserAgent != previousUserAgent {
            for tab in tabManager.tabs {
                tab.webView.customUserAgent = currentUserAgent
                if tab.webView.url != nil {
                    tab.webView.reload()
                }
            }
        }
        snapshotWidth = min(clampedWidth * min(max(devicePixelRatio, 1), 2), 2048)
        lastFrame = nil
    }

    private func navigate(to raw: String) {
        guard let webView = tabManager.activeWebView,
              let target = Navigation.destinationURL(for: raw) else { return }
        webView.load(URLRequest(url: target))
    }

    // MARK: - Input injection

    private func callHelper(_ function: String, _ arguments: [Any]) {
        guard let webView = tabManager.activeWebView,
              let argsData = try? JSONSerialization.data(withJSONObject: arguments),
              let args = String(data: argsData, encoding: .utf8) else { return }
        let script = "window.__kraken && window.__kraken.\(function).apply(null, \(args));"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func injectClick(normalizedX: Double, normalizedY: Double) {
        callHelper("tap", [normalizedX, normalizedY])
    }

    private func injectScroll(normalizedDX: Double, normalizedDY: Double, atX: Double, atY: Double) {
        callHelper("scroll", [normalizedDX * viewportSize.width,
                              normalizedDY * viewportSize.height,
                              atX, atY])
    }

    private func injectKey(_ key: String) {
        callHelper("key", [key])
    }

    private func injectText(_ value: String) {
        callHelper("text", [value])
    }
}

// MARK: - WKNavigationDelegate (downloads + single-window policy)

extension AppDelegate: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloadManager.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloadManager.adopt(download)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        broadcastState()
    }
}

// MARK: - WKUIDelegate (popups become tabs)

extension AppDelegate: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let tab = tabManager.newTab(configuration: configuration)
        lastFrame = nil
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tabManager.tabs.first(where: { $0.webView === webView }) {
            tabManager.closeTab(id: tab.id)
            if tabManager.tabs.isEmpty {
                openHomepageTab()
            }
            lastFrame = nil
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        completionHandler(defaultText)
    }
}
#endif
