import Foundation
import Network

@MainActor
final class FrosttyActionServer {
    static let shared = FrosttyActionServer()

    private(set) var isRunning = false
    private(set) var port: Int = 0
    private var listener: NWListener?
    var registry: FrosttyActionRegistry?
    var broker: FrosttyActionBroker?

    private init() {}

    func start(preferredPort: Int = 41850) {
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

    func handleInvocationJSON(_ data: Data) async -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            return errorJSON("Invalid request: missing 'action' field")
        }

        let args = json["args"] as? [String: String] ?? [:]
        let invocation = FrosttyActionInvocation(action: action, args: args)

        guard let registry else {
            return errorJSON("Action registry not configured")
        }

        let result = await registry.dispatch(invocation)
        switch result {
        case .success(let message):
            return okJSON(message)
        case .failure(let message):
            return errorJSON(message)
        }
    }

    private func writeStateFile() {
        let configDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/frostty")
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        let stateFile = configDirectory.appendingPathComponent("frostty.json")
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
            .appendingPathComponent(".config/frostty/frostty.json")
        try? FileManager.default.removeItem(at: stateFile)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveHTTPRequest(on: connection, buffer: Data(), continueSent: false)
    }

    private func receiveHTTPRequest(
        on connection: NWConnection,
        buffer: Data,
        continueSent: Bool
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] chunk, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                guard let chunk else {
                    connection.cancel()
                    return
                }

                var buffer = buffer
                buffer.append(chunk)

                if !continueSent,
                   Self.hasExpectContinue(in: buffer),
                   Self.headerTerminatorRange(in: buffer) != nil {
                    let continueResponse = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
                    connection.send(content: continueResponse, completion: .contentProcessed { [weak self] _ in
                        Task { @MainActor in
                            self?.receiveHTTPRequest(on: connection, buffer: buffer, continueSent: true)
                        }
                    })
                    return
                }

                do {
                    let request = try HTTPParser.parse(buffer)
                    if Self.needsMoreRequestData(buffer) {
                        self.receiveHTTPRequest(on: connection, buffer: buffer, continueSent: continueSent)
                        return
                    }

                    guard request.method == "POST", request.path == "/action" else {
                        self.send(connection, HTTPParser.response(statusCode: 404, body: nil))
                        return
                    }
                    guard let body = request.body else {
                        self.send(connection, HTTPParser.response(statusCode: 400, body: nil))
                        return
                    }

                    let responseData = await self.handleInvocationJSON(body)
                    let response = HTTPParser.response(
                        statusCode: 200,
                        body: responseData,
                        contentType: "application/json"
                    )
                    self.send(connection, response)
                } catch HTTPParseError.malformedRequest {
                    if Self.needsMoreRequestData(buffer) {
                        self.receiveHTTPRequest(on: connection, buffer: buffer, continueSent: continueSent)
                        return
                    }
                    self.send(connection, HTTPParser.response(statusCode: 400, body: nil))
                } catch {
                    self.send(connection, HTTPParser.response(statusCode: 400, body: nil))
                }
            }
        }
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private static func headerTerminatorRange(in buffer: Data) -> Range<Data.Index>? {
        buffer.range(of: headerTerminator)
    }

    private static func hasExpectContinue(in buffer: Data) -> Bool {
        guard let headerEnd = headerTerminatorRange(in: buffer),
              let headerString = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return false
        }

        return headerString
            .components(separatedBy: "\r\n")
            .dropFirst()
            .contains { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return false }
                return parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "expect"
                    && parts[1].trimmingCharacters(in: .whitespaces).lowercased() == "100-continue"
            }
    }

    static func needsMoreRequestData(_ buffer: Data) -> Bool {
        guard let headerEnd = headerTerminatorRange(in: buffer),
              let headerString = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return buffer.count < HTTPParser.maxHeaderSize
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let lengthLine = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") }) else {
            return false
        }

        let parts = lengthLine.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let expectedLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return false
        }

        let bodyStart = headerEnd.upperBound
        let receivedLength = max(0, buffer.endIndex - bodyStart)
        return receivedLength < expectedLength
    }

    private func send(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialize(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func okJSON(_ message: String?) -> Data {
        var response: [String: Any] = ["ok": true]
        if let message, !message.isEmpty {
            response["message"] = message
        }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func errorJSON(_ message: String) -> Data {
        let response: [String: Any] = ["ok": false, "error": message]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
}
