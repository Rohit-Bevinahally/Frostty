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
    private var leafContainers: [UUID: NSView] = [:]
    var showsSidebar: Bool = true {
        didSet {
            guard oldValue != showsSidebar else { return }
            applyContainerCornerMask()
            relayoutCurrentTree()
        }
    }
    var onRatioChange: (([SplitPathBranch], Double, CGSize) -> Void)?
    var onPaneDrop: ((UUID, UUID, PaneDropZone) -> Void)?
    var onPaneDetachToNewTab: ((UUID, NSPoint) -> Void)?
    var onDeferredLayoutComplete: (() -> Void)?

    private static let minPaneSize: CGFloat = 50
    private static let paneBorderWidth: CGFloat = 1

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
        leafContainers.removeAll()
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
            removeHiddenLeafContainers(except: [maximizedLeafID])
        } else {
            layoutNode(root, in: bounds)
            removeHiddenLeafContainers(except: currentTree.allLeafIDs())
        }

        removeOrphanedLeafContainers()
        applyContainerCornerMask()
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
        registry.setOcclusion(for: id, occluded: false)

        if let surfaceView = registry.view(for: id) {
            let wrapper: SurfaceScrollView
            if let existing = leafContainers[id] as? SurfaceScrollView {
                wrapper = existing
            } else {
                wrapper = SurfaceScrollView(surfaceView: surfaceView)
                leafContainers[id] = wrapper
            }

            wrapper.frame = rect
            wrapper.paneID = id
            wrapper.dragWidgetsEnabled = maximizedLeafID == nil
            wrapper.onPaneDrop = onPaneDrop
            wrapper.onPaneDetachToNewTab = onPaneDetachToNewTab
            configurePaneAppearance(wrapper, paneID: id, frame: rect)
            wrapper.autoresizingMask = []
            if wrapper.superview !== self {
                addSubview(wrapper)
            }
            surfaceView.completeInitialSizingIfNeeded()
            return
        }

        guard let paneView = registry.paneView(for: id) else { return }
        if let browserPane = paneView as? BrowserPaneView {
            browserPane.dragWidgetsEnabled = maximizedLeafID == nil
            browserPane.onPaneDrop = onPaneDrop
            browserPane.onPaneDetachToNewTab = onPaneDetachToNewTab
        }
        leafContainers[id] = paneView
        paneView.frame = rect
        paneView.autoresizingMask = []
        configurePaneAppearance(paneView, paneID: id, frame: rect)
        if paneView.superview !== self {
            addSubview(paneView)
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyContainerCornerMask()
    }

    private func applyContainerCornerMask() {
        guard let layer else { return }
        let radius = FrosttyTerminalCornerMask.windowCornerRadius(for: window)
        FrosttyTerminalCornerMask.apply(
            to: layer,
            radius: radius,
            showSidebar: showsSidebar,
            isFlipped: isFlipped
        )
    }

    private func configurePaneAppearance(_ paneView: NSView, paneID: UUID, frame: CGRect) {
        paneView.wantsLayer = true
        guard let layer = paneView.layer else { return }

        // Outer silhouette is owned by SplitContainerView; panes stay square on top.
        layer.cornerRadius = 0
        layer.maskedCorners = []
        layer.mask = nil
        layer.masksToBounds = false

        guard currentTree.isSplit else {
            layer.borderWidth = 0
            layer.borderColor = nil
            return
        }

        layer.borderWidth = Self.paneBorderWidth
        layer.borderColor = (paneID == currentTree.focusedLeafID
            ? TokyoNight.activeBorderColor
            : TokyoNight.inactiveBorderColor).cgColor
    }

    private func removeDividers() {
        for subview in subviews where subview is SplitDividerView {
            subview.removeFromSuperview()
        }
    }

    private func removeHiddenLeafContainers(except visibleLeafIDs: [UUID]) {
        let visibleIDs = Set(visibleLeafIDs)
        for (id, paneView) in leafContainers where !visibleIDs.contains(id) {
            registry.setOcclusion(for: id, occluded: true)
            paneView.removeFromSuperview()
        }
    }

    private func removeOrphanedLeafContainers() {
        let treeIDs = Set(currentTree.allLeafIDs())
        for (id, paneView) in Array(leafContainers) where !treeIDs.contains(id) || !registry.contains(id) {
            paneView.removeFromSuperview()
            leafContainers.removeValue(forKey: id)
        }
    }
}
