import SwiftUI

struct StatusIndicatorView: View {
    let healthLevel: RepoHealthLevel

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch healthLevel {
        case .clean: return .green
        case .localChanges: return .orange
        case .remoteOutOfSync: return .red
        case .error: return .red.opacity(0.6)
        }
    }
}
