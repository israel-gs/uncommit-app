import SwiftUI

struct RepoRowView: View {
    @Environment(AppViewModel.self) private var viewModel
    let repo: GitRepository

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top: status dot + name + branch
            HStack(spacing: 6) {
                StatusIndicatorView(
                    healthLevel: repo.error != nil ? .error : (repo.status?.healthLevel ?? .error)
                )

                Text(repo.displayName)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                Spacer()

                if let branch = repo.status?.branchName {
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
            if let status = repo.status {
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

                    if status.isClean && !status.hasUnpulledChanges {
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
            } else if let error = repo.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                HStack(spacing: 4) {
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

                Button {
                    Task { await viewModel.checkRemote(for: repo) }
                } label: {
                    HStack(spacing: 2) {
                        if repo.isCheckingRemote {
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
                .disabled(repo.isCheckingRemote)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(repo.path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy path")

                if let editorId = EditorHelper.effectiveEditorBundleId(
                    repo: repo,
                    globalDefault: viewModel.configuration.defaultEditorBundleId
                ) {
                    Button {
                        EditorHelper.openInEditor(path: repo.path, bundleId: editorId)
                    } label: {
                        Image(systemName: "curlybraces")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Open in \(EditorHelper.editorName(for: editorId) ?? "Editor")")
                }

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

    private func openInTerminal(_ path: String) {
        let script = "tell application \"Terminal\" to do script \"cd \(path.replacingOccurrences(of: "\"", with: "\\\""))\""
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

struct StatusBadge: View {
    let count: Int
    let icon: String
    let color: Color
    let label: String
    var files: [String] = []

    private var tooltipText: String {
        var text = "\(count) \(label)"
        if !files.isEmpty {
            text += ":\n" + files.joined(separator: "\n")
        }
        return text
    }

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text("\(count)")
                .monospacedDigit()
        }
        .help(tooltipText)
    }
}
