// SearchBarView.swift
// Frostty
//
// SwiftUI-backed overlay for scrollback search. Designed to mirror the
// UX of Ghostty's search overlay: a rounded text field with an inline
// result count, prev / next / close buttons, and corner-snap dragging.
//
// The view is hosted in AppKit (NSHostingView) so the existing
// SurfaceScrollView can keep its NSView hierarchy unchanged.

import AppKit
import Combine
import SwiftUI

// MARK: - Search state

/// Mutable state shared between the SwiftUI overlay and the AppKit host.
@MainActor
final class SearchBarState: ObservableObject {
    @Published var needle: String = ""
    @Published var total: Int? = nil
    @Published var selected: Int? = nil
    /// Mirror of the SwiftUI `@FocusState` for the search text field.
    /// Read from the AppKit side (`SearchBarView`) to decide how Escape
    /// should be handled.
    @Published var fieldFocused: Bool = false
}

// MARK: - AppKit host

/// AppKit host for the SwiftUI search overlay. Keeps the public API used by
/// `SurfaceScrollView` (`focusSearchField`, `setSearchText`, `resetSearchState`,
/// `updateTotal`, `updateSelected`) and routes user input back through
/// `GhosttySurfaceController.performAction`.
@MainActor
final class SearchBarView: NSView {

    /// Surface controller used to dispatch `search:`, `navigate_search:*`,
    /// and `end_search` binding actions.
    weak var sender: GhosttySurfaceController?

    /// Invoked when Escape is pressed while the search field is focused.
    /// Owner should hand first-responder back to the terminal surface so a
    /// subsequent Escape can dismiss the overlay entirely.
    var onEscapeToTerminal: (() -> Void)?

    /// Last needle that we successfully submitted as a `search:` action.
    /// `SurfaceScrollView` consults this when the bar is re-opened so it can
    /// skip re-submitting an identical query.
    var lastSubmittedQuery: String = ""

    private let state = SearchBarState()
    private var hostingView: NSHostingView<SearchBarOverlay>!
    private var needleCancellable: AnyCancellable?
    private var escapeMonitor: Any?

    /// Set to true while we mutate `state.needle` programmatically so the
    /// Combine pipeline can ignore the change (avoids echoing back through
    /// `search:` when libghostty seeded the needle).
    private var suppressNeedlePublish = false

    // MARK: Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        // SurfaceScrollView positions us by setting `frame` directly, so keep
        // translatesAutoresizingMaskIntoConstraints at its default (true) and
        // rely on autoresizingMask to follow the parent if `layout()` is
        // skipped between resizes.
        autoresizingMask = [.width, .height]

        let overlay = SearchBarOverlay(
            state: state,
            onSubmit: { [weak self] backwards in
                self?.navigate(backwards: backwards)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        let host = NSHostingView(rootView: overlay)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.hostingView = host

        // Debounce only very short needles to avoid running expensive searches
        // for every keystroke; once the user has typed >=3 chars we forward
        // immediately so result counts stay snappy.
        needleCancellable = state.$needle
            .removeDuplicates()
            .map { [weak self] needle -> AnyPublisher<String, Never> in
                guard let self else { return Just(needle).eraseToAnyPublisher() }
                if self.suppressNeedlePublish {
                    return Empty().eraseToAnyPublisher()
                }
                if needle.isEmpty || needle.count >= 3 {
                    return Just(needle).eraseToAnyPublisher()
                }
                return Just(needle)
                    .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] needle in
                self?.submitSearch(needle: needle)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
        }
    }

    // MARK: Escape handling

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installEscapeMonitor()
        } else {
            removeEscapeMonitor()
        }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    private func removeEscapeMonitor() {
        if let m = escapeMonitor {
            NSEvent.removeMonitor(m)
            escapeMonitor = nil
        }
    }

    /// Intercepts unmodified Escape while the bar is visible. First press
    /// hands first-responder back to the terminal; subsequent presses
    /// (when the field no longer holds focus) dismiss the overlay.
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53,
              event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
        else {
            return event
        }
        guard let window = self.window,
              event.window === window,
              window.isKeyWindow
        else {
            return event
        }

        let firstResponder = window.firstResponder
        let surfaceView = sender?.surfaceView

        // Second press: terminal already has focus → dismiss the overlay.
        if let surfaceView, firstResponder === surfaceView {
            _ = sender?.performAction("end_search")
            return nil
        }

        // First press: search field has focus → punt focus to the terminal
        // but keep the overlay visible. We accept either signal that the
        // field is focused:
        //   1. SwiftUI `@FocusState` mirrored into `state.fieldFocused`.
        //   2. AppKit's field editor whose delegate lives in our subtree
        //      (covers cases where SwiftUI's focus binding doesn't fire
        //      reliably inside NSHostingView).
        if isFieldFocused(firstResponder: firstResponder) {
            onEscapeToTerminal?()
            return nil
        }

        return event
    }

    private func isFieldFocused(firstResponder: NSResponder?) -> Bool {
        if state.fieldFocused { return true }
        if let editor = firstResponder as? NSText,
           let delegate = editor.delegate as? NSView,
           delegate.isDescendant(of: hostingView) {
            return true
        }
        return false
    }

    // MARK: Hit testing

    /// Only intercept clicks that land on the actual chrome of the overlay.
    /// The hosting view fills the entire surface, but only the inner search
    /// bar (and its buttons) should consume hit events — everything else
    /// must fall through to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let result = super.hitTest(point) else { return nil }
        return result === self ? nil : result
    }

    // MARK: Public API used by SurfaceScrollView

    func focusSearchField() {
        // Defer to the next runloop tick so the SwiftUI focus state has
        // settled into the view hierarchy.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .frosttySearchBarFocusRequested,
                object: self.state
            )
        }
    }

    func setSearchText(_ text: String) {
        suppressNeedlePublish = true
        state.needle = text
        suppressNeedlePublish = false
    }

    func resetSearchState() {
        state.total = nil
        state.selected = nil
    }

    func updateTotal(_ total: Int) {
        // libghostty sends the underlying `ssize_t`; a negative value is the
        // sentinel for "no value yet" (e.g. before a search has executed or
        // after it has been cleared). Map that back onto the optional our
        // SwiftUI counter expects.
        state.total = total >= 0 ? total : nil
    }

    func updateSelected(_ selected: Int) {
        // Same sentinel convention as `updateTotal`: negative means "no
        // current selection" — i.e. the user hasn't navigated into a hit yet.
        state.selected = selected >= 0 ? selected : nil
    }

    // MARK: Routing

    private func submitSearch(needle: String) {
        lastSubmittedQuery = needle
        let action = "search:\(needle)"
        _ = sender?.performAction(action)
    }

    private func navigate(backwards: Bool) {
        let action = backwards ? "navigate_search:previous" : "navigate_search:next"
        _ = sender?.performAction(action)
    }

    private func close() {
        _ = sender?.performAction("end_search")
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by `SearchBarView.focusSearchField()`; the SwiftUI overlay
    /// listens and pushes focus back into its text field.
    static let frosttySearchBarFocusRequested = Notification.Name(
        "com.frostty.searchBar.focusRequested"
    )
}

// MARK: - SwiftUI overlay

/// The full-surface overlay. Positions the search bar at one of four corners
/// with corner-snap drag handling, and renders the bar itself.
struct SearchBarOverlay: View {
    @ObservedObject var state: SearchBarState
    let onSubmit: (_ backwards: Bool) -> Void
    let onClose: () -> Void

    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @State private var chromeAppearanceTick: UInt = 0

    @FocusState private var focused: Bool

    private let outerPadding: CGFloat = 8

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight

        var alignment: Alignment {
            switch self {
            case .topLeft: return .topLeading
            case .topRight: return .topTrailing
            case .bottomLeft: return .bottomLeading
            case .bottomRight: return .bottomTrailing
            }
        }
    }

    var body: some View {
        let _ = chromeAppearanceTick
        GeometryReader { geo in
            searchBar
                .background(measureBar)
                .padding(outerPadding)
                .offset(dragOffset)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: corner.alignment
                )
                .gesture(dragGesture(in: geo.size))
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigChange)) { _ in
            chromeAppearanceTick &+= 1
        }
    }

    // MARK: Bar chrome

    private var searchBar: some View {
        HStack(spacing: 4) {
            field
            navButton(systemName: "chevron.up") { onSubmit(false) }
            navButton(systemName: "chevron.down") { onSubmit(true) }
            navButton(systemName: "xmark") { onClose() }
        }
        .padding(8)
        .background {
            FrosttyHUDChipBackground(cornerRadius: 8)
        }
        .shadow(color: .black.opacity(FrosttyChromeAppearance.usesGlassBackground ? 0.2 : 0.15), radius: 4)
        .onAppear { focused = true }
        .onReceive(
            NotificationCenter.default.publisher(for: .frosttySearchBarFocusRequested)
        ) { note in
            guard (note.object as? SearchBarState) === state else { return }
            focused = true
        }
    }

    private var field: some View {
        TextField("Search", text: $state.needle)
            .textFieldStyle(.plain)
            .focused($focused)
            .frame(width: 180)
            .padding(.leading, 8)
            .padding(.trailing, 50)
            .padding(.vertical, 6)
            .background {
                FrosttyHUDFieldInsetBackground(cornerRadius: 6)
            }
            .overlay(alignment: .trailing) { counter.padding(.trailing, 8) }
            .onSubmit { onSubmit(NSEvent.modifierFlags.contains(.shift)) }
            .onKeyPress(.return, phases: [.down]) { press in
                onSubmit(press.modifiers.contains(.shift))
                return .handled
            }
            // Escape handling lives on the AppKit side (`SearchBarView`)
            // via an NSEvent local monitor — `.onExitCommand` is unreliable
            // for SwiftUI text fields hosted inside `NSHostingView`.
            .onChange(of: focused) { _, newValue in
                state.fieldFocused = newValue
            }
    }

    @ViewBuilder
    private var counter: some View {
        // Hidden entirely when the user hasn't typed anything yet.
        if !state.needle.isEmpty {
            Text(counterText)
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    /// Formats the inline result indicator.
    ///
    /// Display rules:
    /// - results pending (`total == nil`): `-/-`
    /// - no matches (`total == 0`): `-/0`
    /// - matches but nothing navigated to yet: `-/<total>`
    /// - actively navigated: `<selected+1>/<total>`
    private var counterText: String {
        guard let total = state.total else { return "-/-" }
        if total == 0 { return "-/0" }
        if let selected = state.selected {
            return "\(selected + 1)/\(total)"
        }
        return "-/\(total)"
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(SearchBarButtonStyle())
    }

    // MARK: Drag / corner snap

    private var measureBar: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { barSize = geo.size }
                .onChange(of: geo.size) { _, newValue in barSize = newValue }
        }
    }

    private func dragGesture(in container: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let anchor = anchorPoint(for: corner, in: container)
                let endpoint = CGPoint(
                    x: anchor.x + value.translation.width,
                    y: anchor.y + value.translation.height
                )
                let next = nearestCorner(to: endpoint, in: container)
                withAnimation(.easeOut(duration: 0.18)) {
                    corner = next
                    dragOffset = .zero
                }
            }
    }

    /// Bar-center coordinate (inside `container`) when seated at `corner`.
    private func anchorPoint(for corner: Corner, in container: CGSize) -> CGPoint {
        let halfW = barSize.width / 2 + outerPadding
        let halfH = barSize.height / 2 + outerPadding
        switch corner {
        case .topLeft:
            return CGPoint(x: halfW, y: halfH)
        case .topRight:
            return CGPoint(x: container.width - halfW, y: halfH)
        case .bottomLeft:
            return CGPoint(x: halfW, y: container.height - halfH)
        case .bottomRight:
            return CGPoint(x: container.width - halfW, y: container.height - halfH)
        }
    }

    private func nearestCorner(to point: CGPoint, in container: CGSize) -> Corner {
        let leftHalf = point.x < container.width / 2
        let topHalf = point.y < container.height / 2
        switch (leftHalf, topHalf) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}

// MARK: - Button style

/// Icon button with hover / press tinting matching the search bar chrome.
private struct SearchBarButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let active = hovered || configuration.isPressed
        configuration.label
            .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 2)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
            )
            .onHover { hovered = $0 }
    }

    private func fillColor(isPressed: Bool) -> Color {
        if FrosttyChromeAppearance.usesGlassBackground {
            return Color(
                nsColor: FrosttyChromeAppearance.hudButtonHighlightTint(
                    isPressed: isPressed,
                    isHovering: hovered
                )
            )
        }
        if isPressed { return Color.primary.opacity(0.2) }
        if hovered { return Color.primary.opacity(0.1) }
        return Color.clear
    }
}
