import SwiftUI
import BoltCore

/// A small live companion with its own driver. `state` nil shows a calm, happy idle robot.
struct CompanionPreview: View {
    @EnvironmentObject var model: AppModel
    let appearance: Appearance
    var state: CompanionState? = nil
    var height: CGFloat = 200
    var celebrateOnAppear = false
    @StateObject private var driver = CompanionDriver(tuning: Tuning())

    var body: some View {
        CompanionView(driver: driver, height: height)
            .onAppear {
                driver.tuning = model.tuning
                driver.appearance = appearance
                driver.state = state ?? Self.calm
                driver.twin = model.robotTwin
                if celebrateOnAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { driver.celebrate() }
                }
            }
            .onChange(of: appearance) { _, a in driver.appearance = a }
            .onChange(of: state) { _, s in driver.state = s ?? Self.calm }
            .onChange(of: model.tuning) { _, t in driver.tuning = t }
            .onChange(of: model.robotTwin) { _, t in driver.twin = t }
    }

    static var calm: CompanionState {
        var s = CompanionState()
        s.motion = .idle; s.mood = .happy; s.overlays = []; s.bandWorn = true
        return s
    }
}

/// Palette and face-style chips. Shared by onboarding and More → Companion.
struct AppearancePicker: View {
    @Binding var appearance: Appearance
    /// Tighter spacing and shorter chips so everything fits on one screen.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            Text("Colors").typo(.heading, size: compact ? 19 : 22)
            HStack(spacing: 10) {
                ForEach(BodyPalette.allCases, id: \.self) { p in
                    chip(p.title, on: appearance.palette == p, swatch: Color(uiColor: p.joint)) { appearance.palette = p }
                }
            }
            Text("Face").typo(.heading, size: compact ? 19 : 22).padding(.top, compact ? 0 : 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(FaceStyle.allCases, id: \.self) { f in
                    chip(f.title, on: appearance.face == f, swatch: Color(uiColor: f.defaultEyeColor), horizontal: compact) { appearance.face = f }
                }
            }
        }
    }

    private func chip(_ title: String, on: Bool, swatch: Color, horizontal: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            (horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: compact ? 3 : 6))) {
                Circle().fill(swatch).frame(width: compact ? 20 : 26, height: compact ? 20 : 26)
                    .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2.5))
                Text(title).typo(.label, size: 16).multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: compact ? (horizontal ? 44 : 56) : 64)
            .padding(.vertical, compact ? 2 : 6)
            .sticker(fill: on ? .fillSteps : .card, radius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .padding(.trailing, Sticker.shadowOffset)
    }
}

struct MeetCompanionStep: View {
    var next: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepScaffold(title: "Meet your companion", subtitle: "Pick a name and a look. You can change them any time in More.") {
            VStack(alignment: .leading, spacing: 12) {
                CompanionPreview(appearance: model.companionProfile.appearance, height: 150)
                    .padding(.trailing, Sticker.shadowOffset)
                Text("Name").typo(.heading, size: 19)
                StickerField(placeholder: "Bolt", text: $model.companionProfile.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                AppearancePicker(appearance: $model.companionProfile.appearance, compact: true)
            }
        } footer: {
            BigButton("Continue", fill: .coral, action: next)
        }
    }
}

struct ContactStep: View {
    var next: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        StepScaffold(title: "Someone to call", subtitle: "If you ever fall and need help, \(model.companionProfile.displayName) can offer to call this person. Only you see this. It stays on this phone.") {
            ContactFields(name: $name, phone: $phone)
        } footer: {
            BigButton("Continue", fill: .coral) { save(); next() }
                .disabled(CompanionProfile.sanitizedPhone(phone).isEmpty)
                .opacity(CompanionProfile.sanitizedPhone(phone).isEmpty ? 0.4 : 1)
            Button("Skip for now") { next() }
                .typo(.label, size: 18).foregroundStyle(Color.ink).underline()
                .frame(minHeight: 44)
        }
        .onAppear {
            name = model.companionProfile.contactName ?? ""
            phone = model.companionProfile.contactPhone ?? ""
        }
    }

    private func save() {
        let p = CompanionProfile.sanitizedPhone(phone)
        guard !p.isEmpty else { return }
        model.companionProfile.contactPhone = p
        model.companionProfile.contactName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
