// GhosttySurface.swift
// Frostty
//
// Wraps ghostty_surface_t lifecycle. One instance per terminal pane.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "GhosttySurface")

// MARK: - GhosttySurfaceController

@MainActor
final class GhosttySurfaceController: Identifiable {

    struct ScrollbarState {
        let total: UInt64
        let offset: UInt64
        let len: UInt64
    }

    let id = UUID()

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t? = nil

    weak var surfaceView: SurfaceView?

    var cellSize: NSSize = .zero

    var scrollbar: ScrollbarState?

    var surfaceSize: ghostty_surface_size_s? = nil

    var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceNeedsConfirmQuit(surface)
    }

    var processExited: Bool {
        guard let surface else { return true }
        return GhosttyFFI.surfaceProcessExited(surface)
    }

    // MARK: - Initialization

    init?(app: ghostty_app_t, baseConfig: ghostty_surface_config_s, view: SurfaceView) {
        self.surfaceView = view

        var config = baseConfig
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        )
        config.userdata = Unmanaged.passUnretained(view).toOpaque()

        if config.scale_factor <= 0 {
            config.scale_factor = 1.0
            logger.warning("scale_factor not set by caller, using fallback 1.0")
        }

        guard let newSurface = GhosttyFFI.surfaceNew(app, config: &config) else {
            logger.error("ghostty_surface_new failed")
            return nil
        }
        self.surface = newSurface

        if let screen = view.window?.screen {
            GhosttyFFI.surfaceSetDisplayID(newSurface, displayID: screen.displayID ?? 0)
        }

        GhosttyFFI.surfaceSetContentScale(newSurface, xScale: config.scale_factor, yScale: config.scale_factor)

        let backingFrame = view.convertToBacking(view.frame)
        if backingFrame.width > 0, backingFrame.height > 0 {
            GhosttyFFI.surfaceSetSize(
                newSurface,
                width: UInt32(backingFrame.width),
                height: UInt32(backingFrame.height)
            )
        }

        logger.info("Surface created: \(self.id)")
    }

    deinit {
        if let surface {
            Task.detached { @MainActor in
                GhosttyFFI.surfaceFree(surface)
            }
        }
    }

    // MARK: - Size & Scale

    func updateSize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetSize(surface, width: width, height: height)
        self.surfaceSize = GhosttyFFI.surfaceSize(surface)
    }

    func setContentScale(_ scale: Double) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetContentScale(surface, xScale: scale, yScale: scale)
    }

    // MARK: - Focus & Visibility

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetFocus(surface, focused: focused)
    }

    func setOcclusion(_ occluded: Bool) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetOcclusion(surface, occluded: occluded)
    }

    func refresh() {
        guard let surface else { return }
        GhosttyFFI.surfaceRefresh(surface)
    }

    func setDisplayID(_ displayID: UInt32) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetDisplayID(surface, displayID: displayID)
    }

    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let surface else { return }
        GhosttyFFI.surfaceSetColorScheme(surface, scheme: scheme)
    }

    // MARK: - Close

    func requestClose() {
        guard let surface else { return }
        GhosttyFFI.surfaceRequestClose(surface)
    }

    // MARK: - Input

    @discardableResult
    func sendKey(_ event: ghostty_input_key_s) -> Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceKey(surface, event: event)
    }

    func keyIsBinding(_ event: ghostty_input_key_s) -> Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceKeyIsBinding(surface, event: event)
    }

    func keyTranslationMods(_ mods: ghostty_input_mods_e) -> ghostty_input_mods_e {
        guard let surface else { return mods }
        return GhosttyFFI.surfaceKeyTranslationMods(surface, mods: mods)
    }

    func sendText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8CString.count
        guard len > 0 else { return }
        text.withCString { ptr in
            GhosttyFFI.surfaceText(surface, text: ptr, len: UInt(len - 1))
        }
    }

    func sendPreedit(_ text: String?) {
        guard let surface else { return }
        if let text, !text.isEmpty {
            let len = text.utf8CString.count
            text.withCString { ptr in
                GhosttyFFI.surfacePreedit(surface, text: ptr, len: UInt(len - 1))
            }
        } else {
            GhosttyFFI.surfacePreedit(surface, text: nil, len: 0)
        }
    }

    @discardableResult
    func sendMouseButton(state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceMouseButton(surface, state: state, button: button, mods: mods)
    }

    func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        guard let surface else { return }
        GhosttyFFI.surfaceMousePos(surface, x: x, y: y, mods: mods)
    }

    func sendMouseScroll(x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        guard let surface else { return }
        GhosttyFFI.surfaceMouseScroll(surface, x: x, y: y, mods: mods)
    }

    func sendMousePressure(stage: UInt32, pressure: Double) {
        guard let surface else { return }
        GhosttyFFI.surfaceMousePressure(surface, stage: stage, pressure: pressure)
    }

    var mouseCaptured: Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceMouseCaptured(surface)
    }

    // MARK: - Selection

    var hasSelection: Bool {
        guard let surface else { return false }
        return GhosttyFFI.surfaceHasSelection(surface)
    }

    // MARK: - Splits

    func split(_ direction: ghostty_action_split_direction_e) {
        guard let surface else { return }
        GhosttyFFI.surfaceSplit(surface, direction: direction)
    }

    func splitFocus(_ direction: ghostty_action_goto_split_e) {
        guard let surface else { return }
        GhosttyFFI.surfaceSplitFocus(surface, direction: direction)
    }

    func splitResize(_ direction: ghostty_action_resize_split_direction_e, amount: UInt16) {
        guard let surface else { return }
        GhosttyFFI.surfaceSplitResize(surface, direction: direction, amount: amount)
    }

    func splitEqualize() {
        guard let surface else { return }
        GhosttyFFI.surfaceSplitEqualize(surface)
    }

    // MARK: - Actions

    @discardableResult
    func performAction(_ action: String) -> Bool {
        guard let surface else { return false }
        let len = action.utf8CString.count
        guard len > 0 else { return false }
        return action.withCString { ptr in
            GhosttyFFI.surfaceBindingAction(surface, action: ptr, len: UInt(len - 1))
        }
    }

    // MARK: - IME

    func imePoint() -> (x: Double, y: Double, width: Double, height: Double) {
        guard let surface else { return (0, 0, 0, 0) }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        GhosttyFFI.surfaceIMEPoint(surface, x: &x, y: &y, width: &width, height: &height)
        return (x, y, width, height)
    }

    // MARK: - Config Update

    func updateConfig(_ config: ghostty_config_t) {
        guard let surface else { return }
        GhosttyFFI.surfaceUpdateConfig(surface, config: config)
    }

    func inheritedConfig() -> ghostty_surface_config_s? {
        guard let surface else { return nil }
        return GhosttyFFI.surfaceInheritedConfig(surface)
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    var displayID: UInt32? {
        guard let id = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return id.uint32Value
    }
}
