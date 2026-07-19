import Foundation

struct DownloadEntry: Codable {
    let id: String
    let name: String
    let size: Int64
    let received: Int64
    let progress: Double
    let done: Bool
    let failed: Bool
}
