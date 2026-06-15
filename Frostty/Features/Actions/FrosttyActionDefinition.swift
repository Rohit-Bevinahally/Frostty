import Foundation

enum FrosttyActionParamKind: Sendable, Equatable {
    case string
    case boolean
}

struct FrosttyActionParamDefinition: Sendable, Equatable {
    let name: String
    let kind: FrosttyActionParamKind
    /// When set, this parameter may be supplied positionally at this index.
    let positionalIndex: Int?
    let isOptional: Bool
    let help: String
}

struct FrosttyActionDefinition: Sendable, Equatable {
    let name: String
    let summary: String
    let params: [FrosttyActionParamDefinition]

    func usageLines() -> [String] {
        var lines = ["Frostty +\(name) — \(summary)", ""]
        if params.isEmpty {
            lines.append("No parameters.")
            return lines
        }

        lines.append("Parameters:")
        for param in params {
            let requiredLabel = param.isOptional ? "optional" : "required"
            let positionalLabel = param.positionalIndex.map { "positional \($0)" } ?? "named only"
            let kindLabel = param.kind == .boolean ? "flag" : "string"
            lines.append("  --\(param.name) (\(requiredLabel), \(positionalLabel), \(kindLabel)): \(param.help)")
        }
        return lines
    }
}

struct FrosttyActionInvocation: Sendable, Equatable {
    let action: String
    let args: [String: String]
}

enum FrosttyActionParseError: Error, Equatable, LocalizedError {
    case missingAction
    case invalidActionToken(String)
    case unknownAction(String)
    case unknownFlag(String, action: String)
    case missingValue(String)
    case duplicateFlag(String)
    case unexpectedPositional(String, action: String)
    case missingRequired(String, action: String)

    var errorDescription: String? {
        switch self {
        case .missingAction:
            return "Missing action. Usage: Frostty +action_name [args]"
        case .invalidActionToken(let token):
            return "Invalid action token \"\(token)\". Actions must start with '+'."
        case .unknownAction(let name):
            return "Unknown action \"\(name)\"."
        case .unknownFlag(let flag, let action):
            return "Unknown flag \"\(flag)\" for action \"\(action)\"."
        case .missingValue(let flag):
            return "Flag \"\(flag)\" requires a value."
        case .duplicateFlag(let flag):
            return "Flag \"\(flag)\" was specified more than once."
        case .unexpectedPositional(let value, let action):
            return "Unexpected positional argument \"\(value)\" for action \"\(action)\"."
        case .missingRequired(let param, let action):
            return "Missing required parameter \"\(param)\" for action \"\(action)\"."
        }
    }
}
