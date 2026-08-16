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

    // MARK: - Transient state
    //
    // One observable object per repo. Observation tracks dependencies per
    // PROPERTY, so the previous `[UUID: GitRepoStatus]` dictionary made every
    // row depend on every other row's updates. This dictionary only changes
    // when repos are added or removed; the per-repo values live inside the
    // RepoState objects, where a change reaches just the row that shows it.
    private(set) var repoStates: [UUID: RepoState] = [:]
    var lastFullRefreshAt: Date?
    /// Paths reported as missing during the current refresh cycle. We collect
    /// them here and prune at end-of-cycle to avoid mutating `repositories`
    /// while the monitor is iterating it.
    private var missingPaths: Set<String> = []

    var isRefreshing: Bool = false
    var isCheckingAllRemotes: Bool = false
    var isPullingAll: Bool = false
    private(set) var hasStarted = false

    /// Drives the single shared commits window. Clicking an ahead/behind badge
    /// sets this; the window swaps its content instead of spawning a new window.
    var commitsRequest: CommitsWindowRequest?

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

    /// The observable state object for a repo. Views read through it, so a
    /// status update reaches only the row that shows that repo.
    func state(for repo: GitRepository) -> RepoState? { repoStates[repo.id] }

    func status(for repo: GitRepository) -> GitRepoStatus? { repoStates[repo.id]?.status }
    func error(for repo: GitRepository) -> String? { repoStates[repo.id]?.error }
    func isCheckingRemote(_ repo: GitRepository) -> Bool { repoStates[repo.id]?.isCheckingRemote ?? false }

    /// Creates state objects for new repos and drops the ones whose repo is
    /// gone. Called from every path that mutates `repositories`.
    ///
    /// Internal rather than private so tests can populate a view model the same
    /// way the app does, instead of reaching past this invariant.
    func syncRepoStates() {
        let live = Set(repositories.map(\.id))
        for id in live where repoStates[id] == nil {
            repoStates[id] = RepoState()
        }
        for id in repoStates.keys where !live.contains(id) {
            repoStates[id] = nil
        }
    }

    private func setCheckingRemote(_ checking: Bool, for id: UUID) {
        repoStates[id]?.isCheckingRemote = checking
    }

    private func setError(_ message: String?, for id: UUID) {
        repoStates[id]?.error = message
    }

    /// A transient failure — a fetch with no network, a push git rejected —
    /// must not erase what we already know about the working tree. As long as
    /// we have a status, that status IS the health; the error rides along in
    /// the row as its own line. Only a repo we've never managed to read at all
    /// reports `.error`.
    func healthLevel(for repo: GitRepository) -> RepoHealthLevel {
        repoStates[repo.id]?.healthLevel ?? .error
    }

    // MARK: - Computed

    /// Worst health across repos we have an answer for. Repos still loading are
    /// skipped so the icon isn't red for the first second after launch, and a
    /// repo that errored but has a known status contributes that status — one
    /// unreachable remote shouldn't paint the whole menu bar red, which matters
    /// now that remote checks run on their own.
    var overallHealth: RepoHealthLevel {
        let levels = repositories.compactMap { repoStates[$0.id]?.knownHealthLevel }
        return levels.max() ?? .clean
    }

    var dirtyRepoCount: Int {
        repositories.compactMap { repoStates[$0.id]?.status }.filter {
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

        // Every repo needs its state object before the monitor starts
        // reporting into it.
        syncRepoStates()

        migrateIfNeeded()

        // Reconcile persisted preference with the actual system login-item
        // state, in case the user changed it from System Settings directly.
        let systemEnabled = LaunchAtLoginHelper.isEnabled
        if configuration.launchAtLogin != systemEnabled {
            configuration.launchAtLogin = systemEnabled
            saveConfiguration()
        }

        logger.info("🚀 App started — \(self.repositories.count) repos, \(self.watchedFolders.count) watched folders")
        setupMonitorCallbacks()
        startMonitoring()
    }

    /// Brings an already-persisted config up to the current defaults.
    ///
    /// v0 → v1: automatic remote checks shipped disabled AND with no way to
    /// turn them on, so every stored config says `autoCheckRemote == false`
    /// whether or not the user ever wanted that. Enable it once here; from now
    /// on the toggle in Preferences owns the value and migration won't run again.
    ///
    /// Internal rather than private so it can be tested on its own — it changes
    /// a user-visible preference without asking, so it needs to be pinned down.
    func migrateIfNeeded() {
        guard configuration.configVersion < AppConfiguration.currentVersion else { return }
        logger.info("🔧 Migrating config v\(self.configuration.configVersion) → v\(AppConfiguration.currentVersion) — enabling automatic remote checks")
        configuration.autoCheckRemote = true
        configuration.remoteCheckIntervalSeconds = AppConstants.defaultRemoteCheckInterval
        configuration.configVersion = AppConfiguration.currentVersion
        saveConfiguration()
    }

    // MARK: - Remote check preferences

    /// Both of these change what the monitor polls and how often, so they
    /// restart it rather than only persisting — the remote loop reads its
    /// interval once at start and then sleeps on it.
    func setAutoCheckRemote(_ enabled: Bool) {
        guard configuration.autoCheckRemote != enabled else { return }
        logger.info("👤 User action: Auto remote check → \(enabled)")
        configuration.autoCheckRemote = enabled
        saveAndRestartMonitor()
    }

    func setRemoteCheckInterval(_ seconds: TimeInterval) {
        guard configuration.remoteCheckIntervalSeconds != seconds else { return }
        logger.info("👤 User action: Remote check interval → \(seconds)s")
        configuration.remoteCheckIntervalSeconds = seconds
        saveAndRestartMonitor()
    }

    // MARK: - Launch at Login

    func setLaunchAtLogin(_ enabled: Bool) {
        logger.info("👤 User action: Launch at login → \(enabled)")
        let result = LaunchAtLoginHelper.setEnabled(enabled)
        configuration.launchAtLogin = result
        saveConfiguration()
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
            self.repoStates[id]?.status = status
            self.repoStates[id]?.error = nil
        }
        monitor.onError = { [weak self] path, error in
            guard let self else { return }
            // If the path is definitely gone (and not just unreachable due
            // to an unmounted volume), queue it for removal at end-of-cycle.
            if Self.isPathDefinitelyMissing(path) {
                self.missingPaths.insert(path)
            }
            if let id = self.repoId(for: path) {
                self.setError(error, for: id)
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

    /// Changes the local poll interval. Must restart the monitor: the polling
    /// loop reads the interval once when it starts and then sleeps on it, so
    /// merely persisting the new value left the old cadence running until the
    /// next app launch.
    func setRefreshInterval(_ seconds: TimeInterval) {
        guard configuration.refreshIntervalSeconds != seconds else { return }
        logger.info("👤 User action: Refresh interval → \(seconds)s")
        configuration.refreshIntervalSeconds = seconds
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
            repoStates[$0.id]?.status == nil && repoStates[$0.id]?.error == nil
        }
        if !stuckRepos.isEmpty {
            logger.warning("⚠️ After refreshAll, \(stuckRepos.count) repos still have no status: \(stuckRepos.map(\.displayName).joined(separator: ", "))")
        }
    }

    func checkRemote(for repo: GitRepository) async {
        logger.info("👤 User action: Check Remote — \(repo.displayName)")
        setCheckingRemote(true, for: repo.id)
        defer { setCheckingRemote(false, for: repo.id) }
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
            setCheckingRemote(true, for: repo.id)
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
                    self.setCheckingRemote(false, for: id)
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

    /// Repositories that have incoming commits to fast-forward. Drives both the
    /// "Pull all" button's visibility and what `pullAll()` operates on.
    private var reposNeedingPull: [GitRepository] {
        repositories.filter { repoStates[$0.id]?.status?.hasUnpulledChanges == true }
    }

    var reposNeedingPullCount: Int { reposNeedingPull.count }

    /// Fast-forward-pulls every repo with incoming commits, with a sliding
    /// window of 4 concurrent pulls — mirrors `checkAllRemotes`. Diverged repos
    /// (also ahead) fail loudly under --ff-only and surface their error, exactly
    /// like the per-repo Pull button.
    func pullAll() async {
        let targets = reposNeedingPull
        guard !targets.isEmpty, !isPullingAll else { return }
        logger.info("👤 User action: Pull All — \(targets.count) repos")
        isPullingAll = true
        defer { isPullingAll = false }

        for repo in targets { setCheckingRemote(true, for: repo.id) }

        let maxConcurrent = 4
        await withTaskGroup(of: (UUID, String?).self) { group in
            var index = 0

            func pull(_ repo: GitRepository) {
                group.addTask {
                    do {
                        try await GitService.pull(at: repo.path)
                        return (repo.id, nil)
                    } catch {
                        return (repo.id, error.localizedDescription)
                    }
                }
            }

            while index < min(maxConcurrent, targets.count) {
                pull(targets[index])
                index += 1
            }

            for await (id, errMsg) in group {
                setCheckingRemote(false, for: id)
                if let errMsg {
                    setError(errMsg, for: id)
                } else {
                    setError(nil, for: id)
                    if let repo = repositories.first(where: { $0.id == id }) {
                        await refreshSingle(repo)
                    }
                }

                if index < targets.count {
                    pull(targets[index])
                    index += 1
                }
            }
        }
    }

    func pull(_ repo: GitRepository) async {
        logger.info("👤 User action: Pull — \(repo.displayName)")
        setCheckingRemote(true, for: repo.id)
        defer { setCheckingRemote(false, for: repo.id) }
        do {
            try await GitService.pull(at: repo.path)
            setError(nil, for: repo.id)
            await refreshSingle(repo)
        } catch {
            setError(error.localizedDescription, for: repo.id)
        }
    }

    func push(_ repo: GitRepository) async {
        logger.info("👤 User action: Push — \(repo.displayName)")
        setCheckingRemote(true, for: repo.id)
        defer { setCheckingRemote(false, for: repo.id) }
        do {
            try await GitService.push(at: repo.path)
            setError(nil, for: repo.id)
            await refreshSingle(repo)
        } catch {
            setError(error.localizedDescription, for: repo.id)
        }
    }

    /// Syncs a submodule back to the commit the parent records (`git submodule
    /// update`). Surfaces git's error (e.g. dirty submodule) on the repo row.
    func syncSubmodule(_ repo: GitRepository, submodule name: String) async {
        logger.info("👤 User action: Submodule update \(name) — \(repo.displayName)")
        setCheckingRemote(true, for: repo.id)
        defer { setCheckingRemote(false, for: repo.id) }
        do {
            try await GitService.updateSubmodule(at: repo.path, submodule: name)
            setError(nil, for: repo.id)
            await refreshSingle(repo)
        } catch {
            setError(error.localizedDescription, for: repo.id)
        }
    }

    func checkout(_ repo: GitRepository, to branch: String) async {
        logger.info("👤 User action: Checkout \(branch) — \(repo.displayName)")
        setCheckingRemote(true, for: repo.id)
        defer { setCheckingRemote(false, for: repo.id) }
        do {
            try await GitService.checkout(at: repo.path, branch: branch)
            setError(nil, for: repo.id)
            await refreshSingle(repo)
        } catch {
            setError(error.localizedDescription, for: repo.id)
        }
    }

    private func refreshSingle(_ repo: GitRepository) async {
        let result = await GitService.fullStatus(at: repo.path)
        switch result {
        case .success(let status):
            repoStates[repo.id]?.status = status
        case .failure(let err):
            setError(err.localizedDescription, for: repo.id)
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
        repoStates[id]?.reset()
    }

    // MARK: - Display Mode & Grouping

    /// A set of repositories sharing a root (watched) folder. `folder == nil`
    /// is the catch-all "Other" group for repos added outside any watched folder.
    struct RepoGroup: Identifiable {
        let folder: WatchedFolder?
        let repos: [GitRepository]
        var id: String { folder?.id.uuidString ?? "__other__" }
        var displayName: String { folder?.displayName ?? "Other" }
    }

    var repoDisplayMode: RepoDisplayMode { configuration.repoDisplayMode }

    func setRepoDisplayMode(_ mode: RepoDisplayMode) {
        guard configuration.repoDisplayMode != mode else { return }
        configuration.repoDisplayMode = mode
        saveConfiguration()
    }

    /// Finds the watched folder a repo belongs to. When folders are nested, the
    /// deepest (longest path) match wins so the repo lands in its closest root.
    func watchedFolder(for repo: GitRepository) -> WatchedFolder? {
        watchedFolders
            .filter { repo.path == $0.path || repo.path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// Repositories grouped by root folder. Groups are sorted by name with the
    /// "Other" group (repos under no watched folder) pinned to the end. Empty
    /// groups are omitted.
    var groupedRepositories: [RepoGroup] {
        var byFolder: [UUID: [GitRepository]] = [:]
        var other: [GitRepository] = []
        for repo in repositories {
            if let folder = watchedFolder(for: repo) {
                byFolder[folder.id, default: []].append(repo)
            } else {
                other.append(repo)
            }
        }

        var groups = watchedFolders
            .compactMap { folder -> RepoGroup? in
                guard let repos = byFolder[folder.id], !repos.isEmpty else { return nil }
                return RepoGroup(folder: folder, repos: repos)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        if !other.isEmpty {
            groups.append(RepoGroup(folder: nil, repos: other))
        }
        return groups
    }

    /// The most attention-worthy health level among a group's repos, for the
    /// tab indicator dot.
    func groupHealthLevel(for group: RepoGroup) -> RepoHealthLevel {
        group.repos.map { healthLevel(for: $0) }.max() ?? .clean
    }

    /// Shared row ordering used by both the flat list and each grouped tab:
    /// pinned first, then repos that need attention (errors, pending pull,
    /// local changes, unpushed commits) ahead of clean ones, then by filesystem
    /// path, then by name. Ranking by `healthLevel` floats the repos you need
    /// to act on to the top so they're easy to find. Within the same health
    /// level, ordering by the full path keeps repos in the same directory
    /// adjacent and sorted by their folder name — a file-tree-like grouping.
    /// `localizedStandardCompare` gives natural (Finder-style) ordering,
    /// including numeric segments.
    func sorted(_ repos: [GitRepository]) -> [GitRepository] {
        repos.sorted { a, b in
            if a.isPinned != b.isPinned {
                return a.isPinned
            }
            let healthA = healthLevel(for: a)
            let healthB = healthLevel(for: b)
            if healthA != healthB {
                return healthA > healthB
            }
            let pathOrder = a.path.localizedStandardCompare(b.path)
            if pathOrder != .orderedSame {
                return pathOrder == .orderedAscending
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    // MARK: - Editor

    func setCustomEditor(for repo: GitRepository, bundleId: String?) {
        guard let index = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[index].customEditorBundleId = bundleId
        saveConfiguration()
    }

    // MARK: - Pinning

    func togglePin(for repo: GitRepository) {
        guard let index = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[index].isPinned.toggle()
        logger.info("📌 \(self.repositories[index].isPinned ? "Pinned" : "Unpinned") repo: \(repo.displayName)")
        saveConfiguration()
    }

    func isPinned(_ repo: GitRepository) -> Bool {
        repositories.first(where: { $0.id == repo.id })?.isPinned ?? false
    }

    /// Clears the error shown on a row. The status underneath is untouched —
    /// this only dismisses the message, which otherwise sat there until some
    /// later refresh happened to succeed.
    func dismissError(for repo: GitRepository) {
        setError(nil, for: repo.id)
    }

    func reportEditorError(for repo: GitRepository, message: String) {
        setError(message, for: repo.id)
        let id = repo.id
        // Auto-clear after 4s so the error doesn't linger.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if self.repoStates[id]?.error == message {
                self.setError(nil, for: id)
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
        syncRepoStates()
        saveConfiguration()
        monitor.stopMonitoring()
        setupMonitorCallbacks()
        startMonitoring()
    }
}
