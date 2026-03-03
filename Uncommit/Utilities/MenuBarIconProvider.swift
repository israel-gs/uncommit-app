import SwiftUI

enum MenuBarIconProvider {
    static func symbolName(for health: RepoHealthLevel) -> String {
        switch health {
        case .clean: return "checkmark.circle.fill"
        case .localChanges: return "pencil.circle.fill"
        case .remoteOutOfSync: return "arrow.triangle.2.circlepath.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    static func color(for health: RepoHealthLevel) -> Color {
        switch health {
        case .clean: return .green
        case .localChanges: return .orange
        case .remoteOutOfSync: return .red
        case .error: return .red
        }
    }
}
