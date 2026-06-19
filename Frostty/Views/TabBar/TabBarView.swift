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

private final class TabFrameCache {
    var frames: [UUID: CGRect] = [:]
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

private enum TabBarChromeMetrics {
    static let cornerRadius: CGFloat = 11
    static let chromeHeight: CGFloat = 26
    static let barHeight: CGFloat = 32
}

// MARK: - TabBarView

struct TabBarView: View {
    private static let paneDropGhostCapsuleWidth: CGFloat = 52

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
    @State private var tabFrameCache = TabFrameCache()
    @State private var insertionSlot: Int?
    @State private var editingTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .leading) {
                        HStack(spacing: 10) {
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
                                    onRename: { onRenameTab?(tab.id, $0) },
                                    onEditingChanged: { isEditing in
                                        if isEditing {
                                            editingTabID = tab.id
                                        } else if editingTabID == tab.id {
                                            editingTabID = nil
                                        }
                                    }
                                )
                                .id(tab.id)
                                .background {
                                    if shouldTrackTabFrames {
                                        tabFrameReporter(tabID: tab.id)
                                    }
                                }
                                .offset(x: draggedTabID == tab.id ? dragOffset : 0)
                                .zIndex(draggedTabID == tab.id ? 2 : 0)
                                .scaleEffect(draggedTabID == tab.id ? 1.02 : 1.0)
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
                            guard shouldTrackTabFrames else { return }
                            tabFrameCache.frames = frames
                            guard paneDropGlobalX != nil else { return }
                            updatePaneDropInsertionSlot()
                        }
                    }
                }
                .defaultScrollAnchor(.leading)
                .scrollDisabled(editingTabID != nil)
                .onAppear {
                    scrollToActiveTab(proxy: proxy, animated: false)
                }
                .onChange(of: activeTabID) { _, _ in
                    scrollToActiveTab(proxy: proxy, animated: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: TabBarChromeMetrics.barHeight)
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
            .frame(width: 2, height: 20)
    }

    private var shouldTrackTabFrames: Bool {
        editingTabID == nil
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
        RoundedRectangle(cornerRadius: TabBarChromeMetrics.cornerRadius, style: .continuous)
            .fill(TokyoNight.dropZoneFillColor)
            .overlay {
                RoundedRectangle(cornerRadius: TabBarChromeMetrics.cornerRadius, style: .continuous)
                    .stroke(TokyoNight.dropZoneStrokeColor, lineWidth: 1)
            }
            .frame(width: Self.paneDropGhostCapsuleWidth, height: TabBarChromeMetrics.chromeHeight)
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
                    frames: tabFrameCache.frames
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
            guard let frame = tabFrameCache.frames[tab.id] else { continue }
            if globalX < frame.midX {
                return index
            }
        }

        return tabs.count
    }
}

// MARK: - TabItemView

struct TabItemView: View {
    private static let activeDotSize: CGFloat = 5
    private static let indicatorWidth: CGFloat = 10
    private static let textFontSize: CGFloat = 17

    let tab: Tab
    /// 1-based index shown on inactive tabs only.
    let displayIndex: Int
    let isActive: Bool
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(spacing: 7) {
            indicatorView

            if isEditing {
                TabRenameInlineEditorRepresentable(
                    text: $editText,
                    font: tabNSFont,
                    textColor: tabNSTextColor,
                    allowsScrolling: renameFieldWidth(for: editText) >= renameFieldMaxWidth,
                    onCommit: { commitRename() },
                    onCancel: { cancelRename() }
                )
                    .frame(width: renameFieldWidth(for: editText), alignment: .leading)
                    .overlay(alignment: .leading) {
                        if editText.isEmpty {
                            Text("Title")
                                .font(tabTextFont)
                                .foregroundStyle(tabPlaceholderForeground)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                Text(displayedTitle)
                    .font(tabTextFont)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .frame(width: isEditing ? renameChipWidth(for: editText) : nil, height: TabBarChromeMetrics.chromeHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TabBarChromeMetrics.cornerRadius, style: .continuous)
                .fill(tabFill)
        )
        .foregroundStyle(tabForeground)
        .fixedSize(horizontal: !isEditing, vertical: false)
        .padding(.trailing, 2)
        .contentShape(RoundedRectangle(cornerRadius: TabBarChromeMetrics.cornerRadius, style: .continuous))
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
    }

    private var tabFill: Color {
        if isActive {
            return TokyoNight.activeTabBackgroundColor
        }
        if isHovering {
            return TokyoNight.inactiveTabBackgroundColor.opacity(0.96)
        }
        return TokyoNight.inactiveTabBackgroundColor
    }

    private var tabForeground: Color {
        TokyoNight.activeTabForegroundColor
    }

    private var tabTextFont: Font {
        GhosttyUIFonts.font(size: Self.textFontSize, weight: .medium, fallbackDesign: .monospaced)
    }

    private var tabNSFont: NSFont {
        GhosttyUIFonts.nsFont(size: Self.textFontSize, weight: .medium, fallbackDesign: .monospaced)
    }

    private var tabNSTextColor: NSColor {
        TokyoNight.activeTabForeground
    }

    private var tabPlaceholderForeground: Color {
        tabForeground.opacity(isActive ? 0.56 : 0.62)
    }

    @ViewBuilder
    private var indicatorView: some View {
        if isActive {
            Circle()
                .fill(tabForeground)
                .frame(width: Self.activeDotSize, height: Self.activeDotSize)
                .frame(width: Self.indicatorWidth, alignment: .leading)
        } else {
            Text("\(displayIndex)")
                .font(tabTextFont)
                .lineLimit(1)
                .frame(width: Self.indicatorWidth, alignment: .leading)
        }
    }

    private var displayedTitle: String {
        let raw = tab.tabBarLabel
        let maxLen = isActive ? 40 : 15
        guard raw.count > maxLen else { return raw }
        let idx = raw.index(raw.startIndex, offsetBy: maxLen)
        return String(raw[..<idx]) + "…"
    }

    private func beginRename() {
        editText = tab.tabBarLabel
        isEditing = true
        onEditingChanged?(true)
        NotificationCenter.default.post(name: .frosttyWillBeginEditing, object: nil)
    }

    private func commitRename() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onRename?(trimmed)
        }
        isEditing = false
        onEditingChanged?(false)
        NotificationCenter.default.post(name: .frosttyDidEndEditing, object: nil)
    }

    private func cancelRename() {
        isEditing = false
        onEditingChanged?(false)
        NotificationCenter.default.post(name: .frosttyDidEndEditing, object: nil)
    }

    private var renameFieldMinWidth: CGFloat {
        isActive ? 96 : 64
    }

    private var renameFieldMaxWidth: CGFloat {
        isActive ? 320 : 170
    }

    private func renameFieldWidth(for text: String) -> CGFloat {
        let measuredWidth: CGFloat
        if text.isEmpty {
            measuredWidth = renameMeasuredCellWidth(for: "Title")
        } else {
            let template = String(repeating: renameWidthSampleCharacter, count: text.count)
            measuredWidth = renameMeasuredCellWidth(for: template)
        }
        return min(max(measuredWidth + 2, renameFieldMinWidth), renameFieldMaxWidth)
    }

    private func renameChipWidth(for text: String) -> CGFloat {
        renameFieldWidth(for: text) + 8 + 9 + Self.indicatorWidth + 7
    }

    private var renameWidthSampleCharacter: Character {
        let candidates: [Character] = ["W", "M", "0", "a"]
        return candidates.max { lhs, rhs in
            renameMeasuredCellWidth(for: String(lhs)) < renameMeasuredCellWidth(for: String(rhs))
        } ?? "W"
    }

    private func renameMeasuredCellWidth(for displayText: String) -> CGFloat {
        let cell = NSTextFieldCell(textCell: displayText)
        cell.font = tabNSFont
        cell.lineBreakMode = .byClipping
        cell.wraps = false
        cell.isScrollable = true
        return ceil(
            cell.cellSize(
                forBounds: NSRect(
                    x: 0,
                    y: 0,
                    width: renameFieldMaxWidth,
                    height: TabBarChromeMetrics.chromeHeight
                )
            ).width
        )
    }
}

private struct TabRenameInlineEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let textColor: NSColor
    let allowsScrolling: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TabRenameInlineEditorView {
        let view = TabRenameInlineEditorView()
        view.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.textDidChange(newText)
        }
        view.onCommit = { [weak coordinator = context.coordinator] in
            coordinator?.handleCommit()
        }
        view.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.handleCancel()
        }
        view.apply(font: font, textColor: textColor)
        view.setAllowsScrolling(allowsScrolling)
        view.setText(text)
        view.activate(selectAll: true)
        return view
    }

    func updateNSView(_ nsView: TabRenameInlineEditorView, context: Context) {
        context.coordinator.parent = self
        nsView.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.textDidChange(newText)
        }
        nsView.onCommit = { [weak coordinator = context.coordinator] in
            coordinator?.handleCommit()
        }
        nsView.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.handleCancel()
        }
        nsView.apply(font: font, textColor: textColor)
        nsView.setAllowsScrolling(allowsScrolling)
        nsView.setText(text)
        nsView.activate(selectAll: context.coordinator.shouldSelectAllOnActivate)
        context.coordinator.shouldSelectAllOnActivate = false
    }

    @MainActor
    final class Coordinator {
        var parent: TabRenameInlineEditorRepresentable
        var shouldSelectAllOnActivate = true

        init(parent: TabRenameInlineEditorRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ newText: String) {
            guard parent.text != newText else { return }
            parent.text = newText
        }

        func handleCommit() {
            parent.onCommit()
        }

        func handleCancel() {
            parent.onCancel()
        }
    }
}

@MainActor
private final class TabRenameInlineEditorView: NSView, NSTextViewDelegate {
    var onTextChange: ((String) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private let scrollView = NSScrollView()
    private let textView: TabRenameTextView
    private var isApplyingText = false
    private var hasActivated = false
    private var allowsScrolling = false

    override init(frame frameRect: NSRect) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer(size: NSSize(width: .greatestFiniteMagnitude, height: TabBarChromeMetrics.chromeHeight))
        textContainer.widthTracksTextView = false
        textContainer.lineBreakMode = .byClipping
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        textView = TabRenameTextView(frame: .zero, textContainer: textContainer)
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        relayoutTextView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activate(selectAll: !hasActivated)
    }

    func apply(font: NSFont, textColor: NSColor) {
        let fontChanged = textView.font != font
        let colorChanged = !(textView.textColor?.isEqual(textColor) ?? false)
        guard fontChanged || colorChanged else { return }

        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        updateTextContainerInset(for: font)
        relayoutTextView()
    }

    func setText(_ text: String) {
        guard textView.string != text else { return }
        isApplyingText = true
        textView.string = text
        let location = min(textView.selectedRange().location, text.count)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        isApplyingText = false
        relayoutTextView()
    }

    func setAllowsScrolling(_ allowsScrolling: Bool) {
        guard self.allowsScrolling != allowsScrolling else { return }
        self.allowsScrolling = allowsScrolling
        textView.allowsScrolling = allowsScrolling
        textView.isHorizontallyResizable = allowsScrolling
        relayoutTextView()
    }

    func activate(selectAll: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let needsResponder = window.firstResponder !== self.textView
            let needsActivation = needsResponder || selectAll || !self.hasActivated
            guard needsActivation else { return }

            if needsResponder {
                window.makeFirstResponder(self.textView)
            }
            if selectAll {
                self.textView.selectAll(nil)
            }
            self.hasActivated = true
            if needsResponder || selectAll {
                self.relayoutTextView()
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        relayoutTextView()
        guard !isApplyingText else { return }
        onTextChange?(textView.string)
    }

    private func setup() {
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textView.delegate = self
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.isFieldEditor = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.maxSize = NSSize(width: .greatestFiniteMagnitude, height: TabBarChromeMetrics.chromeHeight)
        textView.minSize = NSSize(width: 0, height: TabBarChromeMetrics.chromeHeight)
        textView.onCommit = { [weak self] in
            self?.onCommit?()
        }
        textView.onCancel = { [weak self] in
            self?.onCancel?()
        }

        scrollView.documentView = textView
    }

    private func relayoutTextView() {
        guard let textContainer = textView.textContainer, let layoutManager = textView.layoutManager else { return }

        let viewportWidth = max(bounds.width, scrollView.contentSize.width, 1)
        let viewportHeight = max(bounds.height, TabBarChromeMetrics.chromeHeight)
        let targetWidth: CGFloat

        // Keep the document locked to the visible field while the chip is still growing.
        // Once the chip is capped, let the document extend and scroll under the caret.
        if allowsScrolling {
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: .greatestFiniteMagnitude, height: viewportHeight)
            layoutManager.ensureLayout(for: textContainer)

            let usedRect = layoutManager.usedRect(for: textContainer)
            let contentWidth = ceil(usedRect.width + (textView.textContainerInset.width * 2))
            targetWidth = max(viewportWidth, contentWidth + 2)
        } else {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: viewportWidth, height: viewportHeight)
            layoutManager.ensureLayout(for: textContainer)
            targetWidth = viewportWidth
        }

        textView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: viewportHeight)
        textView.minSize = NSSize(width: targetWidth, height: viewportHeight)
        textView.maxSize = NSSize(
            width: allowsScrolling ? .greatestFiniteMagnitude : targetWidth,
            height: viewportHeight
        )
        if allowsScrolling {
            textView.scrollRangeToVisible(textView.selectedRange())
        } else {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func updateTextContainerInset(for font: NSFont) {
        let lineHeight = font.ascender - font.descender + font.leading
        let insetY = max(0, floor((TabBarChromeMetrics.chromeHeight - lineHeight) / 2))
        textView.textContainerInset = NSSize(width: 0, height: insetY)
    }
}

private final class TabRenameTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var allowsScrolling = false

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)),
             #selector(insertLineBreak(_:)),
             #selector(insertParagraphSeparator(_:)):
            onCommit?()
        case #selector(cancelOperation(_:)):
            onCancel?()
        default:
            super.doCommand(by: selector)
        }
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onCancel?()
        }
        return result
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard allowsScrolling else { return }
        super.scrollRangeToVisible(range)
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        guard allowsScrolling else { return false }
        return super.scrollToVisible(rect)
    }
}
