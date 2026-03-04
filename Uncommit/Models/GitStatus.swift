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
        return .clean
    }
}

enum RepoHealthLevel: Int, Comparable {
    case clean = 0
    case localChanges = 1
    case remoteOutOfSync = 2
    case error = 3

    static func < (lhs: RepoHealthLevel, rhs: RepoHealthLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
