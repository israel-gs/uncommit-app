import AppKit
import Foundation

/// How the repository list is laid out in the popover.
enum RepoDisplayMode: String, Codable {
    /// A single flat list of every repository.
    case list
    /// Repositories grouped into tabs by their root (watched) folder.
    case grouped
}

struct AppConfiguration: Codable {
    var refreshIntervalSeconds: TimeInterval = 30
    var autoCheckRemote: Bool = false
    var remoteCheckIntervalSeconds: TimeInterval = 300
    var maxDiscoveryDepth: Int = 3
    var repositories: [GitRepository] = []
    var watchedFolders: [WatchedFolder] = []
    var launchAtLogin: Bool = false
    /// Bundle identifier for the default editor app (e.g. "com.microsoft.VSCode").
    var defaultEditorBundleId: String?
    var repoDisplayMode: RepoDisplayMode = .list

    init() {}

    // Custom decoding so that adding new fields doesn't break configs persisted
    // before they existed. `PersistenceService.load()` uses `try?`, so a single
    // missing non-optional key would otherwise fail the whole decode and silently
    // reset the user's repositories and watched folders. `decodeIfPresent` with a
    // fallback to the property default keeps old configs intact.
    enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds, autoCheckRemote, remoteCheckIntervalSeconds
        case maxDiscoveryDepth, repositories, watchedFolders, launchAtLogin
        case defaultEditorBundleId, repoDisplayMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshIntervalSeconds) ?? 30
        autoCheckRemote = try c.decodeIfPresent(Bool.self, forKey: .autoCheckRemote) ?? false
        remoteCheckIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .remoteCheckIntervalSeconds) ?? 300
        maxDiscoveryDepth = try c.decodeIfPresent(Int.self, forKey: .maxDiscoveryDepth) ?? 3
        repositories = try c.decodeIfPresent([GitRepository].self, forKey: .repositories) ?? []
        watchedFolders = try c.decodeIfPresent([WatchedFolder].self, forKey: .watchedFolders) ?? []
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        defaultEditorBundleId = try c.decodeIfPresent(String.self, forKey: .defaultEditorBundleId)
        repoDisplayMode = try c.decodeIfPresent(RepoDisplayMode.self, forKey: .repoDisplayMode) ?? .list
    }
}

// MARK: - Installed App Info (for editor picker)

struct InstalledApp: Identifiable, Hashable {
    let id: String          // bundle identifier
    let name: String
    let bundleURL: URL

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
}
