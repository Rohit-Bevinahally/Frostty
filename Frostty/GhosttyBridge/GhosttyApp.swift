// GhosttyApp.swift
// Frostty
//
// Manages the ghostty_app_t singleton lifecycle and runtime callbacks.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "GhosttyApp")

// MARK: - GhosttyAppController

@MainActor
final class GhosttyAppController {

    static let shared = GhosttyAppController()

    enum Readiness {
        case loading
        case ready
        case error
    }

    private(set) var readiness: Readiness = .loading

    nonisolated(unsafe) private(set) var app: ghostty_app_t? = nil

    private(set) var configManager: GhosttyConfigManager

    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return GhosttyFFI.appNeedsConfirmQuit(app)
    }

    // MARK: - Initialization

    private init() {
        guard GhosttyFFI.initialize() else {
            logger.critical("ghostty_init failed")
            self.configManager = GhosttyConfigManager()
            self.readiness = .error
            return
        }

        self.configManager = GhosttyConfigManager()
        guard configManager.isLoaded, let config = configManager.config else {
            logger.critical("Failed to load configuration")
            self.readiness = .error
            return
        }

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: ghosttyWakeupCallback,
            action_cb: ghosttyActionCallback,
            read_clipboard_cb: ghosttyReadClipboardCallback,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboardCallback,
            write_clipboard_cb: ghosttyWriteClipboardCallback,
            close_surface_cb: ghosttyCloseSurfaceCallback
        )

        guard let newApp = GhosttyFFI.appNew(&runtimeConfig, config: config) else {
            logger.critical("ghostty_app_new failed")
            self.readiness = .error
            return
        }

        self.app = newApp
        self.readiness = .ready

        GhosttyFFI.appSetFocus(newApp, focused: NSApp.isActive)
        registerNotifications()

        logger.info("GhosttyAppController initialized successfully")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let app {
            GhosttyFFI.appFree(app)
        }
    }

    // MARK: - App Operations

    func tick() {
        guard let app else { return }
        GhosttyFFI.appTick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        GhosttyFFI.appSetFocus(app, focused: focused)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        GhosttyFFI.appSetColorScheme(app, scheme: scheme)
    }

    func keyboardChanged() {
        guard let app else { return }
        GhosttyFFI.appKeyboardChanged(app)
    }

    func reloadConfig() {
        guard let app else { return }

        let newConfigManager = GhosttyConfigManager()
        guard newConfigManager.isLoaded, let newConfig = newConfigManager.config else {
            logger.warning("Config reload failed — keeping previous config")
            return
        }

        GhosttyFFI.appUpdateConfig(app, config: newConfig)
        self.configManager = newConfigManager
    }

    // MARK: - Private

    private func registerNotifications() {
        let center = NotificationCenter.default

        center.addObserver(
            self,
            selector: #selector(keyboardSelectionDidChange),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    // MARK: - Notification Handlers

    @objc private func keyboardSelectionDidChange(_ notification: Notification) {
        keyboardChanged()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        setFocus(true)
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        setFocus(false)
    }

    // MARK: - Helpers

    static func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
        guard let ud = GhosttyFFI.surfaceUserdata(surface) else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    static func surfaceView(fromUserdata userdata: UnsafeMutableRawPointer) -> SurfaceView {
        Unmanaged<SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    static func appController(from userdata: UnsafeMutableRawPointer) -> GhosttyAppController {
        Unmanaged<GhosttyAppController>.fromOpaque(userdata).takeUnretainedValue()
    }
}

// MARK: - Sendable Wrapper for C Pointers

/// Wraps a value so it can cross actor isolation boundaries in C callbacks.
/// Safety: these callbacks are always invoked on the main thread by ghostty core.
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - C Callback Functions

private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let ud = UnsafeSendable(userdata)
    DispatchQueue.main.async {
        let controller = GhosttyAppController.appController(from: ud.value)
        controller.tick()
    }
}

private func ghosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app else { return false }
    let safeApp = UnsafeSendable(app)
    let safeTarget = UnsafeSendable(target)
    let safeAction = UnsafeSendable(action)
    return MainActor.assumeIsolated {
        GhosttyActionRouter.handleAction(app: safeApp.value, target: safeTarget.value, action: safeAction.value)
    }
}

private func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata else { return false }
    let safeUserdata = UnsafeSendable(userdata)
    let safeState = UnsafeSendable(state)
    MainActor.assumeIsolated {
        let surfaceView = GhosttyAppController.surfaceView(fromUserdata: safeUserdata.value)
        guard let surface = surfaceView.surfaceController?.surface else { return }

        let pasteboard: NSPasteboard
        switch location {
        case GHOSTTY_CLIPBOARD_SELECTION:
            pasteboard = .init(name: .init("com.frostty.selection"))
        default:
            pasteboard = .general
        }

        let str = pasteboard.string(forType: .string) ?? ""

        let needsConfirm = str.contains("\n") || str.contains("\u{1b}[201~")

        if !needsConfirm {
            str.withCString { ptr in
                GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: safeState.value, confirmed: false)
            }
            return
        }

        let preview = str.prefix(500)
        let alert = NSAlert()
        alert.messageText = "Confirm Paste"
        alert.informativeText = "The clipboard contains potentially unsafe content:\n\n\(preview)"
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            str.withCString { ptr in
                GhosttyFFI.surfaceCompleteClipboardRequest(surface, data: ptr, state: safeState.value, confirmed: true)
            }
        }
    }
    return true
}

private func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata else { return }
    let safeUserdata = UnsafeSendable(userdata)
    let safeState = UnsafeSendable(state)
    let contents: String
    if let string {
        contents = String(cString: string)
    } else {
        contents = ""
    }
    MainActor.assumeIsolated {
        let surfaceView = GhosttyAppController.surfaceView(fromUserdata: safeUserdata.value)
        guard let surface = surfaceView.surfaceController?.surface else { return }

        NotificationCenter.default.post(
            name: .ghosttyConfirmClipboard,
            object: surfaceView,
            userInfo: [
                "contents": contents,
                "surface": surface,
                "state": safeState.value as Any,
                "request": request,
            ]
        )
    }
}

private func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ contentsLen: Int,
    _ confirm: Bool
) {
    guard let contents, contentsLen > 0 else { return }

    var valueStr: String?
    for i in 0..<contentsLen {
        let entry = contents[i]
        if let mime = entry.mime, let data = entry.data {
            let mimeStr = String(cString: mime)
            if mimeStr == "text/plain" {
                valueStr = String(cString: data)
                break
            }
        }
    }
    if valueStr == nil, let data = contents[0].data {
        valueStr = String(cString: data)
    }

    guard let valueStr else { return }

    MainActor.assumeIsolated {
        let pasteboard: NSPasteboard
        switch location {
        case GHOSTTY_CLIPBOARD_SELECTION:
            pasteboard = .init(name: .init("com.frostty.selection"))
        default:
            pasteboard = .general
        }

        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(valueStr, forType: .string)
    }
}

private func ghosttyCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let userdata else { return }
    let safeUserdata = UnsafeSendable(userdata)
    MainActor.assumeIsolated {
        let surfaceView = GhosttyAppController.surfaceView(fromUserdata: safeUserdata.value)

        NotificationCenter.default.post(
            name: .ghosttyCloseSurface,
            object: surfaceView,
            userInfo: ["process_alive": processAlive]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let ghosttyCloseSurface = Notification.Name("com.frostty.ghostty.closeSurface")
    static let ghosttyNewWindow = Notification.Name("com.frostty.ghostty.newWindow")
    static let ghosttyNewTab = Notification.Name("com.frostty.ghostty.newTab")
    static let ghosttyNewSplit = Notification.Name("com.frostty.ghostty.newSplit")
    static let ghosttyCloseTab = Notification.Name("com.frostty.ghostty.closeTab")
    static let ghosttyCloseWindow = Notification.Name("com.frostty.ghostty.closeWindow")
    static let ghosttySetTitle = Notification.Name("com.frostty.ghostty.setTitle")
    static let ghosttySetPwd = Notification.Name("com.frostty.ghostty.setPwd")
    static let ghosttyCellSizeChange = Notification.Name("com.frostty.ghostty.cellSizeChange")
    static let ghosttyInitialSize = Notification.Name("com.frostty.ghostty.initialSize")
    static let ghosttySizeLimit = Notification.Name("com.frostty.ghostty.sizeLimit")
    static let ghosttyConfigChange = Notification.Name("com.frostty.ghostty.configChange")
    static let ghosttyColorChange = Notification.Name("com.frostty.ghostty.colorChange")
    static let ghosttyToggleFullscreen = Notification.Name("com.frostty.ghostty.toggleFullscreen")
    static let ghosttyRendererHealth = Notification.Name("com.frostty.ghostty.rendererHealth")
    static let ghosttyRingBell = Notification.Name("com.frostty.ghostty.ringBell")
    static let ghosttyShowChildExited = Notification.Name("com.frostty.ghostty.showChildExited")
    static let ghosttyGotoSplit = Notification.Name("com.frostty.ghostty.gotoSplit")
    static let ghosttyResizeSplit = Notification.Name("com.frostty.ghostty.resizeSplit")
    static let ghosttyEqualizeSplits = Notification.Name("com.frostty.ghostty.equalizeSplits")
    static let ghosttyDesktopNotification = Notification.Name("com.frostty.ghostty.desktopNotification")
    static let ghosttyGotoTab = Notification.Name("com.frostty.ghostty.gotoTab")
    static let ghosttyConfirmClipboard = Notification.Name("com.frostty.ghostty.confirmClipboard")
    static let frosttyRenameTab = Notification.Name("com.frostty.renameTab")
    static let frosttyWillBeginEditing = Notification.Name("com.frostty.willBeginEditing")
    static let frosttySurfaceDidFocus = Notification.Name("com.frostty.surfaceDidFocus")
    static let ghosttyStartSearch = Notification.Name("com.frostty.ghostty.startSearch")
    static let ghosttyEndSearch = Notification.Name("com.frostty.ghostty.endSearch")
    static let ghosttySearchTotal = Notification.Name("com.frostty.ghostty.searchTotal")
    static let ghosttySearchSelected = Notification.Name("com.frostty.ghostty.searchSelected")
}
