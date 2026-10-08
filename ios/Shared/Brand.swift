import SwiftUI

/// Kiroku 記錄 brand, navy-first like the logo: navy is the frame, ivory is the ink. Colors live in
/// Shared/Brand.xcassets (light = ivory reading surface, dark = navy; twins of the web's CSS tokens). This file
/// only holds the pieces several screens share.
extension View {
    /// Ivory (dark: navy) page behind a List / Form, with Surface rows — the web's --paper / --panel.
    func kirokuList() -> some View {
        scrollContentBackground(.hidden).background(Color(.paper))
    }

    /// Surface row background; put it on a list's content (rows, ForEach, Section, Group).
    func kirokuRows() -> some View { listRowBackground(Color(.surface)) }

    /// Navy chrome like the logo: nav bar + tab bar navy with ivory titles, in both themes. Inline titles: iOS 26
    /// draws a large title in the content, under the solid bar background, where it would be hidden.
    func kirokuChrome() -> some View {
        navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.brandNavy), for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .tabBar)
    }

    /// `toolbar` for the navy bar: on iOS 26 the items drop their glass pills, which turn pale over an ivory list in
    /// light mode (ivory text on them fails contrast), and show as plain ivory / seafoam on navy.
    func kirokuToolbar<C: ToolbarContent>(@ToolbarContentBuilder _ content: () -> C) -> some View {
        toolbar { KirokuPlainToolbar(content: content()) }
    }

    /// Whole screen on navy (record, connect, login): dark scheme so Paper / Surface / system controls resolve
    /// to their navy variants.
    func kirokuNavyScreen() -> some View {
        background(Color(.brandNavy).ignoresSafeArea())
            .tint(Color(.brandSeafoam)) // the global AccentColor resolves with the system appearance, not this scheme
            .environment(\.colorScheme, .dark)
    }
}

/// The logo mark (sound wave flowing into 言), decorative next to visible text, or labelled when alone.
/// On navy, give it a dark color scheme: ivory lines and a seafoam wave, exactly the logo.
struct KirokuMark: View {
    var height: CGFloat = 20

    var body: some View {
        Image(.kirokuMark)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("Kiroku 記錄")
    }
}

/// 「言 Kiroku 記錄」 lockup for navy surfaces: mark, Kiroku in rounded heavy, 記錄 muted.
struct KirokuLockup: View {
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: size * 0.35) {
            KirokuMark(height: size * 1.1)
            Text("Kiroku").fontWeight(.heavy).foregroundStyle(Color(.brandIvory))
            Text("記錄").fontWeight(.bold).foregroundStyle(Color(.onChromeMuted))
        }
        .font(.system(size: size, design: .rounded))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kiroku 記錄")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct KirokuPlainToolbar<C: ToolbarContent>: ToolbarContent {
    let content: C

    var body: some ToolbarContent {
        if #available(iOS 26, *) { content.sharedBackgroundVisibility(.hidden) } else { content }
    }
}
