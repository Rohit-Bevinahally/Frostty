// ShortcutManager.swift
// Frostty
//
// Manages keyboard shortcuts with precedence rules.

import AppKit

@MainActor
class ShortcutManager {

    struct Shortcut {
        let modifiers: NSEvent.ModifierFlags
        let keyCode: UInt16
        let allowWhenSuppressed: Bool
        let isEnabled: (@MainActor () -> Bool)?
        let action: @MainActor () -> Void
    }

    private var shortcuts: [Shortcut] = []
    var isSuppressed: (@MainActor () -> Bool)?
    var contextController: ShortcutContextController?

    func register(
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        allowWhenSuppressed: Bool = false,
        isEnabled: (@MainActor () -> Bool)? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        shortcuts.append(Shortcut(
            modifiers: modifiers,
            keyCode: keyCode,
            allowWhenSuppressed: allowWhenSuppressed,
            isEnabled: isEnabled,
            action: action
        ))
    }

    /// Check if the event should be intercepted based on precedence rules.
    /// Returns false for IME composing, text fields, etc.
    func shouldIntercept(event: NSEvent, firstResponder: NSResponder?) -> Bool {
        switch keyDownDisposition(for: event, firstResponder: firstResponder) {
        case .handleShortcut, .consumeWithoutAction:
            return true
        case .passThrough:
            return false
        }
    }

    /// Try to handle the event. Returns true if a shortcut was executed.
    func handleEvent(_ event: NSEvent) -> Bool {
        handleKeyDown(event, firstResponder: nil)
    }

    /// Route a key-down event once. Returns true when the event is consumed.
    func handleKeyDown(_ event: NSEvent, firstResponder: NSResponder?) -> Bool {
        switch keyDownDisposition(for: event, firstResponder: firstResponder) {
        case .handleShortcut(let shortcut):
            shortcut.action()
            return true
        case .consumeWithoutAction:
            return true
        case .passThrough:
            return false
        }
    }

    private enum KeyDownDisposition {
        case handleShortcut(Shortcut)
        case consumeWithoutAction
        case passThrough
    }

    private func keyDownDisposition(
        for event: NSEvent,
        firstResponder: NSResponder?
    ) -> KeyDownDisposition {
        let suppressed = isSuppressed?() == true
        let contextMatch = resolveContextMatch(for: event, suppressed: suppressed)

        if suppressed || contextController?.activeContext != nil {
            switch contextMatch {
            case .shortcut(let shortcut):
                return .handleShortcut(shortcut)
            case .chordConsumed:
                return .consumeWithoutAction
            case .none:
                if contextController?.activeContext?.passesTextInput == true {
                    return .passThrough
                }
            }

            if suppressed {
                if let shortcut = resolveGlobalShortcut(for: event, suppressed: suppressed) {
                    return .handleShortcut(shortcut)
                }
                return .passThrough
            }
        }

        if suppressed {
            return .passThrough
        }

        if let textInput = firstResponder as? NSTextInputClient, textInput.hasMarkedText() {
            return .passThrough
        }

        if firstResponder is NSTextView || firstResponder is NSTextField {
            return .passThrough
        }

        if let shortcut = resolveGlobalShortcut(for: event, suppressed: suppressed) {
            return .handleShortcut(shortcut)
        }

        return .passThrough
    }

    private func resolveContextMatch(
        for event: NSEvent,
        suppressed: Bool
    ) -> ShortcutContextController.EventMatch {
        guard let contextController, suppressed || contextController.activeContext != nil else {
            return .none
        }
        return contextController.matchEvent(for: event, suppressed: suppressed)
    }

    private func resolveGlobalShortcut(for event: NSEvent, suppressed: Bool) -> Shortcut? {
        if contextController?.blocksFallback == true {
            return shortcuts.first { shortcut in
                matches(shortcut, event: event, suppressed: true) && shortcut.allowWhenSuppressed
            }
        }

        return shortcuts.first { shortcut in
            matches(shortcut, event: event, suppressed: suppressed)
        }
    }

    private func matches(_ shortcut: Shortcut, event: NSEvent, suppressed: Bool) -> Bool {
        let relevantMods: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        let eventMods = event.modifierFlags.intersection(relevantMods)
        let shortcutMods = shortcut.modifiers.intersection(relevantMods)
        guard shortcut.keyCode == event.keyCode, shortcutMods == eventMods else {
            return false
        }
        if suppressed && !shortcut.allowWhenSuppressed {
            return false
        }
        return shortcut.isEnabled?() ?? true
    }
}
