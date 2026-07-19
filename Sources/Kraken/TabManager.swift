#if os(macOS)
import Foundation
import WebKit

final class Tab {
    let id = UUID().uuidString
    let webView: WKWebView
    var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView) {
        self.webView = webView
    }
}

final class TabManager {
    private(set) var tabs: [Tab] = []
    private(set) var activeTabID: String?

    var makeWebView: ((WKWebViewConfiguration?) -> WKWebView)?
    var onStateChange: (() -> Void)?

    var activeTab: Tab? { tabs.first { $0.id == activeTabID } }
    var activeWebView: WKWebView? { activeTab?.webView }

    @discardableResult
    func newTab(configuration: WKWebViewConfiguration? = nil, activate: Bool = true) -> Tab {
        guard let makeWebView else { fatalError("TabManager.makeWebView not set") }
        let webView = makeWebView(configuration)
        let tab = Tab(webView: webView)
        let notify: (WKWebView, Any) -> Void = { [weak self] _, _ in self?.onStateChange?() }
        tab.observations = [
            webView.observe(\.url, changeHandler: notify),
            webView.observe(\.title, changeHandler: notify),
            webView.observe(\.estimatedProgress, changeHandler: notify),
            webView.observe(\.isLoading, changeHandler: notify),
            webView.observe(\.canGoBack, changeHandler: notify),
            webView.observe(\.canGoForward, changeHandler: notify)
        ]
        tabs.append(tab)
        if activate { activeTabID = tab.id }
        onStateChange?()
        return tab
    }

    func closeTab(id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        tab.observations = []
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        if activeTabID == id {
            activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        onStateChange?()
    }

    func switchTab(id: String) {
        guard activeTabID != id, tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        onStateChange?()
    }
}
#endif
