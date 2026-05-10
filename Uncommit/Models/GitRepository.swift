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

    // `lastChecked` is intentionally excluded: it changes on every refresh
    // cycle but isn't rendered. Including it would force SwiftUI to re-diff
    // every row on every poll even when nothing visible changed.
    static func == (lhs: GitRepository, rhs: GitRepository) -> Bool {
        lhs.id == rhs.id &&
        lhs.path == rhs.path &&
        lhs.displayName == rhs.displayName &&
        lhs.customEditorBundleId == rhs.customEditorBundleId &&
        lhs.status == rhs.status &&
        lhs.isCheckingRemote == rhs.isCheckingRemote &&
        lhs.error == rhs.error
    }
}
