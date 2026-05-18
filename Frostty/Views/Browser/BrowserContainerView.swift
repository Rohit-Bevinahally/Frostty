import AppKit
import SwiftUI

struct BrowserContainerView: View {
    let controller: BrowserTabController
    let paneID: UUID

    @State private var appearanceTick: UInt = 0

    var body: some View {
        VStack(spacing: 0) {
            BrowserToolbarView(controller: controller, paneID: paneID, appearanceTick: appearanceTick)
                .zIndex(1)
                .environment(\.colorScheme, .dark)

            if let error = controller.browserState.lastError {
                ErrorBannerView(message: error)
            }

            BrowserWebViewRepresentable(browserView: controller.browserView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(GhosttyUIFonts.font(textStyle: .body))
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigChange)) { _ in
            appearanceTick &+= 1
        }
    }
}

private struct BrowserToolbarView: View {
    let controller: BrowserTabController
    let paneID: UUID
    let appearanceTick: UInt

    @State private var omnibarText: String = ""
    @FocusState private var addressBarFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: {
                controller.goBack()
            }) {
                Image(systemName: "chevron.left")
            }
            .disabled(!controller.browserState.canGoBack)

            Button(action: {
                controller.goForward()
            }) {
                Image(systemName: "chevron.right")
            }
            .disabled(!controller.browserState.canGoForward)

            Button(action: {
                controller.reload()
            }) {
                Image(systemName: "arrow.clockwise")
            }

            TextField("Search or enter address", text: $omnibarText)
                .textFieldStyle(.plain)
                .font(GhosttyUIFonts.font(size: 14, fallbackDesign: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .background(Color.white.opacity(0.12))
                .cornerRadius(4)
                .overlay {
                    if addressBarFocused {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(TokyoNight.activeBorderSwiftUIColor, lineWidth: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focused($addressBarFocused)
                .onSubmit {
                    navigateFromOmnibar()
                }
                .onExitCommand {
                    addressBarFocused = false
                    DispatchQueue.main.async {
                        _ = controller.focus(in: NSApp.keyWindow)
                    }
                }

            if controller.browserState.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onAppear {
            omnibarText = BrowserAddressResolution.omnibarDisplayString(for: controller.browserState.url)
        }
        .onChange(of: controller.browserState.url) { _, newValue in
            omnibarText = BrowserAddressResolution.omnibarDisplayString(for: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .frosttyFocusBrowserAddressBar)) { notification in
            guard let id = notification.userInfo?["paneID"] as? UUID, id == paneID else { return }
            addressBarFocused = true
            DispatchQueue.main.async {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private func navigateFromOmnibar() {
        let trimmed = omnibarText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            controller.loadURL(URL(string: "about:blank")!)
        } else {
            guard let url = BrowserAddressResolution.url(forUserInput: trimmed) else { return }
            controller.loadURL(url)
        }
        addressBarFocused = false
        DispatchQueue.main.async {
            _ = controller.focus(in: NSApp.keyWindow)
        }
    }
}

private struct ErrorBannerView: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(GhosttyUIFonts.font(size: 12))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.15))
    }
}

/// Lets the WKWebView stack composite with the window blur like terminal panes.
private final class BrowserWebViewContainerView: NSView {
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private struct BrowserWebViewRepresentable: NSViewRepresentable {
    let browserView: BrowserView

    func makeNSView(context: Context) -> NSView {
        let container = BrowserWebViewContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false
        browserView.frame = container.bounds
        browserView.autoresizingMask = [.width, .height]
        container.addSubview(browserView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.wantsLayer = true
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        nsView.layer?.isOpaque = false
        if browserView.superview !== nsView {
            browserView.removeFromSuperview()
            browserView.frame = nsView.bounds
            browserView.autoresizingMask = [.width, .height]
            nsView.addSubview(browserView)
        }
    }
}
