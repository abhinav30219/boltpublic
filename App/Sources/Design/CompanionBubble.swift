import SwiftUI

/// Speech bubble for the companion's friendly lines. Never used for safety messages.
struct CompanionBubble: View {
    let text: String
    let onReadAloud: (() -> Void)?

    init(text: String, onReadAloud: (() -> Void)?) {
        self.text = text; self.onReadAloud = onReadAloud
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .typo(.body, size: 19)
                .foregroundStyle(Color.bubbleText)
                .fixedSize(horizontal: false, vertical: true)
            if let onReadAloud {
                Button(action: onReadAloud) {
                    Label("Read aloud", systemImage: "speaker.wave.2.fill")
                        .typo(.label, size: 15)
                        .foregroundStyle(Color.bubbleText)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Color(hex: 0xFFE08A), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.bubbleText, lineWidth: ThemeStore.current == .stickerBook ? 2.5 : Sticker.smallBorder))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedSurface(bubbleShape, fill: Color.bubbleFill, glow: true)
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 6,
                               bottomTrailingRadius: 22, topTrailingRadius: 22, style: .continuous)
    }
}

#Preview {
    CompanionBubble(text: "That was a lovely walk! Your heart is calm again. Time for a glass of water?",
                    onReadAloud: {})
        .padding(16).background(ThemeBackground())
}
#Preview("Accessibility 3") {
    ScrollView {
        CompanionBubble(text: "That was a lovely walk! Your heart is calm again.", onReadAloud: {}).padding(16)
    }
    .background(Color.paper).dynamicTypeSize(.accessibility3)
}
