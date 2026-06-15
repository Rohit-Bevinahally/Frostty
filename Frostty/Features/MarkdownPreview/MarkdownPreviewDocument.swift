import AppKit
import Foundation

struct MarkdownPreviewFileSignature: Equatable, Sendable {
    let fileExists: Bool
    let modificationDate: Date?
    let fileSize: Int?
}

struct MarkdownPreviewRenderResult: Sendable {
    let html: String
    let baseURL: URL
    let displayURL: URL
    let title: String
    let signature: MarkdownPreviewFileSignature
}

struct MarkdownPreviewTheme: Sendable {
    let backgroundCSS: String
    let textCSS: String
    let mutedCSS: String
    let borderCSS: String
    let surfaceCSS: String
    let surfaceStrongCSS: String
    let accentCSS: String
    let accentMutedCSS: String
    let successCSS: String
    let warningCSS: String
    let boldCSS: String
    let listBulletCSS: String
    let listOrderedCSS: String
    let taskCheckedCSS: String
    let taskCheckedTextCSS: String
    let taskUncheckedCSS: String
    let taskUncheckedTextCSS: String
    let headingCSS: [String]
    let fontFamilyCSS: String
    let monospaceFontFamilyCSS: String
    let fontFamilyJS: String
    let baseFontSize: Double

    @MainActor
    static func live() -> Self {
        let config = GhosttyAppController.shared.configManager
        let background = MarkdownPreviewDocument.normalizedColor(config.backgroundColor.withAlphaComponent(1.0))
        let foreground = MarkdownPreviewDocument.resolvedConfigColor(config, key: "foreground", fallback: NSColor.textColor)
        let bold = MarkdownPreviewDocument.normalizedColor(MarkdownPreviewDocument.previewBoldColor)
        let accent = MarkdownPreviewDocument.resolvedPaletteColor(config, index: 4, fallback: foreground)
        let success = MarkdownPreviewDocument.resolvedPaletteColor(config, index: 2, fallback: accent)
        let warning = MarkdownPreviewDocument.resolvedPaletteColor(config, index: 3, fallback: accent)
        let listBullet = accent
        let listOrdered = MarkdownPreviewDocument.resolvedPaletteColor(config, index: 6, fallback: accent)
        let taskChecked = bold
        let taskUnchecked = accent
        let taskUncheckedText = MarkdownPreviewDocument.mix(foreground, taskUnchecked, amount: 0.72)
        let headingIndices = [4, 5, 2, 3, 6, 1]
        let headingCSS = headingIndices.map { index in
            MarkdownPreviewDocument.cssRGBAString(
                MarkdownPreviewDocument.resolvedPaletteColor(config, index: index, fallback: foreground)
            )
        }

        let fontSize = max(
            config.getDouble("font-size", default: MarkdownPreviewDocument.minimumPreviewFontSize),
            MarkdownPreviewDocument.minimumPreviewFontSize
        )
        let bodyFont = GhosttyUIFonts.nsFont(
            size: CGFloat(fontSize),
            weight: .regular,
            fallbackDesign: .monospaced
        )
        let codeFont = GhosttyUIFonts.nsFont(
            size: CGFloat(fontSize),
            weight: .regular,
            fallbackDesign: .monospaced
        )

        let muted = MarkdownPreviewDocument.mix(background, foreground, amount: 0.68)
        let border = MarkdownPreviewDocument.mix(background, accent, amount: 0.26)
        let surface = MarkdownPreviewDocument.mix(background, foreground, amount: 0.08)
        let surfaceStrong = MarkdownPreviewDocument.mix(background, foreground, amount: 0.13)
        let accentMuted = MarkdownPreviewDocument.mix(background, accent, amount: 0.12)

        return Self(
            backgroundCSS: MarkdownPreviewDocument.cssRGBAString(background),
            textCSS: MarkdownPreviewDocument.cssRGBAString(foreground),
            mutedCSS: MarkdownPreviewDocument.cssRGBAString(muted),
            borderCSS: MarkdownPreviewDocument.cssRGBAString(border),
            surfaceCSS: MarkdownPreviewDocument.cssRGBAString(surface),
            surfaceStrongCSS: MarkdownPreviewDocument.cssRGBAString(surfaceStrong),
            accentCSS: MarkdownPreviewDocument.cssRGBAString(accent),
            accentMutedCSS: MarkdownPreviewDocument.cssRGBAString(accentMuted),
            successCSS: MarkdownPreviewDocument.cssRGBAString(success),
            warningCSS: MarkdownPreviewDocument.cssRGBAString(warning),
            boldCSS: MarkdownPreviewDocument.cssRGBAString(bold),
            listBulletCSS: MarkdownPreviewDocument.cssRGBAString(listBullet),
            listOrderedCSS: MarkdownPreviewDocument.cssRGBAString(listOrdered),
            taskCheckedCSS: MarkdownPreviewDocument.cssRGBAString(taskChecked),
            taskCheckedTextCSS: MarkdownPreviewDocument.cssRGBAString(taskChecked),
            taskUncheckedCSS: MarkdownPreviewDocument.cssRGBAString(taskUnchecked),
            taskUncheckedTextCSS: MarkdownPreviewDocument.cssRGBAString(taskUncheckedText),
            headingCSS: headingCSS,
            fontFamilyCSS: MarkdownPreviewDocument.cssFontFamilyStack(for: bodyFont),
            monospaceFontFamilyCSS: MarkdownPreviewDocument.cssFontFamilyStack(for: codeFont),
            fontFamilyJS: bodyFont.familyName ?? bodyFont.fontName,
            baseFontSize: Double(bodyFont.pointSize)
        )
    }
}

enum MarkdownPreviewDocumentError: LocalizedError {
    case unsupportedLocation(URL)
    case missingFile(URL)
    case unreadableFile(URL, Error)
    case unsupportedEncoding(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocation(let url):
            return "\"\(url.path)\" is not a local file."
        case .missingFile(let url):
            return "\"\(url.path)\" could not be found."
        case .unreadableFile(let url, let error):
            return "Unable to read \"\(url.path)\": \(error.localizedDescription)"
        case .unsupportedEncoding(let url):
            return "\"\(url.path)\" is not UTF-8 text."
        }
    }
}

enum MarkdownPreviewDocument {
    /// Preview body text never renders below this size; matches the intended terminal reading size.
    static let minimumPreviewFontSize = 18.0
    /// Original CSS rem values were authored against this body size.
    static let referencePreviewFontSize = 15.0

    /// Hardcoded preview bold accent (#58b99d) until ghostty exposes `bold-color` via the C API.
    static let previewBoldColor = NSColor(
        red: 0x58 / 255.0,
        green: 0xb9 / 255.0,
        blue: 0x9d / 255.0,
        alpha: 1.0
    )

    static func signature(for url: URL) -> MarkdownPreviewFileSignature {
        let normalizedURL = url.standardizedFileURL
        let values = try? normalizedURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ])

        return MarkdownPreviewFileSignature(
            fileExists: values?.isRegularFile == true,
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize
        )
    }

    static func renderSource(at url: URL, theme: MarkdownPreviewTheme) throws -> MarkdownPreviewRenderResult {
        let normalizedURL = try normalizedFileURL(from: url)
        let signature = signature(for: normalizedURL)
        guard signature.fileExists else {
            throw MarkdownPreviewDocumentError.missingFile(normalizedURL)
        }

        let data: Data
        do {
            data = try Data(contentsOf: normalizedURL, options: [.mappedIfSafe])
        } catch {
            throw MarkdownPreviewDocumentError.unreadableFile(normalizedURL, error)
        }

        guard let markdown = String(data: data, encoding: .utf8) else {
            throw MarkdownPreviewDocumentError.unsupportedEncoding(normalizedURL)
        }

        let title = normalizedURL.lastPathComponent
        let html = previewHTML(markdown: markdown, sourceURL: normalizedURL, title: title, theme: theme)

        return MarkdownPreviewRenderResult(
            html: html,
            baseURL: normalizedURL.deletingLastPathComponent(),
            displayURL: normalizedURL,
            title: title,
            signature: signature
        )
    }

    static func errorHTML(for url: URL, message: String, theme: MarkdownPreviewTheme) -> String {
        let pathLiteral = javaScriptStringLiteral(url.path)
        let messageLiteral = javaScriptStringLiteral(message)
        let titleLiteral = javaScriptStringLiteral(url.lastPathComponent)

        return #"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\#(titleLiteral)</title>
          <style>
            html {
              color-scheme: dark;
              font-size: \#(theme.baseFontSize)px;
            }
            body {
              margin: 0;
              min-height: 100vh;
              background: \#(theme.backgroundCSS);
              color: \#(theme.textCSS);
              font: 1rem/1.6 \#(theme.fontFamilyCSS);
              display: flex;
              align-items: center;
              justify-content: center;
              padding: 1.6rem;
              box-sizing: border-box;
            }
            .card {
              width: min(640px, 100%);
              background: \#(theme.surfaceStrongCSS);
              border: 1px solid \#(theme.borderCSS);
              border-radius: 1.2rem;
              padding: 1.6rem;
            }
            h1 {
              margin: 0 0 0.533rem;
              font-size: 1.333rem;
            }
            p {
              margin: 0 0 0.8rem;
              color: \#(theme.mutedCSS);
            }
            .path {
              font-family: \#(theme.monospaceFontFamilyCSS);
              font-size: 0.8rem;
              color: \#(theme.accentCSS);
              word-break: break-word;
            }
          </style>
        </head>
        <body>
          <main class="card">
            <h1>Markdown preview unavailable</h1>
            <p id="message"></p>
            <div class="path" id="path"></div>
          </main>
          <script>
            document.getElementById("message").textContent = \#(messageLiteral);
            document.getElementById("path").textContent = \#(pathLiteral);
          </script>
        </body>
        </html>
        """#
    }

    private static func normalizedFileURL(from url: URL) throws -> URL {
        guard url.isFileURL else {
            throw MarkdownPreviewDocumentError.unsupportedLocation(url)
        }
        return url.standardizedFileURL
    }

    private static func previewHTML(markdown: String, sourceURL: URL, title: String, theme: MarkdownPreviewTheme) -> String {
        let markdownLiteral = javaScriptStringLiteral(markdown)
        let titleLiteral = javaScriptStringLiteral(title)
        let pathLiteral = javaScriptStringLiteral(sourceURL.path)
        let headingCSSBlock = theme.headingCSS.enumerated().map { index, css in
            "h\(index + 1) { color: \(css); }"
        }.joined(separator: "\n            ")
        let mermaidFontLiteral = javaScriptStringLiteral(theme.fontFamilyJS)
        let mermaidBackgroundLiteral = javaScriptStringLiteral(theme.backgroundCSS)
        let mermaidSurfaceLiteral = javaScriptStringLiteral(theme.surfaceStrongCSS)
        let mermaidBorderLiteral = javaScriptStringLiteral(theme.borderCSS)
        let mermaidAccentLiteral = javaScriptStringLiteral(theme.accentCSS)
        let mermaidMutedLiteral = javaScriptStringLiteral(theme.mutedCSS)
        let mermaidTextLiteral = javaScriptStringLiteral(theme.textCSS)

        return #"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="dark">
          <title>\#(titleLiteral)</title>
          <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
          <link rel="stylesheet" href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.10.0/build/styles/tokyo-night-dark.min.css">
          <style>
            :root {
              color-scheme: dark;
              --bg: \#(theme.backgroundCSS);
              --text: \#(theme.textCSS);
              --muted: \#(theme.mutedCSS);
              --border: \#(theme.borderCSS);
              --surface: \#(theme.surfaceCSS);
              --surface-strong: \#(theme.surfaceStrongCSS);
              --accent: \#(theme.accentCSS);
              --accent-muted: \#(theme.accentMutedCSS);
              --success: \#(theme.successCSS);
              --warning: \#(theme.warningCSS);
              --bold: \#(theme.boldCSS);
              --list-bullet: \#(theme.listBulletCSS);
              --list-ordered: \#(theme.listOrderedCSS);
              --task-checked: \#(theme.taskCheckedCSS);
              --task-checked-text: \#(theme.taskCheckedTextCSS);
              --task-unchecked: \#(theme.taskUncheckedCSS);
              --task-unchecked-text: \#(theme.taskUncheckedTextCSS);
              --font-family: \#(theme.fontFamilyCSS);
              --mono-font-family: \#(theme.monospaceFontFamilyCSS);
              --font-size: \#(theme.baseFontSize)px;
            }

            * { box-sizing: border-box; }

            html, body {
              margin: 0;
              min-height: 100%;
              background: var(--bg);
            }

            html {
              font-size: var(--font-size);
            }

            body {
              color: var(--text);
              font: 1rem/1.7 var(--font-family);
              text-rendering: optimizeLegibility;
            }

            main {
              width: min(980px, calc(100vw - 2.133rem));
              margin: 0 auto;
              padding: 1.6rem 1.6rem 9.333rem;
            }

            .page-meta {
              margin-bottom: 1.333rem;
              padding: 0.8rem 0.933rem;
              border-radius: 0.933rem;
              background: var(--surface-strong);
              border: 1px solid var(--border);
            }

            .page-title {
              margin: 0 0 0.267rem;
              font-size: 1rem;
              font-weight: 600;
            }

            .page-path {
              margin: 0;
              font-family: var(--mono-font-family);
              font-size: 0.8rem;
              color: var(--muted);
              word-break: break-all;
            }

            .preview-warning {
              margin: 0 0 1.2rem;
              padding: 0.667rem 0.8rem;
              border-radius: 0.8rem;
              border: 1px solid rgba(224, 175, 104, 0.28);
              background: rgba(224, 175, 104, 0.1);
              color: #f5d49d;
              font-size: 0.867rem;
            }

            article {
              display: block;
            }

            article > :first-child { margin-top: 0; }
            article > :last-child { margin-bottom: 0; }

            h1, h2, h3, h4, h5, h6 {
              margin: 1.55em 0 0.65em;
              line-height: 1.25;
            }

            \#(headingCSSBlock)

            h1 { font-size: 2rem; }
            h2 {
              font-size: 1.55rem;
              padding-bottom: 0.3em;
              border-bottom: 1px solid var(--border);
            }
            h3 { font-size: 1.25rem; }
            h4 { font-size: 1.1rem; }

            p, ul, ol, blockquote, table, pre {
              margin: 0 0 1rem;
            }

            ul, ol {
              padding-left: 1.5rem;
            }

            article ul:not(.task-list) > li::marker {
              color: var(--list-bullet);
              font-size: 1.1em;
            }

            article ol > li::marker {
              color: var(--list-ordered);
              font-weight: 650;
              font-variant-numeric: tabular-nums;
            }

            ul.task-list {
              list-style: none;
              padding-left: 0;
            }

            li.task-list-item {
              display: flex;
              align-items: flex-start;
              gap: 0.65rem;
              list-style: none;
              margin-left: 0;
            }

            li.task-list-item > input[type="checkbox"] {
              appearance: none;
              -webkit-appearance: none;
              width: 1.05rem;
              height: 1.05rem;
              margin: 0.22em 0 0;
              border: 2px solid var(--task-unchecked);
              border-radius: 0.333rem;
              background: color-mix(in srgb, var(--task-unchecked) 16%, transparent);
              display: grid;
              place-content: center;
              flex: 0 0 auto;
            }

            li.task-list-item.is-unchecked {
              color: var(--task-unchecked-text);
            }

            li.task-list-item.is-unchecked > input[type="checkbox"] {
              border-color: var(--task-unchecked);
              background: color-mix(in srgb, var(--task-unchecked) 16%, transparent);
            }

            li.task-list-item.is-checked {
              color: var(--task-checked-text);
            }

            li.task-list-item.is-checked > input[type="checkbox"] {
              border-color: var(--task-checked);
              background: color-mix(in srgb, var(--task-checked) 28%, transparent);
            }

            li.task-list-item.is-checked > input[type="checkbox"]::after {
              content: "";
              width: 0.3rem;
              height: 0.58rem;
              border: solid var(--task-checked);
              border-width: 0 2.5px 2.5px 0;
              transform: rotate(45deg) translateY(-1px);
            }

            li.task-list-item .task-list-item-content {
              flex: 1;
              min-width: 0;
            }

            li.task-list-item.is-checked .task-list-item-content {
              opacity: 0.92;
            }

            li + li {
              margin-top: 0.35rem;
            }

            a {
              color: var(--accent);
            }

            strong, b {
              color: var(--bold);
              font-weight: 650;
            }

            hr {
              border: 0;
              border-top: 1px solid var(--border);
              margin: 1.8rem 0;
            }

            code {
              font-family: var(--mono-font-family);
              font-size: 0.92em;
            }

            p code, li code, td code, blockquote code {
              padding: 0.15rem 0.38rem;
              border-radius: 0.4rem;
              background: rgba(122, 162, 247, 0.12);
              color: #e0af68;
            }

            pre {
              padding: 0.933rem 1.067rem;
              overflow-x: auto;
              border-radius: 0.933rem;
              background: var(--surface);
              border: 1px solid var(--border);
            }

            pre code {
              display: block;
              white-space: pre;
              background: transparent;
            }

            pre code.hljs {
              padding: 0;
              background: transparent !important;
            }

            .hljs {
              background: transparent !important;
              color: var(--text);
            }

            .search-bar {
              position: fixed;
              left: 50%;
              bottom: 1.2rem;
              transform: translateX(-50%);
              display: none;
              align-items: center;
              gap: 0.533rem;
              width: min(560px, calc(100vw - 2.133rem));
              padding: 0.667rem 0.8rem;
              border-radius: 0.8rem;
              background: var(--surface-strong);
              border: 1px solid var(--border);
              box-shadow: 0 0.667rem 2rem rgba(0, 0, 0, 0.28);
              z-index: 20;
            }

            .search-bar.visible {
              display: flex;
            }

            .search-bar input {
              flex: 1;
              border: 0;
              outline: none;
              background: transparent;
              color: var(--text);
              font: 0.933rem/1.4 var(--font-family);
            }

            .search-bar input.no-matches {
              color: #f7768e;
            }

            .search-bar .search-meta {
              color: var(--muted);
              font-size: 0.8rem;
              white-space: nowrap;
            }

            .search-bar .search-meta.no-matches {
              color: #f7768e;
            }

            mark.search-hit {
              background: rgba(122, 162, 247, 0.28);
              color: inherit;
              border-radius: 0.2rem;
            }

            mark.search-hit.active {
              background: rgba(224, 175, 104, 0.42);
            }

            pre.fallback-source {
              white-space: pre-wrap;
              word-break: break-word;
            }

            blockquote {
              padding: 0.2rem 0 0.2rem 1rem;
              color: var(--muted);
              border-left: 3px solid var(--accent);
            }

            .table-wrap {
              overflow-x: auto;
              margin: 1rem 0;
              border: 1px solid var(--border);
            }

            table {
              width: 100%;
              border-collapse: collapse;
              margin: 0;
            }

            th, td {
              padding: 0.65rem 0.8rem;
              border: 1px solid var(--border);
            }

            th {
              text-align: center;
              background: var(--accent-muted);
            }

            img {
              max-width: 100%;
              border-radius: 0.8rem;
            }

            .mermaid {
              display: block;
              overflow-x: auto;
              padding: 0.933rem 0.8rem;
              border-radius: 0.933rem;
              background: var(--surface);
              border: 1px solid var(--border);
            }

            .katex-display {
              overflow-x: auto;
              overflow-y: hidden;
              padding: 0.25rem 0;
            }
          </style>
          <script defer src="https://cdn.jsdelivr.net/npm/marked@13.0.2/marked.min.js"></script>
          <script defer src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.10.0/build/highlight.min.js"></script>
          <script defer src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"></script>
          <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
          <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
        </head>
        <body>
          <main>
            <section class="page-meta">
              <p class="page-title" id="page-title"></p>
              <p class="page-path" id="page-path"></p>
            </section>
            <article id="preview-root"></article>
          </main>
          <div class="search-bar" id="search-bar">
            <span>/</span>
            <input id="search-input" type="search" placeholder="Search preview..." autocomplete="off" spellcheck="false" />
            <span class="search-meta" id="search-meta"></span>
          </div>
          <script>
            const markdownSource = \#(markdownLiteral);
            const sourceTitle = \#(titleLiteral);
            const sourcePath = \#(pathLiteral);

            document.getElementById("page-title").textContent = sourceTitle;
            document.getElementById("page-path").textContent = sourcePath;

            function escapeHTML(value) {
              return value
                .replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;")
                .replace(/"/g, "&quot;")
                .replace(/'/g, "&#39;");
            }

            function showWarning(root, message) {
              const warning = document.createElement("p");
              warning.className = "preview-warning";
              warning.textContent = message;
              root.before(warning);
            }

            function renderFallback(root) {
              showWarning(
                root,
                "Enhanced Markdown libraries could not be loaded. Showing the raw document instead."
              );
              root.innerHTML = `<pre class="fallback-source"><code>${escapeHTML(markdownSource)}</code></pre>`;
            }

            function convertMermaidBlocks(root) {
              const codeBlocks = root.querySelectorAll("pre > code");
              for (const block of codeBlocks) {
                const classNames = Array.from(block.classList);
                const isMermaid = classNames.some((name) => name === "language-mermaid" || name === "lang-mermaid");
                if (!isMermaid) {
                  continue;
                }

                const pre = block.parentElement;
                if (!pre) {
                  continue;
                }

                const container = document.createElement("div");
                container.className = "mermaid";
                container.textContent = block.textContent ?? "";
                pre.replaceWith(container);
              }
            }

            function renderMath(root) {
              if (typeof window.renderMathInElement !== "function") {
                showWarning(root, "KaTeX could not be loaded. Leaving math expressions unrendered.");
                return;
              }

              window.renderMathInElement(root, {
                delimiters: [
                  { left: "$$", right: "$$", display: true },
                  { left: "$", right: "$", display: false },
                  { left: "\\(", right: "\\)", display: false },
                  { left: "\\[", right: "\\]", display: true }
                ],
                throwOnError: false
              });
            }

            function highlightCodeBlocks(root) {
              if (!window.hljs?.highlightElement) {
                return;
              }

              const codeBlocks = root.querySelectorAll("pre > code");
              for (const block of codeBlocks) {
                const classNames = Array.from(block.classList);
                const isMermaid = classNames.some((name) => name === "language-mermaid" || name === "lang-mermaid");
                if (isMermaid) {
                  continue;
                }
                window.hljs.highlightElement(block);
              }
            }

            const searchState = {
              marks: [],
              activeIndex: -1,
              lastQuery: "",
              navigationMode: false
            };

            function clearSearchMarks() {
              for (const mark of searchState.marks) {
                const parent = mark.parentNode;
                if (!parent) {
                  continue;
                }
                parent.replaceChild(document.createTextNode(mark.textContent ?? ""), mark);
                parent.normalize();
              }
              searchState.marks = [];
              searchState.activeIndex = -1;
            }

            function updateSearchMeta() {
              const meta = document.getElementById("search-meta");
              if (!meta) {
                updateSearchInputAppearance();
                return;
              }
              if (!searchState.lastQuery) {
                meta.textContent = "";
                updateSearchInputAppearance();
                return;
              }
              if (searchState.marks.length === 0) {
                meta.textContent = "0/0";
                updateSearchInputAppearance();
                return;
              }
              meta.textContent = `${searchState.activeIndex + 1}/${searchState.marks.length}`;
              updateSearchInputAppearance();
            }

            function updateSearchInputAppearance() {
              const input = document.getElementById("search-input");
              const meta = document.getElementById("search-meta");
              const noMatches = searchState.lastQuery.length > 0 && searchState.marks.length === 0;
              input?.classList.toggle("no-matches", noMatches);
              meta?.classList.toggle("no-matches", noMatches);
            }

            function scrollMarkIntoView(mark) {
              if (!mark) {
                return;
              }
              const rect = mark.getBoundingClientRect();
              const targetY = window.scrollY + rect.top - (window.innerHeight * 0.35);
              window.scrollTo({ top: Math.max(0, targetY), behavior: "smooth" });
            }

            function setActiveSearchMark(index) {
              if (searchState.marks.length === 0) {
                searchState.activeIndex = -1;
                updateSearchMeta();
                return;
              }
              const normalized = ((index % searchState.marks.length) + searchState.marks.length) % searchState.marks.length;
              searchState.marks.forEach((mark, idx) => {
                mark.classList.toggle("active", idx === normalized);
              });
              searchState.activeIndex = normalized;
              scrollMarkIntoView(searchState.marks[normalized]);
              updateSearchMeta();
            }

            function collectTextNodes(root) {
              const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
              const nodes = [];
              let node = walker.nextNode();
              while (node) {
                if (node.nodeValue && node.nodeValue.trim().length > 0 && isSearchableTextNode(node)) {
                  nodes.push(node);
                }
                node = walker.nextNode();
              }
              return nodes;
            }

            function isSearchableTextNode(node) {
              let parent = node.parentElement;
              while (parent) {
                if (parent.id === "search-bar" || parent.closest("#search-bar")) {
                  return false;
                }
                const tag = parent.tagName;
                if (tag === "SCRIPT" || tag === "STYLE" || tag === "CODE" || tag === "PRE") {
                  return false;
                }
                if (parent.classList.contains("mermaid")) {
                  return false;
                }
                if (
                  parent.classList.contains("katex")
                  || parent.classList.contains("katex-html")
                  || parent.classList.contains("katex-mathml")
                ) {
                  return false;
                }
                parent = parent.parentElement;
              }
              return true;
            }

            function findQueryRanges(source, needle) {
              const ranges = [];
              if (!needle) {
                return ranges;
              }
              const lower = source.toLowerCase();
              const needleLower = needle.toLowerCase();
              let start = 0;
              let index = lower.indexOf(needleLower, start);
              while (index !== -1) {
                ranges.push({ start: index, end: index + needle.length });
                start = index + needle.length;
                index = lower.indexOf(needleLower, start);
              }
              return ranges;
            }

            function applySearch(query, activateFirst = false) {
              const root = document.getElementById("preview-root");
              clearSearchMarks();
              searchState.lastQuery = query.trim();
              if (!root || !searchState.lastQuery) {
                updateSearchMeta();
                return;
              }

              for (const textNode of collectTextNodes(root)) {
                const source = textNode.nodeValue ?? "";
                const ranges = findQueryRanges(source, searchState.lastQuery);
                if (ranges.length === 0) {
                  continue;
                }

                const fragment = document.createDocumentFragment();
                let cursor = 0;
                for (const range of ranges) {
                  if (range.start > cursor) {
                    fragment.appendChild(document.createTextNode(source.slice(cursor, range.start)));
                  }
                  const mark = document.createElement("mark");
                  mark.className = "search-hit";
                  mark.textContent = source.slice(range.start, range.end);
                  fragment.appendChild(mark);
                  searchState.marks.push(mark);
                  cursor = range.end;
                }
                if (cursor < source.length) {
                  fragment.appendChild(document.createTextNode(source.slice(cursor)));
                }
                textNode.parentNode?.replaceChild(fragment, textNode);
              }

              if (activateFirst && searchState.marks.length > 0) {
                setActiveSearchMark(0);
              } else {
                searchState.activeIndex = -1;
                updateSearchMeta();
              }
            }

            function wrapTables(root) {
              const tables = root.querySelectorAll("table");
              for (const table of tables) {
                if (table.parentElement?.classList.contains("table-wrap")) {
                  continue;
                }
                const wrap = document.createElement("div");
                wrap.className = "table-wrap";
                table.parentNode?.insertBefore(wrap, table);
                wrap.appendChild(table);
              }
            }

            function enhanceTaskLists(root) {
              const items = root.querySelectorAll("li");
              for (const item of items) {
                const checkbox = item.querySelector(":scope > input[type='checkbox']");
                if (!checkbox) {
                  continue;
                }

                item.classList.add("task-list-item");
                item.classList.toggle("is-checked", checkbox.checked);
                item.classList.toggle("is-unchecked", !checkbox.checked);

                const list = item.parentElement;
                if (list?.tagName === "UL") {
                  list.classList.add("task-list");
                }

                if (item.querySelector(":scope > .task-list-item-content")) {
                  continue;
                }

                const content = document.createElement("span");
                content.className = "task-list-item-content";
                let node = checkbox.nextSibling;
                while (node) {
                  const next = node.nextSibling;
                  content.appendChild(node);
                  node = next;
                }
                item.appendChild(content);
              }
            }

            window.frosttyPreview = {
              scrollBy(dx, dy) {
                window.scrollBy({ left: dx, top: dy, behavior: "smooth" });
              },
              scrollToTop() {
                window.scrollTo({ top: 0, behavior: "smooth" });
              },
              scrollToBottom() {
                window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "smooth" });
              },
              openSearch() {
                document.getElementById("search-bar")?.classList.add("visible");
              },
              openSearchAndFocus() {
                const bar = document.getElementById("search-bar");
                const input = document.getElementById("search-input");
                bar?.classList.add("visible");
                searchState.navigationMode = false;
                if (!input) {
                  return;
                }
                requestAnimationFrame(() => {
                  input.focus();
                  const length = input.value.length;
                  input.setSelectionRange(length, length);
                });
              },
              resumeSearchTyping() {
                searchState.navigationMode = false;
                searchState.activeIndex = -1;
                searchState.marks.forEach((mark) => mark.classList.remove("active"));
                updateSearchMeta();
                this.openSearchAndFocus();
              },
              notifySearchInputFocus() {
                if (!searchState.navigationMode) {
                  return;
                }
                window.webkit?.messageHandlers?.frosttyPreview?.postMessage({ type: "searchInputFocus" });
              },
              commitSearchTyping() {
                const input = document.getElementById("search-input");
                applySearch(input?.value ?? "", true);
                searchState.navigationMode = true;
                input?.blur();
              },
              dismissSearch() {
                const bar = document.getElementById("search-bar");
                const input = document.getElementById("search-input");
                bar?.classList.remove("visible");
                if (input) {
                  input.value = "";
                }
                input?.blur();
                clearSearchMarks();
                searchState.lastQuery = "";
                searchState.navigationMode = false;
                updateSearchMeta();
              },
              findNext() {
                if (!searchState.lastQuery || searchState.marks.length === 0) {
                  return;
                }
                setActiveSearchMark(searchState.activeIndex + 1);
              },
              findPrevious() {
                if (!searchState.lastQuery || searchState.marks.length === 0) {
                  return;
                }
                setActiveSearchMark(searchState.activeIndex - 1);
              }
            };

            async function renderMermaid(root) {
              if (!window.mermaid) {
                showWarning(root, "Mermaid could not be loaded. Leaving diagram blocks as code.");
                return;
              }

              try {
                window.mermaid.initialize({
                  startOnLoad: false,
                  securityLevel: "loose",
                  theme: "base",
                  themeVariables: {
                    fontFamily: \#(mermaidFontLiteral),
                    background: \#(mermaidBackgroundLiteral),
                    primaryColor: \#(mermaidSurfaceLiteral),
                    primaryBorderColor: \#(mermaidBorderLiteral),
                    primaryTextColor: \#(mermaidTextLiteral),
                    secondaryColor: \#(mermaidBackgroundLiteral),
                    tertiaryColor: \#(mermaidSurfaceLiteral),
                    lineColor: \#(mermaidAccentLiteral),
                    textColor: \#(mermaidTextLiteral),
                    mainBkg: \#(mermaidSurfaceLiteral),
                    nodeBorder: \#(mermaidBorderLiteral),
                    clusterBkg: \#(mermaidSurfaceLiteral),
                    clusterBorder: \#(mermaidBorderLiteral),
                    edgeLabelBackground: \#(mermaidBackgroundLiteral),
                    secondaryTextColor: \#(mermaidMutedLiteral),
                    tertiaryTextColor: \#(mermaidMutedLiteral)
                  }
                });

                const nodes = root.querySelectorAll(".mermaid");
                if (nodes.length > 0) {
                  await window.mermaid.run({ nodes });
                }
              } catch (error) {
                console.error("Mermaid render failed", error);
                showWarning(root, "A Mermaid diagram failed to render.");
              }
            }

            async function renderPreview() {
              const root = document.getElementById("preview-root");
              const markedAPI = window.marked?.parse ? window.marked : window.marked?.marked;

              if (!markedAPI?.parse) {
                renderFallback(root);
                return;
              }

              markedAPI.setOptions({
                gfm: true,
                breaks: false,
                headerIds: true,
                mangle: false
              });

              root.innerHTML = markedAPI.parse(markdownSource);
              wrapTables(root);
              enhanceTaskLists(root);
              highlightCodeBlocks(root);
              convertMermaidBlocks(root);
              renderMath(root);
              await renderMermaid(root);
            }

            document.addEventListener("DOMContentLoaded", () => {
              const searchInput = document.getElementById("search-input");
              searchInput?.addEventListener("input", (event) => {
                applySearch(event.target.value ?? "", false);
              });
              searchInput?.addEventListener("focus", () => {
                window.frosttyPreview?.notifySearchInputFocus();
              });
              void renderPreview();
            });
          </script>
        </body>
        </html>
        """#
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        var literal = String(decoding: data ?? Data("\"\"".utf8), as: UTF8.self)
        literal = literal.replacingOccurrences(of: "</", with: "<\\/")
        literal = literal.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        literal = literal.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return literal
    }

    @MainActor
    fileprivate static func resolvedPaletteColor(_ config: GhosttyConfigManager, index: Int, fallback: NSColor) -> NSColor {
        guard let color = config.paletteColor(at: index) else {
            return normalizedColor(fallback)
        }
        return normalizedColor(color)
    }

    @MainActor
    fileprivate static func resolvedConfigColor(_ config: GhosttyConfigManager, key: String, fallback: NSColor) -> NSColor {
        guard let color = config.getColor(key) else {
            return normalizedColor(fallback)
        }

        return normalizedColor(NSColor(
            red: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1.0
        ))
    }

    fileprivate static func normalizedColor(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.deviceRGB) ?? color
    }

    fileprivate static func mix(_ background: NSColor, _ foreground: NSColor, amount: CGFloat) -> NSColor {
        let clamped = max(0, min(1, amount))
        let bg = normalizedColor(background)
        let fg = normalizedColor(foreground)

        return NSColor(
            red: bg.redComponent + (fg.redComponent - bg.redComponent) * clamped,
            green: bg.greenComponent + (fg.greenComponent - bg.greenComponent) * clamped,
            blue: bg.blueComponent + (fg.blueComponent - bg.blueComponent) * clamped,
            alpha: 1.0
        )
    }

    fileprivate static func cssRGBAString(_ color: NSColor) -> String {
        let normalized = normalizedColor(color)
        let red = Int(round(normalized.redComponent * 255))
        let green = Int(round(normalized.greenComponent * 255))
        let blue = Int(round(normalized.blueComponent * 255))
        return "rgb(\(red), \(green), \(blue))"
    }

    fileprivate static func cssFontFamilyStack(for font: NSFont) -> String {
        let family = font.familyName ?? font.fontName
        let escapedFamily = family
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapedFamily)\", ui-monospace, monospace"
    }
}
