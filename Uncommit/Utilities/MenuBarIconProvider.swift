import SwiftUI

enum MenuBarIconProvider {
    static func symbolName(for health: RepoHealthLevel) -> String {
        switch health {
        case .clean: return "checkmark.circle.fill"
        case .unpushed: return "arrow.up.circle.fill"
        case .localChanges: return "pencil.circle.fill"
        case .remoteOutOfSync: return "arrow.triangle.2.circlepath.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    static func color(for health: RepoHealthLevel) -> Color {
        switch health {
        case .clean: return .green
        case .unpushed: return .blue
        case .localChanges: return .orange
        case .remoteOutOfSync: return .red
        case .error: return .red
        }
    }

    /// Spoken description of a health level, and the tooltip behind the dot.
    /// The colour alone carried this meaning, which left it unreadable to
    /// anyone with red-green colour blindness — and `.remoteOutOfSync` and
    /// `.error` are the same red.
    static func description(for health: RepoHealthLevel) -> String {
        switch health {
        case .clean: return "Clean"
        case .unpushed: return "Unpushed commits"
        case .localChanges: return "Local changes"
        case .remoteOutOfSync: return "Behind the remote"
        case .error: return "Could not be read"
        }
    }
}
