// FrosttyWindow.swift
// Frostty
//
// Custom NSWindow with transparent titlebar and shortcut interception.

import AppKit
import SwiftUI

@MainActor
class FrosttyWindow: NSWindow {
    var shortcutManager: ShortcutManager?
    var disablesTitlebarDragging = false

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        tabbingMode = .disallowed
        // Avoid moving the window while dragging tabs / sidebar chrome (see bugs/composer/02).
        isMovableByWindowBackground = false

        // Allow full-size content behind the titlebar
        // styleMask already includes .fullSizeContentView from caller

        backgroundColor = NSColor(red: 0x1d / 255, green: 0x20 / 255, blue: 0x2f / 255, alpha: 1) // TokyoNight barBackground
        minSize = NSSize(width: 400, height: 300)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           let manager = shortcutManager,
           manager.shouldIntercept(event: event, firstResponder: firstResponder) {
            if manager.handleEvent(event) {
                return // Shortcut consumed the event
            }
        }
        super.sendEvent(event)
    }

    override var contentLayoutRect: CGRect {
        guard disablesTitlebarDragging else { return super.contentLayoutRect }
        return CGRect(origin: .zero, size: frame.size)
    }
}

@MainActor
final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}
