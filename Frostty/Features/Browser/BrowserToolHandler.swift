import Foundation

struct BrowserToolResult: Sendable {
    let text: String
    let isError: Bool
}

@MainActor
final class BrowserToolHandler {
    let broker: BrowserTabBroker

    init(broker: BrowserTabBroker) {
        self.broker = broker
    }

    static func isRestrictedForEval(url: String) -> Bool {
        let lowered = url.lowercased()
        let restrictedPaths = ["/login", "/auth", "/oauth", "/signin"]
        guard let urlObject = URL(string: lowered) else {
            return restrictedPaths.contains { lowered.contains($0) }
        }
        let path = urlObject.path.lowercased()
        return restrictedPaths.contains { path.contains($0) }
    }

    func handleTool(name: String, arguments: [String: Any]?) async -> BrowserToolResult {
        switch name {
        case "browser_open":
            return await handleOpen(arguments)
        case "browser_list":
            return handleList()
        case "browser_navigate":
            return await handleNavigate(arguments)
        case "browser_back":
            return await handleBack(arguments)
        case "browser_forward":
            return await handleForward(arguments)
        case "browser_reload":
            return await handleReload(arguments)
        case "browser_snapshot":
            return await handleSnapshot(arguments)
        case "browser_screenshot":
            return await handleScreenshot(arguments)
        case "browser_get_text":
            return await handleGetText(arguments)
        case "browser_get_html":
            return await handleGetHTML(arguments)
        case "browser_eval":
            return await handleEval(arguments)
        case "browser_click":
            return await handleClick(arguments)
        case "browser_fill":
            return await handleFill(arguments)
        case "browser_type":
            return await handleType(arguments)
        case "browser_press":
            return await handlePress(arguments)
        case "browser_select":
            return await handleSelect(arguments)
        case "browser_check":
            return await handleCheck(arguments)
        case "browser_uncheck":
            return await handleUncheck(arguments)
        case "browser_wait":
            return await handleWait(arguments)
        case "browser_get_attribute":
            return await handleGetAttribute(arguments)
        case "browser_get_links":
            return await handleGetLinks(arguments)
        case "browser_get_inputs":
            return await handleGetInputs(arguments)
        case "browser_is_visible":
            return await handleIsVisible(arguments)
        case "browser_hover":
            return await handleHover(arguments)
        case "browser_scroll":
            return await handleScroll(arguments)
        default:
            return BrowserToolResult(text: "Unknown browser tool: \(name)", isError: true)
        }
    }

    private func checkAuthRestriction(_ controller: BrowserTabController) -> BrowserToolResult? {
        let currentURL = controller.browserState.url.absoluteString
        guard Self.isRestrictedForEval(url: currentURL) else { return nil }
        return BrowserToolResult(
            text: "Interaction blocked on auth page: \(currentURL)",
            isError: true
        )
    }

    private func resolveTab(_ arguments: [String: Any]?) -> (controller: BrowserTabController?, error: BrowserToolResult?) {
        let tabIDString = arguments?["tab_id"] as? String
        let tabID = tabIDString.flatMap(UUID.init(uuidString:))

        guard let controller = broker.resolveTab(tabID) else {
            if let tabID {
                return (
                    nil,
                    BrowserToolResult(
                        text: BrowserAutomationError.tabNotFound(tabID).localizedDescription,
                        isError: true
                    )
                )
            }

            return (
                nil,
                BrowserToolResult(
                    text: BrowserAutomationError.noActiveBrowserTab.localizedDescription,
                    isError: true
                )
            )
        }

        return (controller, nil)
    }

    private func runJS(_ controller: BrowserTabController, _ script: String) async -> BrowserToolResult {
        do {
            let result = try await controller.evaluateJavaScript(script)
            let response = BrowserAutomation.parseResponse(result)
            if response.ok {
                return BrowserToolResult(text: response.value ?? "", isError: false)
            }
            return BrowserToolResult(text: response.error ?? "Unknown error", isError: true)
        } catch {
            return BrowserToolResult(
                text: "JavaScript evaluation failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func handleOpen(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let urlString = arguments?["url"] as? String,
              let url = URL(string: urlString) else {
            return BrowserToolResult(text: "Missing or invalid 'url' parameter", isError: true)
        }

        guard let tabID = broker.createTab(url: url) else {
            return BrowserToolResult(text: "Failed to create browser tab", isError: true)
        }

        return BrowserToolResult(text: "{\"tab_id\":\"\(tabID.uuidString)\"}", isError: false)
    }

    private func handleList() -> BrowserToolResult {
        let tabs = broker.listTabs()
        let tabDictionaries = tabs.map { tab in
            ["id": tab.id.uuidString, "url": tab.url, "title": tab.title]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: ["tabs": tabDictionaries]),
              let json = String(data: data, encoding: .utf8) else {
            return BrowserToolResult(text: "{\"tabs\":[]}", isError: false)
        }

        return BrowserToolResult(text: json, isError: false)
    }

    private func handleNavigate(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let urlString = arguments?["url"] as? String,
              let url = URL(string: urlString) else {
            return BrowserToolResult(text: "Missing or invalid 'url' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.loadURL(url)
        return BrowserToolResult(text: "Navigated to \(urlString)", isError: false)
    }

    private func handleBack(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.goBack()
        return BrowserToolResult(text: "Navigated back", isError: false)
    }

    private func handleForward(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.goForward()
        return BrowserToolResult(text: "Navigated forward", isError: false)
    }

    private func handleReload(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.reload()
        return BrowserToolResult(text: "Reloaded", isError: false)
    }

    private func handleSnapshot(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        controller.incrementSnapshotGeneration()
        return await runJS(controller, BrowserAutomation.snapshot())
    }

    private func handleScreenshot(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }

        do {
            let data = try await controller.takeScreenshot()
            let path = "/tmp/frostty-screenshot-\(UUID().uuidString).png"
            try data.write(to: URL(fileURLWithPath: path))
            return BrowserToolResult(text: "{\"path\":\"\(path)\"}", isError: false)
        } catch {
            return BrowserToolResult(
                text: "Screenshot failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    private func handleGetText(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        return await runJS(controller, BrowserAutomation.getText(selector: selector))
    }

    private func handleGetHTML(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        let maxLength = arguments?["max_length"] as? Int ?? 512000
        return await runJS(controller, BrowserAutomation.getHTML(selector: selector, maxLength: maxLength))
    }

    private func handleEval(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let code = arguments?["code"] as? String else {
            return BrowserToolResult(text: "Missing 'code' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        let currentURL = controller.browserState.url.absoluteString
        guard !Self.isRestrictedForEval(url: currentURL) else {
            return BrowserToolResult(
                text: BrowserAutomationError.restrictedPage(currentURL).localizedDescription,
                isError: true
            )
        }

        return await runJS(controller, BrowserAutomation.eval(code: code))
    }

    private func handleClick(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(controller, BrowserAutomation.click(selector: selector))
    }

    private func handleFill(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String,
              let value = arguments?["value"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' or 'value' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(controller, BrowserAutomation.fill(selector: selector, value: value))
    }

    private func handleType(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let text = arguments?["text"] as? String else {
            return BrowserToolResult(text: "Missing 'text' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(controller, BrowserAutomation.type(text: text))
    }

    private func handlePress(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let key = arguments?["key"] as? String else {
            return BrowserToolResult(text: "Missing 'key' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(controller, BrowserAutomation.press(key: key))
    }

    private func handleSelect(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String,
              let value = arguments?["value"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' or 'value' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(controller, BrowserAutomation.select(selector: selector, value: value))
    }

    private func handleCheck(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(controller, BrowserAutomation.check(selector: selector))
    }

    private func handleUncheck(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(controller, BrowserAutomation.uncheck(selector: selector))
    }

    private func handleWait(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let selector = arguments?["selector"] as? String
        let text = arguments?["text"] as? String
        let url = arguments?["url"] as? String
        let timeout = arguments?["timeout"] as? Int ?? 5000

        guard selector != nil || text != nil || url != nil else {
            return BrowserToolResult(
                text: "At least one of 'selector', 'text', or 'url' must be provided",
                isError: true
            )
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        return await runJS(controller, BrowserAutomation.wait(selector: selector, text: text, url: url, timeout: timeout))
    }

    private func handleGetAttribute(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }
        guard let attribute = arguments?["attribute"] as? String else {
            return BrowserToolResult(text: "Missing 'attribute' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        return await runJS(controller, BrowserAutomation.getAttribute(selector: selector, attribute: attribute))
    }

    private func handleGetLinks(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        let maxItems = arguments?["max_items"] as? Int ?? 100
        return await runJS(controller, BrowserAutomation.getLinks(maxItems: maxItems))
    }

    private func handleGetInputs(_ arguments: [String: Any]?) async -> BrowserToolResult {
        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        let maxItems = arguments?["max_items"] as? Int ?? 100
        return await runJS(controller, BrowserAutomation.getInputs(maxItems: maxItems))
    }

    private func handleIsVisible(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        return await runJS(controller, BrowserAutomation.isVisible(selector: selector))
    }

    private func handleHover(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let selector = arguments?["selector"] as? String else {
            return BrowserToolResult(text: "Missing 'selector' parameter", isError: true)
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(controller, BrowserAutomation.hover(selector: selector))
    }

    private func handleScroll(_ arguments: [String: Any]?) async -> BrowserToolResult {
        guard let direction = arguments?["direction"] as? String else {
            return BrowserToolResult(text: "Missing 'direction' parameter", isError: true)
        }

        let validDirections = ["up", "down", "left", "right"]
        guard validDirections.contains(direction) else {
            return BrowserToolResult(
                text: "Invalid 'direction': must be one of up, down, left, right",
                isError: true
            )
        }

        let amount: Int
        if let rawAmount = arguments?["amount"] as? Int {
            guard rawAmount > 0 else {
                return BrowserToolResult(text: "Invalid 'amount': must be greater than 0", isError: true)
            }
            amount = rawAmount
        } else {
            amount = 500
        }

        let resolved = resolveTab(arguments)
        guard let controller = resolved.controller else { return resolved.error! }
        if let restricted = checkAuthRestriction(controller) { return restricted }
        return await runJS(
            controller,
            BrowserAutomation.scroll(
                direction: direction,
                amount: amount,
                selector: arguments?["selector"] as? String
            )
        )
    }
}
