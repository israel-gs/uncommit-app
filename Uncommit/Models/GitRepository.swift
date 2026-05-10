import Foundation

struct GitRepository: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let path: String
    var displayName: String
    /// Per-repo editor override. nil = use global default.
    var customEditorBundleId: String?

    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
