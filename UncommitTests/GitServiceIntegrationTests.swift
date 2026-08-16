import XCTest
@testable import Uncommit

/// Exercises `GitService` against a real repository on disk. These are the only
/// tests that shell out; the parsing rules themselves live in
/// `GitStatusParserTests` and stay pure.
final class GitServiceIntegrationTests: XCTestCase {

    private var repoPath: String!

    override func setUp() async throws {
        try await super.setUp()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uncommit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve symlinks: on macOS the temp dir is behind /private.
        repoPath = dir.resolvingSymlinksInPath().path
        _ = try await ShellExecutor.run("git", arguments: ["init"], workingDirectory: repoPath)
    }

    override func tearDown() async throws {
        if let repoPath { try? FileManager.default.removeItem(atPath: repoPath) }
        try await super.tearDown()
    }

    private func write(_ name: String) throws {
        try "x".write(
            toFile: repoPath + "/" + name,
            atomically: true,
            encoding: .utf8
        )
    }

    /// The regression this suite exists for: counts must reflect reality even
    /// when the displayed name list is truncated. Taking `.count` off the capped
    /// array reported 51 for any bucket over the 50-name cap — the synthetic
    /// "... and N more" row being counted as if it were a file.
    func testCountsAreAccurateAboveTheDisplayCap() async throws {
        for i in 1...120 { try write("file\(i).txt") }

        let result = await GitService.fullStatus(at: repoPath)
        guard case .success(let status) = result else {
            return XCTFail("fullStatus failed: \(result)")
        }

        XCTAssertEqual(status.untrackedCount, 120, "the badge must show the real count")
        XCTAssertEqual(status.totalChangedFiles, 120)
        XCTAssertLessThanOrEqual(
            status.untrackedFiles.count, 51,
            "the displayed list stays capped at 50 names + one summary row"
        )
        XCTAssertEqual(status.untrackedFiles.last, "... and 70 more")
    }

    func testCountsBelowTheCapAreNotTruncated() async throws {
        for i in 1...3 { try write("file\(i).txt") }

        let result = await GitService.fullStatus(at: repoPath)
        guard case .success(let status) = result else {
            return XCTFail("fullStatus failed: \(result)")
        }

        XCTAssertEqual(status.untrackedCount, 3)
        XCTAssertEqual(status.untrackedFiles.count, 3)
        XCTAssertFalse(status.untrackedFiles.contains { $0.hasPrefix("... and") })
    }

    /// A fresh repo has no upstream, so `--branch` emits neither
    /// `branch.upstream` nor `branch.ab`.
    func testFreshRepoHasNoTrackingBranch() async throws {
        let result = await GitService.fullStatus(at: repoPath)
        guard case .success(let status) = result else {
            return XCTFail("fullStatus failed: \(result)")
        }

        XCTAssertFalse(status.hasRemoteTrackingBranch)
        XCTAssertEqual(status.aheadCount, 0)
        XCTAssertEqual(status.behindCount, 0)
        XCTAssertFalse(status.branchName.isEmpty)
        XCTAssertTrue(status.isClean)
    }

    /// The branch name now comes from the `# branch.head` header rather than a
    /// separate `git branch --show-current` process.
    func testBranchNameComesFromTheStatusHeader() async throws {
        _ = try await ShellExecutor.run(
            "git", arguments: ["checkout", "-b", "feature/login"],
            workingDirectory: repoPath
        )

        let parsed = try await GitService.status(at: repoPath)
        XCTAssertEqual(parsed.branchName, "feature/login")

        let result = await GitService.fullStatus(at: repoPath)
        guard case .success(let status) = result else {
            return XCTFail("fullStatus failed: \(result)")
        }
        XCTAssertEqual(status.branchName, "feature/login")
    }
}
