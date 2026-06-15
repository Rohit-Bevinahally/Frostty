// AppDelegate.swift
// Frostty
//
// Application lifecycle, window creation, and main menu.

import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appSession = AppSession()
    private(set) var browserTabBroker = BrowserTabBroker()
    private(set) var frosttyActionBroker = FrosttyActionBroker()
    private(set) var frosttyActionRegistry = FrosttyActionRegistry()
    private var windowControllers: [FrosttyWindowController] = []

    var allWindowControllers: [FrosttyWindowController] {
        windowControllers
    }

    private var frontmostWindowController: FrosttyWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? FrosttyWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? FrosttyWindowController {
            return controller
        }
        return windowControllers.last(where: { $0.window?.isVisible == true }) ?? windowControllers.last
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = GhosttyAppController.shared
        guard controller.readiness == .ready else {
            logger.critical("GhosttyAppController initialization failed")
            let alert = NSAlert()
            alert.messageText = "Failed to Initialize"
            alert.informativeText = "Terminal engine initialization failed. The application will now exit."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        controller.setColorScheme(scheme)

        setupMainMenu()
        registerNotificationObservers()

        browserTabBroker.appDelegate = self
        BrowserServer.shared.toolHandler = BrowserToolHandler(broker: browserTabBroker)
        BrowserServer.shared.start()

        frosttyActionBroker.appDelegate = self
        registerFrosttyActions()
        FrosttyActionServer.shared.registry = frosttyActionRegistry
        FrosttyActionServer.shared.broker = frosttyActionBroker
        FrosttyActionServer.shared.start()

        createInitialWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard GhosttyAppController.shared.app != nil else {
            return .terminateNow
        }

        if GhosttyAppController.shared.needsConfirmQuit {
            let alert = NSAlert()
            alert.messageText = "Quit Frostty?"
            alert.informativeText = "A process is still running. Do you want to quit?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return .terminateCancel
            }
        }

        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserServer.shared.stop()
        FrosttyActionServer.shared.stop()
        windowControllers.removeAll()
    }

    private func registerFrosttyActions() {
        MarkdownPreviewAction.register(in: frosttyActionRegistry, broker: frosttyActionBroker)
    }

    func applicationDidChangeOcclusionState(_ notification: Notification) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        GhosttyAppController.shared.setColorScheme(scheme)
    }

    // MARK: - Notification Observers

    private func registerNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleNewWindow(_:)), name: .ghosttyNewWindow, object: nil)
    }

    @objc private func handleNewWindow(_ notification: Notification) {
        // Single window mode: redirect new window requests to creating a workspace
        if let wc = windowControllers.first {
            let n = wc.windowSession.workspaces.count + 1
            wc.createNewWorkspace(name: "Workspace \(n)", workingDirectory: nil)
        } else {
            createInitialWindow()
        }
    }

    // MARK: - Window Management

    private func createInitialWindow() {
        let initialTab = Tab()
        let windowSession = WindowSession(initialTab: initialTab)
        appSession.addWindow(windowSession)

        let wc = FrosttyWindowController(windowSession: windowSession)
        windowControllers.append(wc)
        wc.showWindow(nil)
    }

    @objc func createNewWorkspaceFromMenu() {
        guard let wc = windowControllers.first else { return }
        let n = wc.windowSession.workspaces.count + 1
        wc.createNewWorkspace(name: "Workspace \(n)", workingDirectory: nil)
    }

    @objc func closeActiveTab(_ sender: Any?) {
        frontmostWindowController?.requestCloseActiveTab(sender)
    }

    @objc func createNewBrowserTabFromMenu() {
        frontmostWindowController?.newBrowserTab(nil)
    }

    func removeWindowController(_ controller: FrosttyWindowController) {
        appSession.removeWindow(id: controller.windowSession.id)
        windowControllers.removeAll { $0 === controller }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Frostty", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Frostty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Workspace", action: #selector(createNewWorkspaceFromMenu), keyEquivalent: "n")
        let browserTabItem = NSMenuItem(
            title: "New Browser Tab",
            action: #selector(createNewBrowserTabFromMenu),
            keyEquivalent: "t"
        )
        browserTabItem.keyEquivalentModifierMask = [.command, .shift]
        browserTabItem.target = self
        fileMenu.addItem(browserTabItem)
        fileMenu.addItem(.separator())

        let closeItem = NSMenuItem(title: "Close", action: #selector(closeActiveTab(_:)), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)

        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")

        let fullScreenItem = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        fullScreenItem.keyEquivalent = "f"
        viewMenu.addItem(fullScreenItem)

        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
