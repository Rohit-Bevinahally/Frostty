// FrosttyWindowController.swift
// Frostty
//
// Central orchestrator: owns WindowSession, manages split containers,
// handles notifications from libghostty, and coordinates all operations.

import AppKit
import QuartzCore
import SwiftUI
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "FrosttyWindowController")

@MainActor
class FrosttyWindowController: NSWindowController, NSWindowDelegate {
    private(set) var windowSession: WindowSession
    private var splitContainerView: SplitContainerView?
    private var hostingView: NSHostingView<MainContentView>?
    private var closingTabIDs: Set<UUID> = []
    private var focusRequestID: UInt64 = 0
    private var isPaneResizeMode = false
    private let shortcutContextController = ShortcutContextController()
    private var markdownPreviewCoordinator: MarkdownPreviewCoordinator!

    // MARK: - Computed Properties

    var activeTab: Tab? {
        windowSession.activeWorkspace?.activeTab
    }

    private var activeRegistry: SurfaceRegistry? {
        activeTab?.registry
    }

    private var isMarkdownPreviewCapturingInput: Bool {
        markdownPreviewCoordinator.isCapturingInput
    }

    var preferredUIFontSurface: ghostty_surface_t? {
        if let surface = preferredUIFontSurface(in: activeTab) {
            return surface
        }

        for workspace in windowSession.workspaces {
            for tab in workspace.tabs {
                if let surface = preferredUIFontSurface(in: tab) {
                    return surface
                }
            }
        }

        return nil
    }

    var activeBrowserControllerForExternal: BrowserTabController? {
        guard let tab = activeTab else { return nil }

        if let focusedID = tab.splitTree.focusedLeafID,
           let controller = tab.registry.browserController(for: focusedID) {
            return controller
        }

        for paneID in tab.splitTree.allLeafIDs() {
            if let controller = tab.registry.browserController(for: paneID) {
                return controller
            }
        }

        return nil
    }

    private func preferredUIFontSurface(in tab: Tab?) -> ghostty_surface_t? {
        guard let tab else { return nil }

        if let focusedID = tab.splitTree.focusedLeafID,
           let surface = tab.registry.controller(for: focusedID)?.surface {
            return surface
        }

        for paneID in tab.splitTree.allLeafIDs() {
            if let surface = tab.registry.controller(for: paneID)?.surface {
                return surface
            }
        }

        return nil
    }

    private var focusedController: GhosttySurfaceController? {
        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID else { return nil }
        return tab.registry.controller(for: focusedID)
    }

    private enum BrowserOpenDestination {
        case newTab
        case split(SplitDirection)
    }

    private struct DetachedPaneMove {
        let paneID: UUID
        let entry: SurfaceRegistry.RegistryEntry
        let sourceTab: Tab
        let sourceWorkspace: Workspace
        let sourceTabWasActive: Bool
        let sourceTabRemoved: Bool
        let newTabTitle: String
        let newTabUsesCustomTitle: Bool
        let newTabPWD: String?
    }

    // MARK: - Initialization

    convenience init(windowSession: WindowSession) {
        let window = FrosttyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.init(window: window, windowSession: windowSession)
    }

    init(window: NSWindow, windowSession: WindowSession) {
        self.windowSession = windowSession
        super.init(window: window)
        markdownPreviewCoordinator = MarkdownPreviewCoordinator(
            host: self,
            shortcutContextController: shortcutContextController
        )
        window.delegate = self
        window.center()
        setupShortcutManager()
        setupUI()
        setupTerminalSurface()
        registerNotificationObservers()
        updateWindowDecorations()
        updateWindowBackgroundAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupShortcutManager() {
        guard let frosttyWindow = window as? FrosttyWindow else { return }
        let manager = ShortcutManager()
        manager.contextController = shortcutContextController
        manager.isSuppressed = { [weak self] in
            self?.isMarkdownPreviewCapturingInput == true
        }

        // Cmd+S -> toggle sidebar (keyCode 1 = S)
        manager.register(modifiers: [.command], keyCode: 1) { [weak self] in
            self?.toggleSidebar()
        }
        // Cmd+1..9 -> switch workspace (keyCodes: 18=1, 19=2, 20=3, 21=4, 23=5, 22=6, 26=7, 28=8, 25=9)
        let workspaceKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, keyCode) in workspaceKeyCodes.enumerated() {
            let idx = index
            manager.register(modifiers: [.command], keyCode: keyCode) { [weak self] in
                self?.switchToWorkspaceByIndex(idx)
            }
        }
        // Alt+1..9 -> switch tab
        for (index, keyCode) in workspaceKeyCodes.enumerated() {
            let idx = index
            manager.register(modifiers: [.option], keyCode: keyCode) { [weak self] in
                self?.switchToTabByIndex(idx)
            }
        }
        // Cmd+T -> new tab adjacent, inherit cwd (keyCode 17 = T)
        manager.register(modifiers: [.command], keyCode: 17) { [weak self] in
            self?.createNewTabAdjacent()
        }
        // Cmd+W -> close active tab with process-aware confirmation (keyCode 13 = W)
        manager.register(modifiers: [.command], keyCode: 13) { [weak self] in
            self?.requestCloseActiveTab()
        }
        // Ctrl+Shift+T -> new tab at end, home dir (keyCode 17 = T)
        manager.register(modifiers: [.control, .shift], keyCode: 17) { [weak self] in
            self?.createNewTabAtEnd()
        }
        // Cmd+Shift+T -> open browser in a new tab
        manager.register(modifiers: [.command, .shift], keyCode: 17) { [weak self] in
            self?.openBrowser(destination: .newTab)
        }
        // Cmd+D -> split right (keyCode 2 = D)
        manager.register(modifiers: [.command], keyCode: 2) { [weak self] in
            self?.splitPane(direction: .horizontal)
        }
        // Cmd+Shift+D -> split down (keyCode 2 = D)
        manager.register(modifiers: [.command, .shift], keyCode: 2) { [weak self] in
            self?.splitPane(direction: .vertical)
        }
        // Cmd+B -> open browser in a horizontal split (keyCode 11 = B)
        manager.register(modifiers: [.command], keyCode: 11) { [weak self] in
            self?.openBrowser(destination: .split(.horizontal))
        }
        // Cmd+Shift+B -> open browser in a vertical split
        manager.register(modifiers: [.command, .shift], keyCode: 11) { [weak self] in
            self?.openBrowser(destination: .split(.vertical))
        }
        // Cmd+L -> focus browser address bar (keyCode 37 = L)
        manager.register(modifiers: [.command], keyCode: 37) { [weak self] in
            self?.focusBrowserAddressBar()
        }
        // Ctrl+D -> close active browser pane, or pass through to terminal when focus is not a browser
        manager.register(
            modifiers: [.control],
            keyCode: 2,
            isEnabled: { [weak self] in
                guard let self,
                      let tab = self.activeTab,
                      let fid = tab.splitTree.focusedLeafID else { return false }
                return tab.registry.browserController(for: fid) != nil
            }
        ) { [weak self] in
            self?.closeActiveBrowserPaneIfPossible()
        }
        // Cmd+R -> enter pane resize mode (keyCode 15 = R)
        manager.register(modifiers: [.command], keyCode: 15) { [weak self] in
            self?.enterResizeMode()
        }
        // Cmd+N -> new workspace (keyCode 45 = N) — single window mode
        manager.register(modifiers: [.command], keyCode: 45) { [weak self] in
            self?.createNewWorkspaceFromShortcut()
        }
        // Ctrl+M -> toggle maximized pane layout (keyCode 46 = M)
        manager.register(modifiers: [.control], keyCode: 46) { [weak self] in
            self?.togglePaneMaximizedLayout()
        }
        // Ctrl+Shift+W -> close workspace (keyCode 13 = W)
        manager.register(modifiers: [.control, .shift], keyCode: 13) { [weak self] in
            self?.closeActiveWorkspace()
        }
        // Ctrl+Shift+I -> rename active tab (keyCode 34 = I)
        manager.register(modifiers: [.control, .shift], keyCode: 34) { [weak self] in
            self?.renameActiveTab()
        }
        // Alt+P -> toggle markdown preview
        manager.register(modifiers: [.option], keyCode: 35, allowWhenSuppressed: true) { [weak self] in
            self?.markdownPreviewCoordinator.toggle()
        }
        // Pane navigation: Ctrl+Shift+H/J/K/L (keyCodes: 4=H, 38=J, 40=K, 37=L)
        manager.register(modifiers: [.control, .shift], keyCode: 4) { [weak self] in
            self?.navigatePane(direction: .spatial(.left))
        }
        manager.register(modifiers: [.control, .shift], keyCode: 38) { [weak self] in
            self?.navigatePane(direction: .spatial(.down))
        }
        manager.register(modifiers: [.control, .shift], keyCode: 40) { [weak self] in
            self?.navigatePane(direction: .spatial(.up))
        }
        manager.register(modifiers: [.control, .shift], keyCode: 37) { [weak self] in
            self?.navigatePane(direction: .spatial(.right))
        }
        // Resize mode: h/j/k/l adjust by 1 cell, Shift+h/j/k/l by 2 cells.
        manager.register(modifiers: [], keyCode: 4, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.resizeFocusedPane(direction: .left, steps: 1)
        }
        manager.register(modifiers: [], keyCode: 38, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.resizeFocusedPane(direction: .down, steps: 1)
        }
        manager.register(modifiers: [], keyCode: 40, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.resizeFocusedPane(direction: .up, steps: 1)
        }
        manager.register(modifiers: [], keyCode: 37, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.resizeFocusedPane(direction: .right, steps: 1)
        }
        manager.register(modifiers: [.shift], keyCode: 4, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.resizeFocusedPane(direction: .left, steps: 2)
        }
        manager.register(modifiers: [.shift], keyCode: 38, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.resizeFocusedPane(direction: .down, steps: 2)
        }
        manager.register(modifiers: [.shift], keyCode: 40, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.resizeFocusedPane(direction: .up, steps: 2)
        }
        manager.register(modifiers: [.shift], keyCode: 37, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.resizeFocusedPane(direction: .right, steps: 2)
        }
        manager.register(modifiers: [], keyCode: 12, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.exitResizeMode()
        }
        manager.register(modifiers: [], keyCode: 53, isEnabled: { [weak self] in
            self?.isPaneResizeMode == true
        }) { [weak self] in
            self?.exitResizeMode()
        }

        frosttyWindow.shortcutManager = manager
    }

    private func setupUI() {
        guard let window = self.window,
              let contentView = window.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        let container = SplitContainerView(registry: SurfaceRegistry())
        container.onRatioChange = { [weak self] path, ratio, splitSize in
            self?.handleDividerDrag(path: path, ratio: ratio, splitSize: splitSize)
        }
        self.splitContainerView = container

        let mainContent = buildMainContentView()
        let hosting = NonDraggableHostingView(rootView: mainContent)
        hosting.frame = contentView.bounds
        hosting.autoresizingMask = [.width, .height]
        contentView.addSubview(hosting)
        self.hostingView = hosting
    }

    private func setupTerminalSurface() {
        guard let tab = activeTab else {
            logger.error("No active tab during setup")
            return
        }

        guard let app = GhosttyAppController.shared.app,
              let window = self.window else {
            logger.error("Failed to set up terminal surface: app or window not available")
            return
        }

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        // Use workspace working directory, or nil for default
        let pwd = windowSession.activeWorkspace?.workingDirectory

        guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: pwd) else {
            logger.error("Failed to create initial surface")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        activateCurrentTab()
    }

    // MARK: - Content View Building

    private func buildMainContentView() -> MainContentView {
        MainContentView(
            windowSession: windowSession,
            markdownPreviewSession: markdownPreviewCoordinator.session,
            splitContainerView: splitContainerView ?? SplitContainerView(registry: SurfaceRegistry()),
            isPaneResizeMode: isPaneResizeMode,
            onTabSelected: { [weak self] tabID in self?.switchToTab(id: tabID) },
            onCloseTab: { [weak self] tabID in self?.requestCloseTab(id: tabID) },
            onMoveTab: { [weak self] fromIndex, toIndex in
                self?.moveTab(fromIndex: fromIndex, toIndex: toIndex)
            },
            onRenameTab: { [weak self] tabID, name in self?.renameTab(id: tabID, name: name) },
            onWorkspaceSelected: { [weak self] wsID in self?.switchToWorkspace(id: wsID) },
            onNewWorkspace: { [weak self] name, wd in
                self?.createNewWorkspace(name: name, workingDirectory: wd) ?? false
            },
            onDeleteWorkspace: { [weak self] wsID in self?.deleteWorkspaceWithConfirmation(id: wsID) },
            onRenameWorkspace: { [weak self] wsID, name in self?.renameWorkspace(id: wsID, name: name) },
            onMoveWorkspace: { [weak self] fromIndex, toIndex in
                self?.moveWorkspace(fromIndex: fromIndex, toIndex: toIndex)
            },
            onSetWorkingDirectory: { [weak self] wsID, path in
                self?.setWorkingDirectory(for: wsID, path: path) ?? false
            },
            onPaneMoveToNewTabAtSlot: { [weak self] paneID, slot in
                self?.movePaneToNewTab(sourceID: paneID, insertionSlot: slot)
            },
            onPaneMoveToNewWorkspaceAtSlot: { [weak self] paneID, slot in
                self?.movePaneToNewWorkspace(sourceID: paneID, insertionSlot: slot)
            },
            onPaneMoveToWorkspace: { [weak self] paneID, workspaceID in
                self?.movePaneToWorkspace(sourceID: paneID, workspaceID: workspaceID)
            },
            canDropPaneToNewTab: { [weak self] paneID in
                self?.canMovePaneToNewTab(sourceID: paneID) ?? false
            },
            onToggleSidebar: { [weak self] in self?.toggleSidebar() },
            onSidebarWidthChanged: { [weak self] width in
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    self?.windowSession.sidebarWidth = width
                }
            }
        )
    }

    private func refreshHostingView() {
        hostingView?.rootView = buildMainContentView()
    }

    // MARK: - Split Container Management

    private func rebuildSplitContainer() {
        guard let tab = activeTab else { return }
        if let container = splitContainerView {
            container.updateRegistry(tab.registry)
            container.onRatioChange = { [weak self] path, ratio, splitSize in
                self?.handleDividerDrag(path: path, ratio: ratio, splitSize: splitSize)
            }
            container.onPaneDrop = { [weak self] sourceID, destinationID, zone in
                self?.handlePaneDrop(sourceID: sourceID, destinationID: destinationID, zone: zone)
            }
            container.onPaneDetachToNewTab = { [weak self] sourceID, screenPoint in
                self?.handlePaneDetachToNewTab(sourceID: sourceID, screenPoint: screenPoint)
            }
        } else {
            let container = SplitContainerView(registry: tab.registry)
            container.onRatioChange = { [weak self] path, ratio, splitSize in
                self?.handleDividerDrag(path: path, ratio: ratio, splitSize: splitSize)
            }
            container.onPaneDrop = { [weak self] sourceID, destinationID, zone in
                self?.handlePaneDrop(sourceID: sourceID, destinationID: destinationID, zone: zone)
            }
            container.onPaneDetachToNewTab = { [weak self] sourceID, screenPoint in
                self?.handlePaneDetachToNewTab(sourceID: sourceID, screenPoint: screenPoint)
            }
            self.splitContainerView = container
        }
    }

    private func updateLayout() {
        guard let tab = activeTab, let container = splitContainerView else { return }
        container.updateLayout(
            tree: tab.splitTree,
            maximizedLeafID: tab.isPaneMaximized ? tab.splitTree.focusedLeafID : nil
        )
    }

    // MARK: - Focus Management

    @discardableResult
    private func focusActiveTabImmediately() -> Bool {
        if isMarkdownPreviewCapturingInput {
            return markdownPreviewCoordinator.focusImmediately()
        }

        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID else {
            return false
        }

        syncFocusToSurfaceTree(in: tab)
        return tab.registry.makeFirstResponder(for: focusedID, in: window)
    }

    private func restoreFocus() {
        focusRequestID &+= 1
        let requestID = focusRequestID
        let startTime = CACurrentMediaTime()

        DispatchQueue.main.async { [weak self] in
            self?.attemptFocusRestore(requestID: requestID, startTime: startTime)
        }
    }

    private static let focusRestoreTimeout: Double = 0.5

    private func attemptFocusRestore(requestID: UInt64, startTime: Double) {
        guard requestID == focusRequestID else { return }
        let elapsed = CACurrentMediaTime() - startTime

        guard window?.isKeyWindow == true else { return }

        if markdownPreviewCoordinator.attemptFocusRestore(elapsed: elapsed, retry: { [weak self] in
            DispatchQueue.main.async {
                self?.attemptFocusRestore(requestID: requestID, startTime: startTime)
            }
        }) {
            return
        }

        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              let focusView = tab.registry.paneView(for: focusedID) else { return }

        let inWindow = focusView.window === self.window
        let hasSuperview = focusView.superview != nil

        guard inWindow, hasSuperview else {
            guard elapsed < Self.focusRestoreTimeout else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                self?.attemptFocusRestore(requestID: requestID, startTime: startTime)
            }
            return
        }

        syncFocusToSurfaceTree(in: tab)
        _ = tab.registry.makeFirstResponder(for: focusedID, in: window)
    }


    // MARK: - Tab Activation Helpers

    private func activateCurrentTab() {
        guard let tab = activeTab else { return }

        markdownPreviewCoordinator.syncForActiveTab(activeTabID: tab.id)

        let visibleIDs = Set(tab.splitTree.allLeafIDs())
        tab.registry.resumeVisible(visibleIDs: visibleIDs)

        rebuildSplitContainer()
        updateLayout()
        syncWindowTitleWithFocusedPane(in: tab)
        syncFocusToSurfaceTree(in: tab)
        focusActiveTabImmediately()
        restoreFocus()
    }

    private func deactivateCurrentTab() {
        guard let tab = activeTab else { return }
        tab.registry.pauseAll()
    }

    /// Update libghostty focus for every pane in the tab.
    private func syncFocusToSurfaceTree(in tab: Tab) {
        let windowIsKey = window?.isKeyWindow ?? false
        tab.registry.syncFocus(focusedID: tab.splitTree.focusedLeafID, windowIsKey: windowIsKey)
    }

    private func applyWindowOcclusion(visible: Bool) {
        guard let activeTab else {
            for workspace in windowSession.workspaces {
                for tab in workspace.tabs {
                    tab.registry.setOcclusionForAll(occluded: true)
                }
            }
            return
        }

        for workspace in windowSession.workspaces {
            for tab in workspace.tabs {
                if visible && tab.id == activeTab.id {
                    let visibleIDs = Set(tab.splitTree.allLeafIDs())
                    tab.registry.resumeVisible(visibleIDs: visibleIDs)
                } else {
                    tab.registry.pauseAll()
                }
            }
        }

        if visible {
            syncFocusToSurfaceTree(in: activeTab)
        }
    }

    private func syncWindowTitleWithFocusedPane(in tab: Tab) {
        syncTabTitleWithFocusedPane(in: tab)
    }

    /// Keeps the tab label and window title aligned with whichever pane is focused (terminal or browser).
    private func syncTabTitleWithFocusedPane(in tab: Tab) {
        guard let fid = tab.splitTree.focusedLeafID else { return }
        if tab.usesCustomTitle { return }

        if tab.registry.browserController(for: fid) != nil {
            tab.title = resolvedBrowserTabTitle(tab: tab, focusedPaneID: fid)
        } else {
            tab.title = resolvedTerminalTabTitle(tab: tab, focusedPaneID: fid)
        }

        if tab.id == activeTab?.id {
            window?.title = tab.tabBarLabel
        }
    }

    private func resolvedTerminalTabTitle(tab: Tab, focusedPaneID: UUID) -> String {
        if let surfaceTitle = tab.registry.title(for: focusedPaneID), !surfaceTitle.isEmpty {
            return surfaceTitle
        }
        return ""
    }

    private func resolvedBrowserTabTitle(tab: Tab, focusedPaneID: UUID) -> String {
        guard let c = tab.registry.browserController(for: focusedPaneID) else { return "" }
        if c.browserState.url.absoluteString.lowercased() == "about:blank" {
            return ""
        }
        if let raw = tab.registry.title(for: focusedPaneID), !raw.isEmpty {
            return raw
        }
        return ""
    }

    private func pageTitleForBrowserCallbacks(tab: Tab, paneID: UUID, suggestedTitle: String) -> String {
        guard let c = tab.registry.browserController(for: paneID) else { return suggestedTitle }
        if c.browserState.url.absoluteString.lowercased() == "about:blank" {
            return ""
        }
        return suggestedTitle
    }

    // MARK: - Tab Operations

    func createNewTabAdjacent(inheritedConfig: Any? = nil) {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window,
              let workspace = windowSession.activeWorkspace else { return }

        let tab = Tab()

        var config: ghostty_surface_config_s
        if let inherited = inheritedConfig as? ghostty_surface_config_s {
            config = inherited
        } else {
            config = GhosttyFFI.surfaceConfigNew()
        }
        config.scale_factor = Double(window.backingScaleFactor)

        // Inherit working directory: from current tab's pwd, or workspace's working directory
        let pwd = activeTab?.pwd ?? workspace.workingDirectory

        guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: pwd) else {
            logger.error("Failed to create surface for new tab")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        activeTab?.registry.pauseAll()

        workspace.insertTabAdjacentToActive(tab)
        workspace.activeTabID = tab.id

        activateCurrentTab()
    }

    func createNewTabAtEnd() {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window,
              let workspace = windowSession.activeWorkspace else { return }

        let tab = Tab()

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        // Home directory (pass nil for pwd to use default)
        guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: nil) else {
            logger.error("Failed to create surface for new tab (end)")
            return
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        activeTab?.registry.pauseAll()

        workspace.addTab(tab)
        workspace.activeTabID = tab.id

        activateCurrentTab()
    }

    @discardableResult
    func createBrowserTab(initialURL: URL = URL(string: "about:blank")!) -> UUID? {
        guard let workspace = windowSession.activeWorkspace else { return nil }

        let tabTitle: String
        if initialURL.absoluteString.lowercased() == "about:blank" {
            tabTitle = ""
        } else {
            tabTitle = initialURL.host ?? initialURL.absoluteString
        }
        let tab = Tab(title: tabTitle)
        guard let browserPaneID = tab.registry.createBrowser(initialURL: initialURL),
              let controller = tab.registry.browserController(for: browserPaneID) else {
            logger.error("Failed to create browser tab")
            return nil
        }

        tab.splitTree = SplitTree(leafID: browserPaneID)
        wireBrowserCallbacks(controller: controller, paneID: browserPaneID, tab: tab)

        activeTab?.registry.pauseAll()

        workspace.insertTabAdjacentToActive(tab)
        workspace.activeTabID = tab.id

        activateCurrentTab()
        scheduleFocusBrowserAddressBar(paneID: browserPaneID)
        return browserPaneID
    }

    @discardableResult
    private func createBrowserSplit(initialURL: URL = URL(string: "about:blank")!, direction: SplitDirection) -> UUID? {
        guard let tab = activeTab,
              let currentFocusID = tab.splitTree.focusedLeafID else { return nil }

        guard let browserPaneID = tab.registry.createBrowser(initialURL: initialURL),
              let controller = tab.registry.browserController(for: browserPaneID) else {
            logger.error("Failed to create browser split")
            return nil
        }

        wireBrowserCallbacks(controller: controller, paneID: browserPaneID, tab: tab)

        let insertionDirection: SpatialDirection = direction == .horizontal ? .right : .down
        let (newTree, _) = tab.splitTree.insert(at: currentFocusID, toward: insertionDirection, newID: browserPaneID)
        tab.splitTree = newTree
        updateLayout()
        focusPane(in: tab, targetID: browserPaneID)
        scheduleFocusBrowserAddressBar(paneID: browserPaneID)
        return browserPaneID
    }

    private func scheduleFocusBrowserAddressBar(paneID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.requestFocusBrowserAddressBar(paneID: paneID)
        }
    }

    private func requestFocusBrowserAddressBar(paneID: UUID) {
        guard window?.isKeyWindow == true else { return }
        resignEphemeralFirstRespondersForSwiftUIEditing()
        window?.makeFirstResponder(hostingView)
        NotificationCenter.default.post(
            name: .frosttyFocusBrowserAddressBar,
            object: nil,
            userInfo: ["paneID": paneID]
        )
    }

    private func focusBrowserAddressBar() {
        guard let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              tab.registry.browserController(for: focusedID) != nil else { return }
        requestFocusBrowserAddressBar(paneID: focusedID)
    }

    /// Closes the focused browser pane (Ctrl+D). If it is the only pane, closes the tab.
    private func closeActiveBrowserPaneIfPossible() {
        guard let tab = activeTab,
              let fid = tab.splitTree.focusedLeafID,
              tab.registry.browserController(for: fid) != nil else { return }

        let (newTree, focusTarget) = tab.splitTree.remove(fid)
        tab.registry.destroyPane(fid)
        tab.splitTree = newTree

        if closingTabIDs.contains(tab.id) { return }

        if tab.splitTree.isEmpty {
            closeTab(id: tab.id)
            return
        }

        if tab.id == activeTab?.id {
            updateLayout()
            if let focusID = focusTarget {
                focusPane(in: tab, targetID: focusID)
            }
        }
    }

    /// Resign terminal / in-pane web views so SwiftUI fields (tab rename, browser omnibar) can take focus.
    private func resignEphemeralFirstRespondersForSwiftUIEditing() {
        if let surfaceView = window?.firstResponder as? SurfaceView {
            surfaceView.surfaceController?.setFocus(false)
        }
        if let view = window?.firstResponder as? NSView {
            var current: NSView? = view
            while let c = current {
                if c is BrowserPaneView {
                    window?.makeFirstResponder(nil)
                    return
                }
                current = c.superview
            }
        }
    }

    @objc func newBrowserTab(_ sender: Any? = nil) {
        openBrowser(destination: .newTab)
    }

    @objc func toggleMarkdownPreview(_ sender: Any? = nil) {
        markdownPreviewCoordinator.toggle()
    }

    @discardableResult
    func handleMarkdownPreviewAction(path: String?, source: MarkdownPreviewInvocationSource) -> Bool {
        markdownPreviewCoordinator.handleAction(path: path, source: source)
    }

    private func openBrowser(destination: BrowserOpenDestination) {
        switch destination {
        case .newTab:
            _ = createBrowserTab()
        case .split(let direction):
            _ = createBrowserSplit(direction: direction)
        }
    }

    private func wireBrowserCallbacks(controller: BrowserTabController, paneID: UUID, tab: Tab) {
        controller.browserView.onTitleChanged = { [weak self, weak tab] title in
            guard let self, let tab else { return }
            guard !tab.usesCustomTitle else { return }
            let shouldUpdateTabTitle = tab.splitTree.allLeafIDs().count == 1 || tab.splitTree.focusedLeafID == paneID
            guard shouldUpdateTabTitle else { return }
            let next = self.pageTitleForBrowserCallbacks(tab: tab, paneID: paneID, suggestedTitle: title)
            tab.title = next
            if tab.id == self.activeTab?.id, tab.splitTree.focusedLeafID == paneID {
                self.window?.title = tab.tabBarLabel
            }
        }

        controller.browserView.onURLChanged = { [weak self, weak tab, weak controller] _ in
            guard let self, let tab, let controller else { return }
            guard !tab.usesCustomTitle else { return }
            let shouldRefreshTitle = tab.splitTree.allLeafIDs().count == 1 || tab.splitTree.focusedLeafID == paneID
            guard shouldRefreshTitle else { return }
            let next = self.pageTitleForBrowserCallbacks(tab: tab, paneID: paneID, suggestedTitle: controller.title)
            tab.title = next
            if tab.id == self.activeTab?.id, tab.splitTree.focusedLeafID == paneID {
                self.window?.title = tab.tabBarLabel
            }
        }
    }


    @objc func requestCloseActiveTab(_ sender: Any? = nil) {
        guard let tabID = activeTab?.id else { return }
        requestCloseTab(id: tabID)
    }

    private func requestCloseTab(id tabID: UUID) {
        guard let (tab, _) = tabAndWorkspace(for: tabID) else { return }
        guard tabNeedsConfirmQuit(tab) else {
            closeTab(id: tabID)
            return
        }
        guard let window = self.window else {
            closeTab(id: tabID)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close Tab?"
        alert.informativeText = "A process is still running in this tab. Do you want to close it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.closeTab(id: tabID)
            }
        }
    }

    private func closeTab(id tabID: UUID) {
        guard !closingTabIDs.contains(tabID) else { return }
        guard let (tab, workspace) = tabAndWorkspace(for: tabID) else { return }

        markdownPreviewCoordinator.dismissIfOwnedBy(tabID: tabID)

        closingTabIDs.insert(tabID)

        // Destroy all surfaces in the tab
        for surfaceID in tab.registry.allIDs {
            tab.registry.destroySurface(surfaceID)
        }

        let result = windowSession.removeTab(id: tabID, fromWorkspace: workspace.id)

        switch result {
        case .switchedTab, .switchedWorkspace:
            activateCurrentTab()
        case .windowShouldClose:
            window?.close()
        }

        closingTabIDs.remove(tabID)
    }

    private func tabNeedsConfirmQuit(_ tab: Tab) -> Bool {
        tab.registry.allIDs.contains { surfaceID in
            tab.registry.controller(for: surfaceID)?.needsConfirmQuit == true
        }
    }

    func switchToTab(id tabID: UUID) {
        guard let targetWorkspace = windowSession.workspaces.first(where: { ws in
            ws.tabs.contains(where: { $0.id == tabID })
        }) else { return }
        let sameWorkspace = windowSession.activeWorkspaceID == targetWorkspace.id
        let sameTab = sameWorkspace && targetWorkspace.activeTabID == tabID
        guard !sameTab else { return }

        deactivateCurrentTab()
        windowSession.activeWorkspaceID = targetWorkspace.id
        targetWorkspace.activeTabID = tabID
        activateCurrentTab()
    }

    private func switchToTabByIndex(_ index: Int) {
        guard index >= 0 else { return }
        deactivateCurrentTab()
        windowSession.selectTab(at: index)
        activateCurrentTab()
    }

    private func moveTab(fromIndex: Int, toIndex: Int) {
        guard let workspace = windowSession.activeWorkspace else { return }
        workspace.moveTab(fromIndex: fromIndex, toIndex: toIndex)
    }

    // MARK: - Workspace Operations

    private func createNewWorkspaceFromShortcut() {
        let n = windowSession.workspaces.count + 1
        createNewWorkspace(name: "Workspace \(n)", workingDirectory: nil)
    }

    @discardableResult
    func createNewWorkspace(name: String, workingDirectory: String?) -> Bool {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window else { return false }

        let sanitizedWorkingDirectory: String?
        do {
            sanitizedWorkingDirectory = try WorkingDirectoryValidator.sanitize(workingDirectory)
        } catch let error as WorkingDirectoryValidationError {
            presentInvalidWorkingDirectoryAlert(error, for: window)
            return false
        } catch {
            presentInvalidWorkingDirectoryAlert(WorkingDirectoryValidator.validationError(for: workingDirectory), for: window)
            return false
        }

        let tab = Tab()

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: sanitizedWorkingDirectory) else {
            logger.error("Failed to create surface for new workspace")
            return false
        }

        tab.splitTree = SplitTree(leafID: surfaceID)

        activeTab?.registry.pauseAll()

        let workspace = Workspace(
            name: name,
            workingDirectory: sanitizedWorkingDirectory,
            tabs: [tab],
            activeTabID: tab.id
        )

        windowSession.addWorkspace(workspace)
        windowSession.activeWorkspaceID = workspace.id

        activateCurrentTab()
        return true
    }

    private func closeActiveWorkspace() {
        guard let workspace = windowSession.activeWorkspace else { return }
        deleteWorkspace(id: workspace.id)
    }

    private func deleteWorkspaceWithConfirmation(id wsID: UUID) {
        guard let workspace = windowSession.workspaces.first(where: { $0.id == wsID }) else { return }
        guard let window = self.window else { deleteWorkspace(id: wsID); return }

        let alert = NSAlert()
        alert.messageText = "Delete Workspace \"\(workspace.name)\"?"
        alert.informativeText = "This will close all \(workspace.tabs.count) tab(s) in this workspace. Any running processes will be terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.deleteWorkspace(id: wsID)
            }
        }
    }

    private func deleteWorkspace(id wsID: UUID) {
        guard let workspace = windowSession.workspaces.first(where: { $0.id == wsID }) else { return }

        let tabIDs = workspace.tabs.map { $0.id }
        for tabID in tabIDs {
            closingTabIDs.insert(tabID)
        }

        // Destroy all surfaces in all tabs of this workspace
        for tab in workspace.tabs {
            for surfaceID in tab.registry.allIDs {
                tab.registry.destroySurface(surfaceID)
            }
        }

        let result = windowSession.removeWorkspace(id: wsID)

        for tabID in tabIDs {
            closingTabIDs.remove(tabID)
        }

        switch result {
        case .switchedTab, .switchedWorkspace:
            activateCurrentTab()
        case .windowShouldClose:
            window?.close()
        }
    }

    func switchToWorkspace(id wsID: UUID) {
        guard windowSession.workspaces.contains(where: { $0.id == wsID }) else { return }
        guard windowSession.activeWorkspaceID != wsID else { return }

        deactivateCurrentTab()
        windowSession.activeWorkspaceID = wsID
        activateCurrentTab()
    }

    private func switchToWorkspaceByIndex(_ index: Int) {
        guard index >= 0, index < windowSession.workspaces.count else { return }
        let wsID = windowSession.workspaces[index].id
        guard windowSession.activeWorkspaceID != wsID else { return }
        deactivateCurrentTab()
        windowSession.selectWorkspace(at: index)
        activateCurrentTab()
    }

    private func moveWorkspace(fromIndex: Int, toIndex: Int) {
        windowSession.moveWorkspace(fromIndex: fromIndex, toIndex: toIndex)
    }

    private func renameWorkspace(id wsID: UUID, name: String) {
        guard let workspace = windowSession.workspaces.first(where: { $0.id == wsID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            workspace.name = trimmed
        }
    }

    @discardableResult
    private func setWorkingDirectory(for wsID: UUID, path: String?) -> Bool {
        guard let workspace = windowSession.workspaces.first(where: { $0.id == wsID }) else { return false }

        let sanitizedPath: String?
        do {
            sanitizedPath = try WorkingDirectoryValidator.sanitize(path)
        } catch let error as WorkingDirectoryValidationError {
            presentInvalidWorkingDirectoryAlert(error)
            return false
        } catch {
            presentInvalidWorkingDirectoryAlert(WorkingDirectoryValidator.validationError(for: path))
            return false
        }

        workspace.workingDirectory = sanitizedPath
        return true
    }

    private func presentInvalidWorkingDirectoryAlert(_ error: WorkingDirectoryValidationError, for window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = "Invalid Working Directory"
        alert.informativeText = error.alertDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        if let window = window ?? self.window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    private func renameTab(id tabID: UUID, name: String) {
        guard let workspace = windowSession.workspaces.first(where: { ws in
            ws.tabs.contains(where: { $0.id == tabID })
        }),
            let tab = workspace.tabs.first(where: { $0.id == tabID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tab.title = trimmed
            tab.usesCustomTitle = true
            if tab.id == activeTab?.id {
                window?.title = trimmed
            }
        } else {
            tab.usesCustomTitle = false
            tab.title = ""
            syncTabTitleWithFocusedPane(in: tab)
        }
    }

    @objc func toggleSidebar() {
        windowSession.showSidebar.toggle()
        updateWindowDecorations()
        // Restore keyboard focus to the terminal after sidebar toggle
        restoreFocus()
    }

    private func updateWindowDecorations() {
        guard let window = self.window else { return }
        let showDecorations = windowSession.showSidebar
        (window as? FrosttyWindow)?.disablesTitlebarDragging = !showDecorations

        // Keep .titled in the styleMask always — removing it breaks keyboard focus.
        // Instead we hide the titlebar chrome and let SwiftUI extend content into that space.
        window.standardWindowButton(.closeButton)?.isHidden = !showDecorations
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !showDecorations
        window.standardWindowButton(.zoomButton)?.isHidden = !showDecorations
        window.titlebarSeparatorStyle = showDecorations ? .automatic : .none

        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.superview?.alphaValue = showDecorations ? 1.0 : 0.0
        }
    }

    private func updateWindowBackgroundAppearance() {
        guard let window = self.window else { return }

        let config = GhosttyAppController.shared.configManager
        let opacity = config.backgroundOpacity
        let shouldUseTransparentBackground = !window.styleMask.contains(.fullScreen) && opacity < 1.0

        if shouldUseTransparentBackground {
            window.isOpaque = false
            // Match Ghostty's macOS behavior: make the window itself transparent and
            // let the terminal renderer provide the tinted background content.
            window.backgroundColor = .white.withAlphaComponent(0.001)

            if let app = GhosttyAppController.shared.app {
                GhosttyFFI.setWindowBackgroundBlur(
                    app,
                    window: Unmanaged.passUnretained(window).toOpaque()
                )
            }
        } else {
            window.isOpaque = true
            window.backgroundColor = config.backgroundColor.withAlphaComponent(1.0)
        }
    }

    // MARK: - Split Operations

    func splitPane(direction: SplitDirection) {
        guard let app = GhosttyAppController.shared.app,
              let window = self.window,
              let tab = activeTab,
              let currentFocusID = tab.splitTree.focusedLeafID else { return }

        var config = GhosttyFFI.surfaceConfigNew()
        config.scale_factor = Double(window.backingScaleFactor)

        let pwd = tab.pwd ?? windowSession.activeWorkspace?.workingDirectory

        guard let newSurfaceID = tab.registry.createSurface(app: app, config: config, pwd: pwd) else {
            logger.error("Failed to create split surface")
            return
        }

        let insertionDirection: SpatialDirection = direction == .horizontal ? .right : .down
        let (newTree, _) = tab.splitTree.insert(at: currentFocusID, toward: insertionDirection, newID: newSurfaceID)
        tab.splitTree = newTree

        updateLayout()
        focusPane(in: tab, targetID: newSurfaceID)
    }

    private func navigatePane(direction: FocusDirection) {
        guard let tab = activeTab,
              let currentID = tab.splitTree.focusedLeafID,
              let targetID = paneFocusTarget(in: tab, requestedDirection: direction, from: currentID) else { return }

        focusPane(in: tab, targetID: targetID)
    }

    private func enterResizeMode() {
        guard let tab = activeTab, !tab.isPaneMaximized, !isPaneResizeMode else { return }
        isPaneResizeMode = true
        refreshHostingView()
        restoreFocus()
    }

    private func exitResizeMode() {
        guard isPaneResizeMode else { return }
        isPaneResizeMode = false
        refreshHostingView()
        restoreFocus()
    }

    private func togglePaneMaximizedLayout() {
        guard let tab = activeTab else { return }
        if !tab.isPaneMaximized, isPaneResizeMode {
            exitResizeMode()
        }
        tab.isPaneMaximized.toggle()
        updateLayout()
        restoreFocus()
    }

    private func resizeFocusedPane(direction: SpatialDirection, steps: Int) {
        guard steps > 0,
              let tab = activeTab,
              let focusedID = tab.splitTree.focusedLeafID,
              let container = splitContainerView else { return }

        let amountPerStep: CGFloat

        if let focusedView = tab.registry.view(for: focusedID) {
            switch direction {
            case .left, .right:
                amountPerStep = focusedView.cachedCellSize.width
            case .up, .down:
                amountPerStep = focusedView.cachedCellSize.height
            }
        } else {
            amountPerStep = 24
        }

        guard amountPerStep > 0 else { return }

        tab.splitTree = tab.splitTree.resize(
            node: focusedID,
            by: Double(amountPerStep * CGFloat(steps)),
            toward: direction,
            bounds: container.bounds.size,
            minSize: 50
        )
        updateLayout()
    }

    private func paneFocusTarget(in tab: Tab, requestedDirection: FocusDirection, from leafID: UUID) -> UUID? {
        let effectiveDirection: FocusDirection

        if tab.isPaneMaximized, case .spatial(let spatialDirection) = requestedDirection {
            switch spatialDirection {
            case .left, .up:
                effectiveDirection = .previous
            case .right, .down:
                effectiveDirection = .next
            }
        } else {
            effectiveDirection = requestedDirection
        }

        return tab.splitTree.focusTarget(for: effectiveDirection, from: leafID)
    }

    private func focusPane(in tab: Tab, targetID: UUID) {
        guard tab.registry.paneView(for: targetID) != nil else { return }
        tab.splitTree.focusedLeafID = targetID
        syncFocusToSurfaceTree(in: tab)
        _ = tab.registry.makeFirstResponder(for: targetID, in: window)
        syncTabTitleWithFocusedPane(in: tab)
        updateLayout()
    }

    private func synchronizePaneFocus(in tab: Tab, focusedID: UUID) {
        syncFocusToSurfaceTree(in: tab)
    }

    private func markFocusedPane(in tab: Tab, focusedID: UUID) {
        syncTabTitleWithFocusedPane(in: tab)
    }

    func renameActiveTab() {
        guard let tab = activeTab else { return }
        resignEphemeralFirstRespondersForSwiftUIEditing()
        window?.makeFirstResponder(hostingView)
        NotificationCenter.default.post(
            name: .frosttyRenameTab,
            object: nil,
            userInfo: ["tabID": tab.id]
        )
    }

    private func handleDividerDrag(path: [SplitPathBranch], ratio: Double, splitSize: CGSize) {
        guard let tab = activeTab else { return }
        tab.splitTree = tab.splitTree.settingRatio(
            at: path,
            to: ratio,
            in: splitSize,
            minSize: 50
        )
        updateLayout()
    }

    private func handlePaneDrop(sourceID: UUID, destinationID: UUID, zone: PaneDropZone) {
        guard sourceID != destinationID,
              let tab = activeTab,
              tab.registry.contains(sourceID),
              tab.registry.contains(destinationID) else { return }

        let direction = paneDirection(for: zone)
        let (treeWithoutSource, _) = tab.splitTree.remove(sourceID)
        let (newTree, _) = treeWithoutSource.insert(at: destinationID, toward: direction, newID: sourceID)
        tab.splitTree = newTree
        focusPane(in: tab, targetID: sourceID)
        postPaneRestructureCompleted(sourceTabID: tab.id, destinationTabID: tab.id, paneID: sourceID)
        syncTabTitlesForRestructuredPanes(sourceTabID: tab.id, destinationTabID: tab.id)
    }

    private func postPaneRestructureCompleted(sourceTabID: UUID, destinationTabID: UUID, paneID: UUID) {
        NotificationCenter.default.post(
            name: .frosttyPaneRestructureCompleted,
            object: nil,
            userInfo: [
                FrosttyUserInfoKey.paneRestructureSourceTabID: sourceTabID,
                FrosttyUserInfoKey.paneRestructureDestinationTabID: destinationTabID,
                FrosttyUserInfoKey.paneRestructurePaneID: paneID
            ]
        )
    }

    private func syncTabTitlesForRestructuredPanes(sourceTabID: UUID, destinationTabID: UUID) {
        for workspace in windowSession.workspaces {
            for tab in workspace.tabs where tab.id == sourceTabID || tab.id == destinationTabID {
                syncTabTitleWithFocusedPane(in: tab)
            }
        }
        refreshHostingView()
    }

    private func handlePaneDetachToNewTab(sourceID: UUID, screenPoint: NSPoint) {
        guard let window,
              let container = splitContainerView,
              let tab = activeTab,
              let workspace = windowSession.activeWorkspace,
              tab.registry.contains(sourceID) else { return }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let containerPoint = container.convert(windowPoint, from: nil)

        // Only detach when the drop ends outside the pane container.
        guard !container.bounds.contains(containerPoint) else { return }

        guard let sourceIndex = workspace.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        movePaneToNewTab(sourceID: sourceID, insertionSlot: sourceIndex + 1)
    }

    private func movePaneToNewTab(sourceID: UUID, insertionSlot: Int) {
        guard canMovePaneToNewTab(sourceID: sourceID) else { return }
        guard let move = detachPaneForMove(sourceID) else { return }
        let newTab = makeDetachedPaneTab(from: move)

        move.sourceWorkspace.insertTab(newTab, at: insertionSlot)
        move.sourceWorkspace.activeTabID = newTab.id
        windowSession.activeWorkspaceID = move.sourceWorkspace.id

        activateCurrentTab()
        postPaneRestructureCompleted(sourceTabID: move.sourceTab.id, destinationTabID: newTab.id, paneID: move.paneID)
        syncTabTitlesForRestructuredPanes(sourceTabID: move.sourceTab.id, destinationTabID: newTab.id)
    }

    private func movePaneToWorkspace(sourceID: UUID, workspaceID: UUID) {
        guard workspaceID != windowSession.activeWorkspaceID,
              let targetWorkspace = windowSession.workspaces.first(where: { $0.id == workspaceID }),
              let move = detachPaneForMove(sourceID) else { return }

        let newTab = makeDetachedPaneTab(from: move)
        targetWorkspace.addTab(newTab)
        targetWorkspace.activeTabID = newTab.id
        windowSession.activeWorkspaceID = targetWorkspace.id
        finalizeSourceWorkspaceAfterPaneMove(move, destinationWorkspaceID: targetWorkspace.id)

        activateCurrentTab()
        postPaneRestructureCompleted(sourceTabID: move.sourceTab.id, destinationTabID: newTab.id, paneID: move.paneID)
        syncTabTitlesForRestructuredPanes(sourceTabID: move.sourceTab.id, destinationTabID: newTab.id)
    }

    private func movePaneToNewWorkspace(sourceID: UUID, insertionSlot: Int) {
        guard let move = detachPaneForMove(sourceID) else { return }

        let newTab = makeDetachedPaneTab(from: move)
        let newWorkspace = Workspace(
            name: "Workspace \(windowSession.workspaces.count + 1)",
            workingDirectory: newTab.pwd ?? move.sourceWorkspace.workingDirectory,
            tabs: [newTab],
            activeTabID: newTab.id
        )

        windowSession.insertWorkspace(newWorkspace, at: insertionSlot)
        windowSession.activeWorkspaceID = newWorkspace.id
        finalizeSourceWorkspaceAfterPaneMove(move, destinationWorkspaceID: newWorkspace.id)

        activateCurrentTab()
        postPaneRestructureCompleted(sourceTabID: move.sourceTab.id, destinationTabID: newTab.id, paneID: move.paneID)
        syncTabTitlesForRestructuredPanes(sourceTabID: move.sourceTab.id, destinationTabID: newTab.id)
    }

    private func detachPaneForMove(_ sourceID: UUID) -> DetachedPaneMove? {
        guard let (sourceTab, sourceWorkspace) = findTabContainingPane(id: sourceID),
              let entry = sourceTab.registry.detachPane(sourceID) else {
            return nil
        }

        markdownPreviewCoordinator.dismissIfOwnedBy(paneID: sourceID)

        let sourceTabWasActive = sourceTab.id == activeTab?.id
        let sourceTabRemoved = sourceTab.splitTree.allLeafIDs().count == 1

        if sourceTabWasActive {
            deactivateCurrentTab()
        }

        if sourceTabRemoved {
            sourceWorkspace.removeTab(id: sourceTab.id)
        } else {
            let (newSourceTree, _) = sourceTab.splitTree.remove(sourceID)
            guard !newSourceTree.isEmpty else {
                sourceTab.registry.attachDetachedPane(entry, id: sourceID)
                if sourceTabWasActive {
                    activateCurrentTab()
                }
                return nil
            }

            sourceTab.splitTree = newSourceTree
            sourceTab.isPaneMaximized = false
        }

        let preserveCustomTitle = sourceTabRemoved && sourceTab.usesCustomTitle && !sourceTab.title.isEmpty

        return DetachedPaneMove(
            paneID: sourceID,
            entry: entry,
            sourceTab: sourceTab,
            sourceWorkspace: sourceWorkspace,
            sourceTabWasActive: sourceTabWasActive,
            sourceTabRemoved: sourceTabRemoved,
            newTabTitle: {
                if preserveCustomTitle {
                    return sourceTab.title
                }
                if let title = entry.title, !title.isEmpty {
                    return title
                }
                return sourceTab.title
            }(),
            newTabUsesCustomTitle: preserveCustomTitle,
            newTabPWD: entry.pwd ?? sourceTab.pwd
        )
    }

    private func makeDetachedPaneTab(from move: DetachedPaneMove) -> Tab {
        let newTab = Tab(
            title: move.newTabTitle,
            pwd: move.newTabPWD,
            usesCustomTitle: move.newTabUsesCustomTitle
        )
        newTab.registry.attachDetachedPane(move.entry, id: move.paneID)
        newTab.splitTree = SplitTree(leafID: move.paneID)
        if let controller = newTab.registry.browserController(for: move.paneID) {
            wireBrowserCallbacks(controller: controller, paneID: move.paneID, tab: newTab)
        }
        return newTab
    }

    private func canMovePaneToNewTab(sourceID: UUID) -> Bool {
        guard let (sourceTab, _) = findTabContainingPane(id: sourceID) else { return false }
        return sourceTab.splitTree.allLeafIDs().count > 1
    }

    private func finalizeSourceWorkspaceAfterPaneMove(_ move: DetachedPaneMove, destinationWorkspaceID: UUID) {
        guard move.sourceTabRemoved,
              move.sourceWorkspace.id != destinationWorkspaceID,
              move.sourceWorkspace.tabs.isEmpty,
              let sourceWorkspaceIndex = windowSession.workspaces.firstIndex(where: { $0.id == move.sourceWorkspace.id }) else {
            return
        }

        windowSession.workspaces.remove(at: sourceWorkspaceIndex)
    }

    private func paneDirection(for zone: PaneDropZone) -> SpatialDirection {
        switch zone {
        case .top:
            return .up
        case .bottom:
            return .down
        case .left:
            return .left
        case .right:
            return .right
        }
    }

    // MARK: - Notification Observers

    private func registerNotificationObservers() {
        let center = NotificationCenter.default

        center.addObserver(self, selector: #selector(handleNewSplitNotification(_:)),
                           name: .ghosttyNewSplit, object: nil)
        center.addObserver(self, selector: #selector(handleCloseSurfaceNotification(_:)),
                           name: .ghosttyCloseSurface, object: nil)
        center.addObserver(self, selector: #selector(handleGotoSplitNotification(_:)),
                           name: .ghosttyGotoSplit, object: nil)
        center.addObserver(self, selector: #selector(handleResizeSplitNotification(_:)),
                           name: .ghosttyResizeSplit, object: nil)
        center.addObserver(self, selector: #selector(handleEqualizeSplitsNotification(_:)),
                           name: .ghosttyEqualizeSplits, object: nil)
        center.addObserver(self, selector: #selector(handleSetTitleNotification(_:)),
                           name: .ghosttySetTitle, object: nil)
        center.addObserver(self, selector: #selector(handleSetPwdNotification(_:)),
                           name: .ghosttySetPwd, object: nil)
        center.addObserver(self, selector: #selector(handleGotoTabNotification(_:)),
                           name: .ghosttyGotoTab, object: nil)
        center.addObserver(self, selector: #selector(handleNewTabNotification(_:)),
                           name: .ghosttyNewTab, object: nil)
        center.addObserver(self, selector: #selector(handleCloseTabNotification(_:)),
                           name: .ghosttyCloseTab, object: nil)
        center.addObserver(self, selector: #selector(handleCloseWindowNotification(_:)),
                           name: .ghosttyCloseWindow, object: nil)
        center.addObserver(self, selector: #selector(handleConfigChangeNotification(_:)),
                           name: .ghosttyConfigChange, object: nil)
        center.addObserver(self, selector: #selector(handleWillBeginEditing(_:)),
                           name: .frosttyWillBeginEditing, object: nil)
        center.addObserver(self, selector: #selector(handleSurfaceDidFocus(_:)),
                           name: .frosttySurfaceDidFocus, object: nil)
        center.addObserver(self, selector: #selector(handleBrowserPaneDidFocus(_:)),
                           name: .frosttyBrowserPaneDidFocus, object: nil)
    }

    // MARK: - Notification Handlers

    @objc private func handleNewSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let app = GhosttyAppController.shared.app else { return }

        let direction = notification.userInfo?["direction"] as? ghostty_action_split_direction_e
        let insertionDirection: SpatialDirection
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT:
            insertionDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_RIGHT:
            insertionDirection = .right
        case GHOSTTY_SPLIT_DIRECTION_UP:
            insertionDirection = .up
        case GHOSTTY_SPLIT_DIRECTION_DOWN:
            insertionDirection = .down
        default:
            insertionDirection = .right
        }

        var config: ghostty_surface_config_s
        if let inheritedConfig = notification.userInfo?["inherited_config"] as? ghostty_surface_config_s {
            config = inheritedConfig
        } else {
            config = GhosttyFFI.surfaceConfigNew()
        }
        if let window = self.window {
            config.scale_factor = Double(window.backingScaleFactor)
        }

        guard let newSurfaceID = tab.registry.createSurface(app: app, config: config) else {
            logger.error("Failed to create split surface")
            return
        }

        let (newTree, _) = tab.splitTree.insert(at: surfaceID, toward: insertionDirection, newID: newSurfaceID)
        tab.splitTree = newTree

        updateLayout()
        focusPane(in: tab, targetID: newSurfaceID)
    }

    @objc private func handleCloseSurfaceNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let (owningTab, owningWorkspace) = findTab(for: surfaceView) else { return }
        guard let surfaceID = owningTab.registry.id(for: surfaceView) else { return }

        markdownPreviewCoordinator.dismissIfOwnedBy(paneID: surfaceID)

        let (newTree, focusTarget) = owningTab.splitTree.remove(surfaceID)
        owningTab.registry.destroySurface(surfaceID)
        owningTab.splitTree = newTree

        if closingTabIDs.contains(owningTab.id) { return }

        if owningTab.splitTree.isEmpty {
            let wasActiveTab = (owningTab.id == activeTab?.id)
            let result = windowSession.removeTab(id: owningTab.id, fromWorkspace: owningWorkspace.id)
            if wasActiveTab {
                switch result {
                case .switchedTab, .switchedWorkspace:
                    activateCurrentTab()
                case .windowShouldClose:
                    window?.close()
                }
            } else {
                refreshHostingView()
            }
            return
        }

        if owningTab.id == activeTab?.id {
            updateLayout()
            if let focusID = focusTarget {
                focusPane(in: owningTab, targetID: focusID)
            }
        }
    }

    @objc private func handleGotoSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }

        let direction = notification.userInfo?["direction"] as? ghostty_action_goto_split_e

        let focusDir: FocusDirection
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: focusDir = .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: focusDir = .next
        case GHOSTTY_GOTO_SPLIT_LEFT: focusDir = .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: focusDir = .spatial(.right)
        case GHOSTTY_GOTO_SPLIT_UP: focusDir = .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: focusDir = .spatial(.down)
        default: focusDir = .next
        }

        guard let targetID = paneFocusTarget(in: tab, requestedDirection: focusDir, from: surfaceID) else { return }
        focusPane(in: tab, targetID: targetID)
    }

    @objc private func handleResizeSplitNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard let tab = activeTab else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let container = splitContainerView else { return }
        guard let resize = notification.userInfo?["resize"] as? ghostty_action_resize_split_s else { return }

        let direction: SpatialDirection
        let amountPerStep: CGFloat
        switch resize.direction {
        case GHOSTTY_RESIZE_SPLIT_LEFT:
            direction = .left
            amountPerStep = surfaceView.cachedCellSize.width
        case GHOSTTY_RESIZE_SPLIT_RIGHT:
            direction = .right
            amountPerStep = surfaceView.cachedCellSize.width
        case GHOSTTY_RESIZE_SPLIT_UP:
            direction = .up
            amountPerStep = surfaceView.cachedCellSize.height
        case GHOSTTY_RESIZE_SPLIT_DOWN:
            direction = .down
            amountPerStep = surfaceView.cachedCellSize.height
        default:
            direction = .right
            amountPerStep = surfaceView.cachedCellSize.width
        }

        guard amountPerStep > 0 else { return }

        let amount = Double(amountPerStep) * Double(resize.amount)
        tab.splitTree = tab.splitTree.resize(
            node: surfaceID,
            by: amount,
            toward: direction,
            bounds: container.bounds.size,
            minSize: 50
        )
        updateLayout()
    }

    @objc private func handleEqualizeSplitsNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard belongsToThisWindow(surfaceView) else { return }
        }
        guard let tab = activeTab else { return }
        tab.splitTree = tab.splitTree.equalize()
        updateLayout()
    }

    @objc private func handleSetTitleNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let title = notification.userInfo?["title"] as? String else { return }
        guard let (tab, _) = findTab(for: surfaceView) else { return }
        guard !tab.usesCustomTitle else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView),
              tab.splitTree.focusedLeafID == surfaceID else { return }

        tab.title = title
        if tab.id == activeTab?.id {
            window?.title = tab.tabBarLabel
        }
    }

    @objc private func handleSetPwdNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let pwd = notification.userInfo?["pwd"] as? String else { return }
        guard let (owningTab, _) = findTab(for: surfaceView) else { return }
        owningTab.pwd = pwd
    }

    @objc private func handleGotoTabNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard findTab(for: surfaceView) != nil else { return }
        guard let rawValue = notification.userInfo?["tab"] as? Int32 else { return }

        switch rawValue {
        case GHOSTTY_GOTO_TAB_NEXT.rawValue:
            deactivateCurrentTab()
            windowSession.nextTab()
            activateCurrentTab()
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue:
            deactivateCurrentTab()
            windowSession.previousTab()
            activateCurrentTab()
        case GHOSTTY_GOTO_TAB_LAST.rawValue:
            let lastIndex = (windowSession.activeWorkspace?.tabs.count ?? 1) - 1
            switchToTabByIndex(lastIndex)
        default:
            if rawValue >= 0 {
                switchToTabByIndex(Int(rawValue))
            }
        }
    }

    @objc private func handleNewTabNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard belongsToThisWindow(surfaceView) else { return }
        }
        createNewTabAdjacent(inheritedConfig: notification.userInfo?["inherited_config"])
    }

    @objc private func handleCloseTabNotification(_ notification: Notification) {
        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let (tab, _) = findTab(for: surfaceView) else { return }
        requestCloseTab(id: tab.id)
    }

    @objc private func handleCloseWindowNotification(_ notification: Notification) {
        if let surfaceView = notification.object as? SurfaceView {
            guard belongsToThisWindow(surfaceView) else { return }
        }
        NSApp.terminate(nil)
    }

    @objc private func handleConfigChangeNotification(_ notification: Notification) {
        updateWindowBackgroundAppearance()
    }

    @objc private func handleWillBeginEditing(_ notification: Notification) {
        resignEphemeralFirstRespondersForSwiftUIEditing()
        window?.makeFirstResponder(hostingView)
    }

    @objc private func handleSurfaceDidFocus(_ notification: Notification) {
        if markdownPreviewCoordinator.shouldRestoreFocusFromTerminalOrBrowser() {
            return
        }

        guard let surfaceView = notification.object as? SurfaceView else { return }
        guard belongsToThisWindow(surfaceView) else { return }
        guard let (tab, _) = findTab(for: surfaceView) else { return }
        guard let surfaceID = tab.registry.id(for: surfaceView) else { return }
        guard tab.splitTree.focusedLeafID != surfaceID else { return }

        tab.splitTree.focusedLeafID = surfaceID
        synchronizePaneFocus(in: tab, focusedID: surfaceID)
        markFocusedPane(in: tab, focusedID: surfaceID)
        if tab.id == activeTab?.id {
            updateLayout()
        }
    }

    @objc private func handleBrowserPaneDidFocus(_ notification: Notification) {
        if markdownPreviewCoordinator.shouldRestoreFocusFromTerminalOrBrowser() {
            return
        }

        guard let paneView = notification.object as? BrowserPaneView else { return }
        guard belongsToThisWindow(paneView) else { return }
        guard let (tab, _) = findTab(for: paneView) else { return }
        guard let paneID = tab.registry.paneID(for: paneView) else { return }
        guard tab.splitTree.focusedLeafID != paneID else { return }

        tab.splitTree.focusedLeafID = paneID
        synchronizePaneFocus(in: tab, focusedID: paneID)
        markFocusedPane(in: tab, focusedID: paneID)
        if tab.id == activeTab?.id {
            updateLayout()
        }
    }

    // MARK: - Helpers

    private func belongsToThisWindow(_ view: NSView) -> Bool {
        view.window === self.window
    }

    private func findTab(for surfaceView: SurfaceView) -> (Tab, Workspace)? {
        for workspace in windowSession.workspaces {
            for tab in workspace.tabs {
                if tab.registry.id(for: surfaceView) != nil {
                    return (tab, workspace)
                }
            }
        }
        return nil
    }

    private func findTab(for browserPaneView: BrowserPaneView) -> (Tab, Workspace)? {
        for workspace in windowSession.workspaces {
            for tab in workspace.tabs {
                if tab.registry.paneID(for: browserPaneView) != nil {
                    return (tab, workspace)
                }
            }
        }
        return nil
    }

    private func findTabContainingPane(id paneID: UUID) -> (Tab, Workspace)? {
        for workspace in windowSession.workspaces {
            for tab in workspace.tabs where tab.registry.contains(paneID) {
                return (tab, workspace)
            }
        }
        return nil
    }

    private func tabAndWorkspace(for tabID: UUID) -> (Tab, Workspace)? {
        for workspace in windowSession.workspaces {
            if let tab = workspace.tabs.first(where: { $0.id == tabID }) {
                return (tab, workspace)
            }
        }
        return nil
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(true)
        updateWindowBackgroundAppearance()
        if let tab = activeTab {
            syncWindowTitleWithFocusedPane(in: tab)
            syncFocusToSurfaceTree(in: tab)
        }
        restoreFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        GhosttyAppController.shared.setFocus(false)
        if let tab = activeTab {
            syncFocusToSurfaceTree(in: tab)
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window?.occlusionState.contains(.visible) ?? false
        applyWindowOcclusion(visible: visible)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        guard let tab = activeTab else { return }
        for id in tab.registry.allIDs {
            tab.registry.view(for: id)?.viewDidChangeBackingProperties()
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        updateWindowBackgroundAppearance()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateWindowBackgroundAppearance()
    }

    func windowWillClose(_ notification: Notification) {
        for workspace in windowSession.workspaces {
            for tab in workspace.tabs {
                closingTabIDs.insert(tab.id)
                for id in tab.registry.allIDs {
                    tab.registry.destroySurface(id)
                }
            }
        }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.removeWindowController(self)
        }
    }
}

extension FrosttyWindowController: MarkdownPreviewHost {
    func markdownPreviewWorkingDirectory(for tab: Tab) -> String? {
        tab.pwd ?? windowSession.activeWorkspace?.workingDirectory
    }

    func restoreFocusAfterMarkdownPreview() {
        restoreFocus()
    }

    func pauseActiveTabSurfaces() {
        activeTab?.registry.pauseAll()
    }
}
