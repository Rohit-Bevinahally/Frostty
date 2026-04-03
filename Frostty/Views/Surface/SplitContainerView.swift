// SplitContainerView.swift
// Frostty
//
// NSView that recursively renders a SplitTree using SurfaceRegistry lookups.

import AppKit
import QuartzCore

@MainActor
class SplitContainerView: NSView {
    private var registry: SurfaceRegistry
    private var currentTree: SplitTree = SplitTree()
    private var maximizedLeafID: UUID?
    private var scrollWrappers: [UUID: SurfaceScrollView] = [:]
    var onRatioChange: (([SplitPathBranch], Double, CGSize) -> Void)?
    var onPaneDrop: ((UUID, UUID, PaneDropZone) -> Void)?
    var onPaneDetachToNewTab: ((UUID, NSPoint) -> Void)?
    var onDeferredLayoutComplete: (() -> Void)?

    private static let minPaneSize: CGFloat = 50
    private static let paneBorderWidth: CGFloat = 1
    private static let paneCornerRadius: CGFloat = 12

    init(registry: SurfaceRegistry) {
        self.registry = registry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: - Update

    func updateRegistry(_ registry: SurfaceRegistry) {
        guard self.registry !== registry else { return }
        self.registry = registry
        currentTree = SplitTree()
        maximizedLeafID = nil
        scrollWrappers.removeAll()
        subviews.forEach { $0.removeFromSuperview() }
        needsLayout = true
    }

    func updateLayout(tree: SplitTree, maximizedLeafID: UUID? = nil) {
        let oldTree = currentTree
        let oldMaximizedLeafID = self.maximizedLeafID
        currentTree = tree
        self.maximizedLeafID = maximizedLeafID

        guard oldTree != tree || oldMaximizedLeafID != maximizedLeafID else { return }

        // Don't move surface views into a zero-bounds container —
        // setFrameSize(zero) kills Metal drawable and ghostty stops rendering.
        // resizeSubviews/layout will handle it when we get proper bounds.
        guard bounds.width > 0 && bounds.height > 0 else { return }

        relayoutCurrentTree()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard currentTree.root != nil else { return }
        relayoutCurrentTree()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard currentTree.root != nil else { return }

        // Deferred layout: surface views haven't been added yet
        if subviews.isEmpty || subviews.allSatisfy({ !($0 is SplitDividerView) }) {
            relayoutCurrentTree()
            let callback = onDeferredLayoutComplete
            onDeferredLayoutComplete = nil
            callback?()
        }
    }

    private func relayoutCurrentTree() {
        removeDividers()

        guard let root = currentTree.root else {
            subviews.forEach { $0.removeFromSuperview() }
            return
        }

        if let maximizedLeafID,
           currentTree.allLeafIDs().contains(maximizedLeafID) {
            layoutLeaf(maximizedLeafID, in: bounds)
            removeHiddenWrappers(except: [maximizedLeafID])
        } else {
            layoutNode(root, in: bounds)
            removeHiddenWrappers(except: currentTree.allLeafIDs())
        }

        removeOrphanedSurfaces()
    }

    // MARK: - Recursive Layout

    private func layoutNode(_ node: SplitNode, in rect: CGRect, path: [SplitPathBranch] = []) {
        switch node {
        case .leaf(let id):
            layoutLeaf(id, in: rect)

        case .split(let data):
            switch data.direction {
            case .horizontal:
                let splitX = rect.minX + rect.width * data.ratio
                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: max(splitX - rect.minX, Self.minPaneSize),
                    height: rect.height
                )
                let dividerRect = CGRect(
                    x: splitX,
                    y: rect.minY,
                    width: 0,
                    height: rect.height
                )
                let secondRect = CGRect(
                    x: splitX,
                    y: rect.minY,
                    width: max(rect.maxX - splitX, Self.minPaneSize),
                    height: rect.height
                )

                layoutNode(data.first, in: firstRect, path: path + [.first])
                addDivider(
                    direction: .horizontal,
                    frame: dividerRect,
                    splitBounds: rect,
                    path: path
                )
                layoutNode(data.second, in: secondRect, path: path + [.second])

            case .vertical:
                let splitY = rect.minY + rect.height * data.ratio
                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: max(splitY - rect.minY, Self.minPaneSize)
                )
                let dividerRect = CGRect(
                    x: rect.minX,
                    y: splitY,
                    width: rect.width,
                    height: 0
                )
                let secondRect = CGRect(
                    x: rect.minX,
                    y: splitY,
                    width: rect.width,
                    height: max(rect.maxY - splitY, Self.minPaneSize)
                )

                layoutNode(data.first, in: firstRect, path: path + [.first])
                addDivider(
                    direction: .vertical,
                    frame: dividerRect,
                    splitBounds: rect,
                    path: path
                )
                layoutNode(data.second, in: secondRect, path: path + [.second])
            }
        }
    }

    private func layoutLeaf(_ id: UUID, in rect: CGRect) {
        guard let surfaceView = registry.view(for: id) else { return }

        let wrapper: SurfaceScrollView
        if let existing = scrollWrappers[id] {
            wrapper = existing
        } else {
            wrapper = SurfaceScrollView(surfaceView: surfaceView)
            scrollWrappers[id] = wrapper
        }

        wrapper.frame = rect
        wrapper.paneID = id
        wrapper.dragWidgetsEnabled = maximizedLeafID == nil
        wrapper.onPaneDrop = onPaneDrop
        wrapper.onPaneDetachToNewTab = onPaneDetachToNewTab
        configureWrapperAppearance(wrapper, paneID: id, frame: rect)
        wrapper.autoresizingMask = []
        if wrapper.superview !== self {
            addSubview(wrapper)
        }

    }

    private func addDivider(
        direction: SplitDirection,
        frame: CGRect,
        splitBounds: CGRect,
        path: [SplitPathBranch]
    ) {
        let divider = SplitDividerView(
            direction: direction,
            splitBounds: splitBounds,
            coordinateView: self,
            minPaneSize: Self.minPaneSize
        )

        // Expand hit area around the visible divider
        let hitExpansion: CGFloat = 3
        let hitFrame: CGRect
        switch direction {
        case .horizontal:
            hitFrame = CGRect(
                x: frame.minX - hitExpansion,
                y: frame.minY,
                width: frame.width + hitExpansion * 2,
                height: frame.height
            )
        case .vertical:
            hitFrame = CGRect(
                x: frame.minX,
                y: frame.minY - hitExpansion,
                width: frame.width,
                height: frame.height + hitExpansion * 2
            )
        }

        divider.frame = hitFrame
        divider.onRatioChange = { [weak self] ratio in
            guard let self else { return }
            self.onRatioChange?(path, ratio, splitBounds.size)
        }
        addSubview(divider)
    }

    private func configureWrapperAppearance(_ wrapper: SurfaceScrollView, paneID: UUID, frame: CGRect) {
        wrapper.wantsLayer = true
        guard let layer = wrapper.layer else { return }

        guard currentTree.isSplit else {
            layer.borderWidth = 0
            layer.borderColor = nil
            layer.cornerRadius = 0
            layer.maskedCorners = []
            layer.masksToBounds = false
            return
        }

        layer.borderWidth = Self.paneBorderWidth
        layer.borderColor = (paneID == currentTree.focusedLeafID
            ? TokyoNight.activeBorderColor
            : TokyoNight.inactiveBorderColor).cgColor

        let maskedCorners = paneMaskedCorners(for: frame)
        layer.cornerRadius = maskedCorners.isEmpty ? 0 : Self.paneCornerRadius
        layer.maskedCorners = maskedCorners
        layer.cornerCurve = .continuous
        layer.masksToBounds = !maskedCorners.isEmpty
    }

    private func paneMaskedCorners(for frame: CGRect) -> CACornerMask {
        let epsilon: CGFloat = 0.5
        var corners: CACornerMask = []

        if abs(frame.minX - bounds.minX) <= epsilon, abs(frame.minY - bounds.minY) <= epsilon {
            corners.insert(.layerMinXMinYCorner)
        }
        if abs(frame.maxX - bounds.maxX) <= epsilon, abs(frame.minY - bounds.minY) <= epsilon {
            corners.insert(.layerMaxXMinYCorner)
        }
        if abs(frame.minX - bounds.minX) <= epsilon, abs(frame.maxY - bounds.maxY) <= epsilon {
            corners.insert(.layerMinXMaxYCorner)
        }
        if abs(frame.maxX - bounds.maxX) <= epsilon, abs(frame.maxY - bounds.maxY) <= epsilon {
            corners.insert(.layerMaxXMaxYCorner)
        }

        return corners
    }

    private func removeDividers() {
        for subview in subviews where subview is SplitDividerView {
            subview.removeFromSuperview()
        }
    }

    private func removeHiddenWrappers(except visibleLeafIDs: [UUID]) {
        let visibleIDs = Set(visibleLeafIDs)
        for (id, wrapper) in scrollWrappers where !visibleIDs.contains(id) {
            wrapper.removeFromSuperview()
        }
    }

    /// Remove orphaned subviews not present in the current tree.
    /// Handles both SurfaceScrollView wrappers and legacy bare SurfaceView subviews.
    private func removeOrphanedSurfaces() {
        let treeIDs = Set(currentTree.allLeafIDs())
        for subview in subviews {
            if let wrapper = subview as? SurfaceScrollView {
                let id = registry.id(for: wrapper.surfaceView)
                if id == nil || !treeIDs.contains(id!) {
                    subview.removeFromSuperview()
                    if let id { scrollWrappers.removeValue(forKey: id) }
                }
            } else if let surface = subview as? SurfaceView {
                // Legacy: shouldn't happen, but clean up
                let id = registry.id(for: surface)
                if id == nil || !treeIDs.contains(id!) {
                    subview.removeFromSuperview()
                }
            }
        }
        // Also clean wrapper dictionary of IDs no longer in tree
        for id in scrollWrappers.keys where !treeIDs.contains(id) {
            scrollWrappers[id]?.removeFromSuperview()
            scrollWrappers.removeValue(forKey: id)
        }
    }
}
