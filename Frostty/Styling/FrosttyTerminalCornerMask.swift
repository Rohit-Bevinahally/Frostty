// FrosttyTerminalCornerMask.swift
// Frostty
//
// Shared terminal silhouette: square top corners, bottom-right always rounded,
// bottom-left rounded only when the sidebar is hidden.

import AppKit
import QuartzCore

@MainActor
enum FrosttyTerminalCornerMask {
    static func windowCornerRadius(for window: NSWindow?) -> CGFloat {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return 12
        }
        return window.value(forKey: "_cornerRadius") as? CGFloat ?? 12
    }

    static func apply(to layer: CALayer, radius: CGFloat, showSidebar: Bool, isFlipped: Bool = false) {
        guard radius > 0 else {
            layer.cornerRadius = 0
            layer.maskedCorners = []
            layer.mask = nil
            layer.masksToBounds = false
            return
        }

        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        layer.cornerRadius = 0
        layer.maskedCorners = []

        let maskLayer = CAShapeLayer()
        maskLayer.frame = bounds
        // Path is already authored in the target layer's coordinate space via
        // `isFlipped`; do not flip again or top/bottom corners swap.
        maskLayer.isGeometryFlipped = false
        maskLayer.path = silhouettePath(
            in: bounds,
            radius: radius,
            showSidebar: showSidebar,
            isFlipped: isFlipped
        )
        layer.mask = maskLayer
        layer.masksToBounds = true
    }

    static func silhouettePath(
        in rect: CGRect,
        radius: CGFloat,
        showSidebar: Bool,
        isFlipped: Bool
    ) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let w = rect.width
        let h = rect.height
        let path = CGMutablePath()

        if isFlipped {
            // View coordinates: origin top-left, y increases downward.
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: h - r))
            if r > 0 {
                path.addArc(
                    tangent1End: CGPoint(x: w, y: h),
                    tangent2End: CGPoint(x: w - r, y: h),
                    radius: r
                )
            } else {
                path.addLine(to: CGPoint(x: w, y: h))
            }
            if showSidebar {
                path.addLine(to: CGPoint(x: 0, y: h))
            } else {
                path.addLine(to: CGPoint(x: r, y: h))
                if r > 0 {
                    path.addArc(
                        tangent1End: CGPoint(x: 0, y: h),
                        tangent2End: CGPoint(x: 0, y: h - r),
                        radius: r
                    )
                } else {
                    path.addLine(to: CGPoint(x: 0, y: h))
                }
            }
            path.addLine(to: .zero)
        } else {
            // Layer coordinates: origin bottom-left, y increases upward.
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w, y: r))
            if r > 0 {
                path.addArc(
                    tangent1End: CGPoint(x: w, y: 0),
                    tangent2End: CGPoint(x: w - r, y: 0),
                    radius: r
                )
            } else {
                path.addLine(to: CGPoint(x: w, y: 0))
            }
            if showSidebar {
                path.addLine(to: CGPoint(x: 0, y: 0))
            } else {
                path.addLine(to: CGPoint(x: r, y: 0))
                if r > 0 {
                    path.addArc(
                        tangent1End: CGPoint(x: 0, y: 0),
                        tangent2End: CGPoint(x: 0, y: r),
                        radius: r
                    )
                } else {
                    path.addLine(to: CGPoint(x: 0, y: 0))
                }
            }
            path.addLine(to: CGPoint(x: 0, y: h))
        }

        path.closeSubpath()
        return path
    }
}
