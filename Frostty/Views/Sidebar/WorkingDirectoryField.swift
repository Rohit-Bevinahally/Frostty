// WorkingDirectoryField.swift
// Frostty
//
// Editable path + folder browse (modal panel).

import AppKit
import SwiftUI

struct WorkingDirectoryField: View {
    @Binding var path: String
    var placeholder: String = "~/path/to/directory"

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $path)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
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
                    .font(.system(size: 13, weight: .medium))
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
