import Foundation

/// Everything transient we know about one repository: its last status, its last
/// error, and whether a remote operation is in flight.
///
/// This is a class, and one instance per repo, for a specific reason. The
/// Observation framework tracks dependencies **per property, not per key**:
/// reading `statuses[someID]` registers the whole `statuses` dictionary, so
/// writing `statuses[otherID] = …` invalidated every row that had ever read it.
/// A refresh cycle over N repos therefore re-rendered every visible row N times.
/// Giving each repo its own observable object scopes an update to the one row
/// that shows it.
@Observable
@MainActor
final class RepoState {
    var status: GitRepoStatus?
    /// Last failure, shown alongside the status rather than replacing it.
    var error: String?
    var isCheckingRemote: Bool = false

    /// A transient failure doesn't erase what we know about the working tree —
    /// only a repo we've never managed to read reports `.error`.
    var healthLevel: RepoHealthLevel {
        status?.healthLevel ?? .error
    }

    /// Health for aggregate views (the menu bar icon). nil means "no answer
    /// yet", so a repo still loading doesn't colour anything.
    var knownHealthLevel: RepoHealthLevel? {
        if let status { return status.healthLevel }
        return error != nil ? .error : nil
    }

    /// Clears everything we'd learned. Used when a repo is dropped, or when its
    /// path changes underneath us.
    func reset() {
        status = nil
        error = nil
        isCheckingRemote = false
    }
}
