// FrosttyChromeGlass.swift
// Frostty
//
// NSGlassEffectView-backed chrome panels and capsules.

@preconcurrency import AppKit
import SwiftUI

// MARK: - Material

struct FrosttyChromeGlassMaterial: Equatable {
    var tint: NSColor
    var style: FrosttyGlassStyle

    init(tint: NSColor, style: FrosttyGlassStyle = .clear) {
        self.tint = tint
        self.style = style
    }
}

// MARK: - Panel style

enum FrosttyChromePanelStyle: Equatable {
    case opaque
    /// Frosted panel. `material.style` selects `.clear` vs `.regular` blur;
    /// `material.tint` alpha controls the color wash on top.
    case glassMaterial(FrosttyChromeGlassMaterial)
    /// No panel view — shows whatever is behind (wallpaper when window glass is excluded).
    case transparent
}

// MARK: - Panel (sidebar / tab bar chrome)

@available(macOS 26.0, *)
@MainActor
final class FrosttyChromeGlassPanelView: NSView {
    private let glassEffectView = NSGlassEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        NSLayoutConstraint.activate([
            glassEffectView.topAnchor.constraint(equalTo: topAnchor),
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(material: FrosttyChromeGlassMaterial) {
        glassEffectView.style = material.style.official
        glassEffectView.tintColor = material.tint
        glassEffectView.cornerRadius = 0
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@available(macOS 26.0, *)
struct FrosttyChromeGlassPanelRepresentable: NSViewRepresentable {
    let material: FrosttyChromeGlassMaterial

    func makeNSView(context: Context) -> FrosttyChromeGlassPanelView {
        let view = FrosttyChromeGlassPanelView()
        view.configure(material: material)
        return view
    }

    func updateNSView(_ nsView: FrosttyChromeGlassPanelView, context: Context) {
        nsView.configure(material: material)
    }
}

// MARK: - Capsule (tabs / workspace rows)

@available(macOS 26.0, *)
@MainActor
final class FrosttyChromeGlassCapsuleView: NSView {
    private let glassEffectView = NSGlassEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        NSLayoutConstraint.activate([
            glassEffectView.topAnchor.constraint(equalTo: topAnchor),
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(cornerRadius: CGFloat, material: FrosttyChromeGlassMaterial) {
        glassEffectView.style = material.style.official
        glassEffectView.tintColor = material.tint
        glassEffectView.cornerRadius = cornerRadius
    }
}

@available(macOS 26.0, *)
struct FrosttyChromeGlassCapsuleRepresentable: NSViewRepresentable {
    let cornerRadius: CGFloat
    let material: FrosttyChromeGlassMaterial

    func makeNSView(context: Context) -> FrosttyChromeGlassCapsuleView {
        let view = FrosttyChromeGlassCapsuleView()
        view.configure(cornerRadius: cornerRadius, material: material)
        return view
    }

    func updateNSView(_ nsView: FrosttyChromeGlassCapsuleView, context: Context) {
        nsView.configure(cornerRadius: cornerRadius, material: material)
    }
}

// MARK: - SwiftUI helpers

struct FrosttyChromePanelBackground: ViewModifier {
    let style: FrosttyChromePanelStyle

    func body(content: Content) -> some View {
        switch style {
        case .opaque:
            content.background(FrosttyChromeAppearance.opaqueChromeBackground)
        case .transparent:
            content.background(Color.clear)
        case .glassMaterial(let material):
            if #available(macOS 26.0, *) {
                content.background {
                    FrosttyChromeGlassPanelRepresentable(material: material)
                }
            } else {
                content.background(FrosttyChromeAppearance.opaqueChromeBackground)
            }
        }
    }
}

extension View {
    func frosttyChromePanelBackground(style: FrosttyChromePanelStyle) -> some View {
        modifier(FrosttyChromePanelBackground(style: style))
    }
}

struct FrosttyChromeCapsuleBackground: View {
    let cornerRadius: CGFloat
    let material: FrosttyChromeGlassMaterial
    var usesSolidFill: Bool = false

    var body: some View {
        if material.tint.alphaComponent <= 0.01 {
            EmptyView()
        } else if usesSolidFill {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: material.tint))
        } else if #available(macOS 26.0, *), FrosttyChromeAppearance.usesGlassBackground {
            FrosttyChromeGlassCapsuleRepresentable(
                cornerRadius: cornerRadius,
                material: material
            )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: material.tint))
        }
    }
}

// MARK: - HUD chips

struct FrosttyHUDChipBackground: View {
    let cornerRadius: CGFloat
    var showAccentStroke: Bool = false

    var body: some View {
        let material = FrosttyChromeAppearance.hudChipMaterial()
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            if #available(macOS 26.0, *), FrosttyChromeAppearance.usesGlassBackground {
                FrosttyChromeGlassCapsuleRepresentable(
                    cornerRadius: cornerRadius,
                    material: material
                )
            } else {
                shape.fill(Color(nsColor: material.tint))
            }

            if showAccentStroke {
                shape.stroke(FrosttyChromeAppearance.hudAccentStrokeColor, lineWidth: 1)
            }
        }
    }
}

struct FrosttyHUDFieldInsetBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        let material = FrosttyChromeAppearance.hudFieldInsetMaterial()
        if material.tint.alphaComponent <= 0.01 {
            EmptyView()
        } else if #available(macOS 26.0, *), FrosttyChromeAppearance.usesGlassBackground {
            FrosttyChromeGlassCapsuleRepresentable(
                cornerRadius: cornerRadius,
                material: material
            )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: material.tint))
        }
    }
}
