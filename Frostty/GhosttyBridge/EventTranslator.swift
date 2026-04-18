// EventTranslator.swift
// Frostty
//
// Converts NSEvent to ghostty input structs.

@preconcurrency import AppKit
import GhosttyKit

// MARK: - EventTranslator

enum EventTranslator {

    // MARK: - Key Events

    static func translateKeyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)

        keyEvent.text = nil
        keyEvent.composing = false

        keyEvent.mods = translateModifiers(event.modifierFlags)

        let effectiveMods = translationMods ?? event.modifierFlags
        keyEvent.consumed_mods = translateModifiers(
            effectiveMods.subtracting([.control, .command])
        )

        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }

        return keyEvent
    }

    // MARK: - Modifier Translation

    static func translateModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.contains(.numericPad) { mods |= GHOSTTY_MODS_NUM.rawValue }

        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    static func modifierFlags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: - Mouse Button Translation

    static func translateMouseButton(_ event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    static func translateMouseButtonFromType(_ event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return GHOSTTY_MOUSE_LEFT
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return GHOSTTY_MOUSE_RIGHT
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return event.buttonNumber == 2 ? GHOSTTY_MOUSE_MIDDLE : GHOSTTY_MOUSE_UNKNOWN
        default:
            return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    // MARK: - Scroll Translation

    static func translateScrollMods(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        var mods: Int32 = 0

        if event.hasPreciseScrollingDeltas {
            mods |= 1
        }

        let momentum = translateMomentumPhase(event.momentumPhase)
        mods |= Int32(momentum.rawValue) << 1

        return ghostty_input_scroll_mods_t(mods)
    }

    static func translateMomentumPhase(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began:
            return GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary:
            return GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed:
            return GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended:
            return GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled:
            return GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin:
            return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default:
            return GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }

    // MARK: - Text Helpers

    static func ghosttyCharacters(from event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }

            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
