import AppKit
import SwiftUI

@MainActor
final class BrowserPaneView: NSView {
    private static let contentTopInset: CGFloat = 12

    let paneID: UUID
    let controller: BrowserTabController
    private let hostingView: BrowserPaneHostingView<BrowserContainerView>

    nonisolated(unsafe) private var ghosttyConfigObserver: NSObjectProtocol?

    private let paneDropOverlayView = PaneDropOverlayView()
    private let paneHandleHostingView = PaneHandleHostingView(rootView: AnyView(EmptyView()))

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

    init(controller: BrowserTabController, paneID: UUID) {
        self.paneID = paneID
        self.controller = controller
        self.hostingView = BrowserPaneHostingView(
            rootView: BrowserContainerView(controller: controller, paneID: paneID)
        )
        super.init(frame: .zero)

        wantsLayer = true
        updateGhosttyBackdrop()

        controller.browserView.onFocus = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .frosttyBrowserPaneDidFocus, object: self)
        }

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor, constant: Self.contentTopInset),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setupPaneDragWidgets()

        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateGhosttyBackdrop()
            }
        }
    }

    deinit {
        if let ghosttyConfigObserver {
            NotificationCenter.default.removeObserver(ghosttyConfigObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { false }

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
        updateGhosttyBackdrop()
        paneDropOverlayView.frame = bounds
        paneHandleHostingView.frame = bounds
        updatePaneDragUI()
        updatePaneHandleIfNeeded()
    }

    func setSuspended(_ suspended: Bool) {
        controller.setSuspended(suspended)
        isHidden = suspended
    }

    private var lastPaneHandleDragEnabled: Bool?

    private func updatePaneHandleIfNeeded() {
        guard dragWidgetsEnabled != lastPaneHandleDragEnabled else { return }
        lastPaneHandleDragEnabled = dragWidgetsEnabled
        refreshPaneHandle()
    }

    private func updateGhosttyBackdrop() {
        let cfg = GhosttyAppController.shared.configManager
        let opacity = cfg.backgroundOpacity
        let bg = cfg.backgroundColor.withAlphaComponent(opacity)
        wantsLayer = true
        layer?.backgroundColor = bg.cgColor
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
            selector: #selector(handleBrowserPaneDragEndedNoTarget(_:)),
            name: .frosttyPaneDragEndedNoTarget,
            object: nil
        )

        refreshPaneHandle()
    }

    private func updatePaneDragUI() {
        if !dragWidgetsEnabled {
            paneDropOverlayView.dropZone = nil
        }
    }

    private func refreshPaneHandle() {
        guard dragWidgetsEnabled else {
            paneHandleHostingView.rootView = AnyView(EmptyView())
            return
        }

        paneHandleHostingView.rootView = AnyView(
            BrowserPaneGrabHandleView(
                previewSourceView: self,
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

    @objc private func handleBrowserPaneDragEndedNoTarget(_ notification: Notification) {
        guard let sourcePaneID = notification.object as? UUID,
              sourcePaneID == paneID,
              let screenPoint = notification.userInfo?[FrosttyUserInfoKey.paneDragEndedNoTargetPoint] as? NSPoint else {
            return
        }

        onPaneDetachToNewTab?(sourcePaneID, screenPoint)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dragWidgetsEnabled,
              let sourceID = draggedPaneID(from: sender.draggingPasteboard),
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
              let sourceID = draggedPaneID(from: sender.draggingPasteboard) else { return false }
        return sourceID != paneID
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { paneDropOverlayView.dropZone = nil }

        guard dragWidgetsEnabled,
              let sourceID = draggedPaneID(from: sender.draggingPasteboard),
              sourceID != paneID else {
            return false
        }

        let point = convert(sender.draggingLocation, from: nil)
        let zone = PaneDropZone.calculate(at: point, in: bounds.size)
        onPaneDrop?(sourceID, paneID, zone)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        paneDropOverlayView.dropZone = nil
    }

    private func draggedPaneID(from pasteboard: NSPasteboard) -> UUID? {
        guard let rawValue = pasteboard.string(forType: .frosttyPaneID) else { return nil }
        return UUID(uuidString: rawValue)
    }

    @discardableResult
    func focus(in window: NSWindow? = nil) -> Bool {
        controller.focus(in: window)
    }
}

private final class BrowserPaneHostingView<Content: View>: NSHostingView<Content> {
    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }
}
