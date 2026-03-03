import AppKit
import Foundation

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
