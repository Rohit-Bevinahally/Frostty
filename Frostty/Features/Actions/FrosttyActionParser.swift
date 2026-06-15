import Foundation

enum FrosttyActionParser {
    static func parse(argv: [String], definitions: [String: FrosttyActionDefinition]) throws -> FrosttyActionInvocation {
        guard !argv.isEmpty else {
            throw FrosttyActionParseError.missingAction
        }

        if argv == ["--help"] || argv == ["-h"] {
            return FrosttyActionInvocation(action: "__help__", args: [:])
        }

        let actionToken = argv[0]
        guard actionToken.hasPrefix("+") else {
            throw FrosttyActionParseError.invalidActionToken(actionToken)
        }

        let actionName = String(actionToken.dropFirst())
        guard !actionName.isEmpty else {
            throw FrosttyActionParseError.invalidActionToken(actionToken)
        }

        if argv.count == 2, (argv[1] == "--help" || argv[1] == "-h") {
            return FrosttyActionInvocation(action: actionName, args: ["__help__": "1"])
        }

        guard let definition = definitions[actionName] else {
            throw FrosttyActionParseError.unknownAction(actionName)
        }

        var namedValues: [String: String] = [:]
        var positionals: [String] = []
        var index = 1

        while index < argv.count {
            let token = argv[index]
            if token.hasPrefix("--") {
                let stripped = String(token.dropFirst(2))
                let parts = stripped.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let flagName = String(parts[0])
                guard let param = definition.params.first(where: { $0.name == flagName }) else {
                    throw FrosttyActionParseError.unknownFlag(flagName, action: actionName)
                }
                if namedValues[flagName] != nil {
                    throw FrosttyActionParseError.duplicateFlag(flagName)
                }

                switch param.kind {
                case .boolean:
                    if parts.count == 2 {
                        let raw = String(parts[1]).lowercased()
                        namedValues[flagName] = ["1", "true", "yes"].contains(raw) ? "1" : "0"
                    } else if index + 1 < argv.count, !argv[index + 1].hasPrefix("-") {
                        index += 1
                        let raw = argv[index].lowercased()
                        namedValues[flagName] = ["1", "true", "yes"].contains(raw) ? "1" : "0"
                    } else {
                        namedValues[flagName] = "1"
                    }
                case .string:
                    let value: String
                    if parts.count == 2 {
                        value = String(parts[1])
                    } else if index + 1 < argv.count, !argv[index + 1].hasPrefix("-") {
                        index += 1
                        value = argv[index]
                    } else {
                        throw FrosttyActionParseError.missingValue(flagName)
                    }
                    namedValues[flagName] = value
                }
            } else if token.hasPrefix("-") {
                throw FrosttyActionParseError.unknownFlag(token, action: actionName)
            } else {
                positionals.append(token)
            }
            index += 1
        }

        var resolved: [String: String] = namedValues
        let positionalParams = definition.params
            .filter { $0.positionalIndex != nil }
            .sorted { ($0.positionalIndex ?? 0) < ($1.positionalIndex ?? 0) }

        for (param, value) in zip(positionalParams, positionals) {
            if resolved[param.name] == nil {
                resolved[param.name] = value
            }
        }

        if positionals.count > positionalParams.count {
            let extra = positionals.dropFirst(positionalParams.count).joined(separator: " ")
            throw FrosttyActionParseError.unexpectedPositional(extra, action: actionName)
        }

        for param in definition.params where !param.isOptional {
            switch param.kind {
            case .boolean:
                if resolved[param.name] == nil {
                    throw FrosttyActionParseError.missingRequired(param.name, action: actionName)
                }
            case .string:
                guard let value = resolved[param.name], !value.isEmpty else {
                    throw FrosttyActionParseError.missingRequired(param.name, action: actionName)
                }
            }
        }

        return FrosttyActionInvocation(action: actionName, args: resolved)
    }

    static func globalHelp(definitions: [String: FrosttyActionDefinition]) -> String {
        var lines = [
            "Frostty actions",
            "",
            "Usage: Frostty +action_name [args]",
            "",
            "Actions:",
        ]
        for name in definitions.keys.sorted() {
            if let definition = definitions[name] {
                lines.append("  +\(name) — \(definition.summary)")
            }
        }
        lines.append("")
        lines.append("Run Frostty +action_name --help for action-specific usage.")
        return lines.joined(separator: "\n")
    }

    static func actionHelp(definition: FrosttyActionDefinition) -> String {
        definition.usageLines().joined(separator: "\n")
    }
}

/// Handles `Frostty +action` when the app binary is invoked from a shell.
/// Forwards to the loopback action server and exits before starting the GUI.
enum FrosttyCLIForwarder {
    private static let stateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/frostty/frostty.json")

    /// Returns `false` when the process should continue into the GUI.
    static func forwardActionIfPresent() -> Bool {
        let argv = Array(CommandLine.arguments.dropFirst())
        guard !argv.isEmpty else { return true }

        if argv[0] == "--help" || argv[0] == "-h" {
            if argv.count == 1 {
                print(localUsage)
                print("")
                print("Frostty must be running for action-specific help (Frostty +action --help).")
                exit(0)
            }
        } else if !argv[0].hasPrefix("+") {
            return true
        }

        guard FileManager.default.fileExists(atPath: stateFile.path) else {
            fputs("error: Frostty is not running (missing \(stateFile.path))\n", stderr)
            fputs("Start Frostty, then run: Frostty \(argv.joined(separator: " "))\n", stderr)
            exit(1)
        }

        guard let port = readPort() else {
            fputs("error: unable to read port from \(stateFile.path)\n", stderr)
            exit(1)
        }

        let payload = buildPayload(argv: argv)
        let exitCode = postAction(port: port, payload: payload)
        exit(exitCode)
    }

    private static let localUsage = """
    Usage: Frostty +action_name [args]

    Run Frostty --help or Frostty +action_name --help for more information.
    """

    private static func readPort() -> Int? {
        guard let data = try? Data(contentsOf: stateFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["port"] as? Int else {
            return nil
        }
        return port
    }

    private static func buildPayload(argv: [String]) -> [String: Any] {
        if argv == ["--help"] {
            return ["action": "__help__", "args": [:] as [String: String]]
        }
        if argv.count >= 2, argv[1] == "--help" || argv[1] == "-h" {
            return ["action": String(argv[0].dropFirst()), "args": ["__help__": "1"]]
        }

        let action = String(argv[0].dropFirst())
        var named: [String: String] = [:]
        var positionals: [String] = []
        var index = 1
        while index < argv.count {
            let token = argv[index]
            if token.hasPrefix("--") {
                let stripped = String(token.dropFirst(2))
                let parts = stripped.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0])
                if parts.count == 2 {
                    named[key] = String(parts[1])
                } else if index + 1 < argv.count, !argv[index + 1].hasPrefix("-") {
                    index += 1
                    named[key] = argv[index]
                } else {
                    named[key] = "1"
                }
            } else if token.hasPrefix("-") {
                fputs("error: unknown flag \(token)\n", stderr)
                exit(2)
            } else {
                positionals.append(token)
            }
            index += 1
        }

        var args = named
        if let first = positionals.first {
            args["path"] = first
            for (offset, value) in positionals.dropFirst().enumerated() {
                args["positional_\(offset + 1)"] = value
            }
        }
        return ["action": action, "args": args]
    }

    private static func postAction(port: Int, payload: [String: Any]) -> Int32 {
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "http://127.0.0.1:\(port)/action") else {
            fputs("error: unable to encode action request\n", stderr)
            return 1
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 5

        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 1

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                fputs("error: unable to reach Frostty on port \(port): \(error.localizedDescription)\n", stderr)
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                fputs("error: Frostty action server returned HTTP \(http.statusCode)\n", stderr)
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fputs("error: invalid response from Frostty\n", stderr)
                return
            }
            if json["ok"] as? Bool == true {
                if let message = json["message"] as? String, !message.isEmpty {
                    print(message)
                }
                exitCode = 0
            } else {
                let message = json["error"] as? String ?? "Unknown Frostty action error"
                fputs("\(message)\n", stderr)
            }
        }.resume()

        semaphore.wait()
        return exitCode
    }
}
