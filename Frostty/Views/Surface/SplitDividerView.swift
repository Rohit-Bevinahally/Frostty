// SplitDividerView.swift
// Frostty
//
// NSView subclass for the split divider line with drag handling.

import AppKit

@MainActor
class SplitDividerView: NSView {
    let direction: SplitDirection
    var onRatioChange: ((Double) -> Void)?

    private var isDragging = false
    private let hitAreaThickness: CGFloat = 7
    private let splitBounds: CGRect
    private weak var coordinateView: NSView?
    private let minPaneSize: CGFloat

    init(
        direction: SplitDirection,
        splitBounds: CGRect,
        coordinateView: NSView,
        minPaneSize: CGFloat
    ) {
        self.direction = direction
        self.splitBounds = splitBounds
        self.coordinateView = coordinateView
        self.minPaneSize = minPaneSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    var thickness: CGFloat { hitAreaThickness }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        let cursor: NSCursor = direction == .horizontal ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        isDragging = true
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: .greatestFiniteMagnitude,
            mode: .eventTracking
        ) { [weak self] trackedEvent, stop in
            guard let self else {
                stop.pointee = true
                return
            }
            guard let trackedEvent else {
                self.isDragging = false
                stop.pointee = true
                return
            }

            switch trackedEvent.type {
            case .leftMouseDragged:
                self.updateRatio(with: trackedEvent)
            case .leftMouseUp:
                self.isDragging = false
                stop.pointee = true
            default:
                break
            }
        }
    }

    private func updateRatio(with event: NSEvent) {
        guard isDragging else { return }
        guard let coordinateView else { return }

        let currentPoint = coordinateView.convert(event.locationInWindow, from: nil)

        let ratio: CGFloat
        switch direction {
        case .horizontal:
            guard splitBounds.width > 0 else { return }
            let position = min(
                max(minPaneSize, currentPoint.x - splitBounds.minX),
                splitBounds.width - minPaneSize
            )
            ratio = position / splitBounds.width
        case .vertical:
            guard splitBounds.height > 0 else { return }
            let position = min(
                max(minPaneSize, currentPoint.y - splitBounds.minY),
                splitBounds.height - minPaneSize
            )
            ratio = position / splitBounds.height
        }

        onRatioChange?(Double(ratio))
    }
}
