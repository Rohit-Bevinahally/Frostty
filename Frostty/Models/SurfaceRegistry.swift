// SurfaceRegistry.swift
// Frostty
//
// Mutable UUID->pane mapping. Controller layer for managing terminal and browser pane lifecycle.

import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "SurfaceRegistry")

@MainActor
final class SurfaceRegistry {
    enum EntryState: Equatable, Sendable {
        case creating
        case attached
        case destroyed
    }

    final class TerminalEntry {
        let view: SurfaceView
        let controller: GhosttySurfaceController
        var state: EntryState

        init(view: SurfaceView, controller: GhosttySurfaceController, state: EntryState) {
            self.view = view
            self.controller = controller
            self.state = state
        }
    }

    final class BrowserEntry {
        let view: BrowserPaneView
        let controller: BrowserTabController
        var state: EntryState

        init(view: BrowserPaneView, controller: BrowserTabController, state: EntryState) {
            self.view = view
            self.controller = controller
            self.state = state
        }
    }

    @MainActor
    enum RegistryEntry {
        case terminal(TerminalEntry)
        case browser(BrowserEntry)

        var state: EntryState {
            get {
                switch self {
                case .terminal(let entry):
                    return entry.state
                case .browser(let entry):
                    return entry.state
                }
            }
            set {
                switch self {
                case .terminal(let entry):
                    entry.state = newValue
                case .browser(let entry):
                    entry.state = newValue
                }
            }
        }

        var paneView: NSView {
            switch self {
            case .terminal(let entry):
                return entry.view
            case .browser(let entry):
                return entry.view
            }
        }

        var terminalView: SurfaceView? {
            guard case .terminal(let entry) = self else { return nil }
            return entry.view
        }

        var terminalController: GhosttySurfaceController? {
            guard case .terminal(let entry) = self else { return nil }
            return entry.controller
        }

        var browserController: BrowserTabController? {
            guard case .browser(let entry) = self else { return nil }
            return entry.controller
        }

        var title: String? {
            switch self {
            case .terminal(let entry):
                return entry.view.title
            case .browser(let entry):
                return entry.controller.title
            }
        }

        var pwd: String? {
            switch self {
            case .terminal(let entry):
                return entry.view.pwd
            case .browser:
                return nil
            }
        }

        func setFocus(_ focused: Bool) {
            switch self {
            case .terminal(let entry):
                entry.controller.setFocus(focused)
                if focused {
                    entry.view.noteExternalFocusState(true)
                } else {
                    entry.view.resetFocusState()
                }
            case .browser:
                break
            }
        }

        func refreshIfVisible() {
            switch self {
            case .terminal(let entry):
                entry.controller.refresh()
            case .browser(let entry):
                entry.view.needsLayout = true
            }
        }

        func setOcclusion(_ occluded: Bool) {
            switch self {
            case .terminal(let entry):
                entry.controller.setOcclusion(occluded)
            case .browser(let entry):
                entry.view.setSuspended(occluded)
            }
        }

        func refresh() {
            switch self {
            case .terminal(let entry):
                entry.controller.refresh()
            case .browser(let entry):
                entry.view.needsLayout = true
            }
        }

        @discardableResult
        func makeFirstResponder(in window: NSWindow?) -> Bool {
            guard let window else { return false }
            switch self {
            case .terminal(let entry):
                let view = entry.view
                guard view.window === window else { return false }
                return window.makeFirstResponder(view)
            case .browser(let entry):
                let pane = entry.view
                guard pane.window === window else { return false }
                return entry.controller.focus(in: window)
            }
        }

        func removeFromSuperview() {
            paneView.removeFromSuperview()
        }
    }

    private var entries: [UUID: RegistryEntry] = [:]

    var count: Int { entries.count }
    var allIDs: [UUID] { Array(entries.keys) }

    func createSurface(app: ghostty_app_t, config: ghostty_surface_config_s) -> UUID? {
        let surfaceView = SurfaceView(frame: .zero)
        surfaceView.wantsLayer = true
        _ = surfaceView.layer

        var mutableConfig = config
        mutableConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        mutableConfig.platform.macos = ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(surfaceView).toOpaque()
        )

        guard let controller = GhosttySurfaceController(app: app, baseConfig: mutableConfig, view: surfaceView) else {
            logger.error("Failed to create surface controller")
            return nil
        }

        surfaceView.surfaceController = controller
        surfaceView.applyGlassBackgroundAppearance()
        let id = controller.id

        entries[id] = .terminal(TerminalEntry(view: surfaceView, controller: controller, state: .attached))
        logger.info("Surface created and registered: \(id)")
        return id
    }

    func createSurface(app: ghostty_app_t, config: ghostty_surface_config_s, pwd: String?) -> UUID? {
        if let pwd {
            return pwd.withCString { cStr in
                var mutableConfig = config
                mutableConfig.working_directory = cStr
                return createSurface(app: app, config: mutableConfig)
            }
        }
        return createSurface(app: app, config: config)
    }

    func createBrowser(initialURL: URL = URL(string: "about:blank")!) -> UUID? {
        let id = UUID()
        let controller = BrowserTabController(initialURL: initialURL)
        let paneView = BrowserPaneView(controller: controller, paneID: id)
        entries[id] = .browser(BrowserEntry(view: paneView, controller: controller, state: .attached))
        logger.info("Browser pane created and registered: \(id)")
        return id
    }

    func destroyPane(_ id: UUID) {
        guard var entry = entries[id] else { return }
        guard entry.state != .destroyed else { return }

        entry.state = .destroyed
        entries[id] = entry

        switch entry {
        case .terminal(let terminalEntry):
            terminalEntry.controller.setOcclusion(true)
            terminalEntry.view.removeFromSuperview()
            terminalEntry.controller.requestClose()
        case .browser(let browserEntry):
            browserEntry.view.setSuspended(true)
            browserEntry.view.removeFromSuperview()
        }

        entries.removeValue(forKey: id)
        logger.info("Pane destroyed: \(id)")
    }

    func destroySurface(_ id: UUID) {
        destroyPane(id)
    }

    func detachPane(_ id: UUID) -> RegistryEntry? {
        guard var entry = entries.removeValue(forKey: id) else { return nil }
        entry.state = .attached
        entry.setFocus(false)
        entry.setOcclusion(true)
        entry.removeFromSuperview()
        logger.info("Pane detached from registry: \(id)")
        return entry
    }

    func detachSurface(_ id: UUID) -> RegistryEntry? {
        detachPane(id)
    }

    func attachDetachedPane(_ entry: RegistryEntry, id: UUID) {
        var attachedEntry = entry
        attachedEntry.state = .attached
        attachedEntry.removeFromSuperview()
        entries[id] = attachedEntry
        logger.info("Detached pane attached to registry: \(id)")
    }

    func attachDetachedSurface(_ entry: RegistryEntry, id: UUID) {
        attachDetachedPane(entry, id: id)
    }

    func view(for id: UUID) -> SurfaceView? { entries[id]?.terminalView }
    func paneView(for id: UUID) -> NSView? { entries[id]?.paneView }
    func controller(for id: UUID) -> GhosttySurfaceController? { entries[id]?.terminalController }
    func browserController(for id: UUID) -> BrowserTabController? { entries[id]?.browserController }
    func state(for id: UUID) -> EntryState? { entries[id]?.state }
    func title(for id: UUID) -> String? { entries[id]?.title }
    func pwd(for id: UUID) -> String? { entries[id]?.pwd }

    func browserPaneIDs() -> [UUID] {
        entries.compactMap { id, entry in
            if case .browser = entry {
                return id
            }
            return nil
        }
    }

    func id(for surfaceView: SurfaceView) -> UUID? {
        entries.first(where: { $0.value.terminalView === surfaceView })?.key
    }

    func paneID(for rootView: NSView) -> UUID? {
        entries.first(where: { $0.value.paneView === rootView })?.key
    }

    @discardableResult
    func makeFirstResponder(for id: UUID, in window: NSWindow?) -> Bool {
        entries[id]?.makeFirstResponder(in: window) ?? false
    }

    /// Unfocus and occlude every pane in this registry.
    func pauseAll() {
        for id in allIDs {
            entries[id]?.setFocus(false)
            setOcclusion(for: id, occluded: true)
        }
    }

    /// Occlude all panes, then de-occlude only those in `visibleIDs`.
    func resumeVisible(visibleIDs: Set<UUID>) {
        setOcclusionForAll(occluded: true)
        for id in visibleIDs where entries[id] != nil {
            setOcclusion(for: id, occluded: false)
            entries[id]?.refreshIfVisible()
        }
    }

    /// Backward-compatible alias; prefer `resumeVisible(visibleIDs:)`.
    func resumeAll(visibleIDs: Set<UUID>? = nil) {
        if let visibleIDs {
            resumeVisible(visibleIDs: visibleIDs)
        } else {
            setOcclusionForAll(occluded: false)
        }
    }

    func setOcclusion(for id: UUID, occluded: Bool) {
        entries[id]?.setOcclusion(occluded)
    }

    func setOcclusionForAll(occluded: Bool) {
        for id in allIDs {
            setOcclusion(for: id, occluded: occluded)
        }
    }

    /// Sync libghostty focus state for all panes. Exactly one pane is focused when the window is key.
    func syncFocus(focusedID: UUID?, windowIsKey: Bool) {
        for id in allIDs {
            let shouldFocus = windowIsKey && focusedID == id
            if shouldFocus {
                entries[id]?.setFocus(true)
            } else {
                entries[id]?.setFocus(false)
            }
        }
    }

    func contains(_ id: UUID) -> Bool { entries[id] != nil }

    func applyConfig(_ config: ghostty_config_t) {
        for id in allIDs {
            guard let entry = entries[id] else { continue }
            guard let controller = entry.terminalController else { continue }
            controller.updateConfig(config)
            controller.refresh()
        }
    }
}
