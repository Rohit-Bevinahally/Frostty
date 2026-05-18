// PaneDragChrome.swift
// Frostty
//
// Shared pane drag handle, drag source, and drop overlay for terminal and browser panes.

import AppKit
import SwiftUI

enum PaneGrabHandleMetrics {
    static let handleHeight: CGFloat = 12
    static let topInset: CGFloat = 2
}

@MainActor
final class PaneDropOverlayView: NSView {
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
final class PaneHandleHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - Terminal (cursor-gated visibility)

struct TerminalPaneGrabHandleView: View {
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
            PaneDragSourceRepresentable(
                previewSourceView: surfaceView,
                paneID: paneID,
                isDragging: $isDragging,
                isHovering: $isHovering,
                onDragStateChanged: onDragStateChanged
            )
            .frame(maxWidth: .infinity)
            .frame(height: PaneGrabHandleMetrics.handleHeight)
            .contentShape(Rectangle())

            if handleVisible {
                Rectangle()
                    .fill(TokyoNight.dragHandleStripColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: PaneGrabHandleMetrics.handleHeight)
                    .allowsHitTesting(false)

                Image(systemName: "ellipsis")
                    .font(GhosttyUIFonts.font(size: 24, weight: .semibold))
                    .foregroundColor(TokyoNight.activeTabForegroundColor)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PaneGrabHandleMetrics.handleHeight)
        .padding(.top, PaneGrabHandleMetrics.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Browser (always shows strip on hover / drag)

struct BrowserPaneGrabHandleView: View {
    let previewSourceView: NSView
    let paneID: UUID
    let onDragStateChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private var handleVisible: Bool {
        isHovering || isDragging
    }

    var body: some View {
        ZStack {
            PaneDragSourceRepresentable(
                previewSourceView: previewSourceView,
                paneID: paneID,
                isDragging: $isDragging,
                isHovering: $isHovering,
                onDragStateChanged: onDragStateChanged
            )
            .frame(maxWidth: .infinity)
            .frame(height: PaneGrabHandleMetrics.handleHeight)
            .contentShape(Rectangle())

            if handleVisible {
                Rectangle()
                    .fill(TokyoNight.dragHandleStripColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: PaneGrabHandleMetrics.handleHeight)
                    .allowsHitTesting(false)

                Image(systemName: "ellipsis")
                    .font(GhosttyUIFonts.font(size: 24, weight: .semibold))
                    .foregroundColor(TokyoNight.activeTabForegroundColor)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PaneGrabHandleMetrics.handleHeight)
        .padding(.top, PaneGrabHandleMetrics.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Drag source

struct PaneDragSourceRepresentable: NSViewRepresentable {
    let previewSourceView: NSView
    let paneID: UUID
    @Binding var isDragging: Bool
    @Binding var isHovering: Bool
    let onDragStateChanged: (Bool) -> Void

    func makeNSView(context: Context) -> PaneDragSourceView {
        let view = PaneDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: PaneDragSourceView, context: Context) {
        update(nsView)
    }

    private func update(_ view: PaneDragSourceView) {
        view.previewSourceView = previewSourceView
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
final class PaneDragSourceView: NSView, NSDraggingSource {
    private static let previewScale: CGFloat = 0.2
    private static let previewCursorGap: CGFloat = 18

    weak var previewSourceView: NSView?
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
        // Consume the initial click so it never reaches the pane content below.
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
        guard !isTracking, let previewSourceView, let paneID else { return }

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(paneID.uuidString, forType: .frosttyPaneID)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

        if let snapshot = previewSourceView.frosttyPaneSnapshotImage {
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
                    userInfo: [FrosttyUserInfoKey.paneDragEndedNoTargetPoint: screenPoint]
                )
            }
        }

        isTracking = false
        onHoverChanged?(false)
        onDragStateChanged?(false)
    }
}
