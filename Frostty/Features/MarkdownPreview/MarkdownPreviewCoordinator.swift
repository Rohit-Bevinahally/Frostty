import AppKit
import QuartzCore

@MainActor
protocol MarkdownPreviewHost: AnyObject {
    var activeTab: Tab? { get }
    var window: NSWindow? { get }

    func markdownPreviewWorkingDirectory(for tab: Tab) -> String?
    func restoreFocusAfterMarkdownPreview()
    func pauseActiveTabSurfaces()
}

@MainActor
final class MarkdownPreviewCoordinator {
    let session = MarkdownPreviewSession()

    private weak var host: MarkdownPreviewHost?
    private let shortcutContextController: ShortcutContextController
    private var previewContextID: UUID?
    private var searchTypingContextID: UUID?
    private var searchNavigationContextID: UUID?

    init(host: MarkdownPreviewHost, shortcutContextController: ShortcutContextController) {
        self.host = host
        self.shortcutContextController = shortcutContextController
    }

    var isCapturingInput: Bool {
        guard session.isPresented else { return false }
        return session.sourceTabID == host?.activeTab?.id
    }

    @objc func toggle() {
        _ = handleAction(path: nil, source: .keyboardToggle)
    }

    @discardableResult
    func handleAction(path: String?, source: MarkdownPreviewInvocationSource) -> Bool {
        guard let host, let tab = host.activeTab else { return false }

        if source == .keyboardToggle,
           session.isPresented,
           session.sourceTabID == tab.id {
            dismiss()
            return true
        }

        guard let sourcePaneID = activeSourcePaneID(alertIfMissing: source == .keyboardToggle) else {
            return false
        }

        let workingDirectory = host.markdownPreviewWorkingDirectory(for: tab)
        if let resolvedURL = MarkdownPreviewSupport.resolvedFileURL(from: path, relativeTo: workingDirectory),
           MarkdownPreviewSupport.isMarkdownFile(at: resolvedURL),
           MarkdownPreviewSupport.fileExists(at: resolvedURL) {
            return open(url: resolvedURL, sourcePaneID: sourcePaneID)
        }

        if let rememberedURL = rememberedURL(in: tab) {
            return open(url: rememberedURL, sourcePaneID: sourcePaneID)
        }

        if source == .keyboardToggle {
            presentAlert("Open a markdown file in preview first.")
        }
        return false
    }

    @discardableResult
    func open(url: URL, sourcePaneID: UUID? = nil) -> Bool {
        guard let host, let tab = host.activeTab else { return false }

        let normalizedURL = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            presentAlert("Choose an existing Markdown file to preview.")
            return false
        }

        let effectiveSourcePaneID = sourcePaneID
            ?? session.sourcePaneID
            ?? activeSourcePaneID(alertIfMissing: true)
        guard let effectiveSourcePaneID else { return false }

        tab.markdownPreviewSourcePath = normalizedURL.path
        tab.registry.pauseAll()
        session.present(
            sourceURL: normalizedURL,
            sourceTabID: tab.id,
            sourcePaneID: effectiveSourcePaneID
        )
        activateShortcutContext()
        host.restoreFocusAfterMarkdownPreview()
        return true
    }

    func dismiss() {
        guard session.isPresented else { return }
        deactivateShortcutContext()
        session.dismiss()
        host?.restoreFocusAfterMarkdownPreview()
    }

    func syncForActiveTab(activeTabID: UUID?) {
        guard session.isPresented else { return }
        guard session.sourceTabID == activeTabID else {
            deactivateShortcutContext()
            session.dismiss()
            return
        }
    }

    func dismissIfOwnedBy(tabID: UUID) {
        guard session.sourceTabID == tabID else { return }
        deactivateShortcutContext()
        session.dismiss()
    }

    func dismissIfOwnedBy(paneID: UUID) {
        guard session.sourcePaneID == paneID else { return }
        deactivateShortcutContext()
        session.dismiss()
    }

    @discardableResult
    func focusImmediately() -> Bool {
        guard isCapturingInput, let host else { return false }
        host.pauseActiveTabSurfaces()
        return session.browserController.focus(in: host.window)
    }

    private static let focusRestoreTimeout: Double = 0.5

    /// Returns `true` when focus restore was handled (including scheduled retries).
    func attemptFocusRestore(elapsed: Double, retry: @escaping @Sendable () -> Void) -> Bool {
        guard isCapturingInput, let host else { return false }

        let browserView = session.browserController.browserView
        let inWindow = browserView.window === host.window
        let hasSuperview = browserView.superview != nil

        guard inWindow, hasSuperview else {
            guard elapsed < Self.focusRestoreTimeout else { return true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: retry)
            return true
        }

        _ = focusImmediately()
        return true
    }

    func shouldRestoreFocusFromTerminalOrBrowser() -> Bool {
        guard isCapturingInput else { return false }
        host?.restoreFocusAfterMarkdownPreview()
        return true
    }

    // MARK: - Private

    private func openSearch() {
        if searchTypingContextID != nil {
            focusSearchInput()
            return
        }

        if searchNavigationContextID != nil {
            resumeSearchTyping()
            return
        }

        pushSearchTypingContext()
        focusSearchInput()
    }

    private func pushSearchTypingContext() {
        let typingContext = MarkdownPreviewSearchShortcutContext.makeTypingContext(
            previewSession: session,
            onCommit: { [weak self] in self?.commitSearch() },
            onDismiss: { [weak self] in self?.dismissSearchContexts() }
        )
        searchTypingContextID = shortcutContextController.push(typingContext)
    }

    private func focusSearchInput() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.host, self.session.isPresented else { return }
            _ = self.session.browserController.focus(in: host.window)
            self.session.browserController.runPreviewJavaScript(
                "window.frosttyPreview?.openSearchAndFocus();"
            )
        }
    }

    private func resumeSearchTyping() {
        if let searchNavigationContextID {
            shortcutContextController.pop(id: searchNavigationContextID)
            self.searchNavigationContextID = nil
        }

        if searchTypingContextID == nil {
            pushSearchTypingContext()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.host, self.session.isPresented else { return }
            _ = self.session.browserController.focus(in: host.window)
            self.session.browserController.runPreviewJavaScript(
                "window.frosttyPreview?.resumeSearchTyping();"
            )
        }
    }

    private func commitSearch() {
        guard let searchTypingContextID else { return }
        shortcutContextController.pop(id: searchTypingContextID)
        self.searchTypingContextID = nil

        session.browserController.runPreviewJavaScript(
            "window.frosttyPreview?.commitSearchTyping();"
        )

        let navigationContext = MarkdownPreviewSearchShortcutContext.makeNavigationContext(
            previewSession: session,
            onDismiss: { [weak self] in self?.dismissSearchContexts() },
            onResumeTyping: { [weak self] in self?.resumeSearchTyping() }
        )
        searchNavigationContextID = shortcutContextController.push(navigationContext)
    }

    private func dismissSearchContexts() {
        if let searchNavigationContextID {
            shortcutContextController.pop(id: searchNavigationContextID)
            self.searchNavigationContextID = nil
        }
        if let searchTypingContextID {
            shortcutContextController.pop(id: searchTypingContextID)
            self.searchTypingContextID = nil
        }
        guard session.isPresented else { return }
        session.browserController.runPreviewJavaScript(
            "window.frosttyPreview?.dismissSearch();"
        )
    }

    private func activateShortcutContext() {
        deactivateShortcutContext()
        let context = MarkdownPreviewShortcutContext.makeContext(
            previewSession: session,
            onDismiss: { [weak self] in self?.dismiss() },
            onReload: { [weak self] in
                self?.session.reload()
                DispatchQueue.main.async { [weak self] in
                    self?.host?.restoreFocusAfterMarkdownPreview()
                }
            },
            onOpenSearch: { [weak self] in self?.openSearch() }
        )
        previewContextID = shortcutContextController.push(context)
        session.browserController.onPreviewBridgeMessage = { [weak self] type in
            guard type == "searchInputFocus" else { return }
            self?.resumeSearchTyping()
        }
    }

    private func deactivateShortcutContext() {
        dismissSearchContexts()
        session.browserController.onPreviewBridgeMessage = nil
        guard let previewContextID else { return }
        shortcutContextController.pop(id: previewContextID)
        self.previewContextID = nil
    }

    private func activeSourcePaneID(alertIfMissing: Bool) -> UUID? {
        guard let host,
              let tab = host.activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              tab.registry.controller(for: focusedID) != nil else {
            if alertIfMissing {
                presentAlert("Focus a terminal pane before opening the Markdown preview.")
            }
            return nil
        }
        return focusedID
    }

    private func rememberedURL(in tab: Tab) -> URL? {
        guard let path = tab.markdownPreviewSourcePath else { return nil }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            tab.markdownPreviewSourcePath = nil
            return nil
        }

        return url
    }

    private func presentAlert(_ message: String) {
        guard let window = host?.window else { return }

        let alert = NSAlert()
        alert.messageText = "Markdown Preview"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }
}
