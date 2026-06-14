import AppKit
import Foundation
import os

private let browserTabControllerLogger = Logger(
    subsystem: "com.frostty.terminal",
    category: "BrowserTabController"
)

@MainActor
final class BrowserTabController {
    let browserState: BrowserState
    private(set) var browserView: BrowserView
    private(set) var snapshotGeneration: Int = 0
    var onNavigationCommit: (() -> Void)?

    init(initialURL: URL = URL(string: "about:blank")!) {
        let state = BrowserState(url: initialURL)
        self.browserState = state
        self.browserView = BrowserView(state: state)

        browserView.onNavigationCommit = { [weak self] in
            self?.snapshotGeneration = 0
            self?.onNavigationCommit?()
        }
    }

    var title: String {
        browserState.title
    }

    var url: URL {
        browserState.url
    }

    func incrementSnapshotGeneration() {
        snapshotGeneration += 1
    }

    @discardableResult
    func focus(in window: NSWindow? = nil) -> Bool {
        browserView.focus(in: window)
    }

    func evaluateJavaScript(_ script: String) async throws -> String {
        try await browserView.evaluateJavaScript(script)
    }

    func takeScreenshot() async throws -> Data {
        try await browserView.takeScreenshot()
    }

    func goBack() {
        browserView.goBack()
    }

    func goForward() {
        browserView.goForward()
    }

    func reload() {
        browserView.reload()
    }

    func loadURL(_ url: URL) {
        browserView.loadURL(url)
    }

    func setSuspended(_ suspended: Bool) {
        browserView.setSuspended(suspended)
    }

    deinit {
        browserTabControllerLogger.debug("BrowserTabController deinit")
    }
}
