// AppSession.swift
// Frostty
//
// Root application state: all open windows.

import Foundation

@MainActor
@Observable
final class AppSession {
    var windows: [WindowSession] = []

    func addWindow(_ windowSession: WindowSession) {
        windows.append(windowSession)
    }

    func removeWindow(id: UUID) {
        windows.removeAll { $0.id == id }
    }
}
