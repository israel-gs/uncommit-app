import AppKit

enum EditorHelper {

    /// Well-known code editors / IDEs with their bundle identifiers.
    private static let knownEditorBundleIds: [String] = [
        "com.microsoft.VSCode",
        "com.vscodium.VSCodium",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.WebStorm",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.CLion",
        "com.jetbrains.CLion-EAP",
        "com.jetbrains.rider",
        "com.jetbrains.goland",
        "com.jetbrains.rubymine",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.fleet",
        "com.apple.dt.Xcode",
        "dev.zed.Zed",
        "com.cursor.Cursor",
        "com.todesktop.230313mzl4w4u92",  // Cursor alternate
        "co.windsurf.windsurf",
        "com.github.atom",
        "com.panic.Nova",
        "com.barebones.bbedit",
        "com.macromates.TextMate",
        "com.coteditor.CotEditor",
        "abnerworks.Typora",
        "com.neovide.neovide",
        "net.kovidgoyal.kitty",
        "com.googlecode.iterm2",
        "com.antigravity.Antigravity",
    ]

    /// Returns editors currently installed on this Mac, sorted by name.
    static func installedEditors() -> [InstalledApp] {
        var result: [InstalledApp] = []
        var seenIds = Set<String>()

        for bundleId in knownEditorBundleIds {
            guard !seenIds.contains(bundleId) else { continue }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                let name = appName(at: url) ?? bundleId
                result.append(InstalledApp(id: bundleId, name: name, bundleURL: url))
                seenIds.insert(bundleId)
            }
        }

        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Open a folder path in the given editor bundle ID.
    static func openInEditor(path: String, bundleId: String) {
        let folderURL = URL(fileURLWithPath: path)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            // Fallback: reveal in Finder if the editor is not found
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open(
            [folderURL],
            withApplicationAt: appURL,
            configuration: configuration
        )
    }

    /// Resolve effective editor for a repo: per-repo override > global default > nil.
    static func effectiveEditorBundleId(repo: GitRepository, globalDefault: String?) -> String? {
        repo.customEditorBundleId ?? globalDefault
    }

    /// Display name for a bundle ID (looks up from installed apps).
    static func editorName(for bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return appName(at: url)
    }

    /// Let the user pick any .app from Finder via NSOpenPanel.
    @MainActor
    static func pickCustomApp() -> InstalledApp? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Select an application to use as your editor"
        panel.prompt = "Select"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else { return nil }
        let name = appName(at: url) ?? bundleId
        return InstalledApp(id: bundleId, name: name, bundleURL: url)
    }

    /// Returns the app icon for a given bundle ID, or nil if the app is not installed.
    static func appIcon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Private

    private static func appName(at url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }
}
