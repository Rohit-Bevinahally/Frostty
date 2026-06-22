// WindowDragRegion.swift
// Frostty
//
// AppKit views that opt into window dragging inside a full-size content view.

import AppKit
import SwiftUI

/// Transparent region that moves the window when clicked and dragged.
@MainActor
final class WindowDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }
}

struct WindowDragRegionRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragRegionView {
        let view = WindowDragRegionView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: WindowDragRegionView, context: Context) {}
}
