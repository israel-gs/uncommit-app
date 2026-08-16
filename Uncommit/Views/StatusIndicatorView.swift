import SwiftUI

/// The per-row health indicator.
///
/// It used to be a bare coloured circle, which made colour the only carrier of
/// the meaning — unusable with red-green colour blindness, and `.remoteOutOfSync`
/// and `.error` are both red anyway. Each level now has its own glyph as well,
/// the same vocabulary the menu bar icon uses, plus a label for VoiceOver.
struct StatusIndicatorView: View {
    let healthLevel: RepoHealthLevel

    var body: some View {
        Image(systemName: MenuBarIconProvider.symbolName(for: healthLevel))
            .font(.system(size: 10))
            .foregroundStyle(MenuBarIconProvider.color(for: healthLevel))
            .help(MenuBarIconProvider.description(for: healthLevel))
            .accessibilityLabel(MenuBarIconProvider.description(for: healthLevel))
    }
}
