import SwiftUI

/// What the shared commits window is currently showing. Carries an explicit
/// git-log range + display metadata so it serves three cases uniformly:
/// commits to push, commits to pull, and a submodule's pointer move.
/// Identifiable so the window can `.id(...)` on it and reload on change.
struct CommitsWindowRequest: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case push, pull, submodule

        var icon: String {
            switch self {
            case .push: "arrow.up.circle.fill"
            case .pull: "arrow.down.circle.fill"
            case .submodule: "shippingbox.fill"
            }
        }
    }

    /// Directory `git log` runs in (the repo, or the submodule's own workdir).
    let repoPath: String
    let title: String       // header + window title
    let subtitle: String    // e.g. "Commits to pull"
    let range: String       // git log revision range
    let kind: Kind

    var id: String { "\(repoPath)#\(range)" }
}

/// Content of the single shared commits window. Reflects whatever badge was
/// clicked last; swapping requests reloads via `.id`.
struct CommitsWindowHost: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        Group {
            if let request = viewModel.commitsRequest {
                CommitsWindowView(request: request)
                    .id(request.id)
            } else {
                Text("Select a repository's ↑/↓ to view its commits")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A roomy, resizable window listing the commits in a revision range. Replaces
/// the cramped popover: subjects wrap, text is selectable, and there's room to
/// grow (diffs later) without fighting the menu-bar popover's bounds.
struct CommitsWindowView: View {
    let request: CommitsWindowRequest

    @State private var commits: [GitCommit] = []
    @State private var loading = false
    @State private var loadError: String?

    private var accent: Color { request.kind == .push ? .blue : .purple }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 460, minHeight: 320)
        .navigationTitle("\(request.title) — \(request.subtitle)")
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: request.kind.icon)
                .font(.title2)
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(request.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(request.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if loading {
                ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
            }

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(loading)
            .help("Reload")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if commits.isEmpty && !loading {
            Text("No commits in range")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(commits) { commit in
                CommitRowDetail(commit: commit, accent: accent)
            }
            .listStyle(.inset)
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            commits = try await GitService.commits(at: request.repoPath, range: request.range, limit: 200)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// One commit, laid out for reading: full wrapping subject, then a selectable
/// metadata line (hash · author · when).
struct CommitRowDetail: View {
    let commit: GitCommit
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.subject)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(commit.hash)
                    .font(.callout.monospaced())
                    .foregroundStyle(accent)
                    .textSelection(.enabled)
                Text(commit.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(commit.relativeDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
