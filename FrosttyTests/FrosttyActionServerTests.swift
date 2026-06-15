import XCTest
@testable import Frostty

@MainActor
final class FrosttyActionServerTests: XCTestCase {
    func testHandleInvocationJSONSuccess() async {
        let server = FrosttyActionServer.shared
        let registry = FrosttyActionRegistry()
        registry.register(definition: MarkdownPreviewAction.definition) { _ in
            .success(message: "ok")
        }
        server.registry = registry

        let payload = #"{"action":"markdown_preview","args":{"path":"/tmp/a.md"}}"#.data(using: .utf8)!
        let responseData = await server.handleInvocationJSON(payload)
        let json = try! JSONSerialization.jsonObject(with: responseData) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, true)
    }

    func testHandleInvocationJSONMissingAction() async {
        let server = FrosttyActionServer.shared
        server.registry = FrosttyActionRegistry()

        let payload = #"{"args":{}}"#.data(using: .utf8)!
        let responseData = await server.handleInvocationJSON(payload)
        let json = try! JSONSerialization.jsonObject(with: responseData) as! [String: Any]
        XCTAssertEqual(json["ok"] as? Bool, false)
    }

    func testNeedsMoreRequestDataWhenBodyNotYetReceived() throws {
        let body = #"{"action":"markdown_preview","args":{"path":"/tmp/a.md"}}"#
        let headers = """
        POST /action HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Expect: 100-continue\r
        \r

        """
        let buffer = Data(headers.utf8)
        XCTAssertTrue(FrosttyActionServer.needsMoreRequestData(buffer))
        let request = try HTTPParser.parse(buffer)
        XCTAssertNil(request.body)
    }

    func testNeedsMoreRequestDataWhenBodyComplete() throws {
        let body = #"{"action":"markdown_preview","args":{"path":"/tmp/a.md"}}"#
        let headers = """
        POST /action HTTP/1.1\r
        Host: localhost\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r

        """
        var buffer = Data(headers.utf8)
        buffer.append(Data(body.utf8))
        XCTAssertFalse(FrosttyActionServer.needsMoreRequestData(buffer))
        let request = try HTTPParser.parse(buffer)
        XCTAssertEqual(request.body, Data(body.utf8))
    }

    func testURLSessionPostsSucceedRepeatedlyWithExpectContinue() async throws {
        let server = FrosttyActionServer.shared
        let registry = FrosttyActionRegistry()
        registry.register(definition: MarkdownPreviewAction.definition) { _ in
            .success(message: nil)
        }
        server.registry = registry
        if !server.isRunning {
            server.start(preferredPort: 52850)
        }
        XCTAssertTrue(server.isRunning)

        try await Task.sleep(for: .milliseconds(100))

        for _ in 0..<50 {
            let status = await postMarkdownPreview(port: server.port)
            XCTAssertEqual(status, 200)
        }
    }

    private func postMarkdownPreview(port: Int) async -> Int {
        guard let url = URL(string: "http://127.0.0.1:\(port)/action"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "action": "markdown_preview",
                  "args": ["path": "/tmp/a.md"],
              ]) else {
            return -1
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            return -1
        }
    }
}
