// MetalView.swift
// Frostty
//
// Simple CAMetalLayer subclass for the terminal rendering surface.

@preconcurrency import QuartzCore
import os

private let logger = Logger(subsystem: "com.frostty.terminal", category: "MetalView")

// MARK: - GhosttyMetalLayer

final class GhosttyMetalLayer: CAMetalLayer {

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        self.displaySyncEnabled = true
        self.pixelFormat = .bgra8Unorm
        self.wantsExtendedDynamicRangeContent = true
        self.isOpaque = false
        self.framebufferOnly = true
    }

    override func nextDrawable() -> CAMetalDrawable? {
        let drawable = super.nextDrawable()
        if drawable == nil {
            logger.debug("nextDrawable returned nil - frame will be dropped")
        }
        return drawable
    }
}
