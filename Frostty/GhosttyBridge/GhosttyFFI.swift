// GhosttyFFI.swift
// Frostty
//
// Thin Swift wrappers around ghostty C functions.
// All FFI calls are centralized here so API changes only affect this one file.

@preconcurrency import AppKit
import GhosttyKit

// MARK: - GhosttyFFI

/// Centralized FFI layer for all ghostty C function calls.
/// Each method is a thin wrapper with no business logic.
enum GhosttyFFI {

    // MARK: - Global

    @discardableResult
    static func initialize() -> Bool {
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
    }

    static func info() -> ghostty_info_s {
        ghostty_info()
    }

    static func translate(_ key: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
        ghostty_translate(key)
    }

    static func freeString(_ string: ghostty_string_s) {
        ghostty_string_free(string)
    }

    // MARK: - Config

    static func configNew() -> ghostty_config_t? {
        ghostty_config_new()
    }

    static func configFree(_ config: ghostty_config_t) {
        ghostty_config_free(config)
    }

    static func configClone(_ config: ghostty_config_t) -> ghostty_config_t? {
        ghostty_config_clone(config)
    }

    static func configLoadDefaultFiles(_ config: ghostty_config_t) {
        ghostty_config_load_default_files(config)
    }

    static func configLoadCLIArgs(_ config: ghostty_config_t) {
        ghostty_config_load_cli_args(config)
    }

    static func configLoadRecursiveFiles(_ config: ghostty_config_t) {
        ghostty_config_load_recursive_files(config)
    }

    static func configLoadFile(_ config: ghostty_config_t, path: String) {
        path.withCString { cStr in
            ghostty_config_load_file(config, cStr)
        }
    }

    static func configFinalize(_ config: ghostty_config_t) {
        ghostty_config_finalize(config)
    }

    static func configGet(_ config: ghostty_config_t, _ value: UnsafeMutableRawPointer, _ key: UnsafePointer<CChar>, _ keyLen: UInt) -> Bool {
        ghostty_config_get(config, value, key, keyLen)
    }

    static func configDiagnosticsCount(_ config: ghostty_config_t) -> UInt32 {
        ghostty_config_diagnostics_count(config)
    }

    static func configGetDiagnostic(_ config: ghostty_config_t, index: UInt32) -> ghostty_diagnostic_s {
        ghostty_config_get_diagnostic(config, index)
    }

    static func configTrigger(_ config: ghostty_config_t, action: UnsafePointer<CChar>, len: UInt) -> ghostty_input_trigger_s {
        ghostty_config_trigger(config, action, len)
    }

    static func configOpenPath() -> ghostty_string_s {
        ghostty_config_open_path()
    }

    // MARK: - App

    static func appNew(_ runtimeConfig: UnsafePointer<ghostty_runtime_config_s>, config: ghostty_config_t) -> ghostty_app_t? {
        ghostty_app_new(runtimeConfig, config)
    }

    static func appFree(_ app: ghostty_app_t) {
        ghostty_app_free(app)
    }

    static func appTick(_ app: ghostty_app_t) {
        ghostty_app_tick(app)
    }

    static func appUserdata(_ app: ghostty_app_t) -> UnsafeMutableRawPointer? {
        ghostty_app_userdata(app)
    }

    static func appSetFocus(_ app: ghostty_app_t, focused: Bool) {
        ghostty_app_set_focus(app, focused)
    }

    static func appSetColorScheme(_ app: ghostty_app_t, scheme: ghostty_color_scheme_e) {
        ghostty_app_set_color_scheme(app, scheme)
    }

    @discardableResult
    static func appKey(_ app: ghostty_app_t, event: ghostty_input_key_s) -> Bool {
        ghostty_app_key(app, event)
    }

    static func appKeyIsBinding(_ app: ghostty_app_t, event: ghostty_input_key_s) -> Bool {
        ghostty_app_key_is_binding(app, event)
    }

    static func appKeyboardChanged(_ app: ghostty_app_t) {
        ghostty_app_keyboard_changed(app)
    }

    static func appOpenConfig(_ app: ghostty_app_t) {
        ghostty_app_open_config(app)
    }

    static func appNeedsConfirmQuit(_ app: ghostty_app_t) -> Bool {
        ghostty_app_needs_confirm_quit(app)
    }

    static func appHasGlobalKeybinds(_ app: ghostty_app_t) -> Bool {
        ghostty_app_has_global_keybinds(app)
    }

    static func appUpdateConfig(_ app: ghostty_app_t, config: ghostty_config_t) {
        ghostty_app_update_config(app, config)
    }

    // MARK: - Surface Config

    static func surfaceConfigNew() -> ghostty_surface_config_s {
        ghostty_surface_config_new()
    }

    // MARK: - Surface

    static func surfaceNew(_ app: ghostty_app_t, config: UnsafePointer<ghostty_surface_config_s>) -> ghostty_surface_t? {
        ghostty_surface_new(app, config)
    }

    static func surfaceFree(_ surface: ghostty_surface_t) {
        ghostty_surface_free(surface)
    }

    static func surfaceUserdata(_ surface: ghostty_surface_t) -> UnsafeMutableRawPointer? {
        ghostty_surface_userdata(surface)
    }

    static func surfaceApp(_ surface: ghostty_surface_t) -> ghostty_app_t? {
        ghostty_surface_app(surface)
    }

    static func surfaceInheritedConfig(_ surface: ghostty_surface_t, context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT) -> ghostty_surface_config_s {
        ghostty_surface_inherited_config(surface, context)
    }

    static func surfaceUpdateConfig(_ surface: ghostty_surface_t, config: ghostty_config_t) {
        ghostty_surface_update_config(surface, config)
    }

    static func surfaceDraw(_ surface: ghostty_surface_t) {
        ghostty_surface_draw(surface)
    }

    static func surfaceRefresh(_ surface: ghostty_surface_t) {
        ghostty_surface_refresh(surface)
    }

    static func surfaceSetSize(_ surface: ghostty_surface_t, width: UInt32, height: UInt32) {
        ghostty_surface_set_size(surface, width, height)
    }

    static func surfaceSize(_ surface: ghostty_surface_t) -> ghostty_surface_size_s {
        ghostty_surface_size(surface)
    }

    static func surfaceSetContentScale(_ surface: ghostty_surface_t, xScale: Double, yScale: Double) {
        ghostty_surface_set_content_scale(surface, xScale, yScale)
    }

    static func surfaceSetFocus(_ surface: ghostty_surface_t, focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    static func surfaceSetOcclusion(_ surface: ghostty_surface_t, occluded: Bool) {
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    static func surfaceSetColorScheme(_ surface: ghostty_surface_t, scheme: ghostty_color_scheme_e) {
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    static func surfaceSetDisplayID(_ surface: ghostty_surface_t, displayID: UInt32) {
        ghostty_surface_set_display_id(surface, displayID)
    }

    static func surfaceKeyTranslationMods(_ surface: ghostty_surface_t, mods: ghostty_input_mods_e) -> ghostty_input_mods_e {
        ghostty_surface_key_translation_mods(surface, mods)
    }

    // MARK: - Surface Input

    @discardableResult
    static func surfaceKey(_ surface: ghostty_surface_t, event: ghostty_input_key_s) -> Bool {
        ghostty_surface_key(surface, event)
    }

    static func surfaceKeyIsBinding(_ surface: ghostty_surface_t, event: ghostty_input_key_s) -> Bool {
        var flags = ghostty_binding_flags_e(rawValue: 0)
        return ghostty_surface_key_is_binding(surface, event, &flags)
    }

    static func surfaceText(_ surface: ghostty_surface_t, text: UnsafePointer<CChar>, len: UInt) {
        ghostty_surface_text(surface, text, len)
    }

    static func surfacePreedit(_ surface: ghostty_surface_t, text: UnsafePointer<CChar>?, len: UInt) {
        ghostty_surface_preedit(surface, text, len)
    }

    static func surfaceMouseCaptured(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_mouse_captured(surface)
    }

    @discardableResult
    static func surfaceMouseButton(_ surface: ghostty_surface_t, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e, mods: ghostty_input_mods_e) -> Bool {
        ghostty_surface_mouse_button(surface, state, button, mods)
    }

    static func surfaceMousePos(_ surface: ghostty_surface_t, x: Double, y: Double, mods: ghostty_input_mods_e) {
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    static func surfaceMouseScroll(_ surface: ghostty_surface_t, x: Double, y: Double, mods: ghostty_input_scroll_mods_t) {
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    static func surfaceMousePressure(_ surface: ghostty_surface_t, stage: UInt32, pressure: Double) {
        ghostty_surface_mouse_pressure(surface, stage, pressure)
    }

    static func surfaceIMEPoint(_ surface: ghostty_surface_t, x: inout Double, y: inout Double, width: inout Double, height: inout Double) {
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    }

    // MARK: - Surface Selection / Clipboard

    static func surfaceHasSelection(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_has_selection(surface)
    }

    static func surfaceReadSelection(_ surface: ghostty_surface_t, text: inout ghostty_text_s) -> Bool {
        ghostty_surface_read_selection(surface, &text)
    }

    static func surfaceReadText(_ surface: ghostty_surface_t, selection: ghostty_selection_s, text: inout ghostty_text_s) -> Bool {
        ghostty_surface_read_text(surface, selection, &text)
    }

    static func surfaceFreeText(_ surface: ghostty_surface_t, text: inout ghostty_text_s) {
        ghostty_surface_free_text(surface, &text)
    }

    static func surfaceCompleteClipboardRequest(_ surface: ghostty_surface_t, data: UnsafePointer<CChar>, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        ghostty_surface_complete_clipboard_request(surface, data, state, confirmed)
    }

    static func surfaceRequestClose(_ surface: ghostty_surface_t) {
        ghostty_surface_request_close(surface)
    }

    static func surfaceNeedsConfirmQuit(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_needs_confirm_quit(surface)
    }

    static func surfaceProcessExited(_ surface: ghostty_surface_t) -> Bool {
        ghostty_surface_process_exited(surface)
    }

    // MARK: - Surface Splits

    static func surfaceSplit(_ surface: ghostty_surface_t, direction: ghostty_action_split_direction_e) {
        ghostty_surface_split(surface, direction)
    }

    static func surfaceSplitFocus(_ surface: ghostty_surface_t, direction: ghostty_action_goto_split_e) {
        ghostty_surface_split_focus(surface, direction)
    }

    static func surfaceSplitResize(_ surface: ghostty_surface_t, direction: ghostty_action_resize_split_direction_e, amount: UInt16) {
        ghostty_surface_split_resize(surface, direction, amount)
    }

    static func surfaceSplitEqualize(_ surface: ghostty_surface_t) {
        ghostty_surface_split_equalize(surface)
    }

    // MARK: - Surface Actions

    @discardableResult
    static func surfaceBindingAction(_ surface: ghostty_surface_t, action: UnsafePointer<CChar>, len: UInt) -> Bool {
        ghostty_surface_binding_action(surface, action, len)
    }

    // MARK: - Surface QuickLook (macOS)

    static func surfaceQuicklookFont(_ surface: ghostty_surface_t) -> UnsafeMutableRawPointer? {
        ghostty_surface_quicklook_font(surface)
    }

    static func surfaceQuicklookWord(_ surface: ghostty_surface_t, text: inout ghostty_text_s) -> Bool {
        ghostty_surface_quicklook_word(surface, &text)
    }

    // MARK: - Window Background

    static func setWindowBackgroundBlur(_ app: ghostty_app_t, window: UnsafeMutableRawPointer) {
        ghostty_set_window_background_blur(app, window)
    }
}
