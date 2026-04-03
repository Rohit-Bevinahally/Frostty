// WindowSession.swift
// Frostty
//
// Represents a single window's state with workspaces.

import Foundation

enum TabRemoveResult {
    case switchedTab(workspaceID: UUID, tabID: UUID)
    case switchedWorkspace(workspaceID: UUID, tabID: UUID)
    case windowShouldClose
}

@MainActor
@Observable
final class WindowSession: Identifiable {
    let id: UUID
    var workspaces: [Workspace]
    var activeWorkspaceID: UUID?
    var showSidebar: Bool
    var sidebarWidth: CGFloat

    static let defaultSidebarWidth: CGFloat = 240
    static let minSidebarWidth: CGFloat = 140
    static let maxSidebarWidth: CGFloat = 400

    var activeWorkspace: Workspace? {
        workspaces.first { $0.id == activeWorkspaceID }
    }

    init(
        id: UUID = UUID(),
        workspaces: [Workspace] = [],
        activeWorkspaceID: UUID? = nil,
        showSidebar: Bool = true,
        sidebarWidth: CGFloat = WindowSession.defaultSidebarWidth
    ) {
        self.id = id
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.showSidebar = showSidebar
        self.sidebarWidth = sidebarWidth
    }

    /// Convenience init with a single workspace containing a single tab.
    convenience init(initialTab: Tab, workspaceName: String = "Default") {
        let workspace = Workspace(name: workspaceName, tabs: [initialTab], activeTabID: initialTab.id)
        self.init(workspaces: [workspace], activeWorkspaceID: workspace.id)
    }

    func addWorkspace(_ workspace: Workspace) {
        workspaces.append(workspace)
        if activeWorkspaceID == nil {
            activeWorkspaceID = workspace.id
        }
    }

    func insertWorkspace(_ workspace: Workspace, at index: Int) {
        let clampedIndex = min(max(index, 0), workspaces.count)
        workspaces.insert(workspace, at: clampedIndex)
        if activeWorkspaceID == nil {
            activeWorkspaceID = workspace.id
        }
    }

    @discardableResult
    func removeTab(id tabID: UUID, fromWorkspace workspaceID: UUID) -> TabRemoveResult {
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return .windowShouldClose
        }

        let workspace = workspaces[wsIndex]
        workspace.removeTab(id: tabID)

        if let newActiveTab = workspace.activeTab {
            return .switchedTab(workspaceID: workspaceID, tabID: newActiveTab.id)
        }

        workspaces.remove(at: wsIndex)

        if workspaces.isEmpty {
            activeWorkspaceID = nil
            return .windowShouldClose
        }

        let newWsIndex = wsIndex < workspaces.count ? wsIndex : workspaces.count - 1
        let newWorkspace = workspaces[newWsIndex]
        activeWorkspaceID = newWorkspace.id

        if let tab = newWorkspace.activeTab {
            return .switchedWorkspace(workspaceID: newWorkspace.id, tabID: tab.id)
        }

        return .windowShouldClose
    }

    @discardableResult
    func removeWorkspace(id: UUID) -> TabRemoveResult {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            return .windowShouldClose
        }

        workspaces.remove(at: index)

        if workspaces.isEmpty {
            activeWorkspaceID = nil
            return .windowShouldClose
        }

        if activeWorkspaceID == id {
            let newIndex = index < workspaces.count ? index : workspaces.count - 1
            let newWorkspace = workspaces[newIndex]
            activeWorkspaceID = newWorkspace.id

            if let tab = newWorkspace.activeTab {
                return .switchedWorkspace(workspaceID: newWorkspace.id, tabID: tab.id)
            }
            return .windowShouldClose
        }

        if let aw = activeWorkspace, let tab = aw.activeTab {
            return .switchedWorkspace(workspaceID: aw.id, tabID: tab.id)
        }
        return .windowShouldClose
    }

    func moveWorkspace(fromIndex: Int, toIndex: Int) {
        guard fromIndex != toIndex,
              workspaces.indices.contains(fromIndex),
              toIndex >= 0, toIndex < workspaces.count else { return }
        let ws = workspaces.remove(at: fromIndex)
        workspaces.insert(ws, at: toIndex)
    }

    func nextTab() {
        guard let workspace = activeWorkspace,
              let currentID = workspace.activeTabID,
              let currentIndex = workspace.tabs.firstIndex(where: { $0.id == currentID }),
              workspace.tabs.count > 1 else { return }
        let nextIndex = (currentIndex + 1) % workspace.tabs.count
        workspace.activeTabID = workspace.tabs[nextIndex].id
    }

    func previousTab() {
        guard let workspace = activeWorkspace,
              let currentID = workspace.activeTabID,
              let currentIndex = workspace.tabs.firstIndex(where: { $0.id == currentID }),
              workspace.tabs.count > 1 else { return }
        let prevIndex = (currentIndex - 1 + workspace.tabs.count) % workspace.tabs.count
        workspace.activeTabID = workspace.tabs[prevIndex].id
    }

    func selectTab(at index: Int) {
        guard let workspace = activeWorkspace,
              index >= 0, index < workspace.tabs.count else { return }
        workspace.activeTabID = workspace.tabs[index].id
    }

    func nextWorkspace() {
        guard let currentID = activeWorkspaceID,
              let currentIndex = workspaces.firstIndex(where: { $0.id == currentID }),
              workspaces.count > 1 else { return }
        let nextIndex = (currentIndex + 1) % workspaces.count
        activeWorkspaceID = workspaces[nextIndex].id
    }

    func previousWorkspace() {
        guard let currentID = activeWorkspaceID,
              let currentIndex = workspaces.firstIndex(where: { $0.id == currentID }),
              workspaces.count > 1 else { return }
        let prevIndex = (currentIndex - 1 + workspaces.count) % workspaces.count
        activeWorkspaceID = workspaces[prevIndex].id
    }

    func selectWorkspace(at index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        activeWorkspaceID = workspaces[index].id
    }
}
