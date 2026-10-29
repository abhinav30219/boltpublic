import SwiftUI

extension View {
    /// Rounded card: Sticker Book draws a 3 pt ink border and a hard 4 pt offset shadow; the other themes use a soft shadow or a hairline.
    func sticker(fill: Color = .card, radius: CGFloat = 20) -> some View {
        themedSurface(RoundedRectangle(cornerRadius: radius, style: .continuous), fill: fill)
    }
}

extension View {
    /// Padded sticker panel for list-style content (replaces the old flat card).
    func stickerPanel(fill: Color = .card) -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.ink)
            .sticker(fill: fill)
    }
}

struct StickerCard<Content: View>: View {
    let fill: Color
    let content: Content

    init(fill: Color = .card, @ViewBuilder content: () -> Content) {
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Color.ink)
            .sticker(fill: fill)
    }
}

#Preview {
    VStack(spacing: 20) {
        StickerCard { Text("Default").typo(.body) }
        StickerCard(fill: .fillHeart) { Text("Heart").typo(.body) }
    }
    .padding().background(ThemeBackground())
}
#Preview("Accessibility 3") {
    StickerCard(fill: .fillHeart) { Text("Heart rate card text").typo(.body) }
        .padding().background(ThemeBackground())
        .dynamicTypeSize(.accessibility3)
}

extension View {
    /// Paper screen with explicit white rows and ink text for a List / Form.
    func paperListStyle() -> some View {
        self.scrollContentBackground(.hidden)
            .listRowBackground(Color.card)
            .background(ThemeBackground())
            .foregroundStyle(Color.ink)
            .tint(.ink)
    }
}
