import SwiftUI
import os

private let logger = Logger(subsystem: "com.uncommit.app", category: "AppViewModel")

@Observable
@MainActor
final class AppViewModel {
    // MARK: - Persistent state
    var repositories: [GitRepository] = []
    var watchedFolders: [WatchedFolder] = []
    var configuration: AppConfiguration = AppConfiguration()

    // MARK: - Transient state (split into separate dicts so a status update
    // for one repo doesn't invalidate observers of the repository array.)
    var statuses: [UUID: GitRepoStatus] = [:]
    var errors: [UUID: String] = [:]
    var checkingRemote: Set<UUID> = []
    var lastFullRefreshAt: Date?
    /// Paths reported as missing during the current refresh cycle. We collect
    /// them here and prune at end-of-cycle to avoid mutating `repositories`
    /// while the monitor is iterating it.
    private var missingPaths: Set<String> = []

    var isRefreshing: Bool = false
    var isCheckingAllRemotes: Bool = false
    private(set) var hasStarted = false

    private let discoveryService = RepoDiscoveryService()
    private let monitor = RepoMonitor()
    private let persistence = PersistenceService()

    // MARK: - Path Helpers

    /// Resolves symlinks and normalizes a filesystem path for reliable comparison.
    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func repoId(for path: String) -> UUID? {
        repositories.first(where: { $0.path == path })?.id
    }

    /// True only when we're confident the path is genuinely gone — not when
    /// it's unreachable because, e.g., an external volume is unmounted. The
    /// heuristic: if the path doesn't exist BUT its parent directory does,
    /// the user almost certainly deleted the folder. If the parent is also
    /// missing, the whole volume is probably away and we leave it alone.
    private static func isPathDefinitelyMissing(_ path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return fm.fileExists(atPath: parent)
    }

    // MARK: - Per-repo accessors (used by views)

    func status(for repo: GitRepository) -> GitRepoStatus? { statuses[repo.id] }
    func error(for repo: GitRepository) -> String? { errors[repo.id] }
    func isCheckingRemote(_ repo: GitRepository) -> Bool { checkingRemote.contains(repo.id) }

    func healthLevel(for repo: GitRepository) -> RepoHealthLevel {
        if errors[repo.id] != nil { return .error }
        return statuses[repo.id]?.healthLevel ?? .error
    }

    // MARK: - Computed

    var overallHealth: RepoHealthLevel {
        if !errors.isEmpty { return .error }
        let levels = statuses.values.map(\.healthLevel)
        if levels.isEmpty { return .clean }
        return levels.max() ?? .clean
    }

    var dirtyRepoCount: Int {
        statuses.values.filter {
            !$0.isClean || $0.hasUnpulledChanges || $0.hasUnpushedChanges
        }.count
    }

    var menuBarIcon: String {
        MenuBarIconProvider.symbolName(for: overallHealth)
    }

    var menuBarIconColor: Color {
        MenuBarIconProvider.color(for: overallHealth)
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

        // Drop repos whose folder no longer exists on disk. This catches the
        // common case of the user deleting a folder while the app was closed.
        let pruned = pruneMissingRepositoriesAndFolders()
        if pruned > 0 || pathsChanged {
            saveConfiguration()
        }

        logger.info("🚀 App started — \(self.repositories.count) repos, \(self.watchedFolders.count) watched folders")
        setupMonitorCallbacks()
        startMonitoring()
    }

    /// Removes repos and watched folders whose path no longer exists on disk.
    /// Returns the number of entries removed.
    @discardableResult
    private func pruneMissingRepositoriesAndFolders() -> Int {
        var removed = 0

        let missingRepos = repositories.filter { Self.isPathDefinitelyMissing($0.path) }
        for repo in missingRepos {
            logger.info("🗑 Auto-removing missing repo: \(repo.displayName) (\(repo.path))")
            forgetTransientState(for: repo.id)
        }
        if !missingRepos.isEmpty {
            let missingIds = Set(missingRepos.map(\.id))
            repositories.removeAll { missingIds.contains($0.id) }
            removed += missingRepos.count
        }

        let missingFolders = watchedFolders.filter { Self.isPathDefinitelyMissing($0.path) }
        for folder in missingFolders {
            logger.info("🗑 Auto-removing missing watched folder: \(folder.displayName) (\(folder.path))")
        }
        if !missingFolders.isEmpty {
            let missingIds = Set(missingFolders.map(\.id))
            watchedFolders.removeAll { missingIds.contains($0.id) }
            removed += missingFolders.count
        }

        return removed
    }

    private func setupMonitorCallbacks() {
        monitor.onStatusUpdate = { [weak self] path, status in
            guard let self else { return }
            guard let id = self.repoId(for: path) else {
                let shortName = URL(fileURLWithPath: path).lastPathComponent
                logger.warning("⚠️ onStatusUpdate — no matching repo for path: \(path) (\(shortName))")
                return
            }
            self.statuses[id] = status
            self.errors[id] = nil
        }
        monitor.onError = { [weak self] path, error in
            guard let self else { return }
            // If the path is definitely gone (and not just unreachable due
            // to an unmounted volume), queue it for removal at end-of-cycle.
            if Self.isPathDefinitelyMissing(path) {
                self.missingPaths.insert(path)
            }
            if let id = self.repoId(for: path) {
                self.errors[id] = error
            }
        }
        monitor.onCycleCompleted = { [weak self] in
            guard let self else { return }
            self.lastFullRefreshAt = Date()
            self.processMissingPaths()
        }
    }

    /// Called at the end of each refresh cycle. Removes repos whose paths
    /// went missing (and prunes any watched folder that's also gone), then
    /// restarts the monitor with the new list.
    private func processMissingPaths() {
        guard !missingPaths.isEmpty else { return }
        let paths = missingPaths
        missingPaths.removeAll()

        let toRemove = repositories.filter { paths.contains($0.path) }
        guard !toRemove.isEmpty else { return }

        for repo in toRemove {
            logger.info("🗑 Auto-removing missing repo: \(repo.displayName) (\(repo.path))")
            forgetTransientState(for: repo.id)
        }
        let removedIds = Set(toRemove.map(\.id))
        repositories.removeAll { removedIds.contains($0.id) }

        // Prune any watched folder that itself disappeared (the repos under
        // it would already be in `paths`).
        let fm = FileManager.default
        let missingFolders = watchedFolders.filter { !fm.fileExists(atPath: $0.path) }
        if !missingFolders.isEmpty {
            for folder in missingFolders {
                logger.info("🗑 Auto-removing missing watched folder: \(folder.displayName)")
            }
            let missingFolderIds = Set(missingFolders.map(\.id))
            watchedFolders.removeAll { missingFolderIds.contains($0.id) }
        }

        saveAndRestartMonitor()
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
        let stuckRepos = repositories.filter {
            statuses[$0.id] == nil && errors[$0.id] == nil
        }
        if !stuckRepos.isEmpty {
            logger.warning("⚠️ After refreshAll, \(stuckRepos.count) repos still have no status: \(stuckRepos.map(\.displayName).joined(separator: ", "))")
        }
    }

    func checkRemote(for repo: GitRepository) async {
        logger.info("👤 User action: Check Remote — \(repo.displayName)")
        checkingRemote.insert(repo.id)
        defer { checkingRemote.remove(repo.id) }
        await monitor.fetchAndCheckRemote(for: repo.path)
    }

    func checkAllRemotes() async {
        guard !isCheckingAllRemotes else {
            logger.debug("👤 checkAllRemotes skipped — already in progress")
            return
        }
        logger.info("👤 User action: Fetch All Remotes — \(self.repositories.count) repos")
        isCheckingAllRemotes = true
        defer { isCheckingAllRemotes = false }

        for repo in repositories {
            checkingRemote.insert(repo.id)
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
                if let id = self.repoId(for: completedPath) {
                    self.checkingRemote.remove(id)
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

    func pull(_ repo: GitRepository) async {
        logger.info("👤 User action: Pull — \(repo.displayName)")
        checkingRemote.insert(repo.id)
        defer { checkingRemote.remove(repo.id) }
        do {
            try await GitService.pull(at: repo.path)
            errors[repo.id] = nil
            await refreshSingle(repo)
        } catch {
            errors[repo.id] = error.localizedDescription
        }
    }

    func push(_ repo: GitRepository) async {
        logger.info("👤 User action: Push — \(repo.displayName)")
        checkingRemote.insert(repo.id)
        defer { checkingRemote.remove(repo.id) }
        do {
            try await GitService.push(at: repo.path)
            errors[repo.id] = nil
            await refreshSingle(repo)
        } catch {
            errors[repo.id] = error.localizedDescription
        }
    }

    private func refreshSingle(_ repo: GitRepository) async {
        let result = await GitService.fullStatus(at: repo.path)
        switch result {
        case .success(let status):
            statuses[repo.id] = status
        case .failure(let err):
            errors[repo.id] = err.localizedDescription
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
        forgetTransientState(for: repo.id)
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
        // The folder itself can be a repo (== match), or a parent of repos
        // (hasPrefix with trailing slash to avoid matching sibling paths
        // that share a prefix, e.g. "/foo" and "/foobar").
        let removed = repositories.filter {
            $0.path == folder.path || $0.path.hasPrefix(folder.path + "/")
        }
        repositories.removeAll {
            $0.path == folder.path || $0.path.hasPrefix(folder.path + "/")
        }
        for repo in removed {
            forgetTransientState(for: repo.id)
        }
        saveAndRestartMonitor()
    }

    func rescanWatchedFolders() async {
        // Prune first so deleted folders don't linger.
        pruneMissingRepositoriesAndFolders()

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

    private func forgetTransientState(for id: UUID) {
        statuses[id] = nil
        errors[id] = nil
        checkingRemote.remove(id)
    }

    // MARK: - Editor

    func setCustomEditor(for repo: GitRepository, bundleId: String?) {
        guard let index = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[index].customEditorBundleId = bundleId
        saveConfiguration()
    }

    func reportEditorError(for repo: GitRepository, message: String) {
        errors[repo.id] = message
        let id = repo.id
        // Auto-clear after 4s so the error doesn't linger.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if self.errors[id] == message {
                self.errors[id] = nil
            }
        }
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
