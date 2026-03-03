import SwiftUI

struct SettingsView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var installedEditors: [InstalledApp] = []
    @State private var editingEditorForRepoId: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Watched Folders
                VStack(alignment: .leading, spacing: 8) {
                    Text("Root Folders")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.watchedFolders) { folder in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(folder.displayName)
                                    .font(.callout)
                                Text(folder.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                viewModel.removeWatchedFolder(folder)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Add Root Folder...") {
                            openFolderPicker { path in
                                Task { await viewModel.addWatchedFolder(at: path) }
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)

                        Button("Rescan All") {
                            Task { await viewModel.rescanWatchedFolders() }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Individual Repositories
                VStack(alignment: .leading, spacing: 8) {
                    Text("Repositories (\(viewModel.repositories.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(viewModel.repositories) { repo in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "arrow.triangle.branch")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(repo.displayName)
                                        .font(.callout)
                                    Text(repo.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()

                                // Per-repo editor override toggle
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if editingEditorForRepoId == repo.id {
                                            editingEditorForRepoId = nil
                                        } else {
                                            editingEditorForRepoId = repo.id
                                        }
                                    }
                                } label: {
                                    Image(systemName: "curlybraces")
                                        .font(.caption)
                                        .foregroundStyle(repo.customEditorBundleId != nil ? .blue : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(repo.customEditorBundleId != nil
                                      ? "Editor: \(EditorHelper.editorName(for: repo.customEditorBundleId!) ?? repo.customEditorBundleId!)"
                                      : "Set custom editor")

                                Button {
                                    viewModel.removeRepository(repo)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }

                            // Per-repo editor picker (expanded)
                            if editingEditorForRepoId == repo.id {
                                editorPickerRow(for: repo)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    Button("Add Repository...") {
                        openFolderPicker { path in
                            viewModel.addRepository(at: path)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }

                Divider()

                // Settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preferences")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    // Default editor
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default editor")
                            .font(.callout)
                        HStack(spacing: 6) {
                            if let bundleId = viewModel.configuration.defaultEditorBundleId,
                               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(EditorHelper.editorName(for: bundleId) ?? bundleId)
                                    .font(.callout)

                                Button {
                                    viewModel.configuration.defaultEditorBundleId = nil
                                    viewModel.saveConfiguration()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Clear default editor")
                            } else {
                                Text("Not set")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(installedEditors) { editor in
                                    Button {
                                        viewModel.configuration.defaultEditorBundleId = editor.id
                                        viewModel.saveConfiguration()
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(nsImage: editor.icon)
                                                .resizable()
                                                .frame(width: 14, height: 14)
                                            Text(editor.name)
                                                .font(.caption)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            viewModel.configuration.defaultEditorBundleId == editor.id
                                                ? Color.accentColor.opacity(0.2)
                                                : Color.clear
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.borderless)
                                }

                                Button("Other…") {
                                    if let app = EditorHelper.pickCustomApp() {
                                        viewModel.configuration.defaultEditorBundleId = app.id
                                        viewModel.saveConfiguration()
                                        // Add to the list if not already present
                                        if !installedEditors.contains(where: { $0.id == app.id }) {
                                            installedEditors.append(app)
                                            installedEditors.sort {
                                                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                                            }
                                        }
                                    }
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()

                    HStack {
                        Text("Refresh interval")
                            .font(.callout)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { viewModel.configuration.refreshIntervalSeconds },
                            set: {
                                viewModel.configuration.refreshIntervalSeconds = $0
                                viewModel.saveConfiguration()
                            }
                        )) {
                            Text("15s").tag(15.0)
                            Text("30s").tag(30.0)
                            Text("60s").tag(60.0)
                            Text("2m").tag(120.0)
                        }
                        .frame(width: 80)
                    }

                    HStack {
                        Text("Scan depth")
                            .font(.callout)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { viewModel.configuration.maxDiscoveryDepth },
                            set: {
                                viewModel.configuration.maxDiscoveryDepth = $0
                                viewModel.saveConfiguration()
                            }
                        )) {
                            Text("2").tag(2)
                            Text("3").tag(3)
                            Text("4").tag(4)
                            Text("5").tag(5)
                        }
                        .frame(width: 80)
                    }
                }

                Divider()

                Button("Quit Uncommit") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.callout)
                .foregroundStyle(.red)
            }
            .padding(12)
        }
        .onAppear {
            installedEditors = EditorHelper.installedEditors()
        }
    }

    // MARK: - Per-repo editor picker row

    @ViewBuilder
    private func editorPickerRow(for repo: GitRepository) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Editor override:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let customId = repo.customEditorBundleId {
                    Text(EditorHelper.editorName(for: customId) ?? customId)
                        .font(.caption)
                        .foregroundStyle(.blue)

                    Button {
                        viewModel.setCustomEditor(for: repo, bundleId: nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Use global default")
                } else {
                    Text("Using global default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(installedEditors) { editor in
                        Button {
                            viewModel.setCustomEditor(for: repo, bundleId: editor.id)
                        } label: {
                            HStack(spacing: 3) {
                                Image(nsImage: editor.icon)
                                    .resizable()
                                    .frame(width: 12, height: 12)
                                Text(editor.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                repo.customEditorBundleId == editor.id
                                    ? Color.blue.opacity(0.2)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .buttonStyle(.borderless)
                    }

                    Button("Other…") {
                        if let app = EditorHelper.pickCustomApp() {
                            viewModel.setCustomEditor(for: repo, bundleId: app.id)
                            if !installedEditors.contains(where: { $0.id == app.id }) {
                                installedEditors.append(app)
                                installedEditors.sort {
                                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                                }
                            }
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 20)
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func openFolderPicker(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder"
        panel.prompt = "Select"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
}
