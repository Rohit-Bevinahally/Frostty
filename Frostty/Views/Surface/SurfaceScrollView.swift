// SurfaceScrollView.swift
// Frostty
//
// Wraps a SurfaceView inside an NSScrollView to provide a native scrollbar
// for terminal scrollback. The scroll view owns the document geometry while
// the SurfaceView stays aligned to the visible rect.

@preconcurrency import AppKit
import SwiftUI

/// Flipped document view so scroll coordinates match top-to-bottom orientation.
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// NSScrollView subclass that pins `scrollerStyle` to `.overlay`. AppKit otherwise
/// auto-syncs `scrollerStyle` to the system-wide `NSScroller.preferredScrollerStyle`
/// (which becomes `.legacy` when a mouse is attached, or when WKWebView triggers
/// a re-evaluation)
@MainActor
private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
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

    // MARK: - Static Helpers

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

    private var cellSizeObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?

    private var lastPaneHandlePaneID: UUID?
    private var lastPaneHandleDragEnabled: Bool?
    private var scrollerStyleObserver: NSObjectProtocol?
    private var scrollPocketFrameObserver: NSObjectProtocol?

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
            if let obs = cellSizeObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = configChangeObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = startSearchObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = endSearchObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = searchTotalObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = searchSelectedObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = scrollerStyleObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = scrollPocketFrameObserver { NotificationCenter.default.removeObserver(obs) }
            NotificationCenter.default.removeObserver(self)
        }
    }

    override var isFlipped: Bool { true }
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func mouseMoved(with event: NSEvent) {
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()

        guard let scroller = scrollView.verticalScroller else { return }

        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [
                .mouseMoved,
                .activeInKeyWindow,
            ],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Setup

    private func setupScrollView() {
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerKnobStyle = .default
        scrollView.usesPredominantAxisScrolling = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.contentView.clipsToBounds = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        documentContentView.wantsLayer = true
        documentContentView.layer?.backgroundColor = NSColor.clear.cgColor
        documentContentView.addSubview(surfaceView)

        // The documentView is an empty NSView that defines scrollable height
        scrollView.documentView = documentContentView

        // Disable elastic scrolling
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        addSubview(scrollView)

        applyGlassSurfaceAppearanceIfNeeded()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewContentBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Register for live scroll notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewWillStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
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

        scrollerStyleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrollView.scrollerStyle = .overlay
                self?.synchronizeCoreSurface()
            }
        }

        if #available(macOS 26.0, *) {
            scrollPocketFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleScrollPocketFrameChange(notification)
                }
            }
        }
    }

    @available(macOS 26.0, *)
    private func handleScrollPocketFrameChange(_ notification: Notification) {
        guard let view = notification.object as? NSView else { return }
        guard view.className.contains("NSScrollPocket") else { return }
        guard scrollView.subviews.contains(view) else { return }
        view.postsFrameChangedNotifications = false
        view.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        view.postsFrameChangedNotifications = true
    }

    private func synchronizeCoreSurface() {
        let width = scrollView.contentSize.width
        let height = surfaceView.frame.height
        guard width > 0, height > 0 else { return }
        surfaceView.contentSizeDidChange(NSSize(width: width, height: height))
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
                    self.applyGlassSurfaceAppearanceIfNeeded()
                }
            }
        }
    }

    private func applyScrollbarConfig() {
        let mode = GhosttyAppController.shared.configManager.scrollbarMode
        scrollView.hasVerticalScroller = (mode == .system)
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        updateTrackingAreas()
    }

    // MARK: - Layout

    private func clearPaneLayerCornerClipping() {
        wantsLayer = true
        clipsToBounds = false
        layer?.cornerRadius = 0
        layer?.maskedCorners = []
        layer?.mask = nil
        layer?.masksToBounds = false
    }

    override func layout() {
        super.layout()
        clearPaneLayerCornerClipping()
        synchronizeLayout()
        synchronizeCoreSurface()
        paneDropOverlayView.frame = bounds
        paneHandleHostingView.frame = bounds
        updatePaneDragUI()
        updatePaneHandleIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyGlassSurfaceAppearanceIfNeeded()
    }

    private func applyGlassSurfaceAppearanceIfNeeded() {
        guard FrosttyConfig.shared.usesGlassBackground else { return }
        surfaceView.applyGlassBackgroundAppearance()
    }

    private func updatePaneHandleIfNeeded() {
        let currentDragEnabled = dragWidgetsEnabled
        guard paneID != lastPaneHandlePaneID || currentDragEnabled != lastPaneHandleDragEnabled else { return }
        lastPaneHandlePaneID = paneID
        lastPaneHandleDragEnabled = currentDragEnabled
        refreshPaneHandle()
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
            TerminalPaneGrabHandleView(
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

        // ScrollView fills our bounds.
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

        synchronizeSurfaceView()
        updateTrackingAreas()

        layoutSearchBar()
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    // MARK: - Scrollbar Update (Core -> UI)

    private func handleScrollbarUpdate(_ state: GhosttySurfaceController.ScrollbarState) {
        guard let validated = Self.validatedScrollbar(
            total: state.total,
            offset: state.offset,
            len: state.len
        ) else {
            handleClearedScrollbarState()
            return
        }

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

        // Keep UI->core dedup aligned with the current core scrollbar position.
        lastSentRow = validated.offset

        // Skip if this is the same offset we already applied
        guard validated.offset != lastAppliedOffset else { return }
        lastAppliedOffset = validated.offset

        // Scroll to the offset position
        let scrollY = Self.offsetToScrollY(offset: validated.offset, cellHeight: cellHeight)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        synchronizeSurfaceView()
        updateTrackingAreas()
    }

    private func handleClearedScrollbarState() {
        lastKnownTotal = 0
        lastKnownLen = 0
        lastAppliedOffset = -1
        lastSentRow = 0

        let contentSize = bounds.size
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        documentContentView.frame = NSRect(
            x: 0,
            y: 0,
            width: contentSize.width,
            height: contentSize.height
        )
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        synchronizeSurfaceView()
        updateTrackingAreas()
    }

    // MARK: - Live Scroll (UI -> Core)

    @objc private func scrollViewContentBoundsDidChange(_ notification: Notification) {
        synchronizeSurfaceView()
    }

    @objc private func scrollViewWillStartLiveScroll(_ notification: Notification) {
        isLiveScrolling = true
    }

    @objc private func scrollViewDidLiveScroll(_ notification: Notification) {
        synchronizeSurfaceView()

        guard cellHeight > 0 else { return }

        let scrollY = scrollView.contentView.documentVisibleRect.origin.y
        let row = Self.scrollYToRow(scrollY: scrollY, cellHeight: cellHeight)
        let clampedRow = Self.clampRow(row, total: lastKnownTotal, len: lastKnownLen)

        sendScrollToRow(clampedRow)
    }

    @objc private func scrollViewDidEndLiveScroll(_ notification: Notification) {
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
            bar.onEscapeToTerminal = { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.surfaceView)
            }
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

    /// Dismiss the scrollback search bar (if visible) by sending `end_search`.
    /// libghostty echoes the end-search action back, which triggers
    /// `hideSearchBar()` via the `.ghosttyEndSearch` notification.
    /// Returns `true` when the bar was present and an `end_search` action
    /// was issued, allowing callers (e.g. `SurfaceView.keyDown`) to consume
    /// the originating event.
    @discardableResult
    func dismissSearchBarIfVisible() -> Bool {
        guard searchBar != nil else { return false }
        surfaceView.surfaceController?.performAction("end_search")
        return true
    }

    private func hideSearchBar() {
        searchBar?.resetSearchState()
        searchBar?.setSearchText("")
        searchBar?.removeFromSuperview()
        searchBar = nil
        window?.makeFirstResponder(surfaceView)
    }

    private func layoutSearchBar() {
        // The overlay positions and sizes its own search field internally
        // (corner-snap, drag, etc.), so we let it span the full surface
        // and rely on its hit test to pass through to the terminal.
        searchBar?.frame = bounds
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
              let screenPoint = notification.userInfo?[FrosttyUserInfoKey.paneDragEndedNoTargetPoint] as? NSPoint else {
            return
        }

        onPaneDetachToNewTab?(sourcePaneID, screenPoint)
    }
}
