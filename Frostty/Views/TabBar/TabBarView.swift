// TabBarView.swift
// Frostty
//
// Capsule shaped tabs, reorder, rename, close, scroll

import AppKit
import SwiftUI

// MARK: - Tab frame preference

private struct TabFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private func insertionSlotForHorizontalDrag(
    tabID: UUID,
    fromIndex: Int,
    translation: CGFloat,
    tabs: [Tab],
    frames: [UUID: CGRect]
) -> Int? {
    guard let draggedFrame = frames[tabID] else { return nil }
    if translation < 0 {
        let draggedMinX = draggedFrame.minX + translation
        var destinationSlot: Int?

        if fromIndex > 0 {
            for candidate in stride(from: fromIndex - 1, through: 0, by: -1) {
                guard let candidateFrame = frames[tabs[candidate].id] else { continue }
                if draggedMinX <= candidateFrame.minX {
                    destinationSlot = candidate
                }
            }
        }

        return destinationSlot
    }

    if translation > 0 {
        let draggedMaxX = draggedFrame.maxX + translation
        var destinationSlot: Int?

        if fromIndex + 2 <= tabs.count {
            for candidate in (fromIndex + 2)...tabs.count {
                guard let candidateFrame = frames[tabs[candidate - 1].id] else { continue }
                if draggedMaxX >= candidateFrame.maxX {
                    destinationSlot = candidate
                }
            }
        }

        return destinationSlot
    }

    return nil
}

private func destinationIndexForReorder(fromIndex: Int, insertionSlot: Int, tabCount: Int) -> Int? {
    let slot = min(max(insertionSlot, 0), tabCount)
    if slot <= fromIndex {
        if slot == fromIndex { return nil }
        return slot
    } else {
        if slot == fromIndex + 1 { return nil }
        return slot - 1
    }
}

// MARK: - TabBarView

struct TabBarView: View {
    private static let paneDropGhostCapsuleWidth: CGFloat = 60

    let tabs: [Tab]
    let activeTabID: UUID?
    let paneDropGlobalX: CGFloat?
    let paneDropInsertionSlot: Int?

    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onMoveTab: ((Int, Int) -> Void)?
    var onRenameTab: ((UUID, String) -> Void)?
    var onPaneDropInsertionSlotChanged: ((Int?) -> Void)?

    @State private var draggedTabID: UUID?
    @State private var draggedTabIndex: Int?
    @State private var dragOffset: CGFloat = 0
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var insertionSlot: Int?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                if let slot = insertionSlot, draggedTabID != nil, slot == index {
                                    reorderInsertionLine
                                }
                                if let slot = paneDropInsertionSlot,
                                   draggedTabID == nil,
                                   slot == index {
                                    paneDropGhostCapsule(slot: slot)
                                }

                                TabItemView(
                                    tab: tab,
                                    displayIndex: index + 1,
                                    isActive: tab.id == activeTabID,
                                    onSelect: { onSelectTab?(tab.id) },
                                    onClose: { onCloseTab?(tab.id) },
                                    onRename: { onRenameTab?(tab.id, $0) }
                                )
                                .id(tab.id)
                                .background(tabFrameReporter(tabID: tab.id))
                                .offset(x: draggedTabID == tab.id ? dragOffset : 0)
                                .zIndex(draggedTabID == tab.id ? 2 : 0)
                                .scaleEffect(draggedTabID == tab.id ? 1.04 : 1.0)
                                .animation(.easeOut(duration: 0.12), value: dragOffset)
                                .highPriorityGesture(tabDragGesture(index: index, tab: tab))
                            }

                            if let slot = insertionSlot, draggedTabID != nil, slot == tabs.count {
                                reorderInsertionLine
                            }
                            if let slot = paneDropInsertionSlot,
                               draggedTabID == nil,
                               slot == tabs.count {
                                paneDropGhostCapsule(slot: slot)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                        Task { @MainActor in
                            tabFrames = frames
                            updatePaneDropInsertionSlot()
                        }
                    }
                }
                .onAppear {
                    scrollToActiveTab(proxy: proxy, animated: false)
                }
                .onChange(of: activeTabID) { _, _ in
                    scrollToActiveTab(proxy: proxy, animated: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 34)
        .background(TokyoNight.barBackgroundColor)
        .onAppear(perform: updatePaneDropInsertionSlot)
        .onChange(of: paneDropGlobalX) { _, _ in
            updatePaneDropInsertionSlot()
        }
        .onChange(of: tabs.map(\.id)) { _, _ in
            updatePaneDropInsertionSlot()
        }
    }

    private var reorderInsertionLine: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(TokyoNight.activeTabBackgroundColor)
            .frame(width: 3, height: 22)
    }

    private func tabFrameReporter(tabID: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TabFramePreferenceKey.self,
                value: [tabID: geo.frame(in: .global)]
            )
        }
    }

    private func paneDropGhostCapsule(slot: Int) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(TokyoNight.dropZoneFillColor)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(TokyoNight.dropZoneStrokeColor, lineWidth: 1)
            }
            .frame(width: Self.paneDropGhostCapsuleWidth, height: 28)
    }

    private func tabDragGesture(index: Int, tab: Tab) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard tabs.count > 1, onMoveTab != nil else { return }
                if draggedTabID == nil {
                    draggedTabID = tab.id
                    draggedTabIndex = index
                }
                guard draggedTabID == tab.id else { return }
                dragOffset = value.translation.width
                insertionSlot = insertionSlotForHorizontalDrag(
                    tabID: tab.id,
                    fromIndex: index,
                    translation: value.translation.width,
                    tabs: tabs,
                    frames: tabFrames
                )
            }
            .onEnded { _ in
                if let fromIndex = draggedTabIndex,
                   draggedTabID == tab.id,
                   tabs.count > 1,
                   let slot = insertionSlot,
                   let toIndex = destinationIndexForReorder(fromIndex: fromIndex, insertionSlot: slot, tabCount: tabs.count) {
                    if fromIndex != toIndex {
                        onMoveTab?(fromIndex, toIndex)
                    }
                }
                withAnimation(.easeOut(duration: 0.18)) {
                    draggedTabID = nil
                    draggedTabIndex = nil
                    dragOffset = 0
                    insertionSlot = nil
                }
            }
    }

    private func scrollToActiveTab(proxy: ScrollViewProxy, animated: Bool) {
        guard let activeTabID else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(activeTabID, anchor: .center)
                }
            } else {
                proxy.scrollTo(activeTabID, anchor: .center)
            }
        }
    }

    private func updatePaneDropInsertionSlot() {
        let slot = paneDropGlobalX.flatMap { insertionSlotForPaneDrop(globalX: $0) }
        onPaneDropInsertionSlotChanged?(slot)
    }

    private func insertionSlotForPaneDrop(globalX: CGFloat) -> Int? {
        guard !tabs.isEmpty else { return 0 }

        for (index, tab) in tabs.enumerated() {
            guard let frame = tabFrames[tab.id] else { continue }
            if globalX < frame.midX {
                return index
            }
        }

        return tabs.count
    }
}

// MARK: - TabItemView

struct TabItemView: View {
    let tab: Tab
    /// 1-based index shown on inactive tabs only.
    let displayIndex: Int
    let isActive: Bool
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var editingWidth: CGFloat?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                TextField("Title", text: $editText, onCommit: { commitRename() })
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .frame(width: editingWidth, alignment: .leading)
                    .foregroundStyle(
                        isActive ? TokyoNight.activeTabForegroundColor : TokyoNight.inactiveTabForegroundColor
                    )
                    .focused($isFieldFocused)
                    .onExitCommand { cancelRename() }
            } else {
                Text(displayedTitle)
                    .font(.system(size: 16, weight: isActive ? .bold : .medium, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(
                        isActive ? TokyoNight.activeTabForegroundColor : TokyoNight.inactiveTabForegroundColor
                    )

                if isActive {
                    Button(action: { onClose?() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TokyoNight.activeTabForegroundColor.opacity(0.65))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(capsuleFill)
        )
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule(style: .continuous))
        .highPriorityGesture(
            TapGesture(count: 2).onEnded {
                beginRename()
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
        .onReceive(NotificationCenter.default.publisher(for: .frosttyRenameTab)) { notification in
            guard let tabID = notification.userInfo?["tabID"] as? UUID, tabID == tab.id else { return }
            beginRename()
        }
        .onChange(of: tab.title) { _, newValue in
            if !isEditing {
                editText = newValue
            }
        }
        .onChange(of: isEditing) { _, editing in
            guard editing else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .frosttyWillBeginEditing, object: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                isFieldFocused = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                guard isEditing else { return }
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var capsuleFill: Color {
        if isActive {
            return TokyoNight.activeTabBackgroundColor
        }
        if isHovering {
            return TokyoNight.inactiveTabBackgroundColor.opacity(0.92)
        }
        return TokyoNight.inactiveTabBackgroundColor
    }

    private var displayedTitle: String {
        let raw = tab.tabBarLabel
        let maxLen = isActive ? 40 : 15
        guard raw.count > maxLen else {
            return isActive ? " \(raw)" : "\(displayIndex) \(raw)"
        }
        let idx = raw.index(raw.startIndex, offsetBy: maxLen)
        let truncated = String(raw[..<idx]) + "…"
        return isActive ? " \(truncated)" : "\(displayIndex) \(truncated)"
    }

    private func beginRename() {
        editText = tab.tabBarLabel
        editingWidth = renameFieldWidth(for: editText)
        isEditing = true
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename?(trimmed)
        }
        isEditing = false
        editingWidth = nil
    }

    private func cancelRename() {
        isEditing = false
        editingWidth = nil
    }

    private func renameFieldWidth(for text: String) -> CGFloat {
        let displayText = text.isEmpty ? tab.tabBarLabel : text
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        let measuredWidth = ceil((displayText as NSString).size(withAttributes: [.font: font]).width)
        let minWidth: CGFloat = isActive ? 120 : 96
        let maxWidth: CGFloat = isActive ? 360 : 220
        return min(max(measuredWidth + 12, minWidth), maxWidth)
    }
}
