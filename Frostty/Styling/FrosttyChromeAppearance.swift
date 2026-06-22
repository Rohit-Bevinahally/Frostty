// FrosttyChromeAppearance.swift
// Frostty
//
// Theme-aware chrome styling

import AppKit
import SwiftUI

@MainActor
enum FrosttyChromeAppearance {
    static var usesGlassBackground: Bool {
        FrosttyConfig.shared.usesGlassBackground
    }

    /// Default glass blur style for chrome panels and inactive capsules.
    static var chromeGlassStyle: FrosttyGlassStyle {
        .clear
    }

    // MARK: - Panel styles

    static var sidebarPanelStyle: FrosttyChromePanelStyle {
        if usesGlassBackground {
            return .glassMaterial(sidebarPanelMaterial)
        }
        return .opaque
    }

    static var sidebarPanelMaterial: FrosttyChromeGlassMaterial {
        FrosttyChromeGlassMaterial(
            tint: TokyoNight.barBackground.withAlphaComponent(0.75),
            style: .regular
        )
    }

    /// No panel — tab bar shows wallpaper; only tab capsules add glass.
    static var tabBarPanelStyle: FrosttyChromePanelStyle {
        if usesGlassBackground {
            return .transparent
        }
        return .opaque
    }

    static var opaqueChromeBackground: Color {
        TokyoNight.barBackgroundColor
    }

    // MARK: - Tab capsules

    static func tabCapsuleMaterial(isActive: Bool, isHovering: Bool) -> FrosttyChromeGlassMaterial {
        FrosttyChromeGlassMaterial(
            tint: tabCapsuleTint(isActive: isActive, isHovering: isHovering),
            style: .clear
        )
    }

    static func tabCapsuleTint(isActive: Bool, isHovering: Bool) -> NSColor {
        if isActive {
            return TokyoNight.activeTabBackground
        }
        if usesGlassBackground {
            if isHovering {
                return TokyoNight.inactiveTabBackground.withAlphaComponent(0.75)
            }
            return TokyoNight.barBackground.withAlphaComponent(0.5)
        }
        if isHovering {
            return TokyoNight.inactiveTabBackground.withAlphaComponent(0.75)
        }
        return TokyoNight.inactiveTabBackground
    }

    static func tabCapsuleUsesSolidFill(isActive: Bool) -> Bool {
        isActive || !usesGlassBackground
    }

    // MARK: - Workspace capsules

    static func workspaceCapsuleMaterial(
        isActive: Bool,
        isHovering: Bool,
        isPaneDropTarget: Bool
    ) -> FrosttyChromeGlassMaterial {
        FrosttyChromeGlassMaterial(
            tint: workspaceCapsuleTint(
                isActive: isActive,
                isHovering: isHovering,
                isPaneDropTarget: isPaneDropTarget
            ),
            style: chromeGlassStyle
        )
    }

    static func workspaceCapsuleTint(
        isActive: Bool,
        isHovering: Bool,
        isPaneDropTarget: Bool
    ) -> NSColor {
        if isPaneDropTarget {
            return NSColor(TokyoNight.dropZoneFillColor)
        }
        if isActive {
            return TokyoNight.activeWorkspaceBackground
        }
        if usesGlassBackground {
            if isHovering {
                return TokyoNight.barBackground.withAlphaComponent(0.86)
            }
            return .clear
        }
        if isHovering {
            return TokyoNight.inactiveWorkspaceBackground
        }
        return .clear
    }

    static func workspaceCapsuleUsesSolidFill(isActive: Bool, isPaneDropTarget: Bool) -> Bool {
        isActive || isPaneDropTarget || !usesGlassBackground
    }

    static func newWorkspaceButtonMaterial(isHovering: Bool) -> FrosttyChromeGlassMaterial {
        FrosttyChromeGlassMaterial(
            tint: newWorkspaceButtonTint(isHovering: isHovering),
            style: chromeGlassStyle
        )
    }

    static func newWorkspaceButtonTint(isHovering: Bool) -> NSColor {
        if usesGlassBackground {
            if isHovering {
                return TokyoNight.barBackground.withAlphaComponent(0.86)
            }
            return .clear
        }
        return NSColor(newWorkspaceButtonFill(isHovering: isHovering))
    }

    static func newWorkspaceButtonFill(isHovering: Bool) -> Color {
        if isHovering {
            return TokyoNight.inactiveWorkspaceBackgroundColor.opacity(0.55)
        }
        return .clear
    }

    // MARK: - HUD chips (search bar, toasts)

    /// Matches the terminal pane glass blur style when glass mode is on.
    static var hudGlassStyle: FrosttyGlassStyle {
        switch FrosttyConfig.shared.backgroundBlur {
        case .macosGlassRegular:
            return .regular
        case .macosGlassClear:
            return .clear
        default:
            return .regular
        }
    }

    static func hudChipMaterial() -> FrosttyChromeGlassMaterial {
        if usesGlassBackground {
            let config = GhosttyAppController.shared.configManager
            let opacity = min(max(config.backgroundOpacity + 0.18, 0.72), 0.9)
            return FrosttyChromeGlassMaterial(
                tint: config.backgroundColor.withAlphaComponent(opacity),
                style: hudGlassStyle
            )
        }
        return FrosttyChromeGlassMaterial(
            tint: TokyoNight.barBackground.withAlphaComponent(0.96),
            style: .regular
        )
    }

    static func hudFieldInsetMaterial() -> FrosttyChromeGlassMaterial {
        if usesGlassBackground {
            let config = GhosttyAppController.shared.configManager
            return FrosttyChromeGlassMaterial(
                tint: config.backgroundColor.withAlphaComponent(0.42),
                style: .clear
            )
        }
        return FrosttyChromeGlassMaterial(
            tint: NSColor.labelColor.withAlphaComponent(0.1),
            style: .clear
        )
    }

    static func hudButtonHighlightTint(isPressed: Bool, isHovering: Bool) -> NSColor {
        let config = GhosttyAppController.shared.configManager
        let base = config.backgroundColor
        if isPressed {
            return base.withAlphaComponent(0.55)
        }
        if isHovering {
            return base.withAlphaComponent(0.32)
        }
        return .clear
    }

    static var hudAccentStrokeColor: Color {
        TokyoNight.activeBorderSwiftUIColor.opacity(usesGlassBackground ? 0.45 : 0.6)
    }
}
