// NewWorkspaceSheet.swift
// Frostty
//
// Modal for naming a workspace and optional working directory.

import SwiftUI

struct NewWorkspaceSheet: View {
    @Binding var isPresented: Bool
    let defaultName: String
    let onCreate: (String, String?) -> Bool

    @State private var name: String
    @State private var workingDirectory: String
    @State private var validationError: WorkingDirectoryValidationError?
    @FocusState private var nameFocused: Bool

    init(isPresented: Binding<Bool>, defaultName: String, onCreate: @escaping (String, String?) -> Bool) {
        _isPresented = isPresented
        self.defaultName = defaultName
        self.onCreate = onCreate
        _name = State(initialValue: defaultName)
        _workingDirectory = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Workspace")
                .font(GhosttyUIFonts.font(textStyle: .headline))
                .foregroundStyle(TokyoNight.activeWorkspaceForegroundColor)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(GhosttyUIFonts.font(textStyle: .subheadline))
                    .foregroundStyle(TokyoNight.inactiveWorkspaceForegroundColor)
                TextField("Workspace name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .font(GhosttyUIFonts.font(size: 13))
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
                    .font(GhosttyUIFonts.font(textStyle: .subheadline))
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
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .tint(TokyoNight.activeTabBackgroundColor)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .background(TokyoNight.barBackgroundColor)
        .font(GhosttyUIFonts.font(textStyle: .body))
        .alert(
            "Invalid Working Directory",
            isPresented: Binding(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                validationError = nil
            }
        } message: {
            Text(validationError?.alertDescription ?? "")
        }
        .onAppear {
            name = defaultName
            workingDirectory = ""
            DispatchQueue.main.async {
                nameFocused = true
            }
        }
    }

    private func submit() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        do {
            let sanitizedWorkingDirectory = try WorkingDirectoryValidator.sanitize(workingDirectory)
            if onCreate(trimmedName, sanitizedWorkingDirectory) {
                isPresented = false
            }
        } catch let error as WorkingDirectoryValidationError {
            validationError = error
        } catch {
            validationError = WorkingDirectoryValidator.validationError(for: workingDirectory)
        }
    }
}
