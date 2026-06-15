import AppKit
import WebKit
import os

private let browserViewLogger = Logger(subsystem: "com.frostty.terminal", category: "BrowserView")

@MainActor
private final class PreviewScriptMessageHandler: NSObject, WKScriptMessageHandler {
    var onMessage: (@MainActor (String) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "frosttyPreview",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        MainActor.assumeIsolated {
            onMessage?(type)
        }
    }
}

@MainActor
private final class FrosttyBrowserWebView: WKWebView {
    var onFocusChanged: ((Bool) -> Void)?

    override var isOpaque: Bool { false }

    override init(frame frameRect: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frameRect, configuration: configuration)
        applyTransparencyToBacking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not implemented")
    }

    override func layout() {
        super.layout()
        applyTransparencyToBacking()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTransparencyToBacking()
    }

    private func applyTransparencyToBacking() {
        setValue(false, forKey: "drawsBackground")
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChanged?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChanged?(false)
        }
        return result
    }
}

@MainActor
final class BrowserView: NSView {
    private struct CustomDocumentLoadState {
        let displayURL: URL
        let title: String
    }

    private let webView: FrosttyBrowserWebView
    private let previewMessageHandler = PreviewScriptMessageHandler()
    private var previewBridgeInstalled = false
    private let state: BrowserState
    private let downloadManager: DownloadManager
    private var redirectCounts: [ObjectIdentifier: Int] = [:]
    private var customDocumentLoadState: CustomDocumentLoadState?

    var onTitleChanged: ((String) -> Void)?
    var onURLChanged: ((URL) -> Void)?
    var onNavigationCommit: (() -> Void)?
    var onFocus: (() -> Void)?
    var onPreviewBridgeMessage: (@MainActor (String) -> Void)? {
        get { previewMessageHandler.onMessage }
        set { previewMessageHandler.onMessage = newValue }
    }

    nonisolated(unsafe) private var configChangeObserver: NSObjectProtocol?

    init(state: BrowserState, downloadManager: DownloadManager = DownloadManager()) {
        self.state = state
        self.downloadManager = downloadManager

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.webView = FrosttyBrowserWebView(frame: .zero, configuration: configuration)

        super.init(frame: .zero)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Color scheme for scrollbars / form controls comes from WKWebpagePreferences in the navigation
        // delegate (not DOM injection). Appearance tracks the window so Frostty matches system / titlebar.
        webView.onFocusChanged = { [weak self] focused in
            if focused {
                self?.onFocus?()
            }
        }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]

        addSubview(webView)
        applyTerminalMatchedAppearance()
        syncWebViewAppearanceWithWindow()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyTerminalMatchedAppearance()
                self.syncWebViewAppearanceWithWindow()
                if Self.isAboutBlankURL(self.state.url) {
                    self.webView.loadHTMLString(Self.transparentBlankHTML(), baseURL: nil)
                }
            }
        }
        loadInitialDocument()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncWebViewAppearanceWithWindow()
    }

    private func syncWebViewAppearanceWithWindow() {
        webView.appearance = NSAppearance(named: .aqua)
    }

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func applyTerminalMatchedAppearance() {
        let cfg = GhosttyAppController.shared.configManager
        let opacity = cfg.backgroundOpacity
        let background = cfg.backgroundColor.withAlphaComponent(opacity)
        wantsLayer = true
        // `BrowserPaneView` paints the Ghostty tint; keep this view transparent so we do not double-blend.
        layer?.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = background
        }
    }

    private func loadInitialDocument() {
        if Self.isAboutBlankURL(state.url) {
            webView.loadHTMLString(Self.transparentBlankHTML(), baseURL: nil)
        } else {
            webView.load(URLRequest(url: state.url))
        }
    }

    private static func isAboutBlankURL(_ url: URL) -> Bool {
        url.absoluteString.lowercased() == "about:blank"
    }

    /// Minimal `about:blank` document: **transparent** page so `underPageBackgroundColor` matches Ghostty.
    private static func transparentBlankHTML() -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          html, body { height: 100%; margin: 0; background: transparent; }
        </style>
        </head><body></body></html>
        """
    }

    func loadURL(_ url: URL) {
        customDocumentLoadState = nil
        setPreviewBridgeEnabled(false)
        state.url = url
        onURLChanged?(url)
        if Self.isAboutBlankURL(url) {
            webView.loadHTMLString(Self.transparentBlankHTML(), baseURL: nil)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func loadHTMLString(
        _ html: String,
        baseURL: URL? = nil,
        displayURL: URL,
        title: String,
        enablePreviewBridge: Bool = false
    ) {
        customDocumentLoadState = CustomDocumentLoadState(displayURL: displayURL, title: title)
        setPreviewBridgeEnabled(enablePreviewBridge)
        state.url = displayURL
        state.title = title
        state.isLoading = true
        state.lastError = nil
        onURLChanged?(displayURL)
        onTitleChanged?(title)
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func setSuspended(_ suspended: Bool) {
        webView.isHidden = suspended
        webView.alphaValue = suspended ? 0 : 1
        if let pagePreferences = webView.configuration.defaultWebpagePreferences {
            pagePreferences.allowsContentJavaScript = !suspended
        }
    }

    func focus(in window: NSWindow? = nil) -> Bool {
        let targetWindow = window ?? webView.window ?? self.window
        guard let targetWindow else { return false }
        if webView.window === targetWindow {
            return targetWindow.makeFirstResponder(webView)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.webView.window === targetWindow else { return }
            _ = targetWindow.makeFirstResponder(self.webView)
        }
        return true
    }

    func scrollPreviewBy(dx: CGFloat, dy: CGFloat) {
        runPreviewJavaScript("window.frosttyPreview?.scrollBy(\(dx), \(dy));")
    }

    func scrollPreviewToTop() {
        runPreviewJavaScript("window.frosttyPreview?.scrollToTop();")
    }

    func scrollPreviewToBottom() {
        runPreviewJavaScript("window.frosttyPreview?.scrollToBottom();")
    }

    func runPreviewJavaScript(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.webView.window != nil, !self.state.isLoading else { return }
            self.webView.evaluateJavaScript(script) { _, error in
                if let error {
                    browserViewLogger.debug("Preview JavaScript failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func evaluateJavaScript(_ script: String) async throws -> String {
        let result: Any?
        if script.contains("await") {
            result = try await webView.callAsyncJavaScript(script, contentWorld: .page)
        } else {
            result = try await webView.evaluateJavaScript(script)
        }

        if let string = result as? String {
            return string
        }

        return String(describing: result)
    }

    func takeScreenshot() async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserAutomationError.screenshotFailed
        }

        return pngData
    }

    private func setPreviewBridgeEnabled(_ enabled: Bool) {
        let controller = webView.configuration.userContentController
        if enabled {
            guard !previewBridgeInstalled else { return }
            controller.add(previewMessageHandler, name: "frosttyPreview")
            previewBridgeInstalled = true
        } else if previewBridgeInstalled {
            controller.removeScriptMessageHandler(forName: "frosttyPreview")
            previewBridgeInstalled = false
        }
    }
}

extension BrowserView: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme else {
            decisionHandler(.cancel, preferences)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true {
            guard BrowserSecurity.isAllowedTopLevelScheme(scheme) else {
                browserViewLogger.warning("Blocked top-level navigation to disallowed scheme: \(scheme)")
                decisionHandler(.cancel, preferences)
                return
            }

            if navigationAction.navigationType == .other && navigationAction.sourceFrame.isMainFrame {
                let frameKey = ObjectIdentifier(navigationAction.sourceFrame)
                let count = redirectCounts[frameKey, default: 0] + 1
                if count > BrowserSecurity.maxRedirectDepth {
                    browserViewLogger.warning("Blocked navigation: exceeded max redirect depth (\(BrowserSecurity.maxRedirectDepth))")
                    redirectCounts.removeValue(forKey: frameKey)
                    decisionHandler(.cancel, preferences)
                    return
                }
                redirectCounts[frameKey] = count
            }

            decisionHandler(.allow, preferences)
            return
        }

        guard BrowserSecurity.isAllowedSubresourceScheme(scheme) else {
            browserViewLogger.warning("Blocked subresource with disallowed scheme: \(scheme)")
            decisionHandler(.cancel, preferences)
            return
        }

        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloadManager
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloadManager
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let navigation {
            redirectCounts[ObjectIdentifier(navigation)] = 0
        }

        state.isLoading = true
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        syncDisplayState(with: webView)

        onNavigationCommit?()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        state.isLoading = true
        state.lastError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let navigation {
            redirectCounts.removeValue(forKey: ObjectIdentifier(navigation))
        }

        state.isLoading = false
        state.canGoBack = webView.canGoBack
        state.canGoForward = webView.canGoForward
        syncDisplayState(with: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if Self.isCancelledNavigationError(error) {
            // Common when back/forward replaces an in-flight load; the new navigation still completes.
            return
        }

        if let navigation {
            redirectCounts.removeValue(forKey: ObjectIdentifier(navigation))
        }

        state.isLoading = false
        state.lastError = error.localizedDescription
        browserViewLogger.error("Navigation failed: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        if Self.isCancelledNavigationError(error) {
            return
        }

        if let navigation {
            redirectCounts.removeValue(forKey: ObjectIdentifier(navigation))
        }

        state.isLoading = false
        state.lastError = error.localizedDescription
        browserViewLogger.error("Provisional navigation failed: \(error.localizedDescription)")
    }

    private static func isCancelledNavigationError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    private func syncDisplayState(with webView: WKWebView) {
        if let customDocumentLoadState {
            state.title = customDocumentLoadState.title
            state.url = customDocumentLoadState.displayURL
            onTitleChanged?(customDocumentLoadState.title)
            onURLChanged?(customDocumentLoadState.displayURL)
            return
        }

        state.title = webView.title ?? state.url.host ?? state.url.absoluteString
        onTitleChanged?(state.title)

        if let currentURL = webView.url {
            state.url = currentURL
            onURLChanged?(currentURL)
        }
    }
}

extension BrowserView: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Web Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo
    ) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Web Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Web Page"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = defaultText ?? ""
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            return textField.stringValue
        }

        return nil
    }
}
