import SwiftUI

struct EmptyStateView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("No repositories tracked")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Add a repository or a root folder\nto start monitoring git status.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Add Repository...") {
                    openFolderPicker { path in
                        viewModel.addRepository(at: path)
                    }
                }

                Button("Add Root Folder...") {
                    openFolderPicker { path in
                        Task { await viewModel.addWatchedFolder(at: path) }
                    }
                }
            }
            .padding(.top, 4)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
