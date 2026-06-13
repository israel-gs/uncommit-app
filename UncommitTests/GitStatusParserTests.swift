import XCTest
@testable import Uncommit

final class GitStatusParserTests: XCTestCase {

    // Helpers to build porcelain v2 records without drowning the tests in the
    // mode/hash columns that the parser ignores.
    //   `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private func v2(_ xy: String, _ path: String, sub: String = "N...") -> String {
        "1 \(xy) \(sub) 100644 100644 100644 1111111 2222222 \(path)\0"
    }

    func testEmptyOutputReturnsAllEmpty() {
        let result = GitService.parsePorcelainV2Z("")
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.modified.isEmpty)
        XCTAssertTrue(result.untracked.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.submodules.isEmpty)
    }

    func testModifiedFile() {
        // ".M" — modified in worktree, not staged
        let result = GitService.parsePorcelainV2Z(v2(".M", "file.swift"))
        XCTAssertEqual(result.modified, ["file.swift"])
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.untracked.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testStagedFile() {
        // "M." — modified and staged
        let result = GitService.parsePorcelainV2Z(v2("M.", "file.swift"))
        XCTAssertEqual(result.staged, ["file.swift"])
        XCTAssertTrue(result.modified.isEmpty)
    }

    func testStagedAndModifiedSameFile() {
        // "MM" — staged change AND further unstaged modification
        let result = GitService.parsePorcelainV2Z(v2("MM", "file.swift"))
        XCTAssertEqual(result.staged, ["file.swift"])
        XCTAssertEqual(result.modified, ["file.swift"])
    }

    func testUntrackedFile() {
        let result = GitService.parsePorcelainV2Z("? newfile.txt\0")
        XCTAssertEqual(result.untracked, ["newfile.txt"])
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.modified.isEmpty)
    }

    func testConflictUnmerged() {
        // Unmerged record: "u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>"
        let output = "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.swift\0"
        let result = GitService.parsePorcelainV2Z(output)
        XCTAssertEqual(result.conflicts, ["conflict.swift"])
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.modified.isEmpty)
    }

    func testRenameStagedConsumesOldName() {
        // Rename: "2 R. ... new\0old\0" — the new name is reported, the old name
        // is consumed (NOT shown as a separate entry).
        let output = "2 R. N... 100644 100644 100644 h1 h2 R100 newname.swift\0oldname.swift\0"
        let result = GitService.parsePorcelainV2Z(output)
        XCTAssertEqual(result.staged, ["newname.swift"])
        XCTAssertFalse(result.staged.contains("oldname.swift"))
        XCTAssertFalse(result.modified.contains("oldname.swift"))
    }

    func testFilenameWithSpacesPreserved() {
        let result = GitService.parsePorcelainV2Z(v2(".M", "file with spaces.txt"))
        XCTAssertEqual(result.modified, ["file with spaces.txt"])
    }

    func testFilenameWithNewlinePreserved() {
        // -z guarantees no quoting, so an embedded newline survives intact.
        let result = GitService.parsePorcelainV2Z(v2(".M", "weird\nname.txt"))
        XCTAssertEqual(result.modified, ["weird\nname.txt"])
    }

    func testFilenameWithUnicodePreserved() {
        let result = GitService.parsePorcelainV2Z(v2(".M", "café-archivo.swift"))
        XCTAssertEqual(result.modified, ["café-archivo.swift"])
    }

    func testFilenameWithQuotesAndBackslashes() {
        // -z is the whole point: these characters would be C-escaped without it.
        let result = GitService.parsePorcelainV2Z(v2(".M", "\"weird\"\\path.txt"))
        XCTAssertEqual(result.modified, ["\"weird\"\\path.txt"])
    }

    func testMultipleEntriesMixed() {
        let output = v2(".M", "modified.swift")
            + "? untracked.txt\0"
            + v2("M.", "staged.swift")
            + "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.swift\0"
        let result = GitService.parsePorcelainV2Z(output)
        XCTAssertEqual(result.modified, ["modified.swift"])
        XCTAssertEqual(result.untracked, ["untracked.txt"])
        XCTAssertEqual(result.staged, ["staged.swift"])
        XCTAssertEqual(result.conflicts, ["conflict.swift"])
    }

    func testRenameInMiddleDoesNotMisalignLaterEntries() {
        // Forgetting to skip the rename's original-name token would shift every
        // later entry, so the next file would be parsed from a path string.
        let output = "2 R. N... 100644 100644 100644 h1 h2 R100 new1.swift\0old1.swift\0"
            + v2(".M", "after.swift")
        let result = GitService.parsePorcelainV2Z(output)
        XCTAssertEqual(result.staged, ["new1.swift"])
        XCTAssertEqual(result.modified, ["after.swift"])
        XCTAssertFalse(result.staged.contains("old1.swift"))
        XCTAssertFalse(result.modified.contains("old1.swift"))
    }

    func testIgnoredEntriesAreSkipped() {
        let output = "! ignored.log\0" + v2(".M", "real.swift")
        let result = GitService.parsePorcelainV2Z(output)
        XCTAssertEqual(result.modified, ["real.swift"])
        XCTAssertFalse(result.untracked.contains("ignored.log"))
    }

    // MARK: - Submodules

    func testSubmodulePointerChangeIsNotAFile() {
        // A submodule whose recorded commit moved: sub field "SC.." with the
        // worktree showing ".M". It must land in `submodules`, NOT `modified`.
        let result = GitService.parsePorcelainV2Z(
            "1 .M SC.. 160000 160000 160000 oldsha newsha sdk/bss-gateway-ts-sdk\0"
        )
        XCTAssertTrue(result.modified.isEmpty)
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertEqual(result.submodules.count, 1)
        let sm = result.submodules[0]
        XCTAssertEqual(sm.name, "sdk/bss-gateway-ts-sdk")
        XCTAssertTrue(sm.commitChanged)
        XCTAssertFalse(sm.hasModifications)
        XCTAssertFalse(sm.hasUntracked)
        XCTAssertFalse(sm.staged)
    }

    func testSubmoduleStagedPointerChange() {
        // Staged pointer move: X is non-dot ("M.").
        let result = GitService.parsePorcelainV2Z(
            "1 M. SC.. 160000 160000 160000 o n libs/core\0"
        )
        XCTAssertEqual(result.submodules.count, 1)
        XCTAssertTrue(result.submodules[0].staged)
        XCTAssertTrue(result.submodules[0].commitChanged)
    }

    func testSubmoduleDirtyContentFlags() {
        // No commit change, but modified + untracked content inside: "S.MU".
        let result = GitService.parsePorcelainV2Z(
            "1 .M S.MU 160000 160000 160000 o n vendor/dep\0"
        )
        XCTAssertEqual(result.submodules.count, 1)
        let sm = result.submodules[0]
        XCTAssertFalse(sm.commitChanged)
        XCTAssertTrue(sm.hasModifications)
        XCTAssertTrue(sm.hasUntracked)
    }

    func testSubmoduleAndFileCoexist() {
        let output = v2(".M", "app.swift")
            + "1 .M SC.. 160000 160000 160000 o n sub/mod\0"
        let result = GitService.parsePorcelainV2Z(output)
        XCTAssertEqual(result.modified, ["app.swift"])
        XCTAssertEqual(result.submodules.map(\.name), ["sub/mod"])
    }

    func testSubmoduleChangeMakesStatusNotClean() {
        let status = GitRepoStatus(
            branchName: "main",
            stagedFiles: [], modifiedFiles: [], untrackedFiles: [], conflictFiles: [],
            stagedCount: 0, modifiedCount: 0, untrackedCount: 0, conflictCount: 0,
            aheadCount: 0, behindCount: 0, hasRemoteTrackingBranch: true,
            submodules: [SubmoduleChange(
                name: "sub", commitChanged: true,
                hasModifications: false, hasUntracked: false, staged: false
            )]
        )
        XCTAssertFalse(status.isClean)
        XCTAssertEqual(status.healthLevel, .localChanges)
    }

    func testHealthLevelOrdering() {
        // unpushed sits between clean and localChanges so a clean repo with
        // commits-not-pushed is highlighted but doesn't outrank actual edits.
        XCTAssertLessThan(RepoHealthLevel.clean, RepoHealthLevel.unpushed)
        XCTAssertLessThan(RepoHealthLevel.unpushed, RepoHealthLevel.localChanges)
        XCTAssertLessThan(RepoHealthLevel.localChanges, RepoHealthLevel.remoteOutOfSync)
        XCTAssertLessThan(RepoHealthLevel.remoteOutOfSync, RepoHealthLevel.error)
    }

    func testHealthLevelUnpushedWhenCleanButAhead() {
        let status = GitRepoStatus(
            branchName: "main",
            stagedFiles: [], modifiedFiles: [], untrackedFiles: [], conflictFiles: [],
            stagedCount: 0, modifiedCount: 0, untrackedCount: 0, conflictCount: 0,
            aheadCount: 2, behindCount: 0, hasRemoteTrackingBranch: true
        )
        XCTAssertEqual(status.healthLevel, .unpushed)
    }

    func testHealthLevelLocalChangesOverridesUnpushed() {
        // Working-tree changes take precedence over unpushed commits.
        let status = GitRepoStatus(
            branchName: "main",
            stagedFiles: [], modifiedFiles: ["x.swift"], untrackedFiles: [], conflictFiles: [],
            stagedCount: 0, modifiedCount: 1, untrackedCount: 0, conflictCount: 0,
            aheadCount: 5, behindCount: 0, hasRemoteTrackingBranch: true
        )
        XCTAssertEqual(status.healthLevel, .localChanges)
    }

    func testHealthLevelRemoteOutOfSyncIsHighest() {
        let status = GitRepoStatus(
            branchName: "main",
            stagedFiles: [], modifiedFiles: ["x.swift"], untrackedFiles: [], conflictFiles: [],
            stagedCount: 0, modifiedCount: 1, untrackedCount: 0, conflictCount: 0,
            aheadCount: 1, behindCount: 1, hasRemoteTrackingBranch: true
        )
        XCTAssertEqual(status.healthLevel, .remoteOutOfSync)
    }
}
