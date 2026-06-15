import Foundation

enum MarkdownPreviewAction {
    static let definition = FrosttyActionDefinition(
        name: "markdown_preview",
        summary: "Open or toggle the markdown preview overlay.",
        params: [
            FrosttyActionParamDefinition(
                name: "path",
                kind: .string,
                positionalIndex: 0,
                isOptional: true,
                help: "Path to a markdown file to preview."
            ),
        ]
    )

    @MainActor
    static func register(in registry: FrosttyActionRegistry, broker: FrosttyActionBroker) {
        registry.register(definition: definition) { invocation in
            guard let controller = broker.frontmostWindowController else {
                return .failure(message: "No Frostty window is available.")
            }

            let path = invocation.args["path"]
            let opened = controller.handleMarkdownPreviewAction(path: path, source: .frosttyAction)
            if opened {
                return .success(message: nil)
            }
            return .failure(message: "Unable to open markdown preview.")
        }
    }
}
