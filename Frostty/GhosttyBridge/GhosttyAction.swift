// GhosttyAction.swift
// Frostty
//
// Routes action callbacks from libghostty to the app.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "GhosttyAction")

// MARK: - GhosttyActionRouter

@MainActor
enum GhosttyActionRouter {

    static func handleAction(
        app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch target.tag {
        case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
            break
        default:
            logger.warning("Unknown action target: \(target.tag.rawValue)")
            return false
        }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            return handleSetTitle(app, target: target, value: action.action.set_title)

        case GHOSTTY_ACTION_PWD:
            return handlePwd(app, target: target, value: action.action.pwd)

        case GHOSTTY_ACTION_NEW_SPLIT:
            return handleNewSplit(app, target: target, direction: action.action.new_split)

        case GHOSTTY_ACTION_NEW_TAB:
            return handleNewTab(app, target: target)

        case GHOSTTY_ACTION_NEW_WINDOW:
            return handleNewWindow(app, target: target)

        case GHOSTTY_ACTION_CLOSE_TAB:
            return handleCloseTab(app, target: target)

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            return handleCloseWindow(app, target: target)

        case GHOSTTY_ACTION_RENDER:
            return handleRender(app, target: target)

        case GHOSTTY_ACTION_CELL_SIZE:
            return handleCellSize(app, target: target, value: action.action.cell_size)

        case GHOSTTY_ACTION_SCROLLBAR:
            return handleScrollbar(app, target: target, value: action.action.scrollbar)

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            return handleMouseShape(app, target: target, shape: action.action.mouse_shape)

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            return handleMouseVisibility(app, target: target, visibility: action.action.mouse_visibility)

        case GHOSTTY_ACTION_QUIT:
            return handleQuit(app)

        case GHOSTTY_ACTION_COLOR_CHANGE:
            return handleColorChange(app, target: target, change: action.action.color_change)

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return handleConfigChange(app, target: target, value: action.action.config_change)

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return handleReloadConfig(app)

        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            return handleToggleFullscreen(app, target: target, mode: action.action.toggle_fullscreen)

        case GHOSTTY_ACTION_OPEN_URL:
            return handleOpenURL(action.action.open_url)

        case GHOSTTY_ACTION_RING_BELL:
            return handleRingBell(app, target: target)

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return handleShowChildExited(app, target: target, value: action.action.child_exited)

        case GHOSTTY_ACTION_RENDERER_HEALTH:
            return handleRendererHealth(app, target: target, health: action.action.renderer_health)

        case GHOSTTY_ACTION_GOTO_SPLIT:
            return handleGotoSplit(app, target: target, direction: action.action.goto_split)

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            return handleResizeSplit(app, target: target, resize: action.action.resize_split)

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            return handleEqualizeSplits(app, target: target)

        case GHOSTTY_ACTION_GOTO_TAB:
            return handleGotoTab(app, target: target, tab: action.action.goto_tab)

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return handleDesktopNotification(app, target: target, value: action.action.desktop_notification)

        case GHOSTTY_ACTION_INITIAL_SIZE:
            return handleInitialSize(app, target: target, value: action.action.initial_size)

        case GHOSTTY_ACTION_SIZE_LIMIT:
            return handleSizeLimit(app, target: target, value: action.action.size_limit)

        case GHOSTTY_ACTION_SECURE_INPUT:
            return handleSecureInput(app, target: target, mode: action.action.secure_input)

        case GHOSTTY_ACTION_KEY_SEQUENCE,
             GHOSTTY_ACTION_PROGRESS_REPORT:
            return true

        default:
            logger.info("Unhandled action: \(action.tag.rawValue)")
            return false
        }
    }

    // MARK: - Action Handlers

    private static func handleSetTitle(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_set_title_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        guard let titlePtr = value.title else { return false }
        let title = String(cString: titlePtr)

        NotificationCenter.default.post(
            name: .ghosttySetTitle,
            object: surfaceView,
            userInfo: ["title": title]
        )
        return true
    }

    private static func handlePwd(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_pwd_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        guard let pwdPtr = value.pwd else { return false }
        let pwd = String(cString: pwdPtr)

        NotificationCenter.default.post(
            name: .ghosttySetPwd,
            object: surfaceView,
            userInfo: ["pwd": pwd]
        )
        return true
    }

    private static func handleNewSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        direction: ghostty_action_split_direction_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        var userInfo: [String: Any] = ["direction": direction]
        if let surface = target.target.surface {
            let inheritedConfig = GhosttyFFI.surfaceInheritedConfig(surface)
            userInfo["inherited_config"] = inheritedConfig
        }

        NotificationCenter.default.post(
            name: .ghosttyNewSplit,
            object: surfaceView,
            userInfo: userInfo
        )
        return true
    }

    private static func handleNewTab(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        let surfaceView = surfaceView(from: target)

        var userInfo: [String: Any] = [:]
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            let inheritedConfig = GhosttyFFI.surfaceInheritedConfig(surface)
            userInfo["inherited_config"] = inheritedConfig
        }

        NotificationCenter.default.post(
            name: .ghosttyNewTab,
            object: surfaceView,
            userInfo: userInfo
        )
        return true
    }

    private static func handleNewWindow(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        let surfaceView = surfaceView(from: target)

        var userInfo: [String: Any] = [:]
        if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface {
            let inheritedConfig = GhosttyFFI.surfaceInheritedConfig(surface)
            userInfo["inherited_config"] = inheritedConfig
        }

        NotificationCenter.default.post(
            name: .ghosttyNewWindow,
            object: surfaceView,
            userInfo: userInfo
        )
        return true
    }

    private static func handleCloseTab(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyCloseTab,
            object: surfaceView
        )
        return true
    }

    private static func handleCloseWindow(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        let surfaceView = surfaceView(from: target)

        NotificationCenter.default.post(
            name: .ghosttyCloseWindow,
            object: surfaceView
        )
        return true
    }

    private static func handleRender(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        surfaceView.needsDisplay = true
        return true
    }

    private static func handleCellSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_cell_size_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        let size = NSSize(width: CGFloat(value.width), height: CGFloat(value.height))
        surfaceView.cachedCellSize = size
        surfaceView.surfaceController?.cellSize = size

        NotificationCenter.default.post(
            name: .ghosttyCellSizeChange,
            object: surfaceView,
            userInfo: ["width": value.width, "height": value.height]
        )
        return true
    }

    private static func handleScrollbar(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_scrollbar_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        let state = GhosttySurfaceController.ScrollbarState(
            total: value.total,
            offset: value.offset,
            len: value.len
        )
        surfaceView.surfaceController?.scrollbar = state
        surfaceView.scrollbarUpdateHandler?(state)
        return true
    }

    private static func handleMouseShape(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        shape: ghostty_action_mouse_shape_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        surfaceView.updateCursorShape(shape)
        return true
    }

    private static func handleMouseVisibility(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        visibility: ghostty_action_mouse_visibility_e
    ) -> Bool {
        let hidden = visibility == GHOSTTY_MOUSE_HIDDEN

        if let surfaceView = surfaceView(from: target) {
            surfaceView.updateMouseVisibility(hidden: hidden)
        } else {
            NSCursor.setHiddenUntilMouseMoves(hidden)
        }
        return true
    }

    private static func handleQuit(_ app: ghostty_app_t) -> Bool {
        NSApplication.shared.terminate(nil)
        return true
    }

    private static func handleColorChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        change: ghostty_action_color_change_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyColorChange,
            object: surfaceView,
            userInfo: ["change": change]
        )
        return true
    }

    private static func handleConfigChange(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_config_change_s
    ) -> Bool {
        NotificationCenter.default.post(
            name: .ghosttyConfigChange,
            object: surfaceView(from: target),
            userInfo: ["config": value.config as Any]
        )
        return true
    }

    private static func handleReloadConfig(_ app: ghostty_app_t) -> Bool {
        GhosttyAppController.shared.reloadConfig()
        return true
    }

    private static func handleToggleFullscreen(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        mode: ghostty_action_fullscreen_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyToggleFullscreen,
            object: surfaceView,
            userInfo: ["mode": mode]
        )
        return true
    }

    private static func handleOpenURL(_ value: ghostty_action_open_url_s) -> Bool {
        guard let urlCStr = value.url else { return false }
        let data = Data(bytes: urlCStr, count: Int(value.len))
        guard let urlString = String(data: data, encoding: .utf8) else { return false }

        let url: URL
        if let candidate = URL(string: urlString), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: urlString)
        }

        NSWorkspace.shared.open(url)
        return true
    }

    private static func handleRingBell(_ app: ghostty_app_t, target: ghostty_target_s) -> Bool {
        guard let surfaceView = surfaceView(from: target) else {
            NSSound.beep()
            return true
        }

        NotificationCenter.default.post(
            name: .ghosttyRingBell,
            object: surfaceView
        )
        return true
    }

    private static func handleShowChildExited(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_surface_message_childexited_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyShowChildExited,
            object: surfaceView,
            userInfo: ["exit_code": value.exit_code, "runtime_ms": value.timetime_ms]
        )
        return true
    }

    private static func handleRendererHealth(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        health: ghostty_action_renderer_health_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyRendererHealth,
            object: surfaceView,
            userInfo: ["health": health]
        )
        return true
    }

    private static func handleGotoSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        direction: ghostty_action_goto_split_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyGotoSplit,
            object: surfaceView,
            userInfo: ["direction": direction]
        )
        return true
    }

    private static func handleResizeSplit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        resize: ghostty_action_resize_split_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyResizeSplit,
            object: surfaceView,
            userInfo: ["resize": resize]
        )
        return true
    }

    private static func handleEqualizeSplits(
        _ app: ghostty_app_t,
        target: ghostty_target_s
    ) -> Bool {
        let surfaceView = surfaceView(from: target)

        NotificationCenter.default.post(
            name: .ghosttyEqualizeSplits,
            object: surfaceView
        )
        return true
    }

    private static func handleGotoTab(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        tab: ghostty_action_goto_tab_e
    ) -> Bool {
        let surfaceView = surfaceView(from: target)
        NotificationCenter.default.post(
            name: .ghosttyGotoTab,
            object: surfaceView,
            userInfo: ["tab": tab.rawValue]
        )
        return true
    }

    private static func handleDesktopNotification(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_desktop_notification_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        let title: String = if let ptr = value.title { String(validatingCString: ptr) ?? "" } else { "" }
        let body: String = if let ptr = value.body { String(validatingCString: ptr) ?? "" } else { "" }

        NotificationCenter.default.post(
            name: .ghosttyDesktopNotification,
            object: surfaceView,
            userInfo: ["title": title, "body": body]
        )
        return true
    }

    private static func handleInitialSize(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_initial_size_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttyInitialSize,
            object: surfaceView,
            userInfo: ["width": value.width, "height": value.height]
        )
        return true
    }

    private static func handleSizeLimit(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        value: ghostty_action_size_limit_s
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        NotificationCenter.default.post(
            name: .ghosttySizeLimit,
            object: surfaceView,
            userInfo: [
                "min_width": value.min_width,
                "min_height": value.min_height,
                "max_width": value.max_width,
                "max_height": value.max_height,
            ]
        )
        return true
    }

    private static func handleSecureInput(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        mode: ghostty_action_secure_input_e
    ) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }
        switch mode {
        case GHOSTTY_SECURE_INPUT_ON:
            surfaceView.passwordInput = true
        case GHOSTTY_SECURE_INPUT_OFF:
            surfaceView.passwordInput = false
        case GHOSTTY_SECURE_INPUT_TOGGLE:
            surfaceView.passwordInput.toggle()
        default:
            return false
        }
        return true
    }

    // MARK: - Helpers

    private static func surfaceView(from target: ghostty_target_s) -> SurfaceView? {
        switch target.tag {
        case GHOSTTY_TARGET_SURFACE:
            guard let surface = target.target.surface else { return nil }
            return GhosttyAppController.surfaceView(from: surface)
        default:
            return nil
        }
    }
}
