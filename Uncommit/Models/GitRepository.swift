import Foundation

struct GitRepository: Identifiable, Codable, Hashable {
    let id: UUID
    let path: String
    var displayName: String
    /// Per-repo editor override. nil = use global default.
    var customEditorBundleId: String?

    // Transient state (not persisted)
    var status: GitRepoStatus?
    var lastChecked: Date?
    var isCheckingRemote: Bool = false
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id, path, displayName, customEditorBundleId
    }

    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // Hashable uses only id
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: GitRepository, rhs: GitRepository) -> Bool {
        lhs.id == rhs.id &&
        lhs.path == rhs.path &&
        lhs.displayName == rhs.displayName &&
        lhs.customEditorBundleId == rhs.customEditorBundleId &&
        lhs.status == rhs.status &&
        lhs.lastChecked == rhs.lastChecked &&
        lhs.isCheckingRemote == rhs.isCheckingRemote &&
        lhs.error == rhs.error
    }
}
