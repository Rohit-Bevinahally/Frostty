// SearchBarView.swift
// Frostty
//
// Minimal search bar for terminal scrollback search.

import AppKit

@MainActor
final class SearchBarView: NSView {

    weak var sender: GhosttySurfaceController?

    var lastSubmittedQuery: String = ""

    private let searchField = NSTextField()
    private let totalLabel = NSTextField(labelWithString: "")
    private let selectedLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.95).cgColor
        layer?.cornerRadius = 6

        searchField.placeholderString = "Search..."
        searchField.isBordered = true
        searchField.bezelStyle = .roundedBezel
        searchField.font = .systemFont(ofSize: 13)
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        totalLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        totalLabel.textColor = .secondaryLabelColor
        totalLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(totalLabel)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

            totalLabel.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            totalLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            totalLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func searchFieldAction(_ sender: NSTextField) {
        let query = sender.stringValue
        guard !query.isEmpty else { return }
        lastSubmittedQuery = query
        self.sender?.performAction("search:" + query)
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    func setSearchText(_ text: String) {
        searchField.stringValue = text
    }

    func resetSearchState() {
        totalLabel.stringValue = ""
        selectedLabel.stringValue = ""
    }

    func updateTotal(_ total: Int) {
        totalLabel.stringValue = total > 0 ? "\(total) results" : "No results"
    }

    func updateSelected(_ selected: Int) {
        selectedLabel.stringValue = "\(selected)"
    }
}
