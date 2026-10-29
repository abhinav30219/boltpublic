import SwiftUI
import BoltCore

/// More → Companion: rename, look, Talk button, emergency contact, reduced animation.
struct CompanionSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var contactName = ""
    @State private var contactPhone = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CompanionPreview(appearance: model.companionProfile.appearance, height: 200)
                    .padding(.trailing, Sticker.shadowOffset)
                Text("Name").typo(.heading, size: 22)
                StickerField(placeholder: "Bolt", text: $model.companionProfile.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                AppearancePicker(appearance: $model.companionProfile.appearance)

                Text("Theme").typo(.heading, size: 22).padding(.top, 4)
                ThemePicker(selection: $model.companionProfile.theme)

                toggleRow("Show Talk to \(model.companionProfile.displayName) button", isOn: $model.companionProfile.showTalkButton)
                toggleRow("Reduce companion animation", isOn: reduceBinding)

                Text("Someone to call").typo(.heading, size: 22).padding(.top, 4)
                Text("Offered when a fall check needs help. Stays on this phone.")
                    .typo(.body, size: 16).foregroundStyle(Color.inkSoft)
                ContactFields(name: $contactName, phone: $contactPhone)
                if model.companionProfile.contactPhone != nil {
                    Button("Remove contact") {
                        contactName = ""; contactPhone = ""
                        model.companionProfile.contactName = nil
                        model.companionProfile.contactPhone = nil
                    }
                    .typo(.label, size: 18).foregroundStyle(Color.alertInk).underline()
                    .frame(minHeight: 44)
                }
            }
            .foregroundStyle(Color.ink)
            .padding(16)
        }
.scrollDismissesKeyboard(.interactively)
.keyboardDoneButton()
        .background(ThemeBackground())
        .navigationTitle("Companion")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            contactName = model.companionProfile.contactName ?? ""
            contactPhone = model.companionProfile.contactPhone ?? ""
        }
        .onChange(of: contactName) { _, _ in saveContact() }
        .onChange(of: contactPhone) { _, _ in saveContact() }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .typo(.body, size: 19).tint(Color.accent)
            .foregroundStyle(Color.ink)
            .padding(14)
            .frame(minHeight: Sticker.minButtonHeight)
            .background { Color.clear.sticker(fill: .card) }
            .padding(.trailing, Sticker.shadowOffset)
    }

    private var reduceBinding: Binding<Bool> {
        Binding(get: { model.tuning.render.reduceAnimation },
                set: { v in var t = model.tuning; t.render.reduceAnimation = v; model.updateTuning(t) })
    }

    private func saveContact() {
        let p = CompanionProfile.sanitizedPhone(contactPhone)
        let n = contactName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.companionProfile.contactPhone = p.isEmpty ? nil : p
        model.companionProfile.contactName = p.isEmpty ? nil : n
    }
}

/// Three tappable previews: background, a tiny card and the word "Bolt" in each theme's style. Applies live.
private struct ThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        VStack(spacing: 12) {
            ForEach(AppTheme.allCases) { theme in
                Button { selection = theme } label: { row(theme) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.title). \(theme.blurb)")
                    .accessibilityAddTraits(selection == theme ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.trailing, Sticker.shadowOffset)
    }

    private func row(_ theme: AppTheme) -> some View {
        let on = selection == theme
        return HStack(spacing: 14) {
            swatch(theme)
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.title).typo(.heading, size: 20)
                Text(theme.blurb).typo(.body, size: 15).foregroundStyle(Color.inkSoft)
            }
            Spacer(minLength: 4)
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(on ? Color.ink : Color.inkSoft)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Color.ink)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: Sticker.minButtonHeight, alignment: .leading)
        .sticker(fill: on ? .fillSteps : .card, radius: 20)
        .contentShape(Rectangle())
    }

    private func swatch(_ theme: AppTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let ink = theme.pick(Color(hex: 0x2B1D18), Color(hex: 0x3A2763), Color(hex: 0xFFF1E6))
        let cardFill = theme.pick(Color.white, Color.white.opacity(0.75), Color.white.opacity(0.1))
        let cardShape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ZStack(alignment: .topLeading) {
            ThemeBackground(theme: theme, fullScreen: false)
            VStack(alignment: .leading, spacing: 5) {
                Text("Bolt").font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(ink)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 4) {
                    Capsule().fill(theme.pick(Color(hex: 0xFF7F6E), Color(hex: 0xE2437F), Color(hex: 0x9BF0D2))).frame(width: 14, height: 6)
                    Capsule().fill(ink.opacity(0.5)).frame(width: 18, height: 6)
                }
                .padding(.horizontal, 7).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardFill, in: cardShape)
                .overlay(cardShape.strokeBorder(theme.pick(Color(hex: 0x2B1D18), Color.clear, Color.white.opacity(0.18)),
                                                lineWidth: theme.pick(2, 0, 1)))
            }
            .padding(8)
        }
        .frame(width: 88, height: 64)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.inkSoft.opacity(0.35), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
