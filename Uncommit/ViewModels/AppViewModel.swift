import SwiftUI
import os

private let logger = Logger(subsystem: "com.uncommit.app", category: "AppViewModel")

@Observable
@MainActor
final class AppViewModel {
    var repositories: [GitRepository] = []
    var watchedFolders: [WatchedFolder] = []
    var isRefreshing: Bool = false
    var isCheckingAllRemotes: Bool = false
    var configuration: AppConfiguration = AppConfiguration()
    private(set) var hasStarted = false

    private let discoveryService = RepoDiscoveryService()
    private let monitor = RepoMonitor()
    private let persistence = PersistenceService()

    // MARK: - Path Helpers

    /// Resolves symlinks and normalizes a filesystem path for reliable comparison.
    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - Computed

    var overallHealth: RepoHealthLevel {
        if repositories.contains(where: { $0.error != nil }) { return .error }
        let levels = repositories.compactMap { $0.status?.healthLevel }
        if levels.isEmpty { return .clean }
        return levels.max() ?? .clean
    }

    var dirtyRepoCount: Int {
        repositories.filter { $0.status?.isClean == false || $0.status?.hasUnpulledChanges == true }.count
    }

    var menuBarIcon: String {
        switch overallHealth {
        case .clean: return "checkmark.circle.fill"
        case .localChanges: return "pencil.circle.fill"
        case .remoteOutOfSync: return "arrow.triangle.2.circlepath.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var menuBarIconColor: Color {
        switch overallHealth {
        case .clean: return .green
        case .localChanges: return .orange
        case .remoteOutOfSync: return .red
        case .error: return .red
        }
    }

    // MARK: - Lifecycle

    /// Called from the view layer (.onAppear) to ensure we're on MainActor
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let loaded = persistence.load()
        self.configuration = loaded
        self.repositories = loaded.repositories
        self.watchedFolders = loaded.watchedFolders

        // Normalize persisted paths to resolve symlinks / trailing slashes.
        // This fixes stale paths that were stored before normalization was added.
        var pathsChanged = false
        for i in repositories.indices {
            let normalized = Self.normalizePath(repositories[i].path)
            if normalized != repositories[i].path {
                logger.info("🔧 Normalized repo path: \(self.repositories[i].path) → \(normalized)")
                repositories[i] = GitRepository(
                    id: repositories[i].id,
                    path: normalized,
                    displayName: URL(fileURLWithPath: normalized).lastPathComponent,
                    customEditorBundleId: repositories[i].customEditorBundleId
                )
                pathsChanged = true
            }
        }
        for i in watchedFolders.indices {
            let normalized = Self.normalizePath(watchedFolders[i].path)
            if normalized != watchedFolders[i].path {
                logger.info("🔧 Normalized folder path: \(self.watchedFolders[i].path) → \(normalized)")
                watchedFolders[i] = WatchedFolder(
                    id: watchedFolders[i].id,
                    path: normalized,
                    displayName: URL(fileURLWithPath: normalized).lastPathComponent
                )
                pathsChanged = true
            }
        }

        // Deduplicate repos that now map to the same canonical path
        var seenPaths = Set<String>()
        let beforeCount = repositories.count
        repositories = repositories.filter { repo in
            if seenPaths.contains(repo.path) {
                logger.info("🗑 Removing duplicate repo after normalization: \(repo.displayName) (\(repo.path))")
                return false
            }
            seenPaths.insert(repo.path)
            return true
        }
        if repositories.count != beforeCount {
            pathsChanged = true
        }

        if pathsChanged {
            saveConfiguration()
        }

        logger.info("🚀 App started — \(self.repositories.count) repos, \(self.watchedFolders.count) watched folders")
        setupMonitorCallbacks()
        startMonitoring()
    }

    private func setupMonitorCallbacks() {
        monitor.onStatusUpdate = { [weak self] path, status in
            guard let self else { return }
            if let index = self.repositories.firstIndex(where: { $0.path == path }) {
                self.repositories[index].status = status
                self.repositories[index].lastChecked = Date()
                self.repositories[index].error = nil
            } else {
                let shortName = URL(fileURLWithPath: path).lastPathComponent
                logger.warning("⚠️ onStatusUpdate — no matching repo for path: \(path) (\(shortName)). Known paths: \(self.repositories.map(\.path).joined(separator: ", "))")
            }
        }
        monitor.onError = { [weak self] path, error in
            guard let self else { return }
            if let index = self.repositories.firstIndex(where: { $0.path == path }) {
                self.repositories[index].error = error
            } else {
                let shortName = URL(fileURLWithPath: path).lastPathComponent
                logger.warning("⚠️ onError — no matching repo for path: \(path) (\(shortName))")
            }
        }
    }

    private func startMonitoring() {
        monitor.startMonitoring(
            repos: repositories,
            localInterval: configuration.refreshIntervalSeconds,
            remoteInterval: configuration.remoteCheckIntervalSeconds,
            autoCheckRemote: configuration.autoCheckRemote
        )
    }

    // MARK: - User Actions

    func refreshAll() async {
        logger.info("👤 User action: Refresh All")
        isRefreshing = true
        defer { isRefreshing = false }

        // If the monitor is already refreshing (background cycle), wait for it
        // instead of silently skipping — the user expects fresh results.
        if monitor.isRefreshing {
            logger.info("👤 Refresh All — waiting for in-progress background refresh")
            while monitor.isRefreshing {
                try? await Task.sleep(for: .milliseconds(200))
            }
        } else {
            await monitor.refreshAllLocal()
        }

        // Diagnostic: report any repos still without status after a full refresh
        let stuckRepos = repositories.filter { $0.status == nil && $0.error == nil }
        if !stuckRepos.isEmpty {
            logger.warning("⚠️ After refreshAll, \(stuckRepos.count) repos still have no status: \(stuckRepos.map(\.displayName).joined(separator: ", "))")
        }
    }

    func checkRemote(for repo: GitRepository) async {
        logger.info("👤 User action: Check Remote — \(repo.displayName)")
        guard let index = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[index].isCheckingRemote = true
        await monitor.fetchAndCheckRemote(for: repo.path)
        if let idx = repositories.firstIndex(where: { $0.id == repo.id }) {
            repositories[idx].isCheckingRemote = false
        }
    }

    func checkAllRemotes() async {
        guard !isCheckingAllRemotes else {
            logger.debug("👤 checkAllRemotes skipped — already in progress")
            return
        }
        logger.info("👤 User action: Fetch All Remotes — \(self.repositories.count) repos")
        isCheckingAllRemotes = true
        defer { isCheckingAllRemotes = false }

        for i in repositories.indices {
            repositories[i].isCheckingRemote = true
        }

        let repos = repositories
        let maxConcurrent = 4

        await withTaskGroup(of: String.self) { group in
            var index = 0

            // Seed initial batch
            while index < min(maxConcurrent, repos.count) {
                let path = repos[index].path
                group.addTask {
                    await self.monitor.fetchAndCheckRemote(for: path)
                    return path
                }
                index += 1
            }

            // As each completes, clear its spinner and add the next repo
            for await completedPath in group {
                if let idx = repositories.firstIndex(where: { $0.path == completedPath }) {
                    repositories[idx].isCheckingRemote = false
                }

                if index < repos.count {
                    let nextPath = repos[index].path
                    group.addTask {
                        await self.monitor.fetchAndCheckRemote(for: nextPath)
                        return nextPath
                    }
                    index += 1
                }
            }
        }
    }

    private func addRepositoryQuietly(at path: String) {
        let normalized = Self.normalizePath(path)
        guard !repositories.contains(where: { $0.path == normalized }) else { return }
        let repo = GitRepository(
            id: UUID(),
            path: normalized,
            displayName: URL(fileURLWithPath: normalized).lastPathComponent
        )
        repositories.append(repo)
    }

    func addRepository(at path: String) {
        let normalized = Self.normalizePath(path)
        logger.info("➕ Adding repo: \(normalized)")
        addRepositoryQuietly(at: normalized)
        saveAndRestartMonitor()
    }

    func removeRepository(_ repo: GitRepository) {
        logger.info("➖ Removing repo: \(repo.displayName)")
        repositories.removeAll { $0.id == repo.id }
        saveAndRestartMonitor()
    }

    func addWatchedFolder(at path: String) async {
        let normalized = Self.normalizePath(path)
        guard !watchedFolders.contains(where: { $0.path == normalized }) else { return }
        let folder = WatchedFolder(
            id: UUID(),
            path: normalized,
            displayName: URL(fileURLWithPath: normalized).lastPathComponent
        )
        watchedFolders.append(folder)

        let discovered = await discoveryService.discoverRepositories(
            under: normalized,
            maxDepth: configuration.maxDiscoveryDepth
        )
        for repoPath in discovered {
            addRepositoryQuietly(at: repoPath)
        }
        saveAndRestartMonitor()
    }

    func removeWatchedFolder(_ folder: WatchedFolder) {
        watchedFolders.removeAll { $0.id == folder.id }
        repositories.removeAll { $0.path.hasPrefix(folder.path + "/") }
        saveAndRestartMonitor()
    }

    func rescanWatchedFolders() async {
        for folder in watchedFolders {
            let discovered = await discoveryService.discoverRepositories(
                under: folder.path,
                maxDepth: configuration.maxDiscoveryDepth
            )
            for repoPath in discovered {
                addRepositoryQuietly(at: repoPath)
            }
        }
        saveAndRestartMonitor()
    }

    // MARK: - Editor

    func setCustomEditor(for repo: GitRepository, bundleId: String?) {
        guard let index = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[index].customEditorBundleId = bundleId
        saveConfiguration()
    }

    // MARK: - Persistence

    func saveConfiguration() {
        configuration.repositories = repositories
        configuration.watchedFolders = watchedFolders
        persistence.save(configuration)
    }

    private func saveAndRestartMonitor() {
        logger.debug("💾 Saving config & restarting monitor")
        saveConfiguration()
        monitor.stopMonitoring()
        setupMonitorCallbacks()
        startMonitoring()
    }
}
