import XCTest
@testable import Uncommit

/// Two git processes writing `refs/remotes/...` in one repository race, and the
/// loser dies with "cannot lock ref 'refs/remotes/origin/…'". These tests pin
/// the guard that keeps the background sweep and a user's click off each other.
@MainActor
final class RemoteConcurrencyTests: XCTestCase {

    private var origin: String!
    private var clone: String!

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uncommit-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()

        // A bare "remote" with one commit, plus a clone that tracks it.
        origin = root.appendingPathComponent("origin.git").path
        let work = root.appendingPathComponent("seed").path
        clone = root.appendingPathComponent("clone").path

        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        _ = try await ShellExecutor.run("git", arguments: ["init", "--bare", origin], workingDirectory: root.path)
        _ = try await ShellExecutor.run("git", arguments: ["init"], workingDirectory: work)
        _ = try await ShellExecutor.run("git", arguments: ["config", "user.email", "t@t.t"], workingDirectory: work)
        _ = try await ShellExecutor.run("git", arguments: ["config", "user.name", "t"], workingDirectory: work)
        _ = try await ShellExecutor.run("git", arguments: ["commit", "--allow-empty", "-m", "seed"], workingDirectory: work)
        _ = try await ShellExecutor.run("git", arguments: ["remote", "add", "origin", origin], workingDirectory: work)
        _ = try await ShellExecutor.run("git", arguments: ["push", "-u", "origin", "HEAD:refs/heads/production"], workingDirectory: work)
        // Point the bare repo's HEAD at production, otherwise the clone checks
        // out whatever the local default branch name is and tracks nothing.
        _ = try await ShellExecutor.run(
            "git", arguments: ["symbolic-ref", "HEAD", "refs/heads/production"],
            workingDirectory: origin
        )
        _ = try await ShellExecutor.run("git", arguments: ["clone", origin, clone], workingDirectory: root.path)
    }

    override func tearDown() async throws {
        if let clone {
            let base = URL(fileURLWithPath: clone).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: base)
        }
        try await super.tearDown()
    }

    /// Collects errors from the monitor's MainActor callback.
    @MainActor private final class Errors {
        var all: [String] = []
        func append(_ m: String) { all.append(m) }
    }

    /// Returning the collector alone keeps the isolation checker happy — a
    /// tuple carrying a closure trips it up.
    private func makeMonitor(_ monitor: RepoMonitor, tracking repoPath: String) -> Errors {
        let errors = Errors()
        monitor.onError = { _, message in errors.append(message) }
        monitor.repositories = [
            GitRepository(id: UUID(), path: repoPath, displayName: "clone")
        ]
        return errors
    }

    /// The exact shape of the reported bug: the background sweep and a manual
    /// check landing on one repo at the same time.
    func testConcurrentFetchesOfTheSameRepoDoNotRace() async {
        let monitor = RepoMonitor()
        let errors = makeMonitor(monitor, tracking: clone)

        // Six callers at once — without the guard, git loses the ref lock and
        // the losers report "cannot lock ref 'refs/remotes/origin/production'".
        let path = clone!
        async let a: Void = monitor.fetchAndCheckRemote(for: path)
        async let b: Void = monitor.fetchAndCheckRemote(for: path)
        async let c: Void = monitor.fetchAndCheckRemote(for: path)
        async let d: Void = monitor.fetchAndCheckRemote(for: path)
        async let e: Void = monitor.fetchAndCheckRemote(for: path)
        async let f: Void = monitor.fetchAndCheckRemote(for: path)
        _ = await (a, b, c, d, e, f)

        let lockErrors = errors.all.filter { $0.contains("cannot lock ref") }
        XCTAssertTrue(lockErrors.isEmpty, "ref lock race: \(lockErrors)")
        XCTAssertTrue(errors.all.isEmpty, "unexpected errors: \(errors.all)")
    }

    /// The reported scenario end to end: the background sweep and a manual
    /// check hitting one repo together. The sweep used to call GitService.fetch
    /// behind the in-flight guard's back, so both ran and git lost the ref lock.
    ///
    /// Timing-dependent by nature — it cannot prove the absence of a race, but
    /// it exercises the path that produced the reported failure.
    func testBackgroundSweepAndManualCheckDoNotCollide() async {
        let monitor = RepoMonitor()
        let errors = makeMonitor(monitor, tracking: clone)
        let path = clone!

        async let sweep: Void = monitor.fetchAndCheckAllRemotes()
        async let manual: Void = monitor.fetchAndCheckRemote(for: path)
        async let manual2: Void = monitor.fetchAndCheckRemote(for: path)
        _ = await (sweep, manual, manual2)

        let lockErrors = errors.all.filter { $0.contains("cannot lock ref") }
        XCTAssertTrue(lockErrors.isEmpty, "ref lock race: \(lockErrors)")
        XCTAssertTrue(errors.all.isEmpty, "unexpected errors: \(errors.all)")
    }

    /// A pull must wait for an in-flight fetch rather than racing it.
    func testWaitForRemoteIdleBlocksUntilTheFetchFinishes() async {
        let monitor = RepoMonitor()
        let errors = makeMonitor(monitor, tracking: clone)

        let path = clone!
        async let fetching: Void = monitor.fetchAndCheckRemote(for: path)
        await monitor.waitForRemoteIdle(path)
        await fetching

        do {
            try await GitService.pull(at: path)
        } catch {
            XCTFail("pull after waiting should succeed, got \(error)")
        }
        XCTAssertTrue(errors.all.isEmpty, "unexpected errors: \(errors.all)")
    }

    /// Sanity: the fixture really does have a tracking branch called
    /// "production", so the test exercises the same ref the report showed.
    func testFixtureTracksProduction() async {
        let result = await GitService.fullStatus(at: clone)
        guard case .success(let status) = result else {
            return XCTFail("fullStatus failed: \(result)")
        }
        XCTAssertEqual(status.branchName, "production")
        XCTAssertTrue(status.hasRemoteTrackingBranch)
    }
}
