// SurfaceScrollView.swift
// Frostty
//
// Wraps a SurfaceView inside an NSScrollView to provide a native scrollbar
// for terminal scrollback. The SurfaceView is placed on top of (not inside)
// the scroll view, which uses an empty document view sized to represent the
// total scrollback height.

@preconcurrency import AppKit
import SwiftUI

/// Flipped document view so scroll coordinates match top-to-bottom orientation.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// NSScrollView subclass that only intercepts hits on its scroller.
/// All other hits pass through to the surfaceView underneath.
private class OverlayScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let scroller = verticalScroller, !scroller.isHidden {
            let scrollerPoint = scroller.convert(point, from: superview)
            if scroller.bounds.contains(scrollerPoint) {
                return super.hitTest(point)
            }
        }
        return nil
    }
}

enum PaneDropZone: Equatable {
    case top
    case bottom
    case left
    case right

    static func calculate(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        let relX = point.x / max(size.width, 1)
        let relY = point.y / max(size.height, 1)

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }
}

extension NSPasteboard.PasteboardType {
    static let frosttyPaneID = NSPasteboard.PasteboardType("com.frostty.pane-id")
}

@MainActor
class SurfaceScrollView: NSView {

    static let maxDocumentHeight: CGFloat = 1_000_000_000

    // MARK: - Static Helpers (testable)

    /// Validate and clamp scrollbar state values.
    /// Returns nil if total is 0 (nothing to scroll).
    static func validatedScrollbar(total: UInt64, offset: UInt64, len: UInt64) -> (total: Int, offset: Int, len: Int)? {
        guard total > 0 else { return nil }
        let clampedTotal = min(Int(clamping: total), Int.max / 2)
        let clampedLen = min(Int(clamping: len), clampedTotal)
        let maxOffset = max(clampedTotal - clampedLen, 0)
        let clampedOffset = min(Int(clamping: offset), maxOffset)
        return (clampedTotal, clampedOffset, clampedLen)
    }

    /// Calculate document height for the given scrollbar parameters.
    static func documentHeight(total: Int, len: Int, cellHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        let gridHeight = CGFloat(total) * cellHeight
        let padding = contentHeight - CGFloat(len) * cellHeight
        return min(gridHeight + padding, maxDocumentHeight)
    }

    /// Convert a ghostty scroll offset (row index from top) to AppKit Y coordinate.
    static func offsetToScrollY(offset: Int, cellHeight: CGFloat) -> CGFloat {
        CGFloat(offset) * cellHeight
    }

    /// Convert an AppKit scroll Y position to a ghostty row index.
    static func scrollYToRow(scrollY: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 0 }
        guard scrollY >= 0 else { return 0 }
        return Int(scrollY / cellHeight)
    }

    /// Clamp a row value to valid range [0, total-len].
    static func clampRow(_ row: Int, total: Int, len: Int) -> Int {
        let maxRow = max(total - len, 0)
        return max(0, min(row, maxRow))
    }

    // MARK: - Instance Properties

    private let scrollView = OverlayScrollView()
    private let documentContentView = FlippedView() // documentView
    private let paneDropOverlayView = PaneDropOverlayView()
    private let paneHandleHostingView = PaneHandleHostingView(rootView: AnyView(EmptyView()))
    private(set) var surfaceView: SurfaceView

    var paneID: UUID? {
        didSet {
            refreshPaneHandle()
        }
    }

    var dragWidgetsEnabled: Bool = false {
        didSet {
            if !dragWidgetsEnabled {
                paneDropOverlayView.dropZone = nil
            }
            refreshPaneHandle()
            updatePaneDragUI()
        }
    }

    var onPaneDrop: ((UUID, UUID, PaneDropZone) -> Void)?
    var onPaneDetachToNewTab: ((UUID, NSPoint) -> Void)?

    private var cellHeight: CGFloat = 0
    private var isLiveScrolling = false
    private var lastAppliedOffset: Int = -1
    private var lastSentRow: Int = -1
    private var lastKnownTotal: Int = 0
    private var lastKnownLen: Int = 0

    private var pendingScrollRow: Int?
    private var throttleScheduled = false

    private var cellSizeObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?

    private var searchBar: SearchBarView?
    private var startSearchObserver: NSObjectProtocol?
    private var endSearchObserver: NSObjectProtocol?
    private var searchTotalObserver: NSObjectProtocol?
    private var searchSelectedObserver: NSObjectProtocol?

    // MARK: - Cell Height

    private func applyCellHeight(pixelHeight: CGFloat) {
        guard pixelHeight > 0, let window = surfaceView.window else { return }
        cellHeight = pixelHeight / window.backingScaleFactor
        synchronizeLayout()

        // Apply any cached scrollbar state now that cellHeight is available.
        if let scrollbar = surfaceView.surfaceController?.scrollbar {
            handleScrollbarUpdate(scrollbar)
        }
    }

    // MARK: - Init

    init(surfaceView: SurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        setupScrollView()
        setupPaneDragWidgets()
        setupObservers()
        setupSearchObservers()
        surfaceView.scrollbarUpdateHandler = { [weak self] state in
            self?.handleScrollbarUpdate(state)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated {
            pendingScrollRow = nil
            if let obs = cellSizeObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = configChangeObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = startSearchObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = endSearchObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = searchTotalObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = searchSelectedObserver { NotificationCenter.default.removeObserver(obs) }
            NotificationCenter.default.removeObserver(self)
        }
    }

    override var isFlipped: Bool { true }

    // MARK: - Setup

    private func setupScrollView() {
        // Configure overlay-style scrollbar
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .default

        // The documentView is an empty NSView that defines scrollable height
        scrollView.documentView = documentContentView

        // Disable elastic scrolling
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        addSubview(surfaceView)
        addSubview(scrollView)

        // Register for live scroll notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidLiveScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        // Apply scrollbar config
        applyScrollbarConfig()
    }

    private func setupPaneDragWidgets() {
        paneDropOverlayView.isHidden = true
        paneHandleHostingView.translatesAutoresizingMaskIntoConstraints = true
        paneHandleHostingView.autoresizingMask = []
        paneHandleHostingView.wantsLayer = true
        paneHandleHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        paneHandleHostingView.layer?.zPosition = 1_000

        addSubview(paneDropOverlayView)
        addSubview(paneHandleHostingView)
        registerForDraggedTypes([.frosttyPaneID])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePaneDragEndedNoTarget(_:)),
            name: .frosttyPaneDragEndedNoTarget,
            object: nil
        )

        refreshPaneHandle()
    }

    private func setupObservers() {
        // Observe cell size changes for this surface only
        cellSizeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyCellSizeChange,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            let height = notification.userInfo?["height"] as? Double
            MainActor.assumeIsolated {
                guard let self, let height else { return }
                self.applyCellHeight(pixelHeight: CGFloat(height))
            }
        }

        // Observe config changes
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            nonisolated(unsafe) let obj = notification.object
            MainActor.assumeIsolated {
                guard let self else { return }
                // Accept if object is nil (app-level) or matches our surfaceView
                let surfaceObj = obj as? SurfaceView
                if surfaceObj == nil || surfaceObj === self.surfaceView {
                    self.applyScrollbarConfig()
                }
            }
        }
    }

    private func applyScrollbarConfig() {
        let mode = GhosttyAppController.shared.configManager.scrollbarMode
        scrollView.hasVerticalScroller = (mode == .system)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        synchronizeLayout()
        paneDropOverlayView.frame = bounds
        paneHandleHostingView.frame = bounds
        refreshPaneHandle()
        updatePaneDragUI()
    }

    private func updatePaneDragUI() {
        if !dragWidgetsEnabled {
            paneDropOverlayView.dropZone = nil
        }
    }

    private func refreshPaneHandle() {
        guard dragWidgetsEnabled, let paneID else {
            paneHandleHostingView.rootView = AnyView(EmptyView())
            return
        }

        paneHandleHostingView.rootView = AnyView(
            FrosttyPaneGrabHandle(
                surfaceView: surfaceView,
                paneID: paneID,
                onDragStateChanged: { [weak self] dragging in
                    guard let self else { return }
                    if !dragging {
                        self.paneDropOverlayView.dropZone = nil
                    }
                    self.updatePaneDragUI()
                }
            )
        )
    }

    private func synchronizeLayout() {
        let contentSize = bounds.size
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        // Apply initial cell size if missed during surface init.
        if cellHeight <= 0 {
            if surfaceView.cachedCellSize.height > 0 {
                applyCellHeight(pixelHeight: surfaceView.cachedCellSize.height)
                return  // applyCellHeight calls synchronizeLayout again with cellHeight set.
            }
        }

        // ScrollView fills our entire bounds
        scrollView.frame = bounds

        // Surface view matches our content size (viewport)
        surfaceView.frame.size = contentSize

        // Update document height if we have scrollbar data
        if lastKnownTotal > 0, cellHeight > 0 {
            let docHeight = Self.documentHeight(
                total: lastKnownTotal,
                len: lastKnownLen,
                cellHeight: cellHeight,
                contentHeight: contentSize.height
            )
            documentContentView.frame = NSRect(
                x: 0, y: 0,
                width: contentSize.width,
                height: docHeight
            )
        } else {
            // No scrollback: document matches viewport
            documentContentView.frame = NSRect(
                x: 0, y: 0,
                width: contentSize.width,
                height: contentSize.height
            )
        }

        // Surface is a sibling of scrollView (not inside it), so it stays at origin.
        surfaceView.frame.origin = .zero

        layoutSearchBar()
    }

    // MARK: - Scrollbar Update (Core -> UI)

    private func handleScrollbarUpdate(_ state: GhosttySurfaceController.ScrollbarState) {
        guard let validated = Self.validatedScrollbar(
            total: state.total,
            offset: state.offset,
            len: state.len
        ) else { return }

        lastKnownTotal = validated.total
        lastKnownLen = validated.len

        guard cellHeight > 0 else { return }

        let contentSize = bounds.size
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        // Always update document height
        let docHeight = Self.documentHeight(
            total: validated.total,
            len: validated.len,
            cellHeight: cellHeight,
            contentHeight: contentSize.height
        )
        documentContentView.frame.size = NSSize(width: contentSize.width, height: docHeight)

        // Skip position update if user is dragging scrollbar
        guard !isLiveScrolling else { return }

        // Skip if this is the same offset we already applied
        guard validated.offset != lastAppliedOffset else { return }
        lastAppliedOffset = validated.offset

        // Scroll to the offset position
        let scrollY = Self.offsetToScrollY(offset: validated.offset, cellHeight: cellHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.flashScrollers()

        // Surface stays at origin; ghostty re-renders the visible content.
        surfaceView.frame.origin = .zero
    }

    // MARK: - Live Scroll (UI -> Core)

    @objc private func scrollViewDidLiveScroll(_ notification: Notification) {
        isLiveScrolling = true

        // Surface stays at origin; ghostty re-renders the visible content.
        surfaceView.frame.origin = .zero

        guard cellHeight > 0 else { return }

        let scrollY = scrollView.contentView.documentVisibleRect.origin.y
        let row = Self.scrollYToRow(scrollY: scrollY, cellHeight: cellHeight)
        let clampedRow = Self.clampRow(row, total: lastKnownTotal, len: lastKnownLen)

        scheduleLiveScrollUpdate(row: clampedRow)
    }

    @objc private func scrollViewDidEndLiveScroll(_ notification: Notification) {
        // Flush any pending scroll
        flushPendingScroll()

        // Final reconciliation: send the final position to core
        guard cellHeight > 0 else {
            isLiveScrolling = false
            return
        }

        let scrollY = scrollView.contentView.documentVisibleRect.origin.y
        let row = Self.scrollYToRow(scrollY: scrollY, cellHeight: cellHeight)
        let clampedRow = Self.clampRow(row, total: lastKnownTotal, len: lastKnownLen)
        sendScrollToRow(clampedRow)

        isLiveScrolling = false
    }

    // MARK: - Throttling

    private func scheduleLiveScrollUpdate(row: Int) {
        pendingScrollRow = row
        guard !throttleScheduled else { return }
        throttleScheduled = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                self?.flushPendingScroll()
            }
        }
    }

    private func flushPendingScroll() {
        throttleScheduled = false
        guard let row = pendingScrollRow else { return }
        pendingScrollRow = nil
        sendScrollToRow(row)
    }

    private func sendScrollToRow(_ row: Int) {
        // Dedup: don't send same row twice
        guard row != lastSentRow else { return }
        lastSentRow = row

        surfaceView.surfaceController?.performAction("scroll_to_row:\(row)")
    }

    // MARK: - Search Bar Integration

    private func setupSearchObservers() {
        guard startSearchObserver == nil,
              endSearchObserver == nil,
              searchTotalObserver == nil,
              searchSelectedObserver == nil else { return }

        startSearchObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyStartSearch,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            let needle = notification.userInfo?["needle"] as? String ?? ""
            MainActor.assumeIsolated {
                guard let self else { return }
                self.showSearchBar(needle: needle)
            }
        }

        endSearchObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyEndSearch,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideSearchBar()
            }
        }

        searchTotalObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySearchTotal,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            let total = notification.userInfo?["total"] as? Int
            MainActor.assumeIsolated {
                guard let self, let total else { return }
                self.searchBar?.updateTotal(total)
            }
        }

        searchSelectedObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySearchSelected,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            let selected = notification.userInfo?["selected"] as? Int
            MainActor.assumeIsolated {
                guard let self, let selected else { return }
                self.searchBar?.updateSelected(selected)
            }
        }
    }

    private func showSearchBar(needle: String) {
        if searchBar == nil {
            let bar = SearchBarView(frame: .zero)
            bar.sender = surfaceView.surfaceController
            searchBar = bar
            addSubview(bar)
        }

        guard let searchBar else { return }
        searchBar.resetSearchState()

        if !needle.isEmpty {
            searchBar.setSearchText(needle)
            searchBar.lastSubmittedQuery = needle
            surfaceView.surfaceController?.performAction("search:" + needle)
        }

        layoutSearchBar()
        searchBar.focusSearchField()
    }

    private func hideSearchBar() {
        searchBar?.resetSearchState()
        searchBar?.setSearchText("")
        searchBar?.removeFromSuperview()
        searchBar = nil
        window?.makeFirstResponder(surfaceView)
    }

    private func layoutSearchBar() {
        guard let searchBar else { return }
        let barHeight: CGFloat = 36
        let padding: CGFloat = 8
        let barWidth = min(bounds.width - padding * 2, 500)
        searchBar.frame = NSRect(
            x: bounds.width - barWidth - padding,
            y: padding,  // top in flipped coordinates (isFlipped = true)
            width: barWidth,
            height: barHeight
        )
    }

    // MARK: - Pane Drag Destination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dragWidgetsEnabled,
              let sourceID = draggedPaneID(from: sender.draggingPasteboard),
              let paneID,
              sourceID != paneID else {
            paneDropOverlayView.dropZone = nil
            return []
        }

        let point = convert(sender.draggingLocation, from: nil)
        paneDropOverlayView.dropZone = PaneDropZone.calculate(at: point, in: bounds.size)
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dragWidgetsEnabled,
              let sourceID = draggedPaneID(from: sender.draggingPasteboard),
              let paneID,
              sourceID != paneID else {
            paneDropOverlayView.dropZone = nil
            return []
        }

        let point = convert(sender.draggingLocation, from: nil)
        paneDropOverlayView.dropZone = PaneDropZone.calculate(at: point, in: bounds.size)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        paneDropOverlayView.dropZone = nil
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard dragWidgetsEnabled,
              let sourceID = draggedPaneID(from: sender.draggingPasteboard),
              let paneID else { return false }
        return sourceID != paneID
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { paneDropOverlayView.dropZone = nil }

        guard dragWidgetsEnabled,
              let sourceID = draggedPaneID(from: sender.draggingPasteboard),
              let destinationID = paneID,
              sourceID != destinationID else {
            return false
        }

        let point = convert(sender.draggingLocation, from: nil)
        let zone = PaneDropZone.calculate(at: point, in: bounds.size)
        onPaneDrop?(sourceID, destinationID, zone)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        paneDropOverlayView.dropZone = nil
    }

    private func draggedPaneID(from pasteboard: NSPasteboard) -> UUID? {
        guard let rawValue = pasteboard.string(forType: .frosttyPaneID) else { return nil }
        return UUID(uuidString: rawValue)
    }

    @objc private func handlePaneDragEndedNoTarget(_ notification: Notification) {
        guard let sourcePaneID = notification.object as? UUID,
              sourcePaneID == paneID,
              let screenPoint = notification.userInfo?[Notification.Name.frosttyPaneDragEndedNoTargetPointKey] as? NSPoint else {
            return
        }

        onPaneDetachToNewTab?(sourcePaneID, screenPoint)
    }
}

@MainActor
private final class PaneDropOverlayView: NSView {
    var dropZone: PaneDropZone? {
        didSet {
            isHidden = dropZone == nil
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let dropZone else { return }

        let fillColor = TokyoNight.dropZoneFill
        let strokeColor = TokyoNight.dropZoneStroke
        let rect: CGRect

        switch dropZone {
        case .top:
            rect = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2)
        case .bottom:
            rect = CGRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2)
        case .left:
            rect = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        case .right:
            rect = CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
        }

        fillColor.setFill()
        NSBezierPath(rect: rect).fill()

        strokeColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
private final class PaneHandleHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

private struct FrosttyPaneGrabHandle: View {
    private static let handleHeight: CGFloat = 12
    private static let topInset: CGFloat = 2

    @ObservedObject var surfaceView: SurfaceView
    let paneID: UUID
    let onDragStateChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var handleVisible: Bool {
        surfaceView.cursorVisible && (isHovering || isDragging)
    }

    var body: some View {
        ZStack {
            FrosttyPaneDragSource(
                surfaceView: surfaceView,
                paneID: paneID,
                isDragging: $isDragging,
                isHovering: $isHovering,
                onDragStateChanged: onDragStateChanged
            )
            .frame(maxWidth: .infinity)
            .frame(height: Self.handleHeight)
            .contentShape(Rectangle())

            if handleVisible {
                Rectangle()
                    .fill(TokyoNight.dragHandleStripColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.handleHeight)
                    .allowsHitTesting(false)

                Image(systemName: "ellipsis")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(TokyoNight.activeTabForegroundColor)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.handleHeight)
        .padding(.top, Self.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct FrosttyPaneDragSource: NSViewRepresentable {
    let surfaceView: SurfaceView
    let paneID: UUID
    @Binding var isDragging: Bool
    @Binding var isHovering: Bool
    let onDragStateChanged: (Bool) -> Void

    func makeNSView(context: Context) -> FrosttyPaneDragSourceView {
        let view = FrosttyPaneDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: FrosttyPaneDragSourceView, context: Context) {
        update(nsView)
    }

    private func update(_ view: FrosttyPaneDragSourceView) {
        view.surfaceView = surfaceView
        view.paneID = paneID
        view.onDragStateChanged = { dragging in
            onDragStateChanged(dragging)
            withAnimation(.easeInOut(duration: 0.15)) {
                isDragging = dragging
            }
        }
        view.onHoverChanged = { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

@MainActor
private final class FrosttyPaneDragSourceView: NSView, NSDraggingSource {
    private static let previewScale: CGFloat = 0.2
    private static let previewCursorGap: CGFloat = 18

    var surfaceView: SurfaceView?
    var paneID: UUID?
    var onDragStateChanged: ((Bool) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var isTracking = false
    private var escapeMonitor: Any?
    private var dragCancelledByEscape = false

    deinit {
        MainActor.assumeIsolated {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        // Consume the initial click so it never reaches the terminal surface.
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isTracking ? .closedHand : .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isTracking, let surfaceView, let paneID else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(paneID.uuidString, forType: .frosttyPaneID)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

        if let snapshot = surfaceView.asImage {
            let imageSize = NSSize(
                width: snapshot.size.width * Self.previewScale,
                height: snapshot.size.height * Self.previewScale
            )
            let scaledImage = NSImage(size: imageSize)
            scaledImage.lockFocus()
            snapshot.draw(
                in: NSRect(origin: .zero, size: imageSize),
                from: NSRect(origin: .zero, size: snapshot.size),
                operation: .copy,
                fraction: 1.0
            )
            scaledImage.unlockFocus()

            let mouseLocation = convert(event.locationInWindow, from: nil)
            let origin = NSPoint(
                x: mouseLocation.x - imageSize.width / 2,
                y: mouseLocation.y - imageSize.height - Self.previewCursorGap
            )
            item.setDraggingFrame(
                NSRect(origin: origin, size: imageSize),
                contents: scaledImage
            )
        }

        onDragStateChanged?(true)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isTracking = true
        dragCancelledByEscape = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dragCancelledByEscape = true
            }
            return event
        }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        NSCursor.closedHand.set()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        if operation == [] && !dragCancelledByEscape, let paneID {
            let endsInWindow = NSApplication.shared.windows.contains { window in
                window.isVisible && window.frame.contains(screenPoint)
            }
            if !endsInWindow {
                NotificationCenter.default.post(
                    name: .frosttyPaneDragEndedNoTarget,
                    object: paneID,
                    userInfo: [Notification.Name.frosttyPaneDragEndedNoTargetPointKey: screenPoint]
                )
            }
        }

        isTracking = false
        onHoverChanged?(false)
        onDragStateChanged?(false)
    }
}

extension Notification.Name {
    static let frosttyPaneDragEndedNoTarget = Notification.Name("frosttyPaneDragEndedNoTarget")
    static let frosttyPaneDragEndedNoTargetPointKey = "endedAtPoint"
}
