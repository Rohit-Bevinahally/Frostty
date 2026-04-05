// Tab.swift
// Frostty
//
// A single terminal tab with split layout and surface registry.

import Foundation

@MainActor
@Observable
final class Tab: Identifiable {
    let id: UUID
    var title: String
    var pwd: String?
    /// When true, automatic title updates from terminals/browsers must not overwrite `title` until the user clears it.
    var usesCustomTitle: Bool = false
    var splitTree: SplitTree
    var isPaneMaximized: Bool
    let registry: SurfaceRegistry

    /// Tab bar / window chrome label: prefers `tab.title`; when empty, uses the focused pane’s title from `SurfaceRegistry` (Ghostty `SET_TITLE` / browser state).
    var tabBarLabel: String {
        if !title.isEmpty { return title }

        let leaves = splitTree.allLeafIDs()
        guard !leaves.isEmpty else { return "Terminal" }

        if let fid = splitTree.focusedLeafID {
            if let bc = registry.browserController(for: fid) {
                if bc.browserState.url.absoluteString.lowercased() == "about:blank" {
                    if let st = registry.title(for: fid), !st.isEmpty { return st }
                    return "Browser"
                }
                if let st = registry.title(for: fid), !st.isEmpty { return st }
                return "Browser"
            }
            if let st = registry.title(for: fid), !st.isEmpty {
                return st
            }
            return "Terminal"
        }

        let allBrowser = leaves.allSatisfy { registry.browserController(for: $0) != nil }
        return allBrowser ? "Browser" : "Terminal"
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        pwd: String? = nil,
        usesCustomTitle: Bool = false,
        splitTree: SplitTree = SplitTree(),
        isPaneMaximized: Bool = false,
        registry: SurfaceRegistry = SurfaceRegistry()
    ) {
        self.id = id
        self.title = title
        self.pwd = pwd
        self.usesCustomTitle = usesCustomTitle
        self.splitTree = splitTree
        self.isPaneMaximized = isPaneMaximized
        self.registry = registry
    }
}
