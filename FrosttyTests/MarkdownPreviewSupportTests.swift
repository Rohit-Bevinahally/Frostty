import XCTest
@testable import Frostty

final class MarkdownPreviewSupportTests: XCTestCase {
    func testMarkdownExtensions() {
        XCTAssertTrue(MarkdownPreviewSupport.isMarkdownPath("README.md"))
        XCTAssertTrue(MarkdownPreviewSupport.isMarkdownPath("notes.markdown"))
        XCTAssertFalse(MarkdownPreviewSupport.isMarkdownPath("image.png"))
    }

    func testResolvedAbsolutePath() {
        let url = MarkdownPreviewSupport.resolvedFileURL(from: "/tmp/example.md")
        XCTAssertEqual(url?.path, "/tmp/example.md")
    }

    func testResolvedRelativePathUsesWorkingDirectory() {
        let url = MarkdownPreviewSupport.resolvedFileURL(from: "docs/readme.md", relativeTo: "/tmp/project")
        XCTAssertEqual(url?.path, "/tmp/project/docs/readme.md")
    }
}
