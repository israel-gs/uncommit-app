import SwiftUI

@main
struct UncommitApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environment(viewModel)
                .task {
                    viewModel.start()
                }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: viewModel.menuBarIcon)
                    .foregroundStyle(viewModel.menuBarIconColor)
                if viewModel.dirtyRepoCount > 0 {
                    Text("\(viewModel.dirtyRepoCount)")
                        .font(.caption2)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
