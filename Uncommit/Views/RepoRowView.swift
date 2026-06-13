import SwiftUI

struct RepoRowView: View {
    @Environment(AppViewModel.self) private var viewModel
    let repo: GitRepository

    private var status: GitRepoStatus? { viewModel.status(for: repo) }
    private var error: String? { viewModel.error(for: repo) }
    private var isCheckingRemote: Bool { viewModel.isCheckingRemote(repo) }

    /// The directory containing the repo, with the home directory abbreviated
    /// to `~`. e.g. "~/Documents/work".
    private var locationPath: String {
        let parent = URL(fileURLWithPath: repo.path).deletingLastPathComponent().path
        return (parent as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top: status dot + name + branch
            HStack(spacing: 6) {
                StatusIndicatorView(healthLevel: viewModel.healthLevel(for: repo))

                Text(repo.displayName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                if repo.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .rotationEffect(.degrees(45))
                }

                Spacer()

                if let branch = status?.branchName {
                    BranchPicker(repo: repo, currentBranch: branch)
                }
            }

            // Location: the directory containing the repo, so projects under
            // the same parent read like a file tree. Secondary, de-emphasized.
            Text(locationPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

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
                            CommitsBadge(repoPath: repo.path, repoName: repo.displayName, count: status.aheadCount, ahead: true)
                        }
                        if status.behindCount > 0 {
                            CommitsBadge(repoPath: repo.path, repoName: repo.displayName, count: status.behindCount, ahead: false)
                        }
                    }
                }
                .font(.caption)

                // Submodules whose pointer/branch/content diverged. Shown in
                // their own block so they never read as plain modified files.
                if !status.submodules.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(status.submodules) { submodule in
                            SubmoduleRow(repo: repo, change: submodule)
                        }
                    }
                    .padding(.top, 2)
                }

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
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.togglePin(for: repo)
                    }
                } label: {
                    Image(systemName: repo.isPinned ? "pin.fill" : "pin")
                        .font(.caption)
                        .foregroundStyle(repo.isPinned ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help(repo.isPinned ? "Unpin" : "Pin to top")

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
                        // Push will be rejected by git if the remote has new
                        // commits we haven't pulled, so we disable it and
                        // tell the user to pull first.
                        let pushBlocked = status.behindCount > 0
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
                        .disabled(isCheckingRemote || pushBlocked)
                        .help(pushBlocked
                              ? "Pull first — remote has \(status.behindCount) new commit(s)"
                              : "Push")
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
                    revealInFinder(repo.path)
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
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

    private func revealInFinder(_ path: String) {
        // Open the folder in a Finder window showing its contents.
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
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

/// One changed submodule: a cube glyph, the path, the branch it currently
/// points to, the pointer move (old → new SHA), and small flags for dirty
/// content. Deliberately compact — it sits inside the repo row.
struct SubmoduleRow: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    let repo: GitRepository
    let change: SubmoduleChange

    /// We can show its commits only when the pointer moved and we resolved both
    /// the recorded and checked-out SHAs (the range needs both ends).
    private var canViewCommits: Bool {
        change.commitChanged && change.oldSHA != nil && change.newSHA != nil
    }

    private var isBusy: Bool { viewModel.isCheckingRemote(repo) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "shippingbox.fill")
                .font(.caption2)
                .foregroundStyle(.purple)
                .help("Submodule")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(change.name)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Submodules normally sit on a detached HEAD (they track a
                    // commit, not a branch), so we only surface a branch chip
                    // when one actually exists — "detached" alone is just noise.
                    if let branch = change.branch {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8))
                            Text(branch)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    pointerLabel
                    if change.hasModifications {
                        flag("pencil", "modified content", .orange)
                    }
                    if change.hasUntracked {
                        flag("questionmark", "untracked content", .gray)
                    }
                    if change.staged {
                        flag("plus", "staged", .green)
                    }
                }
            }

            Spacer(minLength: 0)

            // Actions: view what changed, and sync the submodule back to the
            // commit the parent records.
            if canViewCommits {
                Button {
                    viewModel.commitsRequest = CommitsWindowRequest(
                        repoPath: repo.path + "/" + change.name,
                        title: change.name,
                        subtitle: "Submodule pointer \(change.oldSHA ?? "") → \(change.newSHA ?? "")",
                        range: "\(change.oldSHA ?? "")..\(change.newSHA ?? "")",
                        kind: .submodule
                    )
                    openWindow(id: "commits")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("View the submodule's commits between recorded and checked-out")
            }

            if change.commitChanged {
                Button {
                    Task { await viewModel.syncSubmodule(repo, submodule: change.name) }
                } label: {
                    if isBusy {
                        ProgressView().scaleEffect(0.4).frame(width: 11, height: 11)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help("Sync submodule to the commit the parent records (git submodule update)")
            }
        }
    }

    @ViewBuilder
    private var pointerLabel: some View {
        if change.commitChanged {
            if let old = change.oldSHA, let new = change.newSHA {
                HStack(spacing: 3) {
                    Text(old)
                    Image(systemName: "arrow.right").font(.system(size: 8))
                    Text(new)
                }
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
                .help("Recorded commit → checked-out commit")
            } else {
                Text("commit changed")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func flag(_ icon: String, _ help: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .help(help)
    }
}

/// An ahead/behind arrow that opens a dedicated, resizable window listing the
/// commits pending push or pull. A popover proved too cramped (clipped subjects
/// inside the menu-bar popover), so this routes to a real window instead.
struct CommitsBadge: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.openWindow) private var openWindow
    let repoPath: String
    let repoName: String
    let count: Int
    /// true = ahead (commits to push); false = behind (commits to pull).
    let ahead: Bool

    private var icon: String { ahead ? "arrow.up" : "arrow.down" }
    private var color: Color { ahead ? .blue : .purple }
    private var title: String { ahead ? "\(count) to push" : "\(count) to pull" }

    var body: some View {
        Button {
            // Point the single shared window at this repo+direction, then
            // open/focus it. Reusing one window avoids a pile-up of windows.
            viewModel.commitsRequest = CommitsWindowRequest(
                repoPath: repoPath,
                title: repoName,
                subtitle: ahead ? "Commits to push" : "Commits to pull",
                range: ahead ? "@{u}..HEAD" : "HEAD..@{u}",
                kind: ahead ? .push : .pull
            )
            openWindow(id: "commits")
            // Accessory (LSUIElement) apps don't auto-focus windows; bring it
            // to the front explicitly.
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: icon).foregroundStyle(color)
                Text("\(count)").monospacedDigit()
            }
        }
        .buttonStyle(.borderless)
        .help("\(title) — click to view commits")
    }
}

/// The branch chip, upgraded to a picker: click to see local branches and
/// switch. Branches load lazily when the popover opens. A checkout that would
/// clobber working-tree changes fails and surfaces git's error in the row.
struct BranchPicker: View {
    @Environment(AppViewModel.self) private var viewModel
    let repo: GitRepository
    let currentBranch: String

    @State private var showing = false
    @State private var localBranches: [String] = []
    @State private var remoteBranches: [String] = []
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch").font(.caption2)
                Text(currentBranch).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.system(size: 7)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .help("Switch branch")
        .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Switch branch").font(.caption.weight(.semibold))
            Divider()
            if loading {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red).lineLimit(3)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(localBranches, id: \.self) { branch in
                            branchButton(branch, remote: false)
                        }
                        if !remoteBranches.isEmpty {
                            Text("Remote")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .padding(.leading, 18)
                            ForEach(remoteBranches, id: \.self) { branch in
                                branchButton(branch, remote: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(10)
        .frame(width: 240)
        .task(id: showing) {
            guard showing else { return }
            await load()
        }
    }

    private func branchButton(_ branch: String, remote: Bool) -> some View {
        let isCurrent = !remote && branch == currentBranch
        return Button {
            showing = false
            Task { await viewModel.checkout(repo, to: branch) }
        } label: {
            HStack(spacing: 6) {
                Group {
                    if isCurrent {
                        Image(systemName: "checkmark").font(.caption2)
                    } else if remote {
                        Image(systemName: "cloud").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 12, alignment: .center)
                Text(branch).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let result = try await GitService.branches(at: repo.path)
            localBranches = result.local
            remoteBranches = result.remoteOnly
        } catch {
            loadError = error.localizedDescription
        }
    }
}
