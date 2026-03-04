import SwiftUI

struct RepoListView: View {
    @Environment(AppViewModel.self) private var viewModel
    var searchText: String = ""

    var body: some View {
        if filteredRepos.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text("No repositories match \"\(searchText)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 32)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRepos) { repo in
                        RepoRowView(repo: repo)
                        if repo.id != filteredRepos.last?.id {
                            Divider()
                                .padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Computed

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

    private var filteredRepos: [GitRepository] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return sortedRepos
        }
        return sortedRepos.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }
}
