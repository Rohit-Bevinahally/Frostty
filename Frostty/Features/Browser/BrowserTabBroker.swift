import Foundation

@MainActor
final class BrowserTabBroker {
    weak var appDelegate: AppDelegate?

    func resolveTab(_ tabID: UUID?) -> BrowserTabController? {
        guard let appDelegate else { return nil }

        if let tabID {
            for windowController in appDelegate.allWindowControllers {
                for workspace in windowController.windowSession.workspaces {
                    for tab in workspace.tabs {
                        if let controller = tab.registry.browserController(for: tabID) {
                            return controller
                        }
                    }
                }
            }
            return nil
        }

        let keyWindowController = appDelegate.allWindowControllers.first { $0.window?.isKeyWindow == true }
            ?? appDelegate.allWindowControllers.first
        return keyWindowController?.activeBrowserControllerForExternal
    }

    func listTabs() -> [(id: UUID, url: String, title: String)] {
        guard let appDelegate else { return [] }

        var result: [(id: UUID, url: String, title: String)] = []
        for windowController in appDelegate.allWindowControllers {
            for workspace in windowController.windowSession.workspaces {
                for tab in workspace.tabs {
                    for browserID in tab.registry.browserPaneIDs() {
                        guard let controller = tab.registry.browserController(for: browserID) else { continue }
                        result.append((id: browserID, url: controller.url.absoluteString, title: controller.title))
                    }
                }
            }
        }

        return result
    }

    func createTab(url: URL) -> UUID? {
        guard let appDelegate else { return nil }
        let keyWindowController = appDelegate.allWindowControllers.first { $0.window?.isKeyWindow == true }
            ?? appDelegate.allWindowControllers.first
        return keyWindowController?.createBrowserTab(initialURL: url)
    }
}
