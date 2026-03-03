import SwiftUI

struct RepoListView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(sortedRepos) { repo in
                    RepoRowView(repo: repo)
                    if repo.id != sortedRepos.last?.id {
                        Divider()
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
    }

    private var sortedRepos: [GitRepository] {
        viewModel.repositories.sorted { a, b in
            let aLevel = a.error != nil ? RepoHealthLevel.error : (a.status?.healthLevel ?? .error)
            let bLevel = b.error != nil ? RepoHealthLevel.error : (b.status?.healthLevel ?? .error)
            if aLevel != bLevel {
                return aLevel > bLevel
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }
}
