import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit
import os

private let downloadLogger = Logger(subsystem: "com.frostty.terminal", category: "DownloadManager")

@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    private let downloadsDirectory: URL

    init(downloadsDirectory: URL? = nil) {
        self.downloadsDirectory = downloadsDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        super.init()
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let sanitized = BrowserSecurity.sanitizeFilename(suggestedFilename)

        if let mimeType = response.mimeType, BrowserSecurity.isBlockedMIME(mimeType) {
            downloadLogger.warning("Blocked download with MIME type: \(mimeType)")
            return nil
        }

        let destination = downloadsDirectory.appendingPathComponent(sanitized)
        guard BrowserSecurity.validateDownloadPath(destination.path, allowedDirectory: downloadsDirectory.path) else {
            downloadLogger.error("Download path validation failed: \(destination.path)")
            return nil
        }

        return destination
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadLogger.error("Download failed: \(error.localizedDescription)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloadLogger.info("Download completed")
        if let url = download.progress.fileURL {
            setQuarantineAttribute(on: url)
        }
    }

    private func setQuarantineAttribute(on fileURL: URL) {
        let quarantineProperties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Frostty",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
        ]

        do {
            try (fileURL as NSURL).setResourceValue(quarantineProperties, forKey: .quarantinePropertiesKey)
            downloadLogger.info("Quarantine attribute set on \(fileURL.lastPathComponent)")
        } catch {
            downloadLogger.error("Failed to set quarantine on \(fileURL.path): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
