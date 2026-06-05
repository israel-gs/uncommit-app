import XCTest
@testable import Uncommit

@MainActor
final class RepoGroupingTests: XCTestCase {

    private func makeViewModel(
        repos: [GitRepository],
        folders: [WatchedFolder]
    ) -> AppViewModel {
        let vm = AppViewModel()
        vm.repositories = repos
        vm.watchedFolders = folders
        return vm
    }

    private func repo(_ path: String) -> GitRepository {
        GitRepository(id: UUID(), path: path, displayName: URL(fileURLWithPath: path).lastPathComponent)
    }

    private func folder(_ path: String) -> WatchedFolder {
        WatchedFolder(id: UUID(), path: path, displayName: URL(fileURLWithPath: path).lastPathComponent)
    }

    func testNestedRepoMatchesDeepestFolder() {
        let shallow = folder("/Users/me/code")
        let deep = folder("/Users/me/code/work")
        let nested = repo("/Users/me/code/work/api")

        let vm = makeViewModel(repos: [nested], folders: [shallow, deep])

        XCTAssertEqual(vm.watchedFolder(for: nested)?.id, deep.id)
    }

    func testRepoOutsideAnyFolderFallsIntoOther() {
        let work = folder("/Users/me/work")
        let loose = repo("/Users/me/experiments/toy")

        let vm = makeViewModel(repos: [loose], folders: [work])

        XCTAssertNil(vm.watchedFolder(for: loose))

        let groups = vm.groupedRepositories
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].folder)
        XCTAssertEqual(groups[0].displayName, "Other")
    }

    func testSiblingPrefixDoesNotFalseMatch() {
        // "/Users/me/foo" must not capture a repo under "/Users/me/foobar".
        let foo = folder("/Users/me/foo")
        let sibling = repo("/Users/me/foobar/api")

        let vm = makeViewModel(repos: [sibling], folders: [foo])

        XCTAssertNil(vm.watchedFolder(for: sibling))
    }

    func testFolderItselfAsRepoMatches() {
        let f = folder("/Users/me/standalone")
        let r = repo("/Users/me/standalone")

        let vm = makeViewModel(repos: [r], folders: [f])

        XCTAssertEqual(vm.watchedFolder(for: r)?.id, f.id)
    }

    func testGroupsSortedByNameWithOtherLast() {
        let zebra = folder("/Users/me/zebra")
        let alpha = folder("/Users/me/alpha")
        let vm = makeViewModel(
            repos: [
                repo("/Users/me/zebra/r1"),
                repo("/Users/me/alpha/r2"),
                repo("/Users/me/loose/r3"),
            ],
            folders: [zebra, alpha]
        )

        let names = vm.groupedRepositories.map(\.displayName)
        XCTAssertEqual(names, ["alpha", "zebra", "Other"])
    }

    func testEmptyFoldersAreOmitted() {
        let used = folder("/Users/me/used")
        let unused = folder("/Users/me/unused")
        let vm = makeViewModel(
            repos: [repo("/Users/me/used/r1")],
            folders: [used, unused]
        )

        let ids = vm.groupedRepositories.compactMap(\.folder?.id)
        XCTAssertEqual(ids, [used.id])
    }
}
