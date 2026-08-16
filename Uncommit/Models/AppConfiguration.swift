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
    /// Bumped when a shipped default changes in a way that already-persisted
    /// configs need to be migrated to. See `AppViewModel.migrateIfNeeded()`.
    static let currentVersion = 1

    var refreshIntervalSeconds: TimeInterval = AppConstants.defaultRefreshInterval
    var autoCheckRemote: Bool = true
    var remoteCheckIntervalSeconds: TimeInterval = AppConstants.defaultRemoteCheckInterval
    var maxDiscoveryDepth: Int = AppConstants.defaultMaxDiscoveryDepth
    var repositories: [GitRepository] = []
    var watchedFolders: [WatchedFolder] = []
    var launchAtLogin: Bool = false
    /// Bundle identifier for the default editor app (e.g. "com.microsoft.VSCode").
    var defaultEditorBundleId: String?
    var repoDisplayMode: RepoDisplayMode = .list
    /// Version of the config that produced this value. A config written before
    /// versioning existed decodes as 0 and gets migrated on next launch.
    var configVersion: Int = AppConfiguration.currentVersion
    var popoverWidth: Double = AppConstants.defaultPopoverWidth
    var popoverHeight: Double = AppConstants.defaultPopoverHeight

    init() {}

    // Custom decoding so that adding new fields doesn't break configs persisted
    // before they existed. `PersistenceService.load()` uses `try?`, so a single
    // missing non-optional key would otherwise fail the whole decode and silently
    // reset the user's repositories and watched folders. `decodeIfPresent` with a
    // fallback to the property default keeps old configs intact.
    enum CodingKeys: String, CodingKey {
        case refreshIntervalSeconds, autoCheckRemote, remoteCheckIntervalSeconds
        case maxDiscoveryDepth, repositories, watchedFolders, launchAtLogin
        case defaultEditorBundleId, repoDisplayMode, configVersion
        case popoverWidth, popoverHeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshIntervalSeconds) ?? AppConstants.defaultRefreshInterval
        autoCheckRemote = try c.decodeIfPresent(Bool.self, forKey: .autoCheckRemote) ?? true
        remoteCheckIntervalSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .remoteCheckIntervalSeconds) ?? AppConstants.defaultRemoteCheckInterval
        maxDiscoveryDepth = try c.decodeIfPresent(Int.self, forKey: .maxDiscoveryDepth) ?? AppConstants.defaultMaxDiscoveryDepth
        repositories = try c.decodeIfPresent([GitRepository].self, forKey: .repositories) ?? []
        watchedFolders = try c.decodeIfPresent([WatchedFolder].self, forKey: .watchedFolders) ?? []
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        defaultEditorBundleId = try c.decodeIfPresent(String.self, forKey: .defaultEditorBundleId)
        repoDisplayMode = try c.decodeIfPresent(RepoDisplayMode.self, forKey: .repoDisplayMode) ?? .list
        // Absent = written before versioning existed, so it needs migrating.
        configVersion = try c.decodeIfPresent(Int.self, forKey: .configVersion) ?? 0
        popoverWidth = try c.decodeIfPresent(Double.self, forKey: .popoverWidth) ?? AppConstants.defaultPopoverWidth
        popoverHeight = try c.decodeIfPresent(Double.self, forKey: .popoverHeight) ?? AppConstants.defaultPopoverHeight
    }
}

// MARK: - Installed App Info (for editor picker)

struct InstalledApp: Identifiable, Hashable {
    let id: String          // bundle identifier
    let name: String
    let bundleURL: URL

    /// Memoized — this is read inside `ForEach` bodies that re-render often.
    @MainActor
    var icon: NSImage {
        EditorHelper.icon(atPath: bundleURL.path)
    }
}
