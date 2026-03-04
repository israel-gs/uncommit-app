import Foundation
import os

private let logger = Logger(subsystem: "com.uncommit.app", category: "RepoMonitor")

@MainActor
final class RepoMonitor {
    /// Sequential polling task — replaces Timer to guarantee no overlap.
    private var pollingTask: Task<Void, Never>?
    /// Sequential remote-check task.
    private var remoteCheckTask: Task<Void, Never>?

    private(set) var isRefreshing = false
    private var isCheckingRemotes = false
    /// Tracks repos currently being fetched to prevent duplicate operations.
    private var inFlightRemotePaths: Set<String> = []
    /// Timestamp of last refresh completion — used to enforce cooldown on manual refreshes.
    private var lastRefreshCompletedAt: CFAbsoluteTime = 0
    /// Minimum seconds between refresh cycles (prevents rapid manual refreshes).
    private let refreshCooldown: TimeInterval = 5

    /// Max concurrent local status checks (fast, CPU-bound).
    private let maxConcurrentLocal = 6
    /// Max concurrent remote fetch operations (slow, network-bound).
    private let maxConcurrentRemote = 4

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
        logger.info("🟢 Monitor started — \(repos.count) repos, local=\(localInterval)s, remote=\(remoteInterval)s, autoRemote=\(autoCheckRemote)")

        // Sequential loop: initial check → sleep → check → sleep → ...
        // The next cycle ONLY starts after the current one fully completes,
        // so overlapping refreshes are impossible by design.
        pollingTask = Task { [weak self] in
            // Initial check
            await self?.refreshAllLocal()

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(localInterval))
                guard !Task.isCancelled else { break }
                await self?.refreshAllLocal()
            }
            logger.debug("🔴 Polling loop exited")
        }

        if autoCheckRemote {
            remoteCheckTask = Task { [weak self] in
                // First remote check after the interval (not immediately)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(remoteInterval))
                    guard !Task.isCancelled else { break }
                    await self?.fetchAndCheckAllRemotes()
                }
                logger.debug("🔴 Remote check loop exited")
            }
        }
    }

    func stopMonitoring() {
        logger.info("🔴 Monitor stopped")
        pollingTask?.cancel()
        pollingTask = nil
        remoteCheckTask?.cancel()
        remoteCheckTask = nil
    }

    // MARK: - Local Status (sliding-window, max 6 concurrent)

    func refreshAllLocal() async {
        // Guard: prevents overlap between the sequential loop and manual refreshAll().
        // Within the loop itself, overlap is impossible (it's sequential).
        guard !isRefreshing else {
            logger.debug("🔄 refreshAllLocal skipped — already in progress")
            return
        }

        // Cooldown: prevents rapid-fire manual refreshes.
        let sinceLastRefresh = CFAbsoluteTimeGetCurrent() - lastRefreshCompletedAt
        if lastRefreshCompletedAt > 0 && sinceLastRefresh < refreshCooldown {
            logger.debug("🔄 refreshAllLocal skipped — cooldown (\(String(format: "%.1f", sinceLastRefresh))s < \(self.refreshCooldown)s)")
            return
        }

        let repos = repositories
        guard !repos.isEmpty else { return }

        logger.info("🔄 refreshAllLocal START — \(repos.count) repos (max \(self.maxConcurrentLocal) concurrent)")
        let start = CFAbsoluteTimeGetCurrent()
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshCompletedAt = CFAbsoluteTimeGetCurrent()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            logger.info("🔄 refreshAllLocal DONE — \(repos.count) repos [\(String(format: "%.2f", elapsed))s]")
        }

        var processedCount = 0
        var errorCount = 0

        await withTaskGroup(of: (String, Result<GitRepoStatus, Error>).self) { group in
            var index = 0

            // Seed initial batch
            while index < min(maxConcurrentLocal, repos.count) {
                let path = repos[index].path
                group.addTask {
                    let result = await GitService.fullStatus(at: path)
                    return (path, result)
                }
                index += 1
            }

            // As each completes, report result and add next repo
            for await (path, result) in group {
                processedCount += 1
                switch result {
                case .success(let status):
                    onStatusUpdate?(path, status)
                case .failure(let error):
                    errorCount += 1
                    onError?(path, error.localizedDescription)
                }

                if index < repos.count {
                    let nextPath = repos[index].path
                    group.addTask {
                        let result = await GitService.fullStatus(at: nextPath)
                        return (nextPath, result)
                    }
                    index += 1
                }
            }
        }

        if processedCount != repos.count {
            logger.error("⚠️ refreshAllLocal processed \(processedCount)/\(repos.count) repos! \(repos.count - processedCount) missing")
        }
        if errorCount > 0 {
            logger.info("🔄 refreshAllLocal had \(errorCount)/\(repos.count) errors")
        }
    }

    // MARK: - Remote Check (single repo, with dedup)

    func fetchAndCheckRemote(for repoPath: String) async {
        let shortName = URL(fileURLWithPath: repoPath).lastPathComponent
        // Skip if this repo is already being fetched
        guard !inFlightRemotePaths.contains(repoPath) else {
            logger.debug("🌐 fetchAndCheckRemote skipped — \(shortName) already in-flight")
            return
        }
        inFlightRemotePaths.insert(repoPath)
        logger.debug("🌐 fetchAndCheckRemote START — \(shortName)")
        defer {
            inFlightRemotePaths.remove(repoPath)
            logger.debug("🌐 fetchAndCheckRemote END — \(shortName)")
        }

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

    // MARK: - Remote Check All (sliding-window, max 4 concurrent)

    private func fetchAndCheckAllRemotes() async {
        guard !isCheckingRemotes else {
            logger.debug("🌍 fetchAndCheckAllRemotes skipped — already in progress")
            return
        }
        isCheckingRemotes = true
        let start = CFAbsoluteTimeGetCurrent()
        logger.info("🌍 fetchAndCheckAllRemotes START — \(self.repositories.count) repos (max \(self.maxConcurrentRemote) concurrent)")
        defer {
            isCheckingRemotes = false
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            logger.info("🌍 fetchAndCheckAllRemotes DONE [\(String(format: "%.2f", elapsed))s]")
        }

        let repos = repositories
        guard !repos.isEmpty else { return }

        await withTaskGroup(of: (String, Result<GitRepoStatus, Error>).self) { group in
            var index = 0

            // Seed initial batch
            while index < min(maxConcurrentRemote, repos.count) {
                let path = repos[index].path
                group.addTask {
                    do {
                        try await GitService.fetch(at: path)
                    } catch {
                        return (path, .failure(error))
                    }
                    return (path, await GitService.fullStatus(at: path))
                }
                index += 1
            }

            // As each completes, report result and add next repo
            for await (path, result) in group {
                switch result {
                case .success(let status):
                    onStatusUpdate?(path, status)
                case .failure(let error):
                    onError?(path, error.localizedDescription)
                }

                if index < repos.count {
                    let nextPath = repos[index].path
                    group.addTask {
                        do {
                            try await GitService.fetch(at: nextPath)
                        } catch {
                            return (nextPath, .failure(error))
                        }
                        return (nextPath, await GitService.fullStatus(at: nextPath))
                    }
                    index += 1
                }
            }
        }
    }
}
