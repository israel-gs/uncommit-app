import SwiftUI

/// Repository list grouped into tabs by root (watched) folder. A horizontal,
/// scrollable pill bar selects the active group; the rows below show that
/// group's repositories.
struct GroupedRepoListView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var selectedGroupId: String?

    var body: some View {
        let groups = viewModel.groupedRepositories

        if groups.isEmpty {
            // No repos at all — shouldn't normally render (the popover shows the
            // empty state instead), but guard anyway.
            Color.clear.frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                tabBar(groups)
                Divider()
                RepoRowsScrollView(repos: viewModel.sorted(activeGroup(in: groups).repos))
            }
            .onAppear { ensureValidSelection(groups) }
            .onChange(of: groups.map(\.id)) { _, _ in ensureValidSelection(groups) }
        }
    }

    // MARK: - Tab bar

    @ViewBuilder
    private func tabBar(_ groups: [AppViewModel.RepoGroup]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(groups) { group in
                    tabPill(group, isSelected: group.id == activeGroup(in: groups).id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func tabPill(_ group: AppViewModel.RepoGroup, isSelected: Bool) -> some View {
        Button {
            selectedGroupId = group.id
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(MenuBarIconProvider.color(for: viewModel.groupHealthLevel(for: group)))
                    .frame(width: 6, height: 6)
                Text(group.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(group.repos.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.borderless)
        .help(group.folder?.path ?? "Repositories outside any root folder")
    }

    // MARK: - Selection helpers

    /// The currently selected group, falling back to the first group when the
    /// selection is unset or stale.
    private func activeGroup(in groups: [AppViewModel.RepoGroup]) -> AppViewModel.RepoGroup {
        groups.first { $0.id == selectedGroupId } ?? groups[0]
    }

    /// Keeps `selectedGroupId` pointing at a group that still exists (e.g. after
    /// a watched folder is removed or empties out).
    private func ensureValidSelection(_ groups: [AppViewModel.RepoGroup]) {
        if selectedGroupId == nil || !groups.contains(where: { $0.id == selectedGroupId }) {
            selectedGroupId = groups.first?.id
        }
    }
}
