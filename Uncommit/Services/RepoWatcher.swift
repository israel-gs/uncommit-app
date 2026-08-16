import Foundation
import os

private let logger = Logger(subsystem: "com.uncommit.app", category: "RepoWatcher")

/// Watches every tracked repository with a single FSEvents stream and reports
/// which ones had filesystem activity.
///
/// Polling asked git the same question about every repo on a timer whether or
/// not anything had happened. This turns that around: the filesystem says what
/// changed, and only those repos get re-read. The periodic sweep stays on as a
/// backstop — FSEvents can drop events under load, and it says nothing about a
/// remote moving ahead.
@MainActor
final class RepoWatcher {

    /// Repo paths that saw activity, coalesced. Always called on the MainActor.
    var onRepositoriesChanged: (@MainActor @Sendable (Set<String>) -> Void)?

    private var stream: FSEventStreamRef?
    /// Watched repos as (canonical path, path the app knows it by), longest
    /// canonical first so a repo nested inside another wins the prefix match.
    /// The two forms differ whenever a repo sits behind a symlink — see
    /// `canonical(_:)`.
    private var watched: [(canonical: String, original: String)] = []
    private let queue = DispatchQueue(label: "com.uncommit.app.repowatcher")

    /// FSEvents' own coalescing window. Long enough that a build or a `git
    /// checkout` touching hundreds of files arrives as one callback, short
    /// enough that the row updates while you're still looking at it.
    private let latency: CFTimeInterval = 1.0

    /// High-churn directories whose contents never change `git status`: build
    /// output, dependency trees, and git's own object store (refs DO matter and
    /// are not filtered). Without this, one `npm install` would spin the
    /// refresh loop for minutes.
    private static let ignoredPathFragments = [
        "/node_modules/", "/.build/", "/DerivedData/", "/.next/",
        "/target/", "/dist/", "/__pycache__/", "/.venv/", "/venv/",
        "/.git/objects/", "/Pods/",
    ]

    var isWatching: Bool { stream != nil }

    // MARK: - Lifecycle

    func start(paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }

        // Longest first so "/code/app/sub" is preferred over "/code/app".
        watched = paths
            .map { (canonical: Self.canonical($0), original: $0) }
            .sorted { $0.canonical.count > $1.canonical.count }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer      // report the first event immediately
            | kFSEventStreamCreateFlagWatchRoot    // survive the repo being moved
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            repoWatcherCallback,
            &context,
            watched.map(\.canonical) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            logger.error("✗ Could not create the FSEvents stream — falling back to polling only")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        logger.info("👁 Watching \(paths.count) repositories")
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        watched = []
        logger.debug("👁 Stopped watching")
    }

    /// Fully resolves a path, symlinks and all.
    ///
    /// FSEvents always reports canonical paths ("/private/var/…"), but the paths
    /// we're handed may not be: Foundation's `resolvingSymlinksInPath()` leaves
    /// `/var` alone, so comparing the two forms matched nothing and the watcher
    /// silently never fired. `realpath(3)` has no such exception, and running
    /// both sides through it is the only way the comparison holds.
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Event handling

    /// Maps raw event paths back onto the repos that own them. Called on the
    /// MainActor from the stream callback.
    fileprivate func handle(eventPaths: [String]) {
        var changed = Set<String>()
        for rawPath in eventPaths {
            // FSEvents terminates directory paths with a slash; drop it so an
            // event on the repo root matches the repo root exactly.
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            // Match against the path WITH a trailing slash: an event on the
            // directory itself arrives as ".../node_modules", which doesn't
            // contain "/node_modules/" on its own.
            if Self.ignoredPathFragments.contains(where: { (path + "/").contains($0) }) { continue }
            if let repo = repoOwning(path) {
                changed.insert(repo)
            }
        }
        guard !changed.isEmpty else { return }
        logger.debug("👁 Change in \(changed.count) repo(s)")
        onRepositoriesChanged?(changed)
    }

    /// The repo an event path belongs to, reported back in the form the app
    /// knows it by. `watched` is sorted longest-first so a repo nested inside
    /// another claims its own events.
    private func repoOwning(_ path: String) -> String? {
        watched.first { path == $0.canonical || path.hasPrefix($0.canonical + "/") }?.original
    }
}

/// FSEvents hands us a C function pointer, so this can't be a method or a
/// closure that captures. It pulls the watcher back out of the context pointer,
/// takes only plain strings off the event, and hops to the MainActor — nothing
/// actor-isolated is touched on the stream's queue.
private let repoWatcherCallback: FSEventStreamCallback = {
    _, clientInfo, numEvents, eventPaths, _, _ in

    guard let clientInfo, numEvents > 0 else { return }
    let watcher = Unmanaged<RepoWatcher>.fromOpaque(clientInfo).takeUnretainedValue()

    // kFSEventStreamCreateFlagUseCFTypes means this is a CFArray of CFStrings.
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    Task { @MainActor in
        watcher.handle(eventPaths: paths)
    }
}
