import Foundation

@MainActor
final class RepoMonitor {
    private var pollingTimer: Timer?
    private var remoteCheckTimer: Timer?
    private var isRefreshing = false

    var repositories: [GitRepository] = []
    var onStatusUpdate: (@MainActor @Sendable (String, GitRepoStatus) -> Void)?
    var onError: (@MainActor @Sendable (String, String) -> Void)?

    func startMonitoring(
        repos: [GitRepository],
        localInterval: TimeInterval,
        remoteInterval: TimeInterval,
        autoCheckRemote: Bool
    ) {
        stopMonitoring()
        self.repositories = repos

        pollingTimer = Timer.scheduledTimer(withTimeInterval: localInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAllLocal()
            }
        }

        if autoCheckRemote {
            remoteCheckTimer = Timer.scheduledTimer(withTimeInterval: remoteInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.fetchAndCheckAllRemotes()
                }
            }
        }

        // Initial check
        Task { [weak self] in
            await self?.refreshAllLocal()
        }
    }

    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        remoteCheckTimer?.invalidate()
        remoteCheckTimer = nil
    }

    func refreshAllLocal() async {
        // Prevent overlapping refreshes
        guard !isRefreshing else { return }
        let repos = repositories
        guard !repos.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        // Fire all status checks concurrently, report each as it completes
        await withTaskGroup(of: (String, Result<GitRepoStatus, Error>).self) { group in
            for repo in repos {
                let path = repo.path
                group.addTask {
                    let result = await GitService.fullStatus(at: path)
                    return (path, result)
                }
            }

            for await (path, result) in group {
                switch result {
                case .success(let status):
                    onStatusUpdate?(path, status)
                case .failure(let error):
                    onError?(path, error.localizedDescription)
                }
            }
        }
    }

    func fetchAndCheckRemote(for repoPath: String) async {
        do {
            try await GitService.fetch(at: repoPath)
        } catch {
            onError?(repoPath, error.localizedDescription)
            return
        }

        let result = await GitService.fullStatus(at: repoPath)
        switch result {
        case .success(let status):
            onStatusUpdate?(repoPath, status)
        case .failure(let error):
            onError?(repoPath, error.localizedDescription)
        }
    }

    private func fetchAndCheckAllRemotes() async {
        let repos = repositories
        for repo in repos {
            await fetchAndCheckRemote(for: repo.path)
        }
    }
}
