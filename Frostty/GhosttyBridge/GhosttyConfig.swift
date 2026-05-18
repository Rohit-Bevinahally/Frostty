// GhosttyConfig.swift
// Frostty
//
// Wraps ghostty_config_t lifecycle and provides configuration access.

@preconcurrency import AppKit
import CoreText
import GhosttyKit
import os
import SwiftUI

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

    private func nonEmptyString(_ key: String) -> String? {
        guard let value = getString(key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
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

    var primaryFontFamily: String? {
        nonEmptyString("font-family")
    }

    var windowTitleFontFamily: String? {
        nonEmptyString("window-title-font-family")
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

@MainActor
enum GhosttyUIFonts {
    static func font(textStyle: NSFont.TextStyle) -> Font {
        Font(nsFont(textStyle: textStyle))
    }

    static func font(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        fallbackDesign: NSFontDescriptor.SystemDesign = .default
    ) -> Font {
        Font(nsFont(size: size, weight: weight, fallbackDesign: fallbackDesign))
    }

    static func nsFont(textStyle: NSFont.TextStyle) -> NSFont {
        let preferred = NSFont.preferredFont(forTextStyle: textStyle, options: [:])
        return nsFont(size: preferred.pointSize, weight: preferred.frosttyWeight)
    }

    static func nsFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        fallbackDesign: NSFontDescriptor.SystemDesign = .default
    ) -> NSFont {
        if let family = preferredFamilyName(),
           let configuredFont = configuredFont(family: family, size: size, weight: weight) {
            return configuredFont
        }

        return fallbackSystemFont(size: size, weight: weight, design: fallbackDesign)
    }

    private static func preferredFamilyName() -> String? {
        let config = GhosttyAppController.shared.configManager
        if let family = config.windowTitleFontFamily {
            return family
        }
        if let family = activeSurfaceFontFamily() {
            return family
        }
        return config.primaryFontFamily
    }

    private static func activeSurfaceFontFamily() -> String? {
        for controller in candidateWindowControllers() {
            guard let surface = controller.preferredUIFontSurface,
                  let fontRaw = GhosttyFFI.surfaceQuicklookFont(surface) else {
                continue
            }

            let font = Unmanaged<CTFont>.fromOpaque(fontRaw).takeRetainedValue()
            let family = (CTFontCopyFamilyName(font) as String).trimmingCharacters(in: .whitespacesAndNewlines)
            if !family.isEmpty {
                return family
            }
        }

        return nil
    }

    private static func candidateWindowControllers() -> [FrosttyWindowController] {
        var controllers: [FrosttyWindowController] = []

        if let keyController = NSApp.keyWindow?.windowController as? FrosttyWindowController {
            controllers.append(keyController)
        }

        for window in NSApp.windows {
            guard let controller = window.windowController as? FrosttyWindowController else { continue }
            guard !controllers.contains(where: { $0 === controller }) else { continue }
            controllers.append(controller)
        }

        return controllers
    }

    private static func configuredFont(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(
            fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ]
        )
        return NSFont(descriptor: descriptor, size: size)
    }

    private static func fallbackSystemFont(
        size: CGFloat,
        weight: NSFont.Weight,
        design: NSFontDescriptor.SystemDesign
    ) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard design != .default,
              let descriptor = base.fontDescriptor.withDesign(design),
              let designedFont = NSFont(descriptor: descriptor, size: size) else {
            return base
        }

        return designedFont
    }
}

private extension NSFont {
    var frosttyWeight: NSFont.Weight {
        let traits = fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let rawValue = traits?[.weight] as? CGFloat ?? 0
        return NSFont.Weight(rawValue: rawValue)
    }
}
