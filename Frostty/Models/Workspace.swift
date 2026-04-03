// Workspace.swift
// Frostty
//
// A workspace groups terminal tabs for the sidebar.

import Foundation

@MainActor
@Observable
final class Workspace: Identifiable {
    let id: UUID
    var name: String
    var workingDirectory: String?
    var tabs: [Tab]
    var activeTabID: UUID?

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    init(
        id: UUID = UUID(),
        name: String = "Default",
        workingDirectory: String? = nil,
        tabs: [Tab] = [],
        activeTabID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    func addTab(_ tab: Tab) {
        tabs.append(tab)
        if activeTabID == nil {
            activeTabID = tab.id
        }
    }

    /// Insert a tab adjacent to the currently active tab.
    /// If no active tab, appends to end.
    func insertTabAdjacentToActive(_ tab: Tab) {
        if let currentID = activeTabID,
           let currentIndex = tabs.firstIndex(where: { $0.id == currentID }) {
            tabs.insert(tab, at: currentIndex + 1)
        } else {
            tabs.append(tab)
        }
    }

    func insertTab(_ tab: Tab, afterTabID: UUID) {
        if let index = tabs.firstIndex(where: { $0.id == afterTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    func insertTab(_ tab: Tab, at index: Int) {
        let clampedIndex = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: clampedIndex)
        if activeTabID == nil {
            activeTabID = tab.id
        }
    }

    func removeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)

        if activeTabID == id {
            if tabs.isEmpty {
                activeTabID = nil
            } else if index < tabs.count {
                activeTabID = tabs[index].id
            } else {
                activeTabID = tabs[tabs.count - 1].id
            }
        }
    }

    func moveTab(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              tabs.indices.contains(fromIndex),
              toIndex >= 0, toIndex < tabs.count else { return }
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: toIndex)
    }
}
