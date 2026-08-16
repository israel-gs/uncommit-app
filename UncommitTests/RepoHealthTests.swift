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
        let vm = AppViewModel()
        let r = repo("api")
        vm.repositories = [r]
        vm.statuses[r.id] = status(modified: 2)
        vm.errors[r.id] = "Exit code 1: could not read from remote"

        // The working tree is still known to be dirty; a failed fetch says
        // nothing about it.
        XCTAssertEqual(vm.healthLevel(for: r), .localChanges)
    }

    func testRepoWithNoStatusAtAllReportsError() {
        let vm = AppViewModel()
        let r = repo("broken")
        vm.repositories = [r]
        vm.errors[r.id] = "Invalid directory: /Users/me/broken"

        XCTAssertEqual(vm.healthLevel(for: r), .error)
    }

    // MARK: - Menu bar icon

    func testOneFailingRemoteDoesNotPaintTheWholeMenuBarRed() {
        // The case automatic remote checks make routine: a repo whose fetch
        // fails but whose working tree we last saw clean.
        let vm = AppViewModel()
        let clean = repo("clean")
        let flaky = repo("flaky")
        vm.repositories = [clean, flaky]
        vm.statuses[clean.id] = status()
        vm.statuses[flaky.id] = status()
        vm.errors[flaky.id] = "Process timed out"

        XCTAssertEqual(vm.overallHealth, .clean)
    }

    func testUnreadableRepoStillReachesTheMenuBar() {
        let vm = AppViewModel()
        let clean = repo("clean")
        let gone = repo("gone")
        vm.repositories = [clean, gone]
        vm.statuses[clean.id] = status()
        vm.errors[gone.id] = "Invalid directory: /Users/me/gone"

        XCTAssertEqual(vm.overallHealth, .error)
    }

    func testStillLoadingReposDoNotColourTheIcon() {
        // On launch nothing has a status yet; the icon must not flash red.
        let vm = AppViewModel()
        vm.repositories = [repo("a"), repo("b")]

        XCTAssertEqual(vm.overallHealth, .clean)
    }

    // MARK: - Config migration

    func testMigrationEnablesRemoteChecksForAPreVersioningConfig() {
        let vm = AppViewModel()
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
        let vm = AppViewModel()
        var current = AppConfiguration()
        current.configVersion = AppConfiguration.currentVersion
        current.autoCheckRemote = false
        vm.configuration = current

        vm.migrateIfNeeded()

        XCTAssertFalse(vm.configuration.autoCheckRemote)
    }

    func testWorstHealthWins() {
        let vm = AppViewModel()
        let a = repo("a"), b = repo("b"), c = repo("c")
        vm.repositories = [a, b, c]
        vm.statuses[a.id] = status()
        vm.statuses[b.id] = status(ahead: 3)
        vm.statuses[c.id] = status(behind: 1)

        XCTAssertEqual(vm.overallHealth, .remoteOutOfSync)
    }
}
