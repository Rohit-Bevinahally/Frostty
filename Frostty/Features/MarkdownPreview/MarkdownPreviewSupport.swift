import Foundation

enum MarkdownPreviewInvocationSource: Sendable, Equatable {
    case keyboardToggle
    case frosttyAction
}

enum MarkdownPreviewSupport {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    static func isMarkdownFile(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    static func isMarkdownPath(_ path: String) -> Bool {
        isMarkdownFile(at: URL(fileURLWithPath: path))
    }

    static func resolvedFileURL(from path: String?, relativeTo workingDirectory: String? = nil) -> URL? {
        guard let path, !path.isEmpty else { return nil }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }

        if let workingDirectory {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true)
                .appendingPathComponent(trimmed)
                .standardizedFileURL
        }

        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }

    static func fileExists(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
