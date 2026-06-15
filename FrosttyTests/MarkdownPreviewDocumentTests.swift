import XCTest
@testable import Frostty

final class MarkdownPreviewDocumentTests: XCTestCase {
    func testSignatureMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/definitely-missing-\(UUID().uuidString).md")
        let signature = MarkdownPreviewDocument.signature(for: url)
        XCTAssertFalse(signature.fileExists)
    }

    func testPreviewHTMLIncludesHighlightAndSearchHooks() throws {
        let theme = MarkdownPreviewTheme(
            backgroundCSS: "rgb(0, 0, 0)",
            textCSS: "rgb(255, 255, 255)",
            mutedCSS: "rgb(128, 128, 128)",
            borderCSS: "rgb(64, 64, 64)",
            surfaceCSS: "rgb(32, 32, 32)",
            surfaceStrongCSS: "rgb(48, 48, 48)",
            accentCSS: "rgb(122, 162, 247)",
            accentMutedCSS: "rgb(80, 100, 140)",
            successCSS: "rgb(158, 206, 106)",
            warningCSS: "rgb(224, 175, 104)",
            boldCSS: "rgb(224, 175, 104)",
            listBulletCSS: "rgb(187, 154, 247)",
            listOrderedCSS: "rgb(125, 207, 255)",
            taskCheckedCSS: "rgb(158, 206, 106)",
            taskCheckedTextCSS: "rgb(158, 206, 106)",
            taskUncheckedCSS: "rgb(224, 175, 104)",
            taskUncheckedTextCSS: "rgb(210, 188, 150)",
            headingCSS: [
                "rgb(122, 162, 247)",
                "rgb(187, 154, 247)",
                "rgb(158, 206, 106)",
                "rgb(224, 175, 104)",
                "rgb(247, 118, 142)",
                "rgb(125, 207, 255)",
            ],
            fontFamilyCSS: "\"Menlo\", monospace",
            monospaceFontFamilyCSS: "\"Menlo\", monospace",
            fontFamilyJS: "Menlo",
            baseFontSize: 18
        )

        let html = try MarkdownPreviewDocument.renderSource(
            at: writeTemporaryMarkdown("# Title\n\n**bold**"),
            theme: theme
        ).html

        XCTAssertTrue(html.contains("tokyo-night-dark"))
        XCTAssertTrue(html.contains("window.frosttyPreview"))
        XCTAssertTrue(html.contains("--bold"))
        XCTAssertTrue(html.contains("search-bar"))
        XCTAssertTrue(html.contains("--list-bullet"))
        XCTAssertTrue(html.contains("task-list-item"))
        XCTAssertTrue(html.contains("enhanceTaskLists"))
    }

    private func writeTemporaryMarkdown(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frostty-test-\(UUID().uuidString).md")
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
