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
    var splitTree: SplitTree
    var isPaneMaximized: Bool
    let registry: SurfaceRegistry

    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        pwd: String? = nil,
        splitTree: SplitTree = SplitTree(),
        isPaneMaximized: Bool = false,
        registry: SurfaceRegistry = SurfaceRegistry()
    ) {
        self.id = id
        self.title = title
        self.pwd = pwd
        self.splitTree = splitTree
        self.isPaneMaximized = isPaneMaximized
        self.registry = registry
    }
}
