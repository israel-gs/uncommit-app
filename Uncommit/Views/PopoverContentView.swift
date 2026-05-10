import SwiftUI

struct PopoverContentView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var showingSettings = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Uncommit")
                    .font(.headline)

                lastUpdatedLabel

                Spacer()

                if viewModel.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                }

                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRefreshing)
                .help("Refresh all repositories")

                Button {
                    Task { await viewModel.checkAllRemotes() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isCheckingAllRemotes)
                .help("Fetch all remotes")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSettings.toggle()
                    }
                } label: {
                    Image(systemName: showingSettings ? "xmark" : "gear")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if showingSettings {
                SettingsView()
            } else if viewModel.repositories.isEmpty {
                EmptyStateView()
            } else {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                    TextField("Search repositories…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()

                RepoListView(searchText: searchText)
            }
        }
        .frame(minWidth: 380, maxWidth: 380, minHeight: 200, maxHeight: 550)
    }

    /// "Updated 12s ago" — refreshes once per second via TimelineView so the
    /// label decays without observation churn on the model.
    @ViewBuilder
    private var lastUpdatedLabel: some View {
        if let last = viewModel.lastFullRefreshAt {
            TimelineView(.periodic(from: last, by: 1)) { context in
                Text(Self.relativeLabel(from: last, to: context.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func relativeLabel(from date: Date, to now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 5 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}
