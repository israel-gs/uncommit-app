import Foundation

struct GitRepository: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let path: String
    var displayName: String
    /// Per-repo editor override. nil = use global default.
    var customEditorBundleId: String?
    /// Pinned repos are sorted to the top of the list.
    var isPinned: Bool = false

    var folderName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    init(
        id: UUID,
        path: String,
        displayName: String,
        customEditorBundleId: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.customEditorBundleId = customEditorBundleId
        self.isPinned = isPinned
    }

    // Custom decoding so that adding `isPinned` doesn't break configs
    // persisted before this field existed (a missing key would otherwise
    // fail the whole decode and reset the user's config).
    enum CodingKeys: String, CodingKey {
        case id, path, displayName, customEditorBundleId, isPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        displayName = try c.decode(String.self, forKey: .displayName)
        customEditorBundleId = try c.decodeIfPresent(String.self, forKey: .customEditorBundleId)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}
