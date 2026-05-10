import Foundation

struct GitRepoStatus: Equatable {
    let branchName: String
    let stagedFiles: [String]
    let modifiedFiles: [String]
    let untrackedFiles: [String]
    let conflictFiles: [String]
    /// Accurate counts (file arrays may be capped for display purposes).
    let stagedCount: Int
    let modifiedCount: Int
    let untrackedCount: Int
    let conflictCount: Int
    let aheadCount: Int
    let behindCount: Int
    let hasRemoteTrackingBranch: Bool

    var totalChangedFiles: Int {
        stagedCount + modifiedCount + untrackedCount + conflictCount
    }

    var isClean: Bool {
        totalChangedFiles == 0
    }

    var hasUnpulledChanges: Bool {
        behindCount > 0
    }

    var hasUnpushedChanges: Bool {
        aheadCount > 0
    }

    var healthLevel: RepoHealthLevel {
        if hasUnpulledChanges { return .remoteOutOfSync }
        if !isClean { return .localChanges }
        if hasUnpushedChanges { return .unpushed }
        return .clean
    }
}

enum RepoHealthLevel: Int, Comparable {
    case clean = 0
    /// Working tree is clean but the local branch has commits the remote
    /// doesn't — your work isn't backed up yet.
    case unpushed = 1
    case localChanges = 2
    case remoteOutOfSync = 3
    case error = 4

    static func < (lhs: RepoHealthLevel, rhs: RepoHealthLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
