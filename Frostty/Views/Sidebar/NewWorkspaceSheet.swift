// NewWorkspaceSheet.swift
// Frostty
//
// Modal for naming a workspace and optional working directory.

import SwiftUI

struct NewWorkspaceSheet: View {
    @Binding var isPresented: Bool
    var defaultName: String
    var onCreate: (String, String?) -> Void

    @State private var name: String = ""
    @State private var workingDirectory: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Workspace")
                .font(.headline)
                .foregroundStyle(TokyoNight.activeWorkspaceForegroundColor)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(TokyoNight.inactiveWorkspaceForegroundColor)
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(TokyoNight.inactiveWorkspaceBackgroundColor.opacity(0.45))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(TokyoNight.inactiveWorkspaceForegroundColor.opacity(0.25), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Working directory (optional)")
                    .font(.subheadline)
                    .foregroundStyle(TokyoNight.inactiveWorkspaceForegroundColor)
                WorkingDirectoryField(path: $workingDirectory)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .foregroundStyle(TokyoNight.inactiveWorkspaceForegroundColor)

                Button("Create") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let wd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCreate(trimmedName, wd.isEmpty ? nil : wd)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .tint(TokyoNight.activeTabBackgroundColor)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .background(TokyoNight.barBackgroundColor)
        .onAppear {
            name = defaultName
            workingDirectory = ""
            DispatchQueue.main.async {
                nameFocused = true
            }
        }
    }
}
