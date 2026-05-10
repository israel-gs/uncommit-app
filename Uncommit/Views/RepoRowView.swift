import SwiftUI

struct RepoRowView: View {
    @Environment(AppViewModel.self) private var viewModel
    let repo: GitRepository

    private var status: GitRepoStatus? { viewModel.status(for: repo) }
    private var error: String? { viewModel.error(for: repo) }
    private var isCheckingRemote: Bool { viewModel.isCheckingRemote(repo) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top: status dot + name + branch
            HStack(spacing: 6) {
                StatusIndicatorView(healthLevel: viewModel.healthLevel(for: repo))

                Text(repo.displayName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                Spacer()

                if let branch = status?.branchName {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                        Text(branch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
            }

            // Status details
            if let status = status {
                HStack(spacing: 8) {
                    if status.stagedCount > 0 {
                        StatusBadge(count: status.stagedCount, icon: "plus.circle.fill", color: .green, label: "staged", files: status.stagedFiles)
                    }
                    if status.modifiedCount > 0 {
                        StatusBadge(count: status.modifiedCount, icon: "pencil.circle.fill", color: .orange, label: "modified", files: status.modifiedFiles)
                    }
                    if status.untrackedCount > 0 {
                        StatusBadge(count: status.untrackedCount, icon: "questionmark.circle.fill", color: .gray, label: "untracked", files: status.untrackedFiles)
                    }
                    if status.conflictCount > 0 {
                        StatusBadge(count: status.conflictCount, icon: "exclamationmark.triangle.fill", color: .red, label: "conflicts", files: status.conflictFiles)
                    }

                    if status.isClean && !status.hasUnpulledChanges && !status.hasUnpushedChanges {
                        Text("Clean")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    if status.hasRemoteTrackingBranch {
                        if status.aheadCount > 0 {
                            StatusBadge(count: status.aheadCount, icon: "arrow.up", color: .blue, label: "ahead")
                        }
                        if status.behindCount > 0 {
                            StatusBadge(count: status.behindCount, icon: "arrow.down", color: .purple, label: "behind")
                        }
                    }
                }
                .font(.caption)

                // Show transient errors (e.g. failed fetch / push) alongside
                // the last-known status so the user knows data may be stale.
                if let error = error {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(error)
                            .font(.caption2)
                            .lineLimit(2)
                    }
                    .foregroundStyle(.red)
                }
            } else if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("Checking...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                Spacer()

                // Pull/push are conditional: shown only when relevant. Pull
                // uses --ff-only so it never produces surprise merge commits.
                if let status = status, status.hasRemoteTrackingBranch {
                    if status.behindCount > 0 {
                        Button {
                            Task { await viewModel.pull(repo) }
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down.to.line")
                                Text("Pull")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isCheckingRemote)
                        .help("Pull (fast-forward)")
                    }
                    if status.aheadCount > 0 {
                        Button {
                            Task { await viewModel.push(repo) }
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.up.to.line")
                                Text("Push")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isCheckingRemote)
                        .help("Push")
                    }
                }

                Button {
                    Task { await viewModel.checkRemote(for: repo) }
                } label: {
                    HStack(spacing: 2) {
                        if isCheckingRemote {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text("Check Remote")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(isCheckingRemote)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(repo.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy path")

                editorButton

                Button {
                    openInTerminal(repo.path)
                } label: {
                    Image(systemName: "terminal")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Open in Terminal")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var editorButton: some View {
        if let editorId = EditorHelper.effectiveEditorBundleId(
            repo: repo,
            globalDefault: viewModel.configuration.defaultEditorBundleId
        ) {
            let installed = EditorHelper.appIcon(for: editorId) != nil
            let editorName = EditorHelper.editorName(for: editorId) ?? "editor"
            Button {
                if !EditorHelper.openInEditor(path: repo.path, bundleId: editorId) {
                    viewModel.reportEditorError(
                        for: repo,
                        message: "\(editorName) is not installed"
                    )
                }
            } label: {
                if let icon = EditorHelper.appIcon(for: editorId) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .buttonStyle(.borderless)
            .help(installed
                  ? "Open in \(editorName)"
                  : "\(editorName) is not installed")
        }
    }

    private func openInTerminal(_ path: String) {
        // Avoid AppleScript: passing the path as a string interpolation enables
        // injection (e.g. a folder named with quotes / backslashes).
        // `open -a Terminal <path>` opens a new Terminal window cd'd to <path>
        // and treats <path> as a single argv entry — no shell parsing.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }
}

struct StatusBadge: View {
    let count: Int
    let icon: String
    let color: Color
    let label: String
    var files: [String] = []

    @State private var showingFiles = false

    private var tooltipText: String {
        files.isEmpty ? "\(count) \(label)" : "\(count) \(label) — click for details"
    }

    var body: some View {
        Group {
            if files.isEmpty {
                badgeContent
            } else {
                Button { showingFiles.toggle() } label: { badgeContent }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showingFiles, arrowEdge: .bottom) {
                        filesPopover
                    }
            }
        }
        .help(tooltipText)
    }

    private var badgeContent: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text("\(count)")
                .monospacedDigit()
        }
    }

    private var filesPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text("\(count) \(label)")
                    .font(.caption.weight(.semibold))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                        Text(file)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 480, maxHeight: 320)
        }
        .padding(10)
    }
}
