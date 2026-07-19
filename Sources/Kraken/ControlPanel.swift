#if os(macOS)
import AppKit

final class ControlPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    let window: NSWindow

    private let downloadManager: DownloadManager
    private let homepageField = NSTextField()
    private let tableView = NSTableView()
    private var entries: [DownloadEntry] = []

    var onHomepageChange: ((String) -> Void)?

    init(downloadManager: DownloadManager, addresses: [String], httpPort: UInt16, homepage: String) {
        self.downloadManager = downloadManager
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Kraken Server"
        window.delegate = self
        buildUI(addresses: addresses, httpPort: httpPort, homepage: homepage)
        window.center()
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // MARK: - UI construction

    private func buildUI(addresses: [String], httpPort: UInt16, homepage: String) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Kraken is serving the remote browser at:")
        heading.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(heading)

        if addresses.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "http://localhost:\(httpPort)/"))
        }
        for address in addresses {
            let label = NSTextField(labelWithString: "http://\(address):\(httpPort)/")
            label.isSelectable = true
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            stack.addArrangedSubview(label)
        }

        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)

        let homepageLabel = NSTextField(labelWithString: "Homepage for new tabs")
        homepageLabel.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(homepageLabel)

        homepageField.stringValue = homepage
        homepageField.placeholderString = "https://example.com"
        homepageField.target = self
        homepageField.action = #selector(saveHomepage)
        let saveButton = NSButton(title: "Set", target: self, action: #selector(saveHomepage))
        let homepageRow = NSStackView(views: [homepageField, saveButton])
        homepageRow.orientation = .horizontal
        homepageRow.spacing = 8
        stack.addArrangedSubview(homepageRow)

        stack.setCustomSpacing(20, after: homepageRow)

        let downloadsLabel = NSTextField(labelWithString: "Downloads")
        downloadsLabel.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(downloadsLabel)

        let column = NSTableColumn(identifier: .init("file"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)

        let deleteButton = NSButton(title: "Delete Selected", target: self, action: #selector(deleteSelected))
        let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealInFinder))
        let buttonRow = NSStackView(views: [deleteButton, revealButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)

        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            homepageRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    // MARK: - Actions

    @objc private func saveHomepage() {
        var value = homepageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if !value.contains("://") {
            value = "https://\(value)"
        }
        homepageField.stringValue = value
        onHomepageChange?(value)
    }

    @objc private func deleteSelected() {
        for row in tableView.selectedRowIndexes where entries.indices.contains(row) {
            let entry = entries[row]
            if entry.done {
                _ = downloadManager.deleteFile(named: entry.name)
            } else {
                downloadManager.cancel(id: entry.id)
            }
        }
    }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.downloadsDirectory])
    }

    // MARK: - Downloads table

    func refresh() {
        entries = downloadManager.entries()
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let text: String
        if entry.failed {
            text = "\(entry.name) - failed"
        } else if entry.done {
            text = "\(entry.name) - \(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))"
        } else {
            text = "\(entry.name) - \(Int(entry.progress * 100))% downloading"
        }

        let identifier = NSUserInterfaceItemIdentifier("fileCell")
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
            view.stringValue = text
            return view
        }
        let label = NSTextField(labelWithString: text)
        label.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
#endif
