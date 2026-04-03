// SurfaceRegistry.swift
// Frostty
//
// Mutable UUID->SurfaceView mapping. Controller layer for managing surface lifecycle.

import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "SurfaceRegistry")

@MainActor
final class SurfaceRegistry {

    struct RegistryEntry {
        let view: SurfaceView
        let controller: GhosttySurfaceController
        var state: EntryState
    }

    enum EntryState: Equatable, Sendable {
        case creating
        case attached
        case destroyed
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
        let id = controller.id

        entries[id] = RegistryEntry(view: surfaceView, controller: controller, state: .attached)
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

    func destroySurface(_ id: UUID) {
        guard var entry = entries[id] else { return }
        guard entry.state != .destroyed else { return }
        entry.state = .destroyed
        entries[id] = entry
        entry.controller.setOcclusion(true)
        entry.view.removeFromSuperview()
        entry.controller.requestClose()
        entries.removeValue(forKey: id)
        logger.info("Surface destroyed: \(id)")
    }

    func detachSurface(_ id: UUID) -> RegistryEntry? {
        guard var entry = entries.removeValue(forKey: id) else { return nil }
        entry.state = .attached
        entry.controller.setFocus(false)
        entry.view.resetFocusState()
        entry.view.removeFromSuperview()
        logger.info("Surface detached from registry: \(id)")
        return entry
    }

    func attachDetachedSurface(_ entry: RegistryEntry, id: UUID) {
        var attachedEntry = entry
        attachedEntry.state = .attached
        attachedEntry.view.removeFromSuperview()
        entries[id] = attachedEntry
        logger.info("Detached surface attached to registry: \(id)")
    }

    func view(for id: UUID) -> SurfaceView? { entries[id]?.view }
    func controller(for id: UUID) -> GhosttySurfaceController? { entries[id]?.controller }
    func state(for id: UUID) -> EntryState? { entries[id]?.state }

    func id(for surfaceView: SurfaceView) -> UUID? {
        entries.first(where: { $0.value.view === surfaceView })?.key
    }

    func pauseAll() {
        for id in allIDs {
            entries[id]?.controller.setFocus(false)
            entries[id]?.view.resetFocusState()
        }
    }

    func resumeAll() {
        for id in allIDs {
            entries[id]?.controller.refresh()
            entries[id]?.view.needsDisplay = true
        }
    }

    func contains(_ id: UUID) -> Bool { entries[id] != nil }

    func applyConfig(_ config: ghostty_config_t) {
        for id in allIDs {
            guard let entry = entries[id] else { continue }
            entry.controller.updateConfig(config)
            entry.controller.refresh()
            entry.view.needsDisplay = true
        }
    }
}
