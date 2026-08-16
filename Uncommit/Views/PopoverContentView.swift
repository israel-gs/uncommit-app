import SwiftUI

struct PopoverContentView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var showingSettings = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    /// Size the current resize drag started from.
    @State private var dragOrigin: CGSize?

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

                // "Pull all" — shown when repos have incoming commits or while a
                // pull-all is running. The count doubles as a "how many behind"
                // glance; a spinner replaces the icon while pulling.
                if viewModel.reposNeedingPullCount > 0 || viewModel.isPullingAll {
                    Button {
                        Task { await viewModel.pullAll() }
                    } label: {
                        HStack(spacing: 2) {
                            if viewModel.isPullingAll {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.down.to.line")
                            }
                            if viewModel.reposNeedingPullCount > 0 {
                                Text("\(viewModel.reposNeedingPullCount)")
                            }
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isPullingAll)
                    .accessibilityLabel("Pull all repositories with incoming commits")
                    .help(viewModel.isPullingAll
                          ? "Pulling…"
                          : "Pull all repositories with incoming commits (fast-forward)")
                }

                Button {
                    Task { await viewModel.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh all repositories (⌘R)")
                .accessibilityLabel("Refresh all repositories")

                Button {
                    Task { await viewModel.checkAllRemotes() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isCheckingAllRemotes)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Fetch all remotes (⇧⌘R)")
                .accessibilityLabel("Fetch all remotes")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSettings.toggle()
                    }
                } label: {
                    Image(systemName: showingSettings ? "xmark" : "gear")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: .command)
                .help(showingSettings ? "Close settings (⌘,)" : "Settings (⌘,)")
                .accessibilityLabel(showingSettings ? "Close settings" : "Settings")
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
                        .focused($searchFocused)
                        .onExitCommand { searchText = "" }
                        .accessibilityLabel("Search repositories")
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear search")
                    }

                    displayModeToggle

                    // ⌘F has nowhere else to live: an accessory app has no
                    // menu bar to hang a Find command off.
                    Button("") { searchFocused = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .onAppear { searchFocused = true }

                Divider()

                // While searching we always show a flat result list so matches
                // in other groups aren't hidden behind an inactive tab.
                if viewModel.repoDisplayMode == .grouped && searchText.isEmpty {
                    GroupedRepoListView()
                } else {
                    RepoListView(searchText: searchText)
                }
            }
        }
        .frame(
            minWidth: viewModel.configuration.popoverWidth,
            maxWidth: viewModel.configuration.popoverWidth,
            minHeight: AppConstants.minPopoverHeight,
            maxHeight: viewModel.configuration.popoverHeight
        )
        .overlay(alignment: .bottomTrailing) { resizeGrip }
    }

    /// Drag handle for the popover's size.
    ///
    /// A MenuBarExtra window has no title bar and no system resize edges, so the
    /// size has to be driven from the SwiftUI frame — the panel follows its
    /// content. Height is a ceiling rather than a fixed value, so a short list
    /// still gets a short popover.
    private var resizeGrip: some View {
        Image(systemName: "line.diagonal")
            .font(.system(size: 9, weight: .bold))
            .rotationEffect(.degrees(90))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help("Drag to resize")
            .accessibilityHidden(true)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // Anchor on the size the drag started from, so the
                        // popover doesn't accelerate away as it grows.
                        let origin = dragOrigin ?? CGSize(
                            width: viewModel.configuration.popoverWidth,
                            height: viewModel.configuration.popoverHeight
                        )
                        if dragOrigin == nil { dragOrigin = origin }
                        viewModel.setPopoverSize(
                            width: origin.width + value.translation.width,
                            height: origin.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        viewModel.persistPopoverSize()
                    }
            )
    }

    /// Switches between the flat list and the grouped-by-root-folder tabs.
    private var displayModeToggle: some View {
        let grouped = viewModel.repoDisplayMode == .grouped
        return Button {
            viewModel.setRepoDisplayMode(grouped ? .list : .grouped)
        } label: {
            Image(systemName: grouped ? "square.grid.2x2" : "list.bullet")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .help(grouped ? "Show as a single list" : "Group by root folder")
        .accessibilityLabel(grouped ? "Show as a single list" : "Group by root folder")
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
