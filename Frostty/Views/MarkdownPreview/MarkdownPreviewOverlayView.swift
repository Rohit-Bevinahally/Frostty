import AppKit
import SwiftUI

struct MarkdownPreviewOverlayView: View {
    @Bindable var previewSession: MarkdownPreviewSession

    private var overlayBackgroundColor: Color {
        Color(nsColor: GhosttyAppController.shared.configManager.backgroundColor.withAlphaComponent(1.0))
    }

    var body: some View {
        ZStack {
            MarkdownPreviewBrowserRepresentable(
                browserView: previewSession.browserController.browserView,
                backgroundColor: GhosttyAppController.shared.configManager.backgroundColor.withAlphaComponent(1.0)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if previewSession.isRendering {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(overlayBackgroundColor)
                .overlay(
                    Rectangle()
                        .stroke(TokyoNight.activeBorderSwiftUIColor.opacity(0.34), lineWidth: 1)
                )
        )
        .transition(.opacity)
    }
}

private struct MarkdownPreviewBrowserRepresentable: NSViewRepresentable {
    let browserView: BrowserView
    let backgroundColor: NSColor

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = backgroundColor.cgColor
        browserView.frame = container.bounds
        browserView.autoresizingMask = [.width, .height]
        container.addSubview(browserView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.wantsLayer = true
        nsView.layer?.backgroundColor = backgroundColor.cgColor
        if browserView.superview !== nsView {
            browserView.removeFromSuperview()
            browserView.frame = nsView.bounds
            browserView.autoresizingMask = [.width, .height]
            nsView.addSubview(browserView)
        }
    }
}
