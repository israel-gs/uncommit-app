import XCTest
@testable import Uncommit

/// End-to-end tests for the FSEvents plumbing. These write real files and wait
/// for the callback: the C bridge, the actor hop and the path mapping either
/// work together or the watcher silently never fires, which no unit test of the
/// pieces would catch.
@MainActor
final class RepoWatcherTests: XCTestCase {

    private var root: URL!
    private var watcher: RepoWatcher!

    override func setUp() async throws {
        try await super.setUp()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uncommit-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir.resolvingSymlinksInPath()
        watcher = RepoWatcher()
    }

    override func tearDown() async throws {
        watcher?.stop()
        watcher = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// Waits for the watcher to report `expected`, or fails after `timeout`.
    private func awaitChange(
        for expected: String,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line,
        whileDoing work: () throws -> Void
    ) async rethrows {
        let received = expectation(description: "watcher reported \(expected)")
        received.assertForOverFulfill = false
        watcher.onRepositoriesChanged = { paths in
            if paths.contains(expected) { received.fulfill() }
        }
        try work()
        await fulfillment(of: [received], timeout: timeout)
    }

    private func write(_ name: String, in dir: URL) throws {
        try "hello".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testReportsAChangedFile() async throws {
        watcher.start(paths: [root.path])
        XCTAssertTrue(watcher.isWatching)

        try await awaitChange(for: root.path) {
            try write("file.txt", in: root)
        }
    }

    func testReportsChangesInNestedDirectories() async throws {
        let nested = root.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        watcher.start(paths: [root.path])

        try await awaitChange(for: root.path) {
            try write("code.swift", in: nested)
        }
    }

    /// Git writing refs is exactly what a branch switch or a commit looks like,
    /// and it must not be filtered along with the object store.
    func testGitRefChangesAreReported() async throws {
        let refs = root.appendingPathComponent(".git/refs/heads")
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        watcher.start(paths: [root.path])

        try await awaitChange(for: root.path) {
            try write("main", in: refs)
        }
    }

    /// A repo inside another watched repo must claim its own events, otherwise
    /// a submodule change would refresh the wrong row.
    func testNestedRepoWinsOverItsParent() async throws {
        let inner = root.appendingPathComponent("vendor/sdk")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        watcher.start(paths: [root.path, inner.path])

        try await awaitChange(for: inner.path) {
            try write("lib.swift", in: inner)
        }
    }

    /// The noise filter has to be narrow: swallowing everything would look
    /// exactly like a working watcher that simply never fires.
    func testDependencyChurnIsIgnored() async throws {
        let modules = root.appendingPathComponent("node_modules/left-pad")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        watcher.start(paths: [root.path])

        let fired = expectation(description: "watcher stayed quiet")
        fired.isInverted = true
        watcher.onRepositoriesChanged = { _ in fired.fulfill() }

        try write("index.js", in: modules)
        await fulfillment(of: [fired], timeout: 3)
    }

    func testStopEndsTheStream() {
        watcher.start(paths: [root.path])
        XCTAssertTrue(watcher.isWatching)
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
    }

    func testStartingWithNoPathsIsANoOp() {
        watcher.start(paths: [])
        XCTAssertFalse(watcher.isWatching)
    }
}
