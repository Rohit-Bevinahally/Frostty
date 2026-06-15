import XCTest
@testable import Frostty

final class FrosttyActionParserTests: XCTestCase {
    private let definitions: [String: FrosttyActionDefinition] = [
        "markdown_preview": MarkdownPreviewAction.definition,
    ]

    func testMarkdownPreviewPathParsing() throws {
        let positional = try FrosttyActionParser.parse(
            argv: ["+markdown_preview", "/tmp/readme.md"],
            definitions: definitions
        )
        XCTAssertEqual(positional.args["path"], "/tmp/readme.md")

        let named = try FrosttyActionParser.parse(
            argv: ["+markdown_preview", "--path=/tmp/readme.md"],
            definitions: definitions
        )
        XCTAssertEqual(named.args["path"], "/tmp/readme.md")
    }

    func testRejectsInvalidActionTokens() {
        XCTAssertThrowsError(
            try FrosttyActionParser.parse(argv: ["+missing"], definitions: definitions)
        ) { error in
            XCTAssertEqual(error as? FrosttyActionParseError, .unknownAction("missing"))
        }

        XCTAssertThrowsError(
            try FrosttyActionParser.parse(argv: ["markdown_preview"], definitions: definitions)
        ) { error in
            XCTAssertEqual(error as? FrosttyActionParseError, .invalidActionToken("markdown_preview"))
        }
    }
}
