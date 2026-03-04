import SwiftUI

@main
struct UncommitApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environment(viewModel)
                .onAppear {
                    // start() has an internal guard — safe to call multiple times.
                    // Using onAppear instead of .task to avoid SwiftUI re-triggering
                    // when MenuBarExtra body re-evaluates (label observes repositories).
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
