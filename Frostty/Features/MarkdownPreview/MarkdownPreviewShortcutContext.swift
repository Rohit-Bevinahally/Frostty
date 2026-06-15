import AppKit

@MainActor
enum MarkdownPreviewShortcutContext {
  private static let scrollStep: Double = 120

  static func makeContext(
    previewSession: MarkdownPreviewSession,
    onDismiss: @escaping @MainActor () -> Void,
    onReload: @escaping @MainActor () -> Void,
    onOpenSearch: @escaping @MainActor () -> Void
  ) -> ShortcutContextController.Context {
    let browser = previewSession.browserController

    func deferAction(_ action: @escaping @MainActor () -> Void) {
      DispatchQueue.main.async {
        guard previewSession.isPresented else { return }
        action()
      }
    }

    let shortcuts: [ShortcutManager.Shortcut] = [
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 53,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: onDismiss
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 4,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction { browser.scrollPreviewBy(dx: -scrollStep, dy: 0) } }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 38,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction { browser.scrollPreviewBy(dx: 0, dy: scrollStep) } }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 40,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction { browser.scrollPreviewBy(dx: 0, dy: -scrollStep) } }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 37,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction { browser.scrollPreviewBy(dx: scrollStep, dy: 0) } }
      ),
      ShortcutManager.Shortcut(
        modifiers: [.shift],
        keyCode: 5,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction { browser.scrollPreviewToBottom() } }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 15,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction { onReload() } }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 44,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction { onOpenSearch() } }
      ),
    ]

    let chordShortcuts: [ShortcutManager.Shortcut] = [
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 5,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction { browser.scrollPreviewToTop() } }
      ),
    ]

    return ShortcutContextController.Context(
      blockFallback: true,
      shortcuts: shortcuts,
      chordShortcuts: chordShortcuts,
      chordKeyCode: 5
    )
  }
}
