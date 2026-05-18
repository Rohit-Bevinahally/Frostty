// WorkingDirectoryField.swift
// Frostty
//
// Editable path + folder browse (modal panel).

import AppKit
import SwiftUI

struct WorkingDirectoryValidationError: Error, Equatable, LocalizedError, Sendable {
    let invalidPath: String

    var errorDescription: String? {
        "\"\(invalidPath)\" is not a valid directory."
    }

    var recoverySuggestion: String? {
        "Enter an existing directory path, or leave the field blank to use the default working directory."
    }

    var alertDescription: String {
        "\(errorDescription ?? "Invalid working directory.") \(recoverySuggestion ?? "")"
    }
}

enum WorkingDirectoryValidator {
    static func sanitize(_ rawPath: String?) throws -> String? {
        guard let rawPath else { return nil }

        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalizedPath(for: trimmed)

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorkingDirectoryValidationError(invalidPath: normalized)
        }

        return normalized
    }

    static func validationError(for rawPath: String?) -> WorkingDirectoryValidationError {
        WorkingDirectoryValidationError(invalidPath: normalizedPath(for: rawPath ?? ""))
    }

    private static func normalizedPath(for rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}

struct WorkingDirectoryField: View {
    @Binding var path: String
    var placeholder: String = "~/path/to/directory"

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $path)
                .textFieldStyle(.plain)
                .font(GhosttyUIFonts.font(size: 13, fallbackDesign: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(TokyoNight.inactiveWorkspaceBackgroundColor.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(TokyoNight.inactiveWorkspaceForegroundColor.opacity(0.25), lineWidth: 1)
                )

            Button(action: browseForDirectory) {
                Image(systemName: "folder")
                    .font(GhosttyUIFonts.font(size: 13, weight: .medium))
                    .foregroundStyle(TokyoNight.inactiveWorkspaceForegroundColor)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(TokyoNight.inactiveWorkspaceBackgroundColor.opacity(0.45))
                    )
            }
            .buttonStyle(.plain)
            .help("Choose folder")
        }
    }

    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
