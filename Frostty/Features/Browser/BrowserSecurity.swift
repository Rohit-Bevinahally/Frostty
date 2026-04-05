import Foundation

enum BrowserSecurity {
    static let maxRedirectDepth: Int = 10

    private static let allowedTopLevelSchemes: Set<String> = [
        "http",
        "https",
        "about",
    ]

    private static let blockedSubresourceSchemes: Set<String> = [
        "javascript",
        "data",
    ]

    static func isAllowedTopLevelScheme(_ scheme: String) -> Bool {
        allowedTopLevelSchemes.contains(scheme.lowercased())
    }

    static func isAllowedSubresourceScheme(_ scheme: String) -> Bool {
        !blockedSubresourceSchemes.contains(scheme.lowercased())
    }

    private static let dangerousExtensions: Set<String> = [
        "exe", "scr", "bat", "cmd", "com", "pif", "vbs", "js", "wsh", "msi",
        "app", "dmg", "pkg", "command", "sh", "workflow", "action",
    ]

    static func sanitizeFilename(_ filename: String) -> String {
        var sanitized = filename.replacingOccurrences(of: "\0", with: "")
        sanitized = sanitized
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        while sanitized.hasPrefix(".") {
            sanitized = String(sanitized.dropFirst())
        }

        let nsName = sanitized as NSString
        let ext = nsName.pathExtension.lowercased()
        if dangerousExtensions.contains(ext) {
            sanitized = nsName.deletingPathExtension
        }

        if sanitized.count > 255 {
            sanitized = String(sanitized.prefix(255))
        }

        if sanitized.isEmpty {
            sanitized = "download"
        }

        return sanitized
    }

    private static let blockedMIMETypes: Set<String> = [
        "application/x-msdownload",
        "application/x-msdos-program",
        "application/x-dosexec",
    ]

    static func isBlockedMIME(_ mime: String) -> Bool {
        blockedMIMETypes.contains(mime.lowercased())
    }

    static func validateDownloadPath(_ path: String, allowedDirectory: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        let parentDir = (standardized as NSString).deletingLastPathComponent
        let filename = (standardized as NSString).lastPathComponent
        let resolvedParent = (parentDir as NSString).resolvingSymlinksInPath
        let resolvedPath = (resolvedParent as NSString).appendingPathComponent(filename)
        let resolvedAllowed = (allowedDirectory as NSString).resolvingSymlinksInPath

        return resolvedPath.hasPrefix(resolvedAllowed + "/") || resolvedPath == resolvedAllowed
    }
}
