// FrosttySheetButtonStyle.swift
// Frostty

import SwiftUI

struct FrosttySheetButtonStyle: ButtonStyle {
    enum Kind {
        case cancel
        case accent
    }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay {
                if kind == .cancel {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            TokyoNight.inactiveWorkspaceForegroundColor.opacity(isEnabled ? 0.45 : 0.25),
                            lineWidth: 1
                        )
                }
            }
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch kind {
        case .cancel:
            return TokyoNight.inactiveWorkspaceForegroundColor.opacity(isEnabled ? (isPressed ? 0.75 : 1) : 0.45)
        case .accent:
            return TokyoNight.activeTabForegroundColor
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch kind {
        case .cancel:
            return TokyoNight.inactiveWorkspaceBackgroundColor.opacity(
                isEnabled ? (isPressed ? 0.55 : 0.35) : 0.2
            )
        case .accent:
            return TokyoNight.activeTabBackgroundColor.opacity(
                isEnabled ? (isPressed ? 0.85 : 1) : 0.45
            )
        }
    }
}

extension ButtonStyle where Self == FrosttySheetButtonStyle {
    static var frosttySheetCancel: FrosttySheetButtonStyle { FrosttySheetButtonStyle(kind: .cancel) }
    static var frosttySheetAccent: FrosttySheetButtonStyle { FrosttySheetButtonStyle(kind: .accent) }
}
