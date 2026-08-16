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

    /// Max concurrent local status checks (fast, CPU-bound).
    private let maxConcurrentLocal = 6
    /// Max concurrent remote fetch operations (slow, network-bound).
    private let maxConcurrentRemote = 4
    /// Grace period before the first remote sweep, so it doesn't contend with
    /// the initial local pass on launch.
    private let initialRemoteCheckDelay: TimeInterval = 5
    /// One first sweep per app run. `startMonitoring` also runs on every repo
    /// add/remove, and re-fetching every remote each time would be wasteful.
    private var hasDoneInitialRemoteCheck = false

    /// Filesystem-event source. Tells us WHICH repos changed, so the periodic
    /// sweep stops being the only way to notice anything.
    private let watcher = RepoWatcher()
    /// Repos with pending filesystem activity, drained by `eventRefreshTask`.
    private var pendingEventPaths: Set<String> = []
    private var eventRefreshTask: Task<Void, Never>?
    /// Second coalescing stage on top of FSEvents' own latency: a `git checkout`
    /// fires several callbacks in a row, and this merges them into one refresh.
    private let eventDebounce: TimeInterval = 0.3

    var repositories: [GitRepository] = []
    var onStatusUpdate: (@MainActor @Sendable (String, GitRepoStatus) -> Void)?
    var onError: (@MainActor @Sendable (String, String) -> Void)?
    /// Fired after each completed local refresh cycle so the viewmodel can
    /// stamp `lastFullRefreshAt` for the "Updated Xs ago" display.
    var onCycleCompleted: (@MainActor @Sendable () -> Void)?

    func startMonitoring(
        repos: [GitRepository],
        localInterval: TimeInterval,
        remoteInterval: TimeInterval,
        autoCheckRemote: Bool
    ) {
        stopMonitoring()
        self.repositories = repos
        logger.info("🟢 Monitor started — \(repos.count) repos, local=\(localInterval)s, remote=\(remoteInterval)s, autoRemote=\(autoCheckRemote)")

        // Filesystem events drive the fast path; the loop below is the backstop.
        watcher.onRepositoriesChanged = { [weak self] paths in
            self?.enqueueEventRefresh(for: paths)
        }
        watcher.start(paths: repos.map(\.path))

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
                // One sweep shortly after launch: at a 15-minute cadence, waiting
                // a full interval would leave ahead/behind blank for the first
                // popover the user opens.
                if let self, !self.hasDoneInitialRemoteCheck {
                    self.hasDoneInitialRemoteCheck = true
                    try? await Task.sleep(for: .seconds(self.initialRemoteCheckDelay))
                    guard !Task.isCancelled else { return }
                    await self.fetchAndCheckAllRemotes()
                }

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
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        pendingEventPaths.removeAll()
        watcher.onRepositoriesChanged = nil
        watcher.stop()
    }

    // MARK: - Event-driven refresh

    /// Collects repos reported by the watcher and schedules one refresh for the
    /// batch. Re-arming the task on every burst means a long `git rebase` gets
    /// a single refresh at the end instead of one per file it touches.
    private func enqueueEventRefresh(for paths: Set<String>) {
        pendingEventPaths.formUnion(paths)
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.eventDebounce ?? 0.3))
            guard !Task.isCancelled, let self else { return }
            let batch = self.pendingEventPaths
            self.pendingEventPaths.removeAll()
            guard !batch.isEmpty else { return }
            await self.refreshLocal(paths: batch)
        }
    }

    /// Re-reads a specific set of repos. Shares the concurrency ceiling with the
    /// full sweep, and yields to one already in progress — that sweep is about
    /// to read these repos anyway.
    private func refreshLocal(paths: Set<String>) async {
        guard !isRefreshing else {
            logger.debug("🔄 event refresh skipped — full sweep in progress")
            return
        }
        // Only repos we actually track; the watcher can outlive a removal.
        let targets = repositories.map(\.path).filter { paths.contains($0) }
        guard !targets.isEmpty else { return }

        logger.debug("🔄 event refresh — \(targets.count) repo(s)")
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: (String, Result<GitRepoStatus, Error>).self) { group in
            var index = 0
            while index < min(maxConcurrentLocal, targets.count) {
                let path = targets[index]
                group.addTask { (path, await GitService.fullStatus(at: path)) }
                index += 1
            }
            for await (path, result) in group {
                report(path: path, result: result)
                if index < targets.count {
                    let nextPath = targets[index]
                    group.addTask { (nextPath, await GitService.fullStatus(at: nextPath)) }
                    index += 1
                }
            }
        }
    }

    /// Single place that turns a status result into the right callback.
    private func report(path: String, result: Result<GitRepoStatus, Error>) {
        switch result {
        case .success(let status): onStatusUpdate?(path, status)
        case .failure(let error): onError?(path, error.localizedDescription)
        }
    }

    // MARK: - Local Status (sliding-window, max 6 concurrent)

    func refreshAllLocal() async {
        // Guard: prevents overlap between the sequential loop and manual refreshAll().
        // Within the loop itself, overlap is impossible (it's sequential).
        guard !isRefreshing else {
            logger.debug("🔄 refreshAllLocal skipped — already in progress")
            return
        }

        let repos = repositories
        guard !repos.isEmpty else { return }

        logger.info("🔄 refreshAllLocal START — \(repos.count) repos (max \(self.maxConcurrentLocal) concurrent)")
        let start = CFAbsoluteTimeGetCurrent()
        isRefreshing = true
        defer {
            isRefreshing = false
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
                if case .failure = result { errorCount += 1 }
                report(path: path, result: result)

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

        onCycleCompleted?()
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

        report(path: repoPath, result: await GitService.fullStatus(at: repoPath))
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
                report(path: path, result: result)

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
