import SwiftUI

/// Kiroku 記錄 brand (direction A). Colors live in Assets.xcassets (light + dark, twins of the web's CSS tokens);
/// this file only holds the pieces several screens share.
extension View {
    /// Ivory (dark: ink navy) page behind a List / Form, with Surface rows — the web's --paper / --panel.
    func kirokuList() -> some View {
        scrollContentBackground(.hidden).background(Color(.paper))
    }

    /// Surface row background; put it on a list's content (rows, ForEach, Section, Group).
    func kirokuRows() -> some View { listRowBackground(Color(.surface)) }
}

/// The logo mark (sound wave → written lines), decorative next to visible text, or labelled when alone.
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
