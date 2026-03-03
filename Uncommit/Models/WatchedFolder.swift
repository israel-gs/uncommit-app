import Foundation

struct WatchedFolder: Identifiable, Codable, Hashable {
    let id: UUID
    let path: String
    var displayName: String

    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
