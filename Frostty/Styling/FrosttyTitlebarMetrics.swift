// FrosttyTitlebarMetrics.swift
// Frostty
//
// Layout metrics for merging the native titlebar / traffic lights into the
// tab bar chrome row when the sidebar is visible (Ghostty-style).

import CoreGraphics

enum FrosttyTitlebarMetrics {
    /// Visible tab bar content height (capsule row).
    static let tabBarContentHeight: CGFloat = 32

    /// Combined top chrome height when the sidebar (and traffic lights) are shown.
    static func combinedChromeHeight(titlebarInset: CGFloat, showSidebar: Bool) -> CGFloat {
        guard showSidebar else { return tabBarContentHeight }
        return max(titlebarInset, tabBarContentHeight)
    }
}
