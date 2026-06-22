// TerminalGlassEffect.swift
// Frostty
//
// Liquid glass backdrop for terminal panes on macOS 26+.

@preconcurrency import AppKit

@MainActor
enum TerminalGlassAppearance {
    struct Config: Equatable {
        let style: FrosttyGlassStyle
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat
    }

    static func derivedConfig(
        from configManager: GhosttyConfigManager,
        preferredBackgroundColor: NSColor? = nil,
        cornerRadius: CGFloat
    ) -> Config? {
        let blur = FrosttyConfig.shared.backgroundBlur
        let style: FrosttyGlassStyle
        switch blur {
        case .macosGlassRegular:
            style = .regular
        case .macosGlassClear:
            style = .clear
        default:
            return nil
        }

        return Config(
            style: style,
            backgroundColor: preferredBackgroundColor ?? configManager.backgroundColor,
            backgroundOpacity: configManager.backgroundOpacity,
            cornerRadius: cornerRadius
        )
    }

    static func tintedBackgroundColor(
        backgroundColor: NSColor,
        backgroundOpacity: Double
    ) -> NSColor {
        let opacity = min(max(backgroundOpacity, 0.001), 1.0)
        let base = backgroundColor.usingColorSpace(.sRGB) ?? backgroundColor
        return base.withAlphaComponent(opacity)
    }
}

enum FrosttyGlassStyle: Equatable {
    case regular
    case clear

    @available(macOS 26.0, *)
    var official: NSGlassEffectView.Style {
        switch self {
        case .regular:
            return .regular
        case .clear:
            return .clear
        }
    }
}

/// Glass sits below the terminal surface as a sibling, matching Ghostty.
/// The terminal renderer keeps its background transparent in glass mode so
/// `NSGlassEffectView.tintColor` shows through.
@available(macOS 26.0, *)
@MainActor
final class TerminalGlassView: NSView {
    private let glassEffectView = NSGlassEffectView()
    private let inactiveTintOverlay = NSView()
    private var glassTopConstraint: NSLayoutConstraint!
    private var glassLeadingConstraint: NSLayoutConstraint!
    private var themeTopOffset: CGFloat = 0
    private var chromeExclusionTop: CGFloat = 0
    private var chromeExclusionLeading: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup(topOffset: 0)
    }

    init(topOffset: CGFloat) {
        super.init(frame: .zero)
        setup(topOffset: topOffset)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(topOffset: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false

        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        glassTopConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        glassLeadingConstraint = glassEffectView.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: 0
        )
        themeTopOffset = topOffset

        inactiveTintOverlay.translatesAutoresizingMaskIntoConstraints = false
        inactiveTintOverlay.wantsLayer = true
        inactiveTintOverlay.alphaValue = 0
        addSubview(inactiveTintOverlay, positioned: .above, relativeTo: glassEffectView)

        NSLayoutConstraint.activate([
            glassTopConstraint,
            glassLeadingConstraint,
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),

            inactiveTintOverlay.topAnchor.constraint(equalTo: glassEffectView.topAnchor),
            inactiveTintOverlay.leadingAnchor.constraint(equalTo: glassEffectView.leadingAnchor),
            inactiveTintOverlay.bottomAnchor.constraint(equalTo: glassEffectView.bottomAnchor),
            inactiveTintOverlay.trailingAnchor.constraint(equalTo: glassEffectView.trailingAnchor),
        ])
    }

    func configure(_ config: TerminalGlassAppearance.Config, isKeyWindow: Bool) {
        // Match Ghostty's TerminalViewContainer.configure exactly.
        let tinted = config.backgroundColor.withAlphaComponent(config.backgroundOpacity)

        glassEffectView.style = config.style.official
        glassEffectView.tintColor = tinted

        updateKeyStatus(isKeyWindow, backgroundColor: config.backgroundColor)
        applyCornerMask(radius: config.cornerRadius)
    }

    private var cornerRadius: CGFloat = 0
    private var showSidebar: Bool = false

    func updateCornerMask(radius: CGFloat, showSidebar: Bool) {
        self.cornerRadius = radius
        self.showSidebar = showSidebar
        applyCornerMask(radius: radius)
    }

    private func applyCornerMask(radius: CGFloat) {
        guard radius > 0 else {
            glassEffectView.cornerRadius = 0
            glassEffectView.layer?.mask = nil
            glassEffectView.layer?.masksToBounds = false
            inactiveTintOverlay.layer?.mask = nil
            inactiveTintOverlay.layer?.masksToBounds = false
            return
        }

        glassEffectView.cornerRadius = 0
        glassEffectView.wantsLayer = true
        if let glassLayer = glassEffectView.layer {
            FrosttyTerminalCornerMask.apply(
                to: glassLayer,
                radius: radius,
                showSidebar: showSidebar,
                isFlipped: false
            )
        }

        inactiveTintOverlay.wantsLayer = true
        if let overlayLayer = inactiveTintOverlay.layer {
            FrosttyTerminalCornerMask.apply(
                to: overlayLayer,
                radius: radius,
                showSidebar: showSidebar,
                isFlipped: false
            )
        }
    }

    override func layout() {
        super.layout()
        if cornerRadius > 0 {
            applyCornerMask(radius: cornerRadius)
        }
    }

    func updateTopInset(_ offset: CGFloat) {
        themeTopOffset = offset
        applyGlassFrameConstraints()
    }

    /// Excludes SwiftUI chrome bands from window-level terminal glass so they show wallpaper.
    func updateChromeExclusion(top: CGFloat, leading: CGFloat) {
        chromeExclusionTop = top
        chromeExclusionLeading = leading
        applyGlassFrameConstraints()
    }

    private func applyGlassFrameConstraints() {
        glassTopConstraint.constant = chromeExclusionTop + themeTopOffset
        glassLeadingConstraint.constant = chromeExclusionLeading
    }

    func updateKeyStatus(_ isKeyWindow: Bool, backgroundColor: NSColor) {
        let tint = inactiveTint(for: backgroundColor)
        inactiveTintOverlay.layer?.backgroundColor = tint.color.cgColor
        inactiveTintOverlay.alphaValue = isKeyWindow ? 0 : tint.opacity
    }

    private func inactiveTint(for color: NSColor) -> (color: NSColor, opacity: CGFloat) {
        let isLight = color.frosttyIsLightColor
        let vibrant = color.frosttyAdjustingSaturation(by: 1.2)
        let overlayOpacity: CGFloat = isLight ? 0.35 : 0.85
        return (vibrant, overlayOpacity)
    }
}

/// Window-level glass container matching Ghostty's `TerminalViewContainer`.
/// `NSGlassEffectView.tintColor` only tints correctly when the glass view sits
/// directly below the window's primary content subtree.
@available(macOS 26.0, *)
@MainActor
final class TerminalWindowGlassContainer: NSView {
    private let contentView: NSView
    private var glassView: TerminalGlassView?
    private var derivedConfig: TerminalGlassAppearance.Config?
    private var pendingChromeExclusionTop: CGFloat = 0
    private var pendingChromeExclusionLeading: CGFloat = 0
    private var pendingShowSidebar: Bool = false

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }
        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    init(contentView: NSView) {
        self.contentView = contentView
        super.init(frame: .zero)
        addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyGlass(
        from configManager: GhosttyConfigManager,
        preferredBackgroundColor: NSColor?,
        isKeyWindow: Bool
    ) {
        let newValue = TerminalGlassAppearance.derivedConfig(
            from: configManager,
            preferredBackgroundColor: preferredBackgroundColor,
            cornerRadius: windowCornerRadius ?? 0
        )

        if newValue == derivedConfig {
            if let newValue {
                if glassView == nil {
                    updateGlassIfNeeded(isKeyWindow: isKeyWindow)
                } else {
                    glassView?.configure(newValue, isKeyWindow: isKeyWindow)
                }
            } else {
                updateGlassIfNeeded(isKeyWindow: isKeyWindow)
            }
            return
        }

        derivedConfig = newValue
        updateGlassIfNeeded(isKeyWindow: isKeyWindow)
    }

    func updateKeyStatus(_ isKeyWindow: Bool) {
        guard
            let glassView,
            let derivedConfig
        else {
            return
        }
        glassView.updateKeyStatus(isKeyWindow, backgroundColor: derivedConfig.backgroundColor)
    }

    /// Keeps terminal glass out of sidebar / tab bar chrome so those regions show wallpaper.
    func updateChromeExclusion(topHeight: CGFloat, leadingWidth: CGFloat, showSidebar: Bool) {
        pendingChromeExclusionTop = topHeight
        pendingChromeExclusionLeading = leadingWidth
        pendingShowSidebar = showSidebar
        glassView?.updateChromeExclusion(top: topHeight, leading: leadingWidth)
        glassView?.updateCornerMask(
            radius: windowCornerRadius ?? 0,
            showSidebar: showSidebar
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassIfNeeded(isKeyWindow: window?.isKeyWindow ?? true)
        updateGlassTopInsetIfNeeded()
    }

    override func layout() {
        super.layout()
        if derivedConfig != nil, glassView == nil {
            updateGlassIfNeeded(isKeyWindow: window?.isKeyWindow ?? true)
        }
        updateGlassTopInsetIfNeeded()
    }

    private func addGlassViewIfNeeded() -> TerminalGlassView? {
        if let existing = glassView {
            updateGlassTopInsetIfNeeded()
            existing.updateChromeExclusion(
                top: pendingChromeExclusionTop,
                leading: pendingChromeExclusionLeading
            )
            existing.updateCornerMask(
                radius: windowCornerRadius ?? 0,
                showSidebar: pendingShowSidebar
            )
            return existing
        }

        let topOffset = -(windowThemeFrameView?.safeAreaInsets.top ?? 0)
        let created = TerminalGlassView(topOffset: topOffset)
        addSubview(created, positioned: .below, relativeTo: contentView)
        NSLayoutConstraint.activate([
            created.topAnchor.constraint(equalTo: topAnchor),
            created.leadingAnchor.constraint(equalTo: leadingAnchor),
            created.bottomAnchor.constraint(equalTo: bottomAnchor),
            created.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassView = created
        created.updateChromeExclusion(
            top: pendingChromeExclusionTop,
            leading: pendingChromeExclusionLeading
        )
        created.updateCornerMask(
            radius: windowCornerRadius ?? 0,
            showSidebar: pendingShowSidebar
        )
        return created
    }

    private func updateGlassIfNeeded(isKeyWindow: Bool) {
        guard let derivedConfig else {
            glassView?.removeFromSuperview()
            glassView = nil
            return
        }
        guard let effectView = addGlassViewIfNeeded() else { return }
        effectView.configure(derivedConfig, isKeyWindow: isKeyWindow)
        effectView.updateCornerMask(
            radius: windowCornerRadius ?? 0,
            showSidebar: pendingShowSidebar
        )
    }

    private func updateGlassTopInsetIfNeeded() {
        guard let effectView = glassView, let themeFrameView = windowThemeFrameView else {
            return
        }
        // When chrome is excluded (tab bar / sidebar band), don't pull glass up into that region.
        let themeOffset = pendingChromeExclusionTop > 0
            ? 0
            : -themeFrameView.safeAreaInsets.top
        effectView.updateTopInset(themeOffset)
    }
}

private extension NSColor {
    var frosttyIsLightColor: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b) > 0.5
    }

    func frosttyAdjustingSaturation(by factor: CGFloat) -> NSColor {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        let hsbColor = usingColorSpace(.sRGB) ?? self
        hsbColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(
            hue: h,
            saturation: min(max(s * factor, 0), 1),
            brightness: b,
            alpha: a
        )
    }
}
