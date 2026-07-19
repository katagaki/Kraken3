import Foundation

final class HeadlessDownloads {

    private struct Item {
        let guid: String
        let name: String
        var total: Int64 = 0
        var received: Int64 = 0
        var failed = false
    }

    private var active: [Item] = []
    private var lastBroadcast = Date.distantPast

    var onChange: (() -> Void)?

    func handleWillBegin(guid: String, suggestedFilename: String) {
        Paths.ensureDownloadsDirectory()
        let base = suggestedFilename.isEmpty ? "download" : suggestedFilename
        active.append(Item(guid: guid, name: availableName(for: base)))
        notifyChange()
    }

    func handleProgress(guid: String, total: Int64, received: Int64, state: String) {
        guard let index = active.firstIndex(where: { $0.guid == guid }) else { return }
        switch state {
        case "completed":
            let item = active.remove(at: index)
            // With allowAndName, Chromium writes the file under its GUID.
            let partial = Paths.downloadsDirectory.appendingPathComponent(item.guid)
            let final = Paths.downloadsDirectory.appendingPathComponent(item.name)
            try? FileManager.default.moveItem(at: partial, to: final)
            notifyChange()
        case "canceled":
            active[index].failed = true
            notifyChange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.active.removeAll { $0.guid == guid }
                self?.notifyChange()
            }
        default:
            active[index].total = total
            active[index].received = received
            throttledChange()
        }
    }

    func entries() -> [DownloadEntry] {
        var result: [DownloadEntry] = active.map { item in
            DownloadEntry(
                id: item.guid,
                name: item.name,
                size: item.total,
                received: item.received,
                progress: item.total > 0 ? Double(item.received) / Double(item.total) : 0,
                done: false,
                failed: item.failed
            )
        }

        let activeGuids = Set(active.map(\.guid))
        let activeNames = Set(active.map(\.name))
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.downloadsDirectory,
                                                 includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let completed = files
            .filter { !activeGuids.contains($0.lastPathComponent) && !activeNames.contains($0.lastPathComponent) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .map { url -> DownloadEntry in
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                return DownloadEntry(id: url.lastPathComponent, name: url.lastPathComponent,
                                     size: size, received: size, progress: 1, done: true, failed: false)
            }
        result.append(contentsOf: completed)
        return result
    }

    func deleteFile(named name: String) -> Bool {
        guard !name.contains("/"), !name.contains(".."), !name.isEmpty else { return false }
        let url = Paths.downloadsDirectory.appendingPathComponent(name)
        let ok = (try? FileManager.default.removeItem(at: url)) != nil
        if ok { notifyChange() }
        return ok
    }

    func fileURL(named name: String) -> URL? {
        guard !name.contains("/"), !name.contains(".."), !name.isEmpty else { return nil }
        let url = Paths.downloadsDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func availableName(for base: String) -> String {
        let fm = FileManager.default
        let activeNames = Set(active.map(\.name))
        var candidate = base
        var counter = 1
        while activeNames.contains(candidate)
            || fm.fileExists(atPath: Paths.downloadsDirectory.appendingPathComponent(candidate).path) {
            let ext = (base as NSString).pathExtension
            let stem = (base as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func throttledChange() {
        guard Date().timeIntervalSince(lastBroadcast) > 0.4 else { return }
        notifyChange()
    }

    private func notifyChange() {
        lastBroadcast = Date()
        onChange?()
    }
}
