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
            RepoRowsScrollView(repos: filteredRepos)
        }
    }

    // MARK: - Computed

    private var filteredRepos: [GitRepository] {
        viewModel.sorted(viewModel.repositories.filtered(by: searchText))
    }
}

// MARK: - Shared rows

/// Renders an ordered list of repository rows with dividers between them.
/// Reused by both the flat list and each grouped tab.
struct RepoRowsScrollView: View {
    let repos: [GitRepository]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(repos) { repo in
                    RepoRowView(repo: repo)
                    if repo.id != repos.last?.id {
                        Divider()
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
    }
}

// MARK: - Filtering

extension Array where Element == GitRepository {
    /// Filters by display name. An empty/whitespace query returns the array
    /// unchanged.
    func filtered(by searchText: String) -> [GitRepository] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return self
        }
        return filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }
}
