#if os(macOS)
import Foundation
import WebKit

final class DownloadManager: NSObject, WKDownloadDelegate {

    private final class ActiveDownload {
        let id = UUID().uuidString
        let download: WKDownload
        var filename: String = "download"
        var observation: NSKeyValueObservation?
        var failed = false

        init(download: WKDownload) {
            self.download = download
        }
    }

    private var active: [ActiveDownload] = []
    private var lastBroadcast = Date.distantPast

    var onChange: (() -> Void)?

    func adopt(_ download: WKDownload) {
        download.delegate = self
        let item = ActiveDownload(download: download)
        item.observation = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            DispatchQueue.main.async { self?.throttledChange() }
        }
        active.append(item)
        notifyChange()
    }

    private func throttledChange() {
        guard Date().timeIntervalSince(lastBroadcast) > 0.4 else { return }
        notifyChange()
    }

    private func notifyChange() {
        lastBroadcast = Date()
        onChange?()
    }

    func entries() -> [DownloadEntry] {
        var result: [DownloadEntry] = active.map { item in
            let progress = item.download.progress
            return DownloadEntry(
                id: item.id,
                name: item.filename,
                size: progress.totalUnitCount,
                received: progress.completedUnitCount,
                progress: progress.fractionCompleted,
                done: false,
                failed: item.failed
            )
        }

        let activeNames = Set(active.map(\.filename))
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Paths.downloadsDirectory,
                                                 includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let completed = files
            .filter { !activeNames.contains($0.lastPathComponent) }
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

    func cancel(id: String) {
        guard let item = active.first(where: { $0.id == id }) else { return }
        item.download.cancel { [weak self] _ in
            DispatchQueue.main.async {
                self?.active.removeAll { $0.id == id }
                self?.notifyChange()
            }
        }
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

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        Paths.ensureDownloadsDirectory()
        let fm = FileManager.default
        let base = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var candidate = base
        var counter = 1
        while fm.fileExists(atPath: Paths.downloadsDirectory.appendingPathComponent(candidate).path) {
            let ext = (base as NSString).pathExtension
            let stem = (base as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            counter += 1
        }
        if let item = active.first(where: { $0.download === download }) {
            item.filename = candidate
        }
        notifyChange()
        completionHandler(Paths.downloadsDirectory.appendingPathComponent(candidate))
    }

    func downloadDidFinish(_ download: WKDownload) {
        active.removeAll { $0.download === download }
        notifyChange()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        NSLog("Kraken: download failed: \(error.localizedDescription)")
        if let item = active.first(where: { $0.download === download }) {
            item.failed = true
        }
        notifyChange()
        // Drop the failed entry after a short grace period so the client sees the failure.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.active.removeAll { $0.download === download }
            self?.notifyChange()
        }
    }
}
#endif
