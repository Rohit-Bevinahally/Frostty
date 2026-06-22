// MainContentView.swift
// Frostty
//
// SwiftUI root view composing sidebar, tab bar, and terminal content.

import AppKit
import SwiftUI

struct MainContentView: View {
    @Bindable var windowSession: WindowSession
    @Bindable var markdownPreviewSession: MarkdownPreviewSession
    let splitContainerView: SplitContainerView
    let isPaneResizeMode: Bool

    var onTabSelected: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onMoveTab: ((Int, Int) -> Void)?
    var onRenameTab: ((UUID, String) -> Void)?

    var onWorkspaceSelected: ((UUID) -> Void)?
    var onNewWorkspace: ((String, String?) -> Bool)?
    var onDeleteWorkspace: ((UUID) -> Void)?
    var onRenameWorkspace: ((UUID, String) -> Void)?
    var onMoveWorkspace: ((Int, Int) -> Void)?
    var onSetWorkingDirectory: ((UUID, String?) -> Bool)?
    var onPaneMoveToNewTabAtSlot: ((UUID, Int) -> Void)?
    var onPaneMoveToNewWorkspaceAtSlot: ((UUID, Int) -> Void)?
    var onPaneMoveToWorkspace: ((UUID, UUID) -> Void)?
    var canDropPaneToNewTab: ((UUID) -> Bool)?

    var onToggleSidebar: (() -> Void)?
    var onSidebarWidthChanged: ((CGFloat) -> Void)?

    @State private var paneTabDropGlobalX: CGFloat?
    @State private var paneTabDropInsertionSlot: Int?
    @State private var liveSidebarWidth: CGFloat?
    @State private var chromeAppearanceTick: UInt = 0

    var body: some View {
        let _ = chromeAppearanceTick
        GeometryReader { geo in
            let activeWorkspace = windowSession.activeWorkspace
            let activeTabs = activeWorkspace?.tabs ?? []
            let activeTabID = activeWorkspace?.activeTabID
            let titlebarInset = windowSession.showSidebar ? geo.safeAreaInsets.top : 0
            let combinedChromeHeight = FrosttyTitlebarMetrics.combinedChromeHeight(
                titlebarInset: titlebarInset,
                showSidebar: windowSession.showSidebar
            )
            let sidebarWidth = liveSidebarWidth ?? windowSession.sidebarWidth

            HStack(spacing: 0) {
                if windowSession.showSidebar {
                    SidebarView(
                        workspaces: windowSession.workspaces,
                        activeWorkspaceID: windowSession.activeWorkspaceID,
                        currentWidth: sidebarWidth,
                        titlebarInset: titlebarInset,
                        onSelectWorkspace: onWorkspaceSelected,
                        onAddWorkspace: onNewWorkspace,
                        onDeleteWorkspace: onDeleteWorkspace,
                        onRenameWorkspace: onRenameWorkspace,
                        onMoveWorkspace: onMoveWorkspace,
                        onSetWorkingDirectory: onSetWorkingDirectory,
                        onPaneMoveToNewWorkspaceAtSlot: onPaneMoveToNewWorkspaceAtSlot,
                        onPaneMoveToWorkspace: onPaneMoveToWorkspace,
                        onSidebarWidthChanging: { newWidth in
                            liveSidebarWidth = clampedSidebarWidth(newWidth)
                        },
                        onSidebarWidthChangeEnded: { newWidth in
                            let clamped = clampedSidebarWidth(newWidth)
                            onSidebarWidthChanged?(clamped)
                            liveSidebarWidth = nil
                        }
                    )
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))
                }

                VStack(spacing: 0) {
                    if !activeTabs.isEmpty {
                        TabBarView(
                            tabs: activeTabs,
                            activeTabID: activeTabID,
                            titlebarInset: titlebarInset,
                            showSidebar: windowSession.showSidebar,
                            paneDropGlobalX: paneTabDropGlobalX,
                            paneDropInsertionSlot: paneTabDropInsertionSlot,
                            onSelectTab: onTabSelected,
                            onCloseTab: onCloseTab,
                            onMoveTab: onMoveTab,
                            onRenameTab: onRenameTab,
                            onPaneDropInsertionSlotChanged: { paneTabDropInsertionSlot = $0 }
                        )
                        .overlay(alignment: .topLeading) {
                            GeometryReader { dropGeo in
                                PaneDragDropTargetRepresentable(
                                    globalFrame: dropGeo.frame(in: .global),
                                    onDragUpdated: { paneID, point in
                                        guard canDropPaneToNewTab?(paneID) ?? true else {
                                            clearPaneTabDropState()
                                            return false
                                        }
                                        paneTabDropGlobalX = point.x
                                        return true
                                    },
                                    onDragExited: clearPaneTabDropState,
                                    onDrop: { paneID, _ in
                                        let slot = paneTabDropInsertionSlot
                                        clearPaneTabDropState()
                                        guard canDropPaneToNewTab?(paneID) ?? true,
                                              let slot else { return false }
                                        onPaneMoveToNewTabAtSlot?(paneID, slot)
                                        return true
                                    }
                                )
                            }
                            .frame(height: combinedChromeHeight)
                        }
                    } else if windowSession.showSidebar, titlebarInset > 0 {
                        Color.clear
                            .frame(height: combinedChromeHeight)
                            .frame(maxWidth: .infinity)
                            .frosttyChromePanelBackground(style: FrosttyChromeAppearance.tabBarPanelStyle)
                    }

                    ZStack {
                        TerminalContainerRepresentable(splitContainerView: splitContainerView)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if markdownPreviewSession.isPresented {
                            MarkdownPreviewOverlayView(previewSession: markdownPreviewSession)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                if isPaneResizeMode {
                    ResizeModeToast()
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .animation(.easeInOut(duration: 0.2), value: windowSession.showSidebar)
        .animation(.easeInOut(duration: 0.15), value: isPaneResizeMode)
        .animation(.easeInOut(duration: 0.18), value: markdownPreviewSession.isPresented)
        .font(GhosttyUIFonts.font(textStyle: .body))
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigChange)) { _ in
            chromeAppearanceTick &+= 1
        }
    }

    private func clampedSidebarWidth(_ width: CGFloat) -> CGFloat {
        max(WindowSession.minSidebarWidth, min(WindowSession.maxSidebarWidth, width))
    }

    private func clearPaneTabDropState() {
        paneTabDropGlobalX = nil
        paneTabDropInsertionSlot = nil
    }
}

private struct ResizeModeToast: View {
    @State private var chromeAppearanceTick: UInt = 0

    var body: some View {
        let _ = chromeAppearanceTick
        Text("Resize Mode")
            .font(GhosttyUIFonts.font(size: 13, weight: .semibold))
            .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            FrosttyHUDChipBackground(cornerRadius: 12, showAccentStroke: true)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
        }
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigChange)) { _ in
            chromeAppearanceTick &+= 1
        }
    }
}

// MARK: - TerminalContainerRepresentable

/// Wraps the AppKit SplitContainerView for embedding in SwiftUI.
struct TerminalContainerRepresentable: NSViewRepresentable {
    let splitContainerView: SplitContainerView

    func makeNSView(context: Context) -> NSView {
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = NSColor.clear.cgColor
        splitContainerView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(splitContainerView)
        NSLayoutConstraint.activate([
            splitContainerView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            splitContainerView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            splitContainerView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            splitContainerView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.wantsLayer = true
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        if splitContainerView.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            splitContainerView.translatesAutoresizingMaskIntoConstraints = false
            nsView.addSubview(splitContainerView)
            NSLayoutConstraint.activate([
                splitContainerView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
                splitContainerView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor),
                splitContainerView.topAnchor.constraint(equalTo: nsView.topAnchor),
                splitContainerView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
            ])
        }
    }
}

struct PaneDragDropTargetRepresentable: NSViewRepresentable {
    let globalFrame: CGRect
    let onDragUpdated: (UUID, CGPoint) -> Bool
    let onDragExited: () -> Void
    let onDrop: (UUID, CGPoint) -> Bool

    func makeNSView(context: Context) -> PaneDragDropTargetView {
        let view = PaneDragDropTargetView()
        view.registerForDraggedTypes([.frosttyPaneID])
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: PaneDragDropTargetView, context: Context) {
        nsView.globalFrame = globalFrame
        nsView.onDragUpdated = onDragUpdated
        nsView.onDragExited = onDragExited
        nsView.onDrop = onDrop
    }
}

@MainActor
final class PaneDragDropTargetView: NSView {
    var globalFrame: CGRect = .zero
    var onDragUpdated: ((UUID, CGPoint) -> Bool)?
    var onDragExited: (() -> Void)?
    var onDrop: ((UUID, CGPoint) -> Bool)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let paneID = draggedPaneID(from: sender.draggingPasteboard) else { return [] }
        let accepted = onDragUpdated?(paneID, globalLocation(from: sender)) ?? true
        guard accepted else {
            onDragExited?()
            return []
        }
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let paneID = draggedPaneID(from: sender.draggingPasteboard) else { return [] }
        let accepted = onDragUpdated?(paneID, globalLocation(from: sender)) ?? true
        guard accepted else {
            onDragExited?()
            return []
        }
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggedPaneID(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let paneID = draggedPaneID(from: sender.draggingPasteboard) else { return false }
        return onDrop?(paneID, globalLocation(from: sender)) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onDragExited?()
    }

    private func globalLocation(from sender: any NSDraggingInfo) -> CGPoint {
        let localPoint = convert(sender.draggingLocation, from: nil)
        return CGPoint(
            x: globalFrame.minX + localPoint.x,
            y: globalFrame.minY + localPoint.y
        )
    }

    private func draggedPaneID(from pasteboard: NSPasteboard) -> UUID? {
        guard let rawValue = pasteboard.string(forType: .frosttyPaneID) else { return nil }
        return UUID(uuidString: rawValue)
    }
}
