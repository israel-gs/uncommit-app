import XCTest
@testable import Uncommit

final class GitStatusParserTests: XCTestCase {

    func testEmptyOutputReturnsAllEmpty() {
        let result = GitService.parsePorcelainV1Z("")
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.modified.isEmpty)
        XCTAssertTrue(result.untracked.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testModifiedFile() {
        // " M file.swift" — modified in worktree, not staged
        let output = " M file.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.modified, ["file.swift"])
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.untracked.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    func testStagedFile() {
        // "M  file.swift" — modified and staged
        let output = "M  file.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.staged, ["file.swift"])
        XCTAssertTrue(result.modified.isEmpty)
    }

    func testStagedAndModifiedSameFile() {
        // "MM file.swift" — staged change AND further unstaged modification
        let output = "MM file.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.staged, ["file.swift"])
        XCTAssertEqual(result.modified, ["file.swift"])
    }

    func testUntrackedFile() {
        let output = "?? newfile.txt\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.untracked, ["newfile.txt"])
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.modified.isEmpty)
    }

    func testConflictUU() {
        let output = "UU conflict.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.conflicts, ["conflict.swift"])
        XCTAssertTrue(result.staged.isEmpty)
        XCTAssertTrue(result.modified.isEmpty)
    }

    func testConflictAA() {
        let output = "AA both-added.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.conflicts, ["both-added.swift"])
    }

    func testConflictDD() {
        let output = "DD both-deleted.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.conflicts, ["both-deleted.swift"])
    }

    func testRenameStagedConsumesOldName() {
        // Rename: "R  new\0old\0" — the new name is reported, the old name is
        // consumed (NOT shown as a separate entry).
        let output = "R  newname.swift\0oldname.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.staged, ["newname.swift"])
        XCTAssertFalse(result.staged.contains("oldname.swift"))
        XCTAssertFalse(result.modified.contains("oldname.swift"))
    }

    func testCopyEntryConsumesSourceName() {
        let output = "C  copy.swift\0source.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.staged, ["copy.swift"])
        XCTAssertFalse(result.staged.contains("source.swift"))
    }

    func testFilenameWithSpacesPreserved() {
        let output = " M file with spaces.txt\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.modified, ["file with spaces.txt"])
    }

    func testFilenameWithNewlinePreserved() {
        // -z guarantees no quoting, so an embedded newline survives intact.
        let output = " M weird\nname.txt\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.modified, ["weird\nname.txt"])
    }

    func testFilenameWithUnicodePreserved() {
        let output = " M café-archivo.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.modified, ["café-archivo.swift"])
    }

    func testFilenameWithQuotesAndBackslashes() {
        // -z is the whole point: these characters would be C-escaped without it.
        let output = " M \"weird\"\\path.txt\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.modified, ["\"weird\"\\path.txt"])
    }

    func testMultipleEntriesMixed() {
        let output = " M modified.swift\0?? untracked.txt\0M  staged.swift\0UU conflict.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.modified, ["modified.swift"])
        XCTAssertEqual(result.untracked, ["untracked.txt"])
        XCTAssertEqual(result.staged, ["staged.swift"])
        XCTAssertEqual(result.conflicts, ["conflict.swift"])
    }

    func testRenameInMiddleDoesNotMisalignLaterEntries() {
        // Common alignment bug: forgetting to skip the old name shifts every
        // subsequent entry, so the next file ends up parsed from a path string
        // instead of a status-prefixed entry.
        let output = "R  new1.swift\0old1.swift\0 M after.swift\0"
        let result = GitService.parsePorcelainV1Z(output)
        XCTAssertEqual(result.staged, ["new1.swift"])
        XCTAssertEqual(result.modified, ["after.swift"])
        XCTAssertFalse(result.staged.contains("old1.swift"))
        XCTAssertFalse(result.modified.contains("old1.swift"))
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
