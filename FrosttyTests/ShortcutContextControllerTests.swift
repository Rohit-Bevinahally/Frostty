import AppKit
import XCTest
@testable import Frostty

@MainActor
final class ShortcutContextControllerTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        var value = false
    }
    func testBlocksFallbackWhenContextActive() {
        let controller = ShortcutContextController()
        XCTAssertFalse(controller.blocksFallback)

        let context = ShortcutContextController.Context(
            blockFallback: true,
            shortcuts: []
        )
        _ = controller.push(context)
        XCTAssertTrue(controller.blocksFallback)

        controller.pop(id: context.id)
        XCTAssertFalse(controller.blocksFallback)
    }

    func testLeaderKeyChordFiresOnSecondPress() {
        let controller = ShortcutContextController()
        let fired = Flag()
        let context = makeChordContext(
            chordKeyCode: 5,
            completionKeyCode: 5,
            onFire: { fired.value = true }
        )
        _ = controller.push(context)

        let first = keyEvent(keyCode: 5, timestamp: 0)
        let second = keyEvent(keyCode: 5, timestamp: 1)

        if case .consumed = controller.handleChordIfNeeded(first, suppressed: false) {
            XCTAssertFalse(fired.value)
        } else {
            XCTFail("Expected first g press to arm chord")
        }

        if case .matched = controller.handleChordIfNeeded(second, suppressed: false) {
            fired.value = true
        }
        XCTAssertTrue(fired.value)
    }

    func testLeaderKeyChordDoesNotCompleteOnSameEvent() {
        let controller = ShortcutContextController()
        let fired = Flag()
        let context = makeChordContext(
            chordKeyCode: 5,
            completionKeyCode: 5,
            onFire: { fired.value = true }
        )
        _ = controller.push(context)

        let event = keyEvent(keyCode: 5, timestamp: 0)

        if case .consumed = controller.handleChordIfNeeded(event, suppressed: false) {
            XCTAssertFalse(fired.value)
        } else {
            XCTFail("Expected first g press to arm chord")
        }
        if case .consumed = controller.handleChordIfNeeded(event, suppressed: false) {
            XCTAssertFalse(fired.value)
        } else {
            XCTFail("Expected same event to stay consumed")
        }
        XCTAssertFalse(fired.value)
    }

    func testLeaderKeyChordCompletesWithDifferentSecondKey() {
        let controller = ShortcutContextController()
        let fired = Flag()
        let context = ShortcutContextController.Context(
            blockFallback: true,
            shortcuts: [],
            chordShortcuts: [
                ShortcutManager.Shortcut(
                    modifiers: [],
                    keyCode: 40,
                    allowWhenSuppressed: false,
                    isEnabled: nil,
                    action: { fired.value = true }
                ),
            ],
            chordKeyCode: 5
        )
        _ = controller.push(context)

        if case .consumed = controller.handleChordIfNeeded(keyEvent(keyCode: 5, timestamp: 0), suppressed: false) {
            XCTAssertFalse(fired.value)
        } else {
            XCTFail("Expected g to arm chord")
        }
        if case .matched = controller.handleChordIfNeeded(keyEvent(keyCode: 40, timestamp: 1), suppressed: false) {
            fired.value = true
        }
        XCTAssertTrue(fired.value)
    }

    func testMatchEventCachesChordCompletionForSameEvent() {
        let controller = ShortcutContextController()
        let fired = Flag()
        let context = makeChordContext(
            chordKeyCode: 5,
            completionKeyCode: 5,
            onFire: { fired.value = true }
        )
        _ = controller.push(context)

        let first = keyEvent(keyCode: 5, timestamp: 0)
        let second = keyEvent(keyCode: 5, timestamp: 1)

        if case .chordConsumed = controller.matchEvent(for: first, suppressed: false) {
            XCTAssertFalse(fired.value)
        } else {
            XCTFail("Expected first g press to arm chord")
        }
        if case .chordConsumed = controller.matchEvent(for: first, suppressed: false) {
            XCTAssertFalse(fired.value)
        } else {
            XCTFail("Expected cached first g press to stay consumed")
        }

        if case .shortcut = controller.matchEvent(for: second, suppressed: false) {
            fired.value = true
        }
        XCTAssertTrue(fired.value)
        if case .shortcut = controller.matchEvent(for: second, suppressed: false) {
            XCTAssertTrue(fired.value)
        } else {
            XCTFail("Expected cached second g press to stay matched")
        }
    }

    func testMatchEventCacheIsScopedByKeyCode() {
        let controller = ShortcutContextController()
        let context = ShortcutContextController.Context(
            blockFallback: true,
            shortcuts: [
                ShortcutManager.Shortcut(
                    modifiers: [],
                    keyCode: 4,
                    allowWhenSuppressed: true,
                    isEnabled: nil,
                    action: {}
                ),
            ]
        )
        _ = controller.push(context)

        let hEvent = keyEvent(keyCode: 4, timestamp: 0)
        let aEvent = keyEvent(keyCode: 0, timestamp: 0)

        if case .shortcut = controller.matchEvent(for: hEvent, suppressed: true) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected h to match")
        }

        if case .none = controller.matchEvent(for: aEvent, suppressed: true) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected a to miss cache from h")
        }
    }

    func testChordIgnoredWhilePassesTextInput() {
        let controller = ShortcutContextController()
        let fired = Flag()
        let preview = makeChordContext(
            chordKeyCode: 5,
            completionKeyCode: 5,
            onFire: { fired.value = true }
        )
        let typing = ShortcutContextController.Context(
            blockFallback: true,
            passesTextInput: true,
            shortcuts: []
        )
        _ = controller.push(preview)
        _ = controller.push(typing)

        if case .none = controller.matchEvent(for: keyEvent(keyCode: 5, timestamp: 0), suppressed: true) {
            XCTAssertFalse(fired.value)
        } else {
            XCTFail("Expected g to pass through while typing")
        }
    }

    private func makeChordContext(
        chordKeyCode: UInt16,
        completionKeyCode: UInt16,
        onFire: @escaping @Sendable () -> Void
    ) -> ShortcutContextController.Context {
        ShortcutContextController.Context(
            blockFallback: true,
            shortcuts: [],
            chordShortcuts: [
                ShortcutManager.Shortcut(
                    modifiers: [],
                    keyCode: completionKeyCode,
                    allowWhenSuppressed: false,
                    isEnabled: nil,
                    action: onFire
                ),
            ],
            chordKeyCode: chordKeyCode
        )
    }

    private func keyEvent(keyCode: UInt16, timestamp: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
