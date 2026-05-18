// SidebarView.swift
// Frostty
//
// Workspace list, frame-based reorder, new workspace sheet, WD editor.

import AppKit
import SwiftUI

private enum WorkspaceCapsuleMetrics {
    static let cornerRadius: CGFloat = 8
    static let minHeight: CGFloat = 34
}

private struct WorkspaceFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private final class WorkspaceFrameCache {
    var frames: [UUID: CGRect] = [:]
}

private func insertionSlotForVerticalDrag(dragMidY: CGFloat, workspaces: [Workspace], frames: [UUID: CGRect]) -> Int {
    let orderedMids = workspaces.compactMap { w -> CGFloat? in frames[w.id].map(\.midY) }
    var slot = 0
    for my in orderedMids where dragMidY > my {
        slot += 1
    }
    return min(slot, workspaces.count)
}

private func destinationIndexForWorkspaceReorder(fromIndex: Int, insertionSlot: Int, count: Int) -> Int? {
    let slot = min(max(insertionSlot, 0), count)
    if slot <= fromIndex {
        if slot == fromIndex { return nil }
        return slot
    } else {
        if slot == fromIndex + 1 { return nil }
        return slot - 1
    }
}

// MARK: - Working directory sheet

private struct WorkingDirectoryEditorPayload: Identifiable {
    let workspaceID: UUID
    var draftPath: String
    var id: UUID { workspaceID }
}

private struct EditWorkingDirectorySheet: View {
    let workspaceID: UUID
    @State private var path: String
    @State private var validationError: WorkingDirectoryValidationError?
    let onSave: (UUID, String?) -> Bool
    let onDismiss: () -> Void

    init(workspaceID: UUID, initialPath: String, onSave: @escaping (UUID, String?) -> Bool, onDismiss: @escaping () -> Void) {
        self.workspaceID = workspaceID
        _path = State(initialValue: initialPath)
        self.onSave = onSave
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Working directory")
                .font(GhosttyUIFonts.font(textStyle: .headline))
                .foregroundStyle(TokyoNight.activeWorkspaceForegroundColor)

            WorkingDirectoryField(path: $path)

            HStack {
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(TokyoNight.inactiveWorkspaceForegroundColor)
                Button("Save") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
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
    }

    private func submit() {
        do {
            let sanitizedPath = try WorkingDirectoryValidator.sanitize(path)
            if onSave(workspaceID, sanitizedPath) {
                onDismiss()
            }
        } catch let error as WorkingDirectoryValidationError {
            validationError = error
        } catch {
            validationError = WorkingDirectoryValidator.validationError(for: path)
        }
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    let workspaces: [Workspace]
    let activeWorkspaceID: UUID?
    let currentWidth: CGFloat

    var onSelectWorkspace: ((UUID) -> Void)?
    var onAddWorkspace: ((String, String?) -> Bool)?
    var onDeleteWorkspace: ((UUID) -> Void)?
    var onRenameWorkspace: ((UUID, String) -> Void)?
    var onMoveWorkspace: ((Int, Int) -> Void)?
    var onSetWorkingDirectory: ((UUID, String?) -> Bool)?
    var onPaneMoveToNewWorkspaceAtSlot: ((UUID, Int) -> Void)?
    var onPaneMoveToWorkspace: ((UUID, UUID) -> Void)?
    var onSidebarWidthChanging: ((CGFloat) -> Void)?
    var onSidebarWidthChangeEnded: ((CGFloat) -> Void)?

    @State private var draggedWorkspaceID: UUID?
    @State private var draggedFromIndex: Int?
    @State private var dragOffsetY: CGFloat = 0
    @State private var workspaceFrameCache = WorkspaceFrameCache()
    @State private var insertionSlot: Int?

    @State private var showNewWorkspaceSheet = false
    @State private var newWorkspaceDefaultName = "Workspace"
    @State private var workingDirectoryEditor: WorkingDirectoryEditorPayload?
    @State private var paneDropWorkspaceID: UUID?
    @State private var paneDropInsertionSlot: Int?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                        if let slot = insertionSlot, draggedWorkspaceID != nil, slot == index {
                            workspaceReorderInsertionLine
                        }
                        if let slot = paneDropInsertionSlot,
                           draggedWorkspaceID == nil,
                           paneDropWorkspaceID == nil,
                           slot == index {
                            paneDropWorkspaceGhostCapsule
                        }

                        WorkspaceRowView(
                            workspace: workspace,
                            isActive: workspace.id == activeWorkspaceID,
                            isPaneDropTarget: paneDropWorkspaceID == workspace.id,
                            onSelect: { onSelectWorkspace?(workspace.id) },
                            onRename: { newName in onRenameWorkspace?(workspace.id, newName) },
                            onDelete: { onDeleteWorkspace?(workspace.id) },
                            onSetWorkingDirectory: {
                                workingDirectoryEditor = WorkingDirectoryEditorPayload(
                                    workspaceID: workspace.id,
                                    draftPath: workspace.workingDirectory ?? ""
                                )
                            }
                        )
                        .background(workspaceFrameReporter(workspaceID: workspace.id))
                        .offset(y: draggedWorkspaceID == workspace.id ? dragOffsetY : 0)
                        .zIndex(draggedWorkspaceID == workspace.id ? 2 : 0)
                        .scaleEffect(draggedWorkspaceID == workspace.id ? 1.02 : 1.0)
                        .animation(.easeOut(duration: 0.12), value: dragOffsetY)
                        .highPriorityGesture(workspaceDragGesture(index: index, workspace: workspace))
                    }

                    if let slot = insertionSlot, draggedWorkspaceID != nil, slot == workspaces.count {
                        workspaceReorderInsertionLine
                    }
                    if let slot = paneDropInsertionSlot,
                       draggedWorkspaceID == nil,
                       paneDropWorkspaceID == nil,
                       slot == workspaces.count {
                        paneDropWorkspaceGhostCapsule
                    }

                    workspaceSectionSeparator
                    newWorkspaceButton
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .onPreferenceChange(WorkspaceFramePreferenceKey.self) { frames in
                    Task { @MainActor in
                        workspaceFrameCache.frames = frames
                        guard paneDropWorkspaceID != nil || paneDropInsertionSlot != nil else { return }
                        updatePaneDropState()
                    }
                }
            }
        }
        .background(TokyoNight.barBackgroundColor)
        .font(GhosttyUIFonts.font(textStyle: .body))
        .overlay {
            GeometryReader { geo in
                PaneDragDropTargetRepresentable(
                    globalFrame: geo.frame(in: .global),
                    onDragUpdated: { _, point in
                        updatePaneDropState(for: point)
                        return true
                    },
                    onDragExited: clearPaneDropState,
                    onDrop: { paneID, _ in
                        let targetWorkspaceID = paneDropWorkspaceID
                        let targetInsertionSlot = paneDropInsertionSlot
                        clearPaneDropState()

                        if let targetWorkspaceID {
                            onPaneMoveToWorkspace?(paneID, targetWorkspaceID)
                            return true
                        }

                        guard let targetInsertionSlot else { return false }
                        onPaneMoveToNewWorkspaceAtSlot?(paneID, targetInsertionSlot)
                        return true
                    }
                )
                .padding(.trailing, 8)
            }
        }
        .overlay(alignment: .trailing) {
            SidebarResizeHandle(
                currentWidth: currentWidth,
                onWidthChanging: onSidebarWidthChanging,
                onWidthChangeEnded: onSidebarWidthChangeEnded
            )
        }
        .sheet(isPresented: $showNewWorkspaceSheet) {
            NewWorkspaceSheet(
                isPresented: $showNewWorkspaceSheet,
                defaultName: newWorkspaceDefaultName,
                onCreate: { name, wd in
                    onAddWorkspace?(name, wd) ?? false
                }
            )
        }
        .sheet(item: $workingDirectoryEditor) { payload in
            EditWorkingDirectorySheet(
                workspaceID: payload.workspaceID,
                initialPath: payload.draftPath,
                onSave: { id, path in
                    onSetWorkingDirectory?(id, path) ?? false
                },
                onDismiss: { workingDirectoryEditor = nil }
            )
        }
    }

    private var workspaceReorderInsertionLine: some View {
        HStack {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(TokyoNight.activeWorkspaceBackgroundColor)
                .frame(height: 3)
                .padding(.vertical, 2)
        }
    }

    private var paneDropWorkspaceGhostCapsule: some View {
        RoundedRectangle(cornerRadius: WorkspaceCapsuleMetrics.cornerRadius, style: .continuous)
            .fill(TokyoNight.dropZoneFillColor)
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceCapsuleMetrics.cornerRadius, style: .continuous)
                    .stroke(TokyoNight.dropZoneStrokeColor, lineWidth: 1)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: WorkspaceCapsuleMetrics.minHeight)
    }

    private func workspaceFrameReporter(workspaceID: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: WorkspaceFramePreferenceKey.self,
                value: [workspaceID: geo.frame(in: .global)]
            )
        }
    }

    private var newWorkspaceButton: some View {
        NewWorkspaceRowButton(
            title: "New Workspace",
            systemImage: "plus.rectangle",
            action: {
                newWorkspaceDefaultName = "Workspace \(workspaces.count + 1)"
                showNewWorkspaceSheet = true
            }
        )
        .padding(.horizontal, 4)
    }

    private var workspaceSectionSeparator: some View {
        Rectangle()
            .fill(TokyoNight.inactiveBorderSwiftUIColor.opacity(0.7))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
    }

    private func workspaceDragGesture(index: Int, workspace: Workspace) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard workspaces.count > 1, onMoveWorkspace != nil else { return }
                if draggedWorkspaceID == nil {
                    draggedWorkspaceID = workspace.id
                    draggedFromIndex = index
                }
                guard draggedWorkspaceID == workspace.id else { return }
                dragOffsetY = value.translation.height
                let baseMidY = workspaceFrameCache.frames[workspace.id]?.midY ?? 0
                let dragMidY = baseMidY + value.translation.height
                insertionSlot = insertionSlotForVerticalDrag(
                    dragMidY: dragMidY,
                    workspaces: workspaces,
                    frames: workspaceFrameCache.frames
                )
            }
            .onEnded { _ in
                if let from = draggedFromIndex,
                   draggedWorkspaceID == workspace.id,
                   workspaces.count > 1,
                   let slot = insertionSlot,
                   let to = destinationIndexForWorkspaceReorder(
                    fromIndex: from,
                    insertionSlot: slot,
                    count: workspaces.count
                   ),
                   from != to {
                    onMoveWorkspace?(from, to)
                }
                withAnimation(.easeOut(duration: 0.18)) {
                    draggedWorkspaceID = nil
                    draggedFromIndex = nil
                    dragOffsetY = 0
                    insertionSlot = nil
                }
            }
    }

    private func updatePaneDropState() {
        guard let paneDropInsertionSlot else { return }
        if paneDropWorkspaceID == nil {
            self.paneDropInsertionSlot = min(max(paneDropInsertionSlot, 0), workspaces.count)
        }
    }

    private func updatePaneDropState(for globalPoint: CGPoint) {
        if let hoveredWorkspaceID = workspaceContainingPoint(at: globalPoint),
           hoveredWorkspaceID == activeWorkspaceID {
            paneDropWorkspaceID = nil
            paneDropInsertionSlot = nil
            return
        }

        if let workspaceID = workspaceDropTarget(at: globalPoint) {
            paneDropWorkspaceID = workspaceID
            paneDropInsertionSlot = nil
            return
        }

        paneDropWorkspaceID = nil
        paneDropInsertionSlot = workspaceInsertionSlot(for: globalPoint.y)
    }

    private func clearPaneDropState() {
        paneDropWorkspaceID = nil
        paneDropInsertionSlot = nil
    }

    private func workspaceContainingPoint(at globalPoint: CGPoint) -> UUID? {
        for workspace in workspaces {
            guard let frame = workspaceFrameCache.frames[workspace.id] else { continue }
            if frame.insetBy(dx: -4, dy: -2).contains(globalPoint) {
                return workspace.id
            }
        }
        return nil
    }

    private func workspaceDropTarget(at globalPoint: CGPoint) -> UUID? {
        guard let workspaceID = workspaceContainingPoint(at: globalPoint),
              workspaceID != activeWorkspaceID else { return nil }
        return workspaceID
    }

    private func workspaceInsertionSlot(for globalY: CGFloat) -> Int {
        let orderedMids = workspaces.compactMap { workspaceFrameCache.frames[$0.id]?.midY }
        var slot = 0
        for midY in orderedMids where globalY > midY {
            slot += 1
        }
        return min(slot, workspaces.count)
    }
}

// MARK: - New workspace row button (hover highlight)

private struct NewWorkspaceRowButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(GhosttyUIFonts.font(size: 16, weight: .medium, fallbackDesign: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TokyoNight.inactiveWorkspaceForegroundColor)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? TokyoNight.inactiveWorkspaceBackgroundColor.opacity(0.55) : Color.clear)
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - WorkspaceRowView

struct WorkspaceRowView: View {
    let workspace: Workspace
    let isActive: Bool
    let isPaneDropTarget: Bool
    var onSelect: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onSetWorkingDirectory: (() -> Void)?

    @State private var isEditing = false
    @State private var editText = ""
    @State private var isHovering = false
    @FocusState private var isFieldFocused: Bool

    private var editingForeground: Color {
        isActive ? TokyoNight.activeWorkspaceForegroundColor : TokyoNight.inactiveWorkspaceForegroundColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(GhosttyUIFonts.font(size: 16, weight: .medium))
                .foregroundStyle(isActive ? TokyoNight.activeWorkspaceForegroundColor : TokyoNight.inactiveWorkspaceForegroundColor)

            if isEditing {
                TextField("Name", text: $editText, onCommit: {
                    commitRename()
                })
                .textFieldStyle(.plain)
                .font(GhosttyUIFonts.font(size: 16, weight: .medium, fallbackDesign: .monospaced))
                .foregroundStyle(editingForeground)
                .focused($isFieldFocused)
                .onExitCommand {
                    isEditing = false
                }
                .onAppear {
                    isFieldFocused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
            } else {
                Text(workspace.name)
                    .font(GhosttyUIFonts.font(
                        size: 16,
                        weight: .semibold,
                        fallbackDesign: .monospaced
                    ))
                    .lineLimit(1)
                    .foregroundStyle(isActive ? TokyoNight.activeWorkspaceForegroundColor : TokyoNight.inactiveWorkspaceForegroundColor)
            }

            Spacer()

            Text("\(workspace.tabs.count)")
                .font(GhosttyUIFonts.font(size: 13, weight: .bold, fallbackDesign: .rounded))
                .foregroundStyle(isActive ? TokyoNight.activeWorkspaceForegroundColor : TokyoNight.inactiveWorkspaceForegroundColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: WorkspaceCapsuleMetrics.minHeight)
        .background(
            RoundedRectangle(cornerRadius: WorkspaceCapsuleMetrics.cornerRadius, style: .continuous)
                .fill(
                    isPaneDropTarget
                        ? TokyoNight.dropZoneFillColor
                        : (isActive
                        ? TokyoNight.activeWorkspaceBackgroundColor
                        : (isHovering ? TokyoNight.inactiveWorkspaceBackgroundColor : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WorkspaceCapsuleMetrics.cornerRadius, style: .continuous)
                        .stroke(
                            isPaneDropTarget
                                ? TokyoNight.dropZoneStrokeColor
                                : Color.clear,
                            lineWidth: 1
                        )
                )
        )
        .contentShape(Rectangle())
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                editText = workspace.name
                isEditing = true
            }
        )
        .simultaneousGesture(TapGesture().onEnded {
            if !isEditing {
                onSelect?()
            }
        })
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Rename") {
                editText = workspace.name
                isEditing = true
            }
            Button("Set Working Directory...") {
                onSetWorkingDirectory?()
            }
            Divider()
            Button("Delete", role: .destructive) {
                onDelete?()
            }
        }
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename?(trimmed)
        }
        isEditing = false
    }
}

// MARK: - SidebarResizeHandle

struct SidebarResizeHandle: View {
    let currentWidth: CGFloat
    var onWidthChanging: ((CGFloat) -> Void)?
    var onWidthChangeEnded: ((CGFloat) -> Void)?

    @State private var isHovering = false
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering && !isHovering {
                    NSCursor.resizeLeftRight.push()
                    isHovering = true
                } else if !hovering && isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil {
                            dragStartWidth = currentWidth
                        }
                        let base = dragStartWidth ?? currentWidth
                        let delta = value.location.x - value.startLocation.x
                        let newWidth = base + delta
                        onWidthChanging?(newWidth)
                    }
                    .onEnded { value in
                        let base = dragStartWidth ?? currentWidth
                        let delta = value.location.x - value.startLocation.x
                        let newWidth = base + delta
                        onWidthChangeEnded?(newWidth)
                        dragStartWidth = nil
                    }
            )
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}
