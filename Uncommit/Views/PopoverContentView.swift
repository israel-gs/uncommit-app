import SwiftUI

struct PopoverContentView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Uncommit")
                    .font(.headline)
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
                RepoListView()
            }
        }
        .frame(minWidth: 380, maxWidth: 380, minHeight: 200, maxHeight: 550)
    }
}
