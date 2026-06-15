import Foundation

enum FrosttyActionResult: Sendable, Equatable {
    case success(message: String?)
    case failure(message: String)
}

@MainActor
final class FrosttyActionRegistry {
    typealias Handler = @MainActor (FrosttyActionInvocation) async -> FrosttyActionResult

    private var definitions: [String: FrosttyActionDefinition] = [:]
    private var handlers: [String: Handler] = [:]

    func register(definition: FrosttyActionDefinition, handler: @escaping Handler) {
        definitions[definition.name] = definition
        handlers[definition.name] = handler
    }

    func definition(named name: String) -> FrosttyActionDefinition? {
        definitions[name]
    }

    func actionNames() -> [String] {
        Array(definitions.keys)
    }

    func allDefinitions() -> [String: FrosttyActionDefinition] {
        definitions
    }

    func dispatch(_ invocation: FrosttyActionInvocation) async -> FrosttyActionResult {
        if invocation.action == "__help__" {
            return .success(message: FrosttyActionParser.globalHelp(definitions: definitions))
        }

        if invocation.args["__help__"] != nil {
            guard let definition = definitions[invocation.action] else {
                return .failure(message: "Unknown action \"\(invocation.action)\".")
            }
            return .success(message: FrosttyActionParser.actionHelp(definition: definition))
        }

        guard let handler = handlers[invocation.action] else {
            return .failure(message: "Unknown action \"\(invocation.action)\".")
        }

        return await handler(invocation)
    }
}
