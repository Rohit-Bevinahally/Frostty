import AppKit

@MainActor
final class FrosttyActionBroker {
    weak var appDelegate: AppDelegate?

    var frontmostWindowController: FrosttyWindowController? {
        guard let appDelegate else { return nil }
        if let controller = NSApp.keyWindow?.windowController as? FrosttyWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? FrosttyWindowController {
            return controller
        }
        return appDelegate.allWindowControllers.last(where: { $0.window?.isVisible == true })
            ?? appDelegate.allWindowControllers.last
    }
}
