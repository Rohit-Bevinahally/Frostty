import Foundation
import Network

@MainActor
final class BrowserServer {
    static let shared = BrowserServer()

    private(set) var isRunning = false
    private(set) var port: Int = 0
    private var listener: NWListener?
    var toolHandler: BrowserToolHandler?

    private init() {}

    func start(preferredPort: Int = 41840) {
        if isRunning { return }

        for offset in 0..<10 {
            let portToTry = preferredPort + offset
            do {
                let parameters = NWParameters.tcp
                let localPort = NWEndpoint.Port(integerLiteral: UInt16(portToTry))
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: localPort)
                let listener = try NWListener(using: parameters)

                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        self?.handleConnection(connection)
                    }
                }
                listener.start(queue: .main)

                self.listener = listener
                self.port = portToTry
                self.isRunning = true
                writeStateFile()
                return
            } catch {
                continue
            }
        }
    }

    func stop() {
        removeStateFile()
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
    }

    private func writeStateFile() {
        let configDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/frostty")
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let stateFile = configDirectory.appendingPathComponent("browser.json")
        let state: [String: Any] = [
            "port": port,
            "pid": ProcessInfo.processInfo.processIdentifier,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) {
            try? data.write(to: stateFile)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
        }
    }

    private func removeStateFile() {
        let stateFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/frostty/browser.json")
        try? FileManager.default.removeItem(at: stateFile)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self, let data else {
                    connection.cancel()
                    return
                }

                do {
                    let request = try HTTPParser.parse(data)
                    guard request.method == "POST", request.path == "/browser" else {
                        self.send(connection, HTTPParser.response(statusCode: 404, body: nil))
                        return
                    }
                    guard let body = request.body else {
                        self.send(connection, HTTPParser.response(statusCode: 400, body: nil))
                        return
                    }

                    let responseData = await self.handleRequest(body)
                    let response = HTTPParser.response(
                        statusCode: 200,
                        body: responseData,
                        contentType: "application/json"
                    )
                    self.send(connection, response)
                } catch {
                    self.send(connection, HTTPParser.response(statusCode: 400, body: nil))
                }
            }
        }
    }

    private func send(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleRequest(_ data: Data) async -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["command"] as? String else {
            return errorJSON("Invalid request: missing 'command' field")
        }

        guard let handler = toolHandler else {
            return errorJSON("Browser handler not configured")
        }

        let args = json["args"] as? [String: Any]
        let toolName = "browser_\(command)"
        let result = await handler.handleTool(name: toolName, arguments: args)

        if result.isError {
            return errorJSON(result.text)
        }

        return okJSON(result.text)
    }

    private func okJSON(_ result: String) -> Data {
        let response: [String: Any] = ["ok": true, "result": result]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func errorJSON(_ message: String) -> Data {
        let response: [String: Any] = ["ok": false, "error": message]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
}
