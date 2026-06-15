import AppKit

/// Stable identity for routing the same key event through multiple handlers.
///
/// Do not use `NSEvent.eventNumber` here. WebKit re-dispatches key events that reject
/// `eventNumber` and will raise `NSInternalInconsistencyException`.
struct KeyEventIdentity: Equatable, Hashable {
    let timestamp: TimeInterval
    let windowNumber: Int
    let keyCode: UInt16
    let modifiers: UInt
    let isARepeat: Bool

    init(_ event: NSEvent) {
        timestamp = event.timestamp
        windowNumber = event.windowNumber
        keyCode = event.keyCode
        let relevantMods: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        modifiers = event.modifierFlags.intersection(relevantMods).rawValue
        isARepeat = event.isARepeat
    }
}
