// GhosttyConfig.swift
// Frostty
//
// Wraps ghostty_config_t lifecycle and provides configuration access.
// Simplified from Calyx — no glass presets, no managed config blocks.

@preconcurrency import AppKit
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "GhosttyConfig")

// MARK: - GhosttyConfigManager

@MainActor
final class GhosttyConfigManager {

    /// The underlying ghostty configuration handle.
    nonisolated(unsafe) private(set) var config: ghostty_config_t? = nil {
        didSet {
            guard let old = oldValue else { return }
            GhosttyFFI.configFree(old)
        }
    }

    var isLoaded: Bool { config != nil }

    var diagnostics: [String] {
        guard let cfg = config else { return [] }
        let count = GhosttyFFI.configDiagnosticsCount(cfg)
        var result: [String] = []
        for i in 0..<count {
            let diag = GhosttyFFI.configGetDiagnostic(cfg, index: i)
            result.append(String(cString: diag.message))
        }
        return result
    }

    // MARK: - Initialization

    init() {
        self.config = Self.loadDefaultConfig()
    }

    init(clone source: ghostty_config_t) {
        self.config = GhosttyFFI.configClone(source)
    }

    deinit {
        config = nil
    }

    // MARK: - Loading

    static func loadDefaultConfig() -> ghostty_config_t? {
        guard let cfg = GhosttyFFI.configNew() else {
            logger.critical("ghostty_config_new failed")
            return nil
        }

        GhosttyFFI.configLoadDefaultFiles(cfg)
        GhosttyFFI.configLoadRecursiveFiles(cfg)
        GhosttyFFI.configFinalize(cfg)

        let diagCount = GhosttyFFI.configDiagnosticsCount(cfg)
        if diagCount > 0 {
            logger.warning("Configuration loaded with \(diagCount) diagnostic(s)")
            for i in 0..<diagCount {
                let diag = GhosttyFFI.configGetDiagnostic(cfg, index: i)
                let message = String(cString: diag.message)
                logger.warning("Config diagnostic: \(message)")
            }
        }

        return cfg
    }

    @discardableResult
    func reload() -> Bool {
        guard let newConfig = Self.loadDefaultConfig() else {
            logger.error("Failed to reload configuration")
            return false
        }
        self.config = newConfig
        return true
    }

    func cloneConfig() -> ghostty_config_t? {
        guard let cfg = config else { return nil }
        return GhosttyFFI.configClone(cfg)
    }

    // MARK: - Config Value Access

    func getBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let cfg = config else { return defaultValue }
        var value = defaultValue
        _ = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &value, ptr, UInt(key.utf8.count))
        }
        return value
    }

    func getString(_ key: String) -> String? {
        guard let cfg = config else { return nil }
        var v: UnsafePointer<Int8>? = nil
        let found = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &v, ptr, UInt(key.utf8.count))
        }
        guard found, let ptr = v else { return nil }
        return String(cString: ptr)
    }

    func getDouble(_ key: String, default defaultValue: Double = 0) -> Double {
        guard let cfg = config else { return defaultValue }
        var value = defaultValue
        _ = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &value, ptr, UInt(key.utf8.count))
        }
        return value
    }

    func getColor(_ key: String) -> ghostty_config_color_s? {
        guard let cfg = config else { return nil }
        var color = ghostty_config_color_s()
        let found = key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &color, ptr, UInt(key.utf8.count))
        }
        return found ? color : nil
    }

    func get<T>(_ key: String, value: inout T) -> Bool {
        guard let cfg = config else { return false }
        return key.withCString { ptr in
            GhosttyFFI.configGet(cfg, &value, ptr, UInt(key.utf8.count))
        }
    }

    // MARK: - Derived Properties

    var shouldQuitAfterLastWindowClosed: Bool {
        getBool("quit-after-last-window-closed", default: false)
    }

    var backgroundOpacity: Double {
        let v = getDouble("background-opacity", default: 1.0)
        if v.isFinite, v > 0, v <= 1 { return v }
        return 1.0
    }

    var backgroundColor: NSColor {
        guard let color = getColor("background") else { return .windowBackgroundColor }
        return NSColor(
            red: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1.0
        )
    }

    // MARK: - Scrollbar

    enum ScrollbarMode: String {
        case system
        case never
    }

    var scrollbarMode: ScrollbarMode {
        guard let str = getString("scrollbar") else { return .system }
        return ScrollbarMode(rawValue: str) ?? .system
    }
}
