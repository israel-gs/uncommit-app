import Foundation

/// A submodule whose state differs from what the parent repo records. Git
/// reports these in `status` as if they were plain file paths; we pull them
/// out into their own bucket so the UI can show what actually changed (the
/// pointer moved, the submodule is on another branch, or it has dirty content)
/// instead of a misleading "modified file" badge.
struct SubmoduleChange: Equatable, Identifiable, Sendable {
    /// Path of the submodule relative to the repo root — also its display name.
    let name: String
    /// The submodule's checked-out commit differs from the one the parent
    /// records (the porcelain v2 `c` flag). This is "the pointer moved".
    let commitChanged: Bool
    /// The submodule has modified tracked content in its own working tree (`m`).
    let hasModifications: Bool
    /// The submodule has untracked files in its own working tree (`u`).
    let hasUntracked: Bool
    /// Whether the pointer change is staged in the parent's index.
    let staged: Bool
    /// The submodule's current branch, or nil when on a detached HEAD.
    /// Filled by enrichment, not by the status parser.
    var branch: String?
    /// The submodule's current HEAD, short form. Filled by enrichment.
    var newSHA: String?
    /// The commit the parent repo has recorded (committed) for this submodule,
    /// short form. Filled by enrichment.
    var oldSHA: String?

    var id: String { name }
}

/// A single commit, as shown in the ahead/behind detail popovers.
struct GitCommit: Identifiable, Equatable, Sendable {
    let hash: String          // short hash
    let subject: String
    let author: String
    let relativeDate: String  // git's "%ar", e.g. "2 hours ago"

    var id: String { hash }
}

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
    /// Submodules whose state diverges from what the parent records. Kept
    /// separate from the file buckets so they never render as plain files.
    var submodules: [SubmoduleChange] = []

    var totalChangedFiles: Int {
        stagedCount + modifiedCount + untrackedCount + conflictCount
    }

    var isClean: Bool {
        totalChangedFiles == 0 && submodules.isEmpty
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
