import XCTest
@testable import Uncommit

@MainActor
final class RepoHealthTests: XCTestCase {

    private func repo(_ name: String) -> GitRepository {
        GitRepository(id: UUID(), path: "/Users/me/\(name)", displayName: name)
    }

    private func status(
        ahead: Int = 0,
        behind: Int = 0,
        modified: Int = 0
    ) -> GitRepoStatus {
        GitRepoStatus(
            branchName: "main",
            stagedFiles: [], modifiedFiles: [], untrackedFiles: [], conflictFiles: [],
            stagedCount: 0, modifiedCount: modified, untrackedCount: 0, conflictCount: 0,
            aheadCount: ahead, behindCount: behind, hasRemoteTrackingBranch: true
        )
    }

    // MARK: - An error must not erase a known status

    func testErrorDoesNotOverrideAKnownStatus() {
        let vm = makeIsolatedViewModel()
        let r = repo("api")
        vm.repositories = [r]
        vm.syncRepoStates()
        vm.repoStates[r.id]?.status = status(modified: 2)
        vm.repoStates[r.id]?.error = "Exit code 1: could not read from remote"

        // The working tree is still known to be dirty; a failed fetch says
        // nothing about it.
        XCTAssertEqual(vm.healthLevel(for: r), .localChanges)
    }

    func testRepoWithNoStatusAtAllReportsError() {
        let vm = makeIsolatedViewModel()
        let r = repo("broken")
        vm.repositories = [r]
        vm.syncRepoStates()
        vm.repoStates[r.id]?.error = "Invalid directory: /Users/me/broken"

        XCTAssertEqual(vm.healthLevel(for: r), .error)
    }

    // MARK: - Menu bar icon

    func testOneFailingRemoteDoesNotPaintTheWholeMenuBarRed() {
        // The case automatic remote checks make routine: a repo whose fetch
        // fails but whose working tree we last saw clean.
        let vm = makeIsolatedViewModel()
        let clean = repo("clean")
        let flaky = repo("flaky")
        vm.repositories = [clean, flaky]
        vm.syncRepoStates()
        vm.repoStates[clean.id]?.status = status()
        vm.repoStates[flaky.id]?.status = status()
        vm.repoStates[flaky.id]?.error = "Process timed out"

        XCTAssertEqual(vm.overallHealth, .clean)
    }

    func testUnreadableRepoStillReachesTheMenuBar() {
        let vm = makeIsolatedViewModel()
        let clean = repo("clean")
        let gone = repo("gone")
        vm.repositories = [clean, gone]
        vm.syncRepoStates()
        vm.repoStates[clean.id]?.status = status()
        vm.repoStates[gone.id]?.error = "Invalid directory: /Users/me/gone"

        XCTAssertEqual(vm.overallHealth, .error)
    }

    func testStillLoadingReposDoNotColourTheIcon() {
        // On launch nothing has a status yet; the icon must not flash red.
        let vm = makeIsolatedViewModel()
        vm.repositories = [repo("a"), repo("b")]
        vm.syncRepoStates()

        XCTAssertEqual(vm.overallHealth, .clean)
    }

    // MARK: - Per-repo state objects

    /// The invariant the whole design rests on: each repo owns a distinct
    /// observable object, so writing one repo's status can't reach another's
    /// observers.
    func testEachRepoGetsItsOwnStateObject() {
        let vm = makeIsolatedViewModel()
        let a = repo("a"), b = repo("b")
        vm.repositories = [a, b]
        vm.syncRepoStates()

        let stateA = vm.state(for: a)
        let stateB = vm.state(for: b)
        XCTAssertNotNil(stateA)
        XCTAssertNotNil(stateB)
        XCTAssertFalse(stateA === stateB)

        stateA?.status = status(modified: 1)
        XCTAssertNil(vm.status(for: b), "one repo's update must not leak into another")
    }

    func testStateSurvivesRepeatedSyncs() {
        // Re-syncing on every repo add/remove must not wipe what we already know.
        let vm = makeIsolatedViewModel()
        let a = repo("a")
        vm.repositories = [a]
        vm.syncRepoStates()
        vm.repoStates[a.id]?.status = status(modified: 3)

        vm.repositories = [a, repo("b")]
        vm.syncRepoStates()

        XCTAssertEqual(vm.status(for: a)?.modifiedCount, 3)
        XCTAssertEqual(vm.repoStates.count, 2)
    }

    func testRemovingARepoDropsItsState() {
        let vm = makeIsolatedViewModel()
        let a = repo("a"), b = repo("b")
        vm.repositories = [a, b]
        vm.syncRepoStates()

        vm.repositories = [a]
        vm.syncRepoStates()

        XCTAssertEqual(vm.repoStates.count, 1)
        XCTAssertNil(vm.state(for: b))
    }

    // MARK: - Config migration

    func testMigrationEnablesRemoteChecksForAPreVersioningConfig() {
        let vm = makeIsolatedViewModel()
        var old = AppConfiguration()
        old.configVersion = 0
        old.autoCheckRemote = false
        vm.configuration = old

        vm.migrateIfNeeded()

        XCTAssertTrue(vm.configuration.autoCheckRemote)
        XCTAssertEqual(vm.configuration.remoteCheckIntervalSeconds, AppConstants.defaultRemoteCheckInterval)
        XCTAssertEqual(vm.configuration.configVersion, AppConfiguration.currentVersion)
    }

    func testMigrationDoesNotReEnableAfterTheUserOptsOut() {
        // Once migrated, turning the toggle off has to stick across launches.
        let vm = makeIsolatedViewModel()
        var current = AppConfiguration()
        current.configVersion = AppConfiguration.currentVersion
        current.autoCheckRemote = false
        vm.configuration = current

        vm.migrateIfNeeded()

        XCTAssertFalse(vm.configuration.autoCheckRemote)
    }

    func testWorstHealthWins() {
        let vm = makeIsolatedViewModel()
        let a = repo("a"), b = repo("b"), c = repo("c")
        vm.repositories = [a, b, c]
        vm.syncRepoStates()
        vm.repoStates[a.id]?.status = status()
        vm.repoStates[b.id]?.status = status(ahead: 3)
        vm.repoStates[c.id]?.status = status(behind: 1)

        XCTAssertEqual(vm.overallHealth, .remoteOutOfSync)
    }
}
