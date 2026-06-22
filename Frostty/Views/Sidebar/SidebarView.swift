// SidebarView.swift
// Frostty
//
// Workspace list, frame-based reorder, new workspace sheet, WD editor.

import AppKit
import SwiftUI

private enum WorkspaceCapsuleMetrics {
    static let cornerRadius: CGFloat = 8
    static let minHeight: CGFloat = 34
    /// Matches Cmd+1…9 workspace shortcuts in `FrosttyWindowController`.
    static let keyboardShortcutCount = 9
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

private struct NewWorkspaceSheetRequest: Identifiable {
    let id = UUID()
    let defaultName: String
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
                    .buttonStyle(.frosttySheetCancel)
                Button("Save") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.frosttySheetAccent)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .background(FrosttyChromeAppearance.opaqueChromeBackground)
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
    let titlebarInset: CGFloat

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

    @State private var newWorkspaceSheetRequest: NewWorkspaceSheetRequest?
    @State private var workingDirectoryEditor: WorkingDirectoryEditorPayload?
    @State private var paneDropWorkspaceID: UUID?
    @State private var paneDropInsertionSlot: Int?
    @State private var chromeAppearanceTick: UInt = 0

    var body: some View {
        let _ = chromeAppearanceTick
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
                            workspaceIndex: index,
                            isActive: workspace.id == activeWorkspaceID,
                            isPaneDropTarget: paneDropWorkspaceID == workspace.id,
                            dragEnabled: workspaces.count > 1 && onMoveWorkspace != nil,
                            onSelect: { onSelectWorkspace?(workspace.id) },
                            onRename: { newName in onRenameWorkspace?(workspace.id, newName) },
                            onDelete: { onDeleteWorkspace?(workspace.id) },
                            onSetWorkingDirectory: {
                                workingDirectoryEditor = WorkingDirectoryEditorPayload(
                                    workspaceID: workspace.id,
                                    draftPath: workspace.workingDirectory ?? ""
                                )
                            },
                            onDragChanged: { translation in
                                if draggedWorkspaceID == nil {
                                    draggedWorkspaceID = workspace.id
                                    draggedFromIndex = index
                                }
                                guard draggedWorkspaceID == workspace.id else { return }
                                dragOffsetY = translation
                                let baseMidY = workspaceFrameCache.frames[workspace.id]?.midY ?? 0
                                insertionSlot = insertionSlotForVerticalDrag(
                                    dragMidY: baseMidY + translation,
                                    workspaces: workspaces,
                                    frames: workspaceFrameCache.frames
                                )
                            },
                            onDragEnded: {
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
                        )
                        .background(workspaceFrameReporter(workspaceID: workspace.id))
                        .offset(y: draggedWorkspaceID == workspace.id ? dragOffsetY : 0)
                        .zIndex(draggedWorkspaceID == workspace.id ? 2 : 0)
                        .scaleEffect(draggedWorkspaceID == workspace.id ? 1.02 : 1.0)
                        .animation(.easeOut(duration: 0.12), value: dragOffsetY)
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
                .padding(.top, titlebarInset + 8)
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
        .overlay(alignment: .top) {
            if titlebarInset > 0 {
                WindowDragRegionRepresentable()
                    .frame(height: titlebarInset)
                    .frame(maxWidth: .infinity)
            }
        }
        .frosttyChromePanelBackground(style: FrosttyChromeAppearance.sidebarPanelStyle)
        .font(GhosttyUIFonts.font(textStyle: .body))
        .background {
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
                .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigChange)) { _ in
            chromeAppearanceTick &+= 1
        }
        .overlay(alignment: .trailing) {
            SidebarResizeHandle(
                currentWidth: currentWidth,
                onWidthChanging: onSidebarWidthChanging,
                onWidthChangeEnded: onSidebarWidthChangeEnded
            )
        }
        .sheet(item: $newWorkspaceSheetRequest) { request in
            NewWorkspaceSheet(
                isPresented: Binding(
                    get: { newWorkspaceSheetRequest != nil },
                    set: { if !$0 { newWorkspaceSheetRequest = nil } }
                ),
                defaultName: request.defaultName,
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
        .onReceive(NotificationCenter.default.publisher(for: .frosttyShowNewWorkspaceSheet)) { notification in
            let defaultName = (notification.userInfo?["defaultName"] as? String)
                ?? defaultNameForNewWorkspace()
            newWorkspaceSheetRequest = NewWorkspaceSheetRequest(defaultName: defaultName)
        }
    }

    private func defaultNameForNewWorkspace() -> String {
        "Workspace \(workspaces.count + 1)"
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
                newWorkspaceSheetRequest = NewWorkspaceSheetRequest(
                    defaultName: defaultNameForNewWorkspace()
                )
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
            FrosttyChromeCapsuleBackground(
                cornerRadius: 8,
                material: FrosttyChromeAppearance.newWorkspaceButtonMaterial(isHovering: hovering)
            )
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - WorkspaceRowView

struct WorkspaceRowView: View {
    let workspace: Workspace
    let workspaceIndex: Int
    let isActive: Bool
    let isPaneDropTarget: Bool
    var dragEnabled: Bool = false
    var onSelect: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onSetWorkingDirectory: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var isEditing = false
    @State private var editText = ""
    @State private var isHovering = false
    @State private var shouldSelectRenameText = false

    private var editingForeground: Color {
        isActive ? TokyoNight.activeWorkspaceForegroundColor : TokyoNight.inactiveWorkspaceForegroundColor
    }

    var body: some View {
        ZStack {
            rowChrome
                .allowsHitTesting(isEditing)

            if !isEditing {
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        TapGesture(count: 2).onEnded {
                            beginRename()
                        }
                    )
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            onSelect?()
                        }
                    )
                    .gesture(rowDragGesture)
            }
        }
        .frame(maxWidth: .infinity, minHeight: WorkspaceCapsuleMetrics.minHeight, alignment: .leading)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button("Rename") {
                beginRename()
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

    private var rowDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard dragEnabled else { return }
                onDragChanged?(value.translation.height)
            }
            .onEnded { _ in
                guard dragEnabled else { return }
                onDragEnded?()
            }
    }

    private var rowChrome: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(GhosttyUIFonts.font(size: 16, weight: .medium))
                .foregroundStyle(isActive ? TokyoNight.activeWorkspaceForegroundColor : TokyoNight.inactiveWorkspaceForegroundColor)

            if isEditing {
                WorkspaceRenameField(
                    text: $editText,
                    font: GhosttyUIFonts.nsFont(size: 16, weight: .medium, fallbackDesign: .monospaced),
                    textColor: isActive ? TokyoNight.activeWorkspaceForeground : TokyoNight.inactiveWorkspaceForeground,
                    selectAllOnActivate: $shouldSelectRenameText,
                    onCommit: { commitRename() },
                    onCancel: { endRename() }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(workspace.name)
                    .font(GhosttyUIFonts.font(
                        size: 16,
                        weight: .semibold,
                        fallbackDesign: .monospaced
                    ))
                    .lineLimit(1)
                    .textSelection(.disabled)
                    .foregroundStyle(isActive ? TokyoNight.activeWorkspaceForegroundColor : TokyoNight.inactiveWorkspaceForegroundColor)
            }

            Spacer()

            if workspaceIndex < WorkspaceCapsuleMetrics.keyboardShortcutCount {
                WorkspaceKeyboardShortcutLabel(
                    number: workspaceIndex + 1,
                    isActive: isActive
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: WorkspaceCapsuleMetrics.minHeight, alignment: .leading)
        .background {
            FrosttyChromeCapsuleBackground(
                cornerRadius: WorkspaceCapsuleMetrics.cornerRadius,
                material: FrosttyChromeAppearance.workspaceCapsuleMaterial(
                    isActive: isActive,
                    isHovering: isHovering,
                    isPaneDropTarget: isPaneDropTarget
                ),
                usesSolidFill: FrosttyChromeAppearance.workspaceCapsuleUsesSolidFill(
                    isActive: isActive,
                    isPaneDropTarget: isPaneDropTarget
                )
            )
        }
        .overlay {
            if isPaneDropTarget {
                RoundedRectangle(cornerRadius: WorkspaceCapsuleMetrics.cornerRadius, style: .continuous)
                    .stroke(TokyoNight.dropZoneStrokeColor, lineWidth: 1)
            }
        }
    }

    private func beginRename() {
        editText = workspace.name
        shouldSelectRenameText = true
        isEditing = true
        NotificationCenter.default.post(name: .frosttyWillBeginEditing, object: nil)
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename?(trimmed)
        }
        endRename()
    }

    private func endRename() {
        guard isEditing else { return }
        isEditing = false
        shouldSelectRenameText = false
        NotificationCenter.default.post(name: .frosttyDidEndEditing, object: nil)
    }
}

// MARK: - Workspace shortcut label

private struct WorkspaceKeyboardShortcutLabel: View {
    let number: Int
    let isActive: Bool

    private var foreground: Color {
        isActive ? TokyoNight.activeWorkspaceForegroundColor : TokyoNight.inactiveWorkspaceForegroundColor
    }

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "command")
                .font(GhosttyUIFonts.font(size: 12, weight: .semibold))
            Text("\(number)")
                .font(GhosttyUIFonts.font(size: 12, weight: .semibold, fallbackDesign: .rounded))
        }
        .foregroundStyle(foreground.opacity(isActive ? 0.9 : 0.75))
        .accessibilityLabel("Switch to workspace \(number), Command \(number)")
    }
}

// MARK: - Workspace rename field

private struct WorkspaceRenameField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    @Binding var selectAllOnActivate: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.backgroundColor = .clear
        field.font = font
        field.textColor = textColor
        field.delegate = context.coordinator
        context.coordinator.textField = field
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textField = nsView
        nsView.font = font
        nsView.textColor = textColor

        if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if selectAllOnActivate {
            context.coordinator.activate(selectAll: true)
            DispatchQueue.main.async {
                selectAllOnActivate = false
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: WorkspaceRenameField
        weak var textField: NSTextField?

        init(parent: WorkspaceRenameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, field === textField else { return }
            parent.text = field.stringValue
            parent.onCancel()
        }

        func activate(selectAll: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let field = self.textField, let window = field.window else { return }
                window.makeFirstResponder(field)
                if selectAll, let editor = field.currentEditor() {
                    editor.selectAll(nil)
                }
            }
        }
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
