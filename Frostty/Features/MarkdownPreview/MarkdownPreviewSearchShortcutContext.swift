import AppKit

@MainActor
enum MarkdownPreviewSearchShortcutContext {
  static func makeTypingContext(
    previewSession: MarkdownPreviewSession,
    onCommit: @escaping @MainActor () -> Void,
    onDismiss: @escaping @MainActor () -> Void
  ) -> ShortcutContextController.Context {
    let shortcuts: [ShortcutManager.Shortcut] = [
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 53,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction(previewSession: previewSession, onCommit: onDismiss) }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 36,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction(previewSession: previewSession, onCommit: onCommit) }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 76,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction(previewSession: previewSession, onCommit: onCommit) }
      ),
    ]

    return ShortcutContextController.Context(
      blockFallback: true,
      passesTextInput: true,
      shortcuts: shortcuts
    )
  }

  static func makeNavigationContext(
    previewSession: MarkdownPreviewSession,
    onDismiss: @escaping @MainActor () -> Void,
    onResumeTyping: @escaping @MainActor () -> Void
  ) -> ShortcutContextController.Context {
    let browser = previewSession.browserController

    let shortcuts: [ShortcutManager.Shortcut] = [
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 53,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction(previewSession: previewSession, onCommit: onDismiss) }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 44,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction(previewSession: previewSession, onCommit: onResumeTyping) }
      ),
      ShortcutManager.Shortcut(
        modifiers: [],
        keyCode: 45,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction(previewSession: previewSession) { browser.runPreviewJavaScript("window.frosttyPreview?.findNext();") } }
      ),
      ShortcutManager.Shortcut(
        modifiers: [.shift],
        keyCode: 45,
        allowWhenSuppressed: true,
        isEnabled: nil,
        action: { deferAction(previewSession: previewSession) { browser.runPreviewJavaScript("window.frosttyPreview?.findPrevious();") } }
      ),
    ]

    return ShortcutContextController.Context(
      blockFallback: true,
      passesTextInput: false,
      shortcuts: shortcuts
    )
  }

  private static func deferAction(
    previewSession: MarkdownPreviewSession,
    onCommit: @escaping @MainActor () -> Void
  ) {
    DispatchQueue.main.async {
      guard previewSession.isPresented else { return }
      onCommit()
    }
  }
}
