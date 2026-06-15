import Foundation

@MainActor
@Observable
final class MarkdownPreviewSession {
    private static let pollInterval: Duration = .milliseconds(800)

    let browserController = BrowserTabController(initialURL: URL(string: "about:blank")!)

    var isPresented: Bool = false
    var sourceURL: URL?
    var sourceTabID: UUID?
    var sourcePaneID: UUID?
    var displayTitle: String = "Markdown Preview"
    var displayPath: String = ""
    var statusMessage: String = "Choose a Markdown file to preview."
    var errorMessage: String?
    var isRendering: Bool = false

    private var sourceSignature: MarkdownPreviewFileSignature?
    private var watchTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration: UInt64 = 0
    private var configChangeObserver: NSObjectProtocol?

    init() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPresented else { return }
                self.reload()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            if let configChangeObserver {
                NotificationCenter.default.removeObserver(configChangeObserver)
            }
            watchTask?.cancel()
            renderTask?.cancel()
        }
    }

    func present(sourceURL url: URL, sourceTabID: UUID, sourcePaneID: UUID?) {
        let normalizedURL = url.standardizedFileURL
        self.sourceURL = normalizedURL
        self.sourceTabID = sourceTabID
        self.sourcePaneID = sourcePaneID
        self.displayTitle = normalizedURL.lastPathComponent
        self.displayPath = normalizedURL.path
        self.statusMessage = "Watching for changes..."
        self.errorMessage = nil
        self.isPresented = true

        reload()
        startWatching()
    }

    func dismiss() {
        renderGeneration &+= 1
        watchTask?.cancel()
        watchTask = nil
        renderTask?.cancel()
        renderTask = nil

        isPresented = false
        isRendering = false
        sourceURL = nil
        sourceTabID = nil
        sourcePaneID = nil
        sourceSignature = nil
        displayTitle = "Markdown Preview"
        displayPath = ""
        statusMessage = "Choose a Markdown file to preview."
        errorMessage = nil
    }

    func reload() {
        guard let sourceURL else { return }

        renderGeneration &+= 1
        let generation = renderGeneration
        let theme = MarkdownPreviewTheme.live()
        sourceSignature = MarkdownPreviewDocument.signature(for: sourceURL)
        isRendering = true
        errorMessage = nil
        statusMessage = "Rendering \(sourceURL.lastPathComponent)..."

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MarkdownPreviewDocument.renderSource(at: sourceURL, theme: theme) }
            }.value

            guard let self, !Task.isCancelled, generation == self.renderGeneration else { return }
            self.isRendering = false

            switch result {
            case .success(let renderResult):
                self.sourceSignature = renderResult.signature
                self.displayTitle = renderResult.title
                self.displayPath = renderResult.displayURL.path
                self.statusMessage = "Watching for changes..."
                self.errorMessage = nil
                self.browserController.loadHTMLString(
                    renderResult.html,
                    baseURL: renderResult.baseURL,
                    displayURL: renderResult.displayURL,
                    title: renderResult.title,
                    enablePreviewBridge: true
                )

            case .failure(let error):
                self.statusMessage = "Unable to render preview."
                self.errorMessage = error.localizedDescription
                let errorURL = sourceURL.standardizedFileURL
                self.browserController.loadHTMLString(
                    MarkdownPreviewDocument.errorHTML(for: errorURL, message: error.localizedDescription, theme: theme),
                    baseURL: errorURL.deletingLastPathComponent(),
                    displayURL: errorURL,
                    title: errorURL.lastPathComponent
                )
            }
        }
    }

    private func startWatching() {
        watchTask?.cancel()

        guard let watchedURL = sourceURL else { return }

        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.pollForSourceChanges(expectedURL: watchedURL)
            }
        }
    }

    private func pollForSourceChanges(expectedURL: URL) {
        guard isPresented, !isRendering else { return }
        guard sourceURL == expectedURL else { return }

        let latestSignature = MarkdownPreviewDocument.signature(for: expectedURL)
        guard latestSignature != sourceSignature else { return }

        sourceSignature = latestSignature
        reload()
    }
}
