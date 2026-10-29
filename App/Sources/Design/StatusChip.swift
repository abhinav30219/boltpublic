import SwiftUI

struct StatusChip: View {
    let text: String
    let ok: Bool

    init(text: String, ok: Bool) { self.text = text; self.ok = ok }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .typo(.label, size: 14)
        .foregroundStyle(ok ? Color.ink : Color.alertInk)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(minHeight: 28)
        .background(ok ? Color.chipOk : Color.chipOff, in: Capsule())
        .overlay(Capsule().strokeBorder(ok ? Color.line : Color.alertInk, lineWidth: Sticker.smallBorder))
        .accessibilityElement(children: .combine)
    }
}

/// "Offline · on-device" proof badge, driven by the real network state.
struct OnDeviceBadge: View {
    let offline: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: offline ? "airplane" : "iphone").accessibilityHidden(true)
            Text(offline ? "Offline · all on-device" : "On-device")
        }
        .typo(.label, size: 14)
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(offline ? Color.chipOk : Color.fillRelax, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.line, lineWidth: Sticker.smallBorder))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(spacing: 12) { StatusChip(text: "Bolt connected", ok: true); StatusChip(text: "Bolt not found", ok: false) }
        .padding(16).background(ThemeBackground())
}
#Preview("Accessibility 3") {
    StatusChip(text: "Bolt connected", ok: true).padding(16).background(ThemeBackground())
        .dynamicTypeSize(.accessibility3)
}
