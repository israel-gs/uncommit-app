import SwiftUI

@Observable
@MainActor
final class AppViewModel {
    var repositories: [GitRepository] = []
    var watchedFolders: [WatchedFolder] = []
    var isRefreshing: Bool = false
    var configuration: AppConfiguration = AppConfiguration()
    private(set) var hasStarted = false

    private let discoveryService = RepoDiscoveryService()
    private let monitor = RepoMonitor()
    private let persistence = PersistenceService()

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

    /// Called from the view layer (.task) to ensure we're on MainActor
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let loaded = persistence.load()
        self.configuration = loaded
        self.repositories = loaded.repositories
        self.watchedFolders = loaded.watchedFolders
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
            }
        }
        monitor.onError = { [weak self] path, error in
            guard let self else { return }
            if let index = self.repositories.firstIndex(where: { $0.path == path }) {
                self.repositories[index].error = error
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
        isRefreshing = true
        await monitor.refreshAllLocal()
        isRefreshing = false
    }

    func checkRemote(for repo: GitRepository) async {
        guard let index = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[index].isCheckingRemote = true
        await monitor.fetchAndCheckRemote(for: repo.path)
        if let idx = repositories.firstIndex(where: { $0.id == repo.id }) {
            repositories[idx].isCheckingRemote = false
        }
    }

    func checkAllRemotes() async {
        for i in repositories.indices {
            repositories[i].isCheckingRemote = true
        }
        // Check sequentially to avoid actor isolation issues
        for repo in repositories {
            await monitor.fetchAndCheckRemote(for: repo.path)
        }
        for i in repositories.indices {
            repositories[i].isCheckingRemote = false
        }
    }

    private func addRepositoryQuietly(at path: String) {
        guard !repositories.contains(where: { $0.path == path }) else { return }
        let repo = GitRepository(
            id: UUID(),
            path: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent
        )
        repositories.append(repo)
    }

    func addRepository(at path: String) {
        addRepositoryQuietly(at: path)
        saveAndRestartMonitor()
    }

    func removeRepository(_ repo: GitRepository) {
        repositories.removeAll { $0.id == repo.id }
        saveAndRestartMonitor()
    }

    func addWatchedFolder(at path: String) async {
        guard !watchedFolders.contains(where: { $0.path == path }) else { return }
        let folder = WatchedFolder(
            id: UUID(),
            path: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent
        )
        watchedFolders.append(folder)

        let discovered = await discoveryService.discoverRepositories(
            under: path,
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
        saveConfiguration()
        monitor.stopMonitoring()
        setupMonitorCallbacks()
        startMonitoring()
    }
}
