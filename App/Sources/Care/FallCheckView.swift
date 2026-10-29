import SwiftUI
import BoltCore

/// Full-screen "Are you okay?" flow. Reflects `AppModel.fallAlert`; AppModel owns the escalation timer.
/// All text here is code-written (never Gemma).
struct FallCheckView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var speech: SpeechService
    @State private var chime = Chime()

    private var companionName: String { model.companionProfile.displayName }

    private static var concernedState: CompanionState {
        var s = CompanionState()
        s.motion = .idle; s.mood = .concerned; s.overlays = []; s.bandWorn = true
        return s
    }

    var body: some View {
        ZStack {
            ThemeBackground()
            switch model.fallAlert {
            case .asking(let since): asking(since: since)
            case .escalated: escalated
            case nil: Color.clear
            }
        }
        // The chime pauses while the phone is speaking a line (the chime would talk over it), then resumes.
        .onChange(of: isEscalated && !speech.speaking, initial: true) { _, on in
            if on { chime.start() } else { chime.stop() }
        }
        // The words are spoken by AppModel's fall script (robot or phone), not here.
        .onDisappear { chime.stop() }
    }

    private var isAsking: Bool {
        if case .asking = model.fallAlert { return true }
        return false
    }

    private var isEscalated: Bool {
        if case .escalated = model.fallAlert { return true }
        return false
    }

    private func asking(since: Date) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                companionView
                Text("Are you okay?").typo(.heading, size: 32).multilineTextAlignment(.center)
                Text(model.fallLine)
                    .typo(.body, size: 19).multilineTextAlignment(.center)
                BigButton("I'm okay", fill: .fillSteps) { model.fallRespondOK() }
                BigButton("I need help", fill: .coral) { model.fallRequestHelp() }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(ceil(model.tuning.fall.responseTimeoutSeconds - ctx.date.timeIntervalSince(since))))
                    Text("\(companionName) will call for help in \(left / 60):\(String(format: "%02d", left % 60))")
                        .typo(.label, size: 16).monospacedDigit()
                }
            }
            .padding(24)
        }
    }

    private var escalated: some View {
        ScrollView {
            VStack(spacing: 20) {
                companionView
                Text("Let's get you help").typo(.heading, size: 32).multilineTextAlignment(.center)
                Text(model.fallLine).typo(.body, size: 19).multilineTextAlignment(.center)
                if let contact = model.companionProfile.contact {
                    BigButton("Call \(contact.name)", fill: .fillSteps) { call(contact.phone) }
                }
                BigButton("Call emergency services", fill: .coral) { call(model.tuning.fall.emergencyNumber) }
                BigButton("I'm okay now", fill: .fillSteps) { model.fallRespondOK() }
            }
            .padding(24)
        }
    }

    private var companionView: some View {
        CompanionPreview(appearance: model.companionProfile.appearance, state: Self.concernedState, height: 160)
    }

    private func call(_ number: String) {
        let digits = CompanionProfile.sanitizedPhone(number)
        guard !digits.isEmpty, let url = URL(string: "tel://\(digits)") else { return }
        UIApplication.shared.open(url)
    }
}
