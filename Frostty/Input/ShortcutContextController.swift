import AppKit

@MainActor
final class ShortcutContextController {
    struct Context {
        let id: UUID
        let blockFallback: Bool
        /// When true, printable keys pass through to the first responder unless they match a context shortcut.
        let passesTextInput: Bool
        let shortcuts: [ShortcutManager.Shortcut]
        /// Shortcuts that fire after `chordKeyCode` (leader) and a second key within the chord timeout (e.g. `gg`, `gk`).
        let chordShortcuts: [ShortcutManager.Shortcut]
        /// Leader key that arms chord completion (e.g. `g` for `gg` / `gk`).
        let chordKeyCode: UInt16?
        var onActivate: (() -> Void)?
        var onDeactivate: (() -> Void)?

        init(
            id: UUID = UUID(),
            blockFallback: Bool,
            passesTextInput: Bool = false,
            shortcuts: [ShortcutManager.Shortcut],
            chordShortcuts: [ShortcutManager.Shortcut] = [],
            chordKeyCode: UInt16? = nil,
            onActivate: (() -> Void)? = nil,
            onDeactivate: (() -> Void)? = nil
        ) {
            self.id = id
            self.blockFallback = blockFallback
            self.passesTextInput = passesTextInput
            self.shortcuts = shortcuts
            self.chordShortcuts = chordShortcuts
            self.chordKeyCode = chordKeyCode
            self.onActivate = onActivate
            self.onDeactivate = onDeactivate
        }
    }

    enum EventMatch {
        case none
        case shortcut(ShortcutManager.Shortcut)
        case chordConsumed
    }

    private var stack: [Context] = []
    private var pendingChordKeyCode: UInt16?
    private var pendingChordDeadline: ContinuousClock.Instant?
    private var chordArmEventIdentity: KeyEventIdentity?
    private var chordArmedContext: Context?
    private var cachedRouteKey: KeyEventIdentity?
    private var cachedMatchResult: EventMatch?
    private let chordTimeout: Duration = .milliseconds(400)

    var blocksFallback: Bool {
        stack.last?.blockFallback == true
    }

    var activeContext: Context? {
        stack.last
    }

    @discardableResult
    func push(_ context: Context) -> UUID {
        stack.append(context)
        context.onActivate?()
        return context.id
    }

    func pop(id: UUID) {
        guard let index = stack.lastIndex(where: { $0.id == id }) else { return }
        let removed = stack.remove(at: index)
        removed.onDeactivate?()
        clearRouteCache()
        if stack.isEmpty {
            clearChord()
        }
    }

    func popAll() {
        while let context = stack.popLast() {
            context.onDeactivate?()
        }
        clearChord()
        clearRouteCache()
    }

    enum ChordHandlingResult {
        case matched(ShortcutManager.Shortcut)
        case consumed
        case noMatch
    }

    func handleChordIfNeeded(_ event: NSEvent, suppressed: Bool) -> ChordHandlingResult {
        if stack.last?.passesTextInput == true {
            return .noMatch
        }

        let eventIdentity = KeyEventIdentity(event)
        let relevantMods: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        if !event.modifierFlags.intersection(relevantMods).isEmpty {
            if pendingChordKeyCode != nil {
                clearChord()
            }
            return .noMatch
        }

        if let pendingKey = pendingChordKeyCode, !chordIsExpired() {
            if let armedEventIdentity = chordArmEventIdentity,
               eventIdentity == armedEventIdentity {
                return .consumed
            }

            let completingContext = chordArmedContext
            clearChord()

            if let completingContext,
               let shortcut = completingContext.chordShortcuts.first(where: { matches($0, event: event, suppressed: suppressed) }) {
                return .matched(shortcut)
            }
            return .noMatch
        }

        if pendingChordKeyCode != nil, chordIsExpired() {
            clearChord()
        }

        guard let context = chordOwnerContext(matching: event),
              let chordKeyCode = context.chordKeyCode,
              event.keyCode == chordKeyCode else {
            return .noMatch
        }

        armChord(keyCode: chordKeyCode, context: context, eventIdentity: eventIdentity)
        return .consumed
    }

    func matchEvent(for event: NSEvent, suppressed: Bool) -> EventMatch {
        let routeKey = KeyEventIdentity(event)
        if cachedRouteKey == routeKey, let cachedMatchResult {
            return cachedMatchResult
        }

        let result = computeMatchEvent(for: event, suppressed: suppressed)
        cachedRouteKey = routeKey
        cachedMatchResult = result
        return result
    }

    func matchingShortcut(for event: NSEvent, suppressed: Bool) -> ShortcutManager.Shortcut? {
        if case .shortcut(let shortcut) = matchEvent(for: event, suppressed: suppressed) {
            return shortcut
        }
        return nil
    }

    func armChord(keyCode: UInt16, context: Context, eventIdentity: KeyEventIdentity) {
        pendingChordKeyCode = keyCode
        pendingChordDeadline = ContinuousClock.now + chordTimeout
        chordArmEventIdentity = eventIdentity
        chordArmedContext = context
    }

    func clearChord() {
        pendingChordKeyCode = nil
        pendingChordDeadline = nil
        chordArmEventIdentity = nil
        chordArmedContext = nil
    }

    func clearRouteCache() {
        cachedRouteKey = nil
        cachedMatchResult = nil
    }

    func chordIsExpired(now: ContinuousClock.Instant = .now) -> Bool {
        guard let pendingChordDeadline else { return true }
        return now > pendingChordDeadline
    }

    private func computeMatchEvent(for event: NSEvent, suppressed: Bool) -> EventMatch {
        guard let context = stack.last else { return .none }

        switch handleChordIfNeeded(event, suppressed: suppressed) {
        case .matched(let shortcut):
            return .shortcut(shortcut)
        case .consumed:
            return .chordConsumed
        case .noMatch:
            break
        }

        if let shortcut = context.shortcuts.first(where: { matches($0, event: event, suppressed: suppressed) }) {
            return .shortcut(shortcut)
        }

        return .none
    }

    private func chordOwnerContext(matching event: NSEvent) -> Context? {
        stack.last(where: { $0.chordKeyCode == event.keyCode })
    }

    private func matches(_ shortcut: ShortcutManager.Shortcut, event: NSEvent, suppressed: Bool) -> Bool {
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
