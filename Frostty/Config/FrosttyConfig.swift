// FrosttyConfig.swift
// Frostty
//
// Frostty-specific configuration at ~/.config/frostty/config.
// Use for settings not exposed by the Ghostty C API and Frostty-only options.

import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "FrosttyConfig")

// MARK: - BackgroundBlurMode

enum BackgroundBlurMode: Equatable {
    case disabled
    case radius(Int)
    case macosGlassRegular
    case macosGlassClear

    init?(configString: String) {
        switch configString {
        case "false", "0":
            self = .disabled
        case "true":
            self = .radius(20)
        case "macos-glass-regular":
            if #available(macOS 26.0, *) {
                self = .macosGlassRegular
            } else {
                return nil
            }
        case "macos-glass-clear":
            if #available(macOS 26.0, *) {
                self = .macosGlassClear
            } else {
                return nil
            }
        default:
            guard let radius = Int(configString), radius > 0 else { return nil }
            self = .radius(radius)
        }
    }

    var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        default:
            return true
        }
    }

    var isGlassStyle: Bool {
        switch self {
        case .macosGlassRegular, .macosGlassClear:
            return true
        default:
            return false
        }
    }
}

// MARK: - FrosttyConfig

@MainActor
final class FrosttyConfig {

    static let shared = FrosttyConfig()

    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/frostty/config")
    }

    private(set) var values: [String: String] = [:]
    private(set) var configPath: String?

    private init() {
        reload()
    }

    @discardableResult
    func reload() -> Bool {
        let path = Self.defaultConfigURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            values = [:]
            configPath = nil
            return false
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            logger.error("Failed to read Frostty config at \(path, privacy: .public)")
            values = [:]
            configPath = path
            return false
        }

        values = Self.parseEntries(from: content)
        configPath = path
        return true
    }

    func value(for key: String) -> String? {
        values[key]
    }

    func bool(for key: String, default defaultValue: Bool = false) -> Bool {
        guard let raw = value(for: key)?.lowercased() else { return defaultValue }
        switch raw {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return defaultValue
        }
    }

    func double(for key: String) -> Double? {
        guard let raw = value(for: key) else { return nil }
        return Double(raw)
    }

    // MARK: - Derived Properties

    var backgroundBlur: BackgroundBlurMode {
        guard let value = value(for: "background-blur"),
              let parsed = BackgroundBlurMode(configString: value) else {
            return .disabled
        }
        return parsed
    }

    var usesGlassBackground: Bool {
        backgroundBlur.isGlassStyle
    }

    // MARK: - Parsing

    static func parseEntries(from content: String) -> [String: String] {
        var entries: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }

            let key = trimmed[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }

            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            entries[key] = value
        }
        return entries
    }
}
