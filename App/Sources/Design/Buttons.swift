import SwiftUI

private struct StickerPressStyle: ButtonStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 32, style: .continuous)
        let pressed = configuration.isPressed
        return configuration.label
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: Sticker.minButtonHeight)
            .foregroundStyle(Color.ink)
            .themedSurface(shape, fill: fill)
            .offset(x: pressed ? Sticker.shadowOffset : 0, y: pressed ? Sticker.shadowOffset : 0)
            .opacity(pressed && Sticker.shadowOffset == 0 ? 0.8 : 1)
            .contentShape(shape)
    }
}

struct BigButton: View {
    let title: String
    let fill: Color
    let action: () -> Void

    init(_ title: String, fill: Color, action: @escaping () -> Void) {
        self.title = title; self.fill = fill; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).typo(.heading, size: 22).multilineTextAlignment(.center)
        }
        .buttonStyle(StickerPressStyle(fill: fill))
    }
}

struct TalkButton: View {
    let name: String
    let action: () -> Void

    init(name: String, action: @escaping () -> Void) { self.name = name; self.action = action }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill").font(.system(size: 26, weight: .bold))
                Text("Talk to \(name)").typo(.heading, size: 22).multilineTextAlignment(.center)
            }
        }
        // Ink on coral (about 6:1); white on coral would be under 3:1.
        .buttonStyle(StickerPressStyle(fill: .coral))
        .accessibilityLabel("Talk to \(name)")
    }
}

#Preview {
    VStack(spacing: 20) {
        BigButton("Call my daughter", fill: .fillSteps) {}
        TalkButton(name: "Bolt") {}
    }
    .padding(20).background(ThemeBackground())
}
#Preview("Accessibility 3") {
    ScrollView {
        VStack(spacing: 20) {
            BigButton("Call my daughter", fill: .fillSteps) {}
            TalkButton(name: "Bolt") {}
        }.padding(20)
    }
    .background(Color.paper).dynamicTypeSize(.accessibility3)
}
