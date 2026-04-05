import Foundation

enum BrowserAddressResolution {
    /// Resolves omnibar input to an `http`, `https`, or `about` URL, or a Google search URL.
    static func url(forUserInput raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.lowercased().hasPrefix("about:") {
            return URL(string: trimmed)
        }

        if let direct = URL(string: trimmed),
           let scheme = direct.scheme?.lowercased(),
           BrowserSecurity.isAllowedTopLevelScheme(scheme) {
            if scheme == "about" {
                return direct
            }
            if let host = direct.host, !host.isEmpty {
                return direct
            }
        }

        let withHTTPS: String
        if !trimmed.contains("://") {
            withHTTPS = "https://\(trimmed)"
        } else {
            withHTTPS = trimmed
        }

        if let url = URL(string: withHTTPS),
           let scheme = url.scheme?.lowercased(),
           BrowserSecurity.isAllowedTopLevelScheme(scheme),
           let host = url.host,
           !host.isEmpty {
            let looksLikeHost =
                host.contains(".")
                || host == "localhost"
                || host.hasPrefix("[")
                || host.contains(":")
            if looksLikeHost {
                return url
            }
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    /// Text shown in the omnibar; empty for `about:blank` so the placeholder is visible.
    static func omnibarDisplayString(for url: URL) -> String {
        if url.absoluteString.lowercased() == "about:blank" {
            return ""
        }
        return url.absoluteString
    }
}
