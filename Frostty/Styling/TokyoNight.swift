// TokyoNight.swift
// Frostty
//
// Hardcoded Tokyo Night color constants for tab bar and sidebar styling.

import AppKit
import SwiftUI

enum TokyoNight {
    // Active tab/workspace
    static let activeTabBackground = NSColor(
        red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0, alpha: 1.0
    ) // #7aa2f7
    static let activeTabForeground = NSColor(
        red: 0x1f / 255.0, green: 0x23 / 255.0, blue: 0x35 / 255.0, alpha: 1.0
    ) // #1f2335

    // Inactive tab
    static let inactiveTabBackground = NSColor(
        red: 0x54 / 255.0, green: 0x5c / 255.0, blue: 0x7e / 255.0, alpha: 1.0
    ) // #545c7e
    static let inactiveTabForeground = NSColor(
        red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0, alpha: 1.0
    ) // #7aa2f7

    // Workspace sidebar
    static let activeWorkspaceBackground = activeTabBackground   // #7aa2f7
    static let activeWorkspaceForeground = activeTabForeground   // #1f2335
    static let inactiveWorkspaceBackground = NSColor(
        red: 0x29 / 255.0, green: 0x2e / 255.0, blue: 0x42 / 255.0, alpha: 1.0
    ) // #292e42
    static let inactiveWorkspaceForeground = NSColor(
        red: 0x54 / 255.0, green: 0x5c / 255.0, blue: 0x7e / 255.0, alpha: 1.0
    ) // #545c7e

    // Bar and sidebar background
    static let barBackground = NSColor(
        red: 0x1d / 255.0, green: 0x20 / 255.0, blue: 0x2f / 255.0, alpha: 1.0
    ) // #1d202f

    // Border colors for split panes
    static let activeBorderColor = NSColor(
        red: 0x7a / 255.0, green: 0xa2 / 255.0, blue: 0xf7 / 255.0, alpha: 1.0
    ) // #7aa2f7
    static let inactiveBorderColor = NSColor(
        red: 0x54 / 255.0, green: 0x5c / 255.0, blue: 0x7e / 255.0, alpha: 1.0
    ) // #545c7e

    static let dragHandleStrip = NSColor(
        red: 0x86 / 255.0, green: 0x8f / 255.0, blue: 0xb8 / 255.0, alpha: 1.0
    ) // #868fb8

    static let dropZoneFill = NSColor.controlAccentColor.withAlphaComponent(0.22)
    static let dropZoneStroke = NSColor.controlAccentColor.withAlphaComponent(0.55)

    // SwiftUI Color versions — tabs
    static let activeTabBackgroundColor = Color(nsColor: activeTabBackground)
    static let activeTabForegroundColor = Color(nsColor: activeTabForeground)
    static let inactiveTabBackgroundColor = Color(nsColor: inactiveTabBackground)
    static let inactiveTabForegroundColor = Color(nsColor: inactiveTabForeground)

    // SwiftUI Color versions — workspaces
    static let activeWorkspaceBackgroundColor = Color(nsColor: activeWorkspaceBackground)
    static let activeWorkspaceForegroundColor = Color(nsColor: activeWorkspaceForeground)
    static let inactiveWorkspaceBackgroundColor = Color(nsColor: inactiveWorkspaceBackground)
    static let inactiveWorkspaceForegroundColor = Color(nsColor: inactiveWorkspaceForeground)

    // SwiftUI Color versions — general
    static let barBackgroundColor = Color(nsColor: barBackground)
    static let activeBorderSwiftUIColor = Color(nsColor: activeBorderColor)
    static let inactiveBorderSwiftUIColor = Color(nsColor: inactiveBorderColor)
    static let dragHandleStripColor = Color(nsColor: dragHandleStrip)
    static let dropZoneFillColor = Color(nsColor: dropZoneFill)
    static let dropZoneStrokeColor = Color(nsColor: dropZoneStroke)
}
