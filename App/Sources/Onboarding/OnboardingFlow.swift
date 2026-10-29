import SwiftUI
import BoltCore

struct OnboardingFlow: View {
    enum Step: Int, CaseIterable { case welcome, privacy, profile, companion, contact, model, band }
    @EnvironmentObject var model: AppModel
    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome {
                ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                    .tint(Color.accent)
                    .padding(.horizontal, 24).padding(.top, 12)
                    .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            }
            Group {
                switch step {
                case .welcome: WelcomeStep { go(.privacy) }
                case .privacy: PrivacyStep { go(.profile) }
                case .profile: ProfileStep { go(.companion) }
                case .companion: MeetCompanionStep { go(.contact) }
                case .contact: ContactStep { go(.model) }
                case .model: ModelStep { go(.band) }
                // No calibration step: a provisional baseline forms from the first 30 s of band data and
                // keeps adapting, and a saved baseline is reused on every later launch.
                case .band: BandStep { model.onboardingDone = true }
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .foregroundStyle(Color.ink)
        .background(ThemeBackground())
    }

    private func go(_ s: Step) { withAnimation(.easeInOut(duration: 0.3)) { step = s } }
}

/// Title, subtitle, scrolling content and a pinned footer. Shared by every onboarding step.
struct StepScaffold<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).typo(.heading, size: 32).accessibilityAddTraits(.isHeader)
                        Text(subtitle).typo(.body, size: 18).foregroundStyle(Color.inkSoft)
                    }
                    content
                }
                .padding(24)
                .padding(.trailing, Sticker.shadowOffset)
            }
.scrollDismissesKeyboard(.interactively)
.keyboardDoneButton()
            VStack(spacing: 10) { footer }
                .padding(.horizontal, 24).padding(.vertical, 16)
                .padding(.trailing, Sticker.shadowOffset)
        }
    }
}

// MARK: steps

private struct WelcomeStep: View {
    var next: () -> Void
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            CompanionPreview(appearance: model.companionProfile.appearance, height: 260, celebrateOnAppear: true)
            VStack(spacing: 10) {
                Text("Bolt").typo(.heading, size: 44)
                Text("Your private health companion.\nYour body, explained as it happens, all on your phone.")
                    .typo(.body, size: 20).multilineTextAlignment(.center).foregroundStyle(Color.inkSoft)
            }
            .padding(.horizontal, 24)
            Spacer()
            BigButton("Get started", fill: .coral, action: next)
                .padding(.horizontal, 24).padding(.bottom, 24).padding(.trailing, Sticker.shadowOffset)
        }
    }
}

private struct PrivacyStep: View {
    var next: () -> Void
    var body: some View {
        StepScaffold(title: "Private by design", subtitle: "Your health data never leaves your wrist and your pocket.") {
            VStack(alignment: .leading, spacing: 14) {
                row("applewatch.radiowaves.left.and.right", "Band to phone", "Heart rate, SpO2, motion and skin temperature stream over Bluetooth.", .fillHeart)
                row("cpu", "Gemma 4 on your iPhone", "Google's open model runs through LiteRT-LM on the phone's GPU. No cloud.", .fillRelax)
                row("figure.walk", "Our activity model, on-device", "A LiteRT activity model reads your motion every few seconds.", .fillSteps)
                row("airplane", "Works in airplane mode", "Turn the network off. Everything keeps working.", .fillOxygen)
            }
        } footer: {
            BigButton("Continue", fill: .coral, action: next)
        }
    }
    private func row(_ icon: String, _ title: String, _ text: String, _ fill: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 22, weight: .bold)).frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).typo(.heading, size: 20)
                Text(text).typo(.body, size: 17)
            }
        }
        .stickerPanel(fill: fill)
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileStep: View {
    var next: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var age = ""
    var body: some View {
        StepScaffold(title: "About you", subtitle: "Bolt uses this to word insights for you. It stays on this phone.") {
            VStack(alignment: .leading, spacing: 16) {
                StickerField(placeholder: "Your first name", text: $model.profile.name)
                    .textContentType(.givenName)
                StickerField(placeholder: "Age (optional)", text: $age)
                    .keyboardType(.numberPad)
                    .onChange(of: age) { _, v in model.profile.age = Int(v) }
                Text("What matters to you?").typo(.heading, size: 22).padding(.top, 4)
                FlowChips(options: UserProfile.goalOptions, selected: $model.profile.goals)
            }
        } footer: {
            BigButton("Continue", fill: .coral, action: next)
        }
        .onAppear { age = model.profile.age.map(String.init) ?? "" }
    }
}

private struct FlowChips: View {
    let options: [String]
    @Binding var selected: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(options, id: \.self) { o in
                let on = selected.contains(o)
                Button {
                    if on { selected.removeAll { $0 == o } } else { selected.append(o) }
                } label: {
                    HStack {
                        Text(o).typo(.body, size: 18).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 24, weight: .bold))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: Sticker.minButtonHeight, alignment: .leading)
                    .sticker(fill: on ? .fillSteps : .card, radius: 20)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

private struct ModelStep: View {
    var next: () -> Void
    @EnvironmentObject var model: AppModel
    var body: some View {
        StepScaffold(title: "Load Gemma", subtitle: "Gemma 4 runs on this iPhone. The first load takes a little longer while it prepares the GPU.") {
            VStack(alignment: .leading, spacing: 14) {
                if model.models.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("No model on this phone yet", systemImage: "externaldrive.badge.questionmark").typo(.heading, size: 20)
                        Text("On your Mac: connect this iPhone, open Finder, select the iPhone, choose Files, open Bolt and drag in gemma-4-E2B-it-gpu.litertlm. Then tap Refresh.")
                            .typo(.body, size: 16).foregroundStyle(Color.inkSoft)
                        BigButton("Refresh", fill: .fillSteps) { model.refreshModels() }
                    }
                    .stickerPanel()
                } else {
                    ForEach(model.models) { m in
                        Button { model.selectedModel = m } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.displayName).typo(.heading, size: 20)
                                    Text("\(m.name) · \(String(format: "%.1f", m.sizeGB)) GB").typo(.body, size: 14).foregroundStyle(Color.inkSoft)
                                }
                                Spacer()
                                Image(systemName: model.selectedModel == m ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.coral)
                            }
                            .stickerPanel(fill: model.selectedModel == m ? .fillSteps : .card)
                        }
                    }
                }
                status
            }
        } footer: {
            switch model.engineState {
            case .ready:
                BigButton("Continue", fill: .coral, action: next)
            case .loading:
                HStack(spacing: 10) { ProgressView().tint(.ink); Text("Loading…").typo(.heading, size: 22) }
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, minHeight: Sticker.minButtonHeight)
                    .sticker(fill: .fillSteps, radius: 32)
                    .padding(.trailing, Sticker.shadowOffset)
            default:
                BigButton("Load model", fill: model.selectedModel != nil ? .coral : .fillSteps) { Task { await model.loadModel() } }
                    .disabled(model.selectedModel == nil)
                Button("Skip for now", action: next).typo(.label, size: 18).foregroundStyle(Color.ink).underline().frame(minHeight: 44)
            }
        }
        .onAppear { model.refreshModels() }
    }

    @ViewBuilder private var status: some View {
        switch model.engineState {
        case .ready:
            VStack(alignment: .leading, spacing: 4) {
                Label("Gemma is ready on \(model.engineStats.backend)", systemImage: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x1E7A55)).typo(.label, size: 18)
                if let s = model.engineStats.loadSeconds { Text(String(format: "Loaded in %.1f s", s)).typo(.body, size: 14).foregroundStyle(Color.inkSoft) }
                if let t = model.engineStats.lastTokensPerSecond { Text(String(format: "%.0f tokens per second", t)).typo(.body, size: 14).foregroundStyle(Color.inkSoft) }
            }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(Color.alertInk).typo(.body, size: 16)
        default: EmptyView()
        }
    }
}

private struct BandStep: View {
    var next: () -> Void
    @EnvironmentObject var model: AppModel
    var body: some View {
        StepScaffold(title: "Connect your band", subtitle: "Wear your band snugly, then tap Scan.") {
            BandConnectView(band: model.band) {
                model.useBand()
                next()
            }
            .stickerPanel()
        } footer: {
            BigButton("Use the demo session instead", fill: .fillSteps) {
                model.startDemo()
                next()
            }
        }
    }
}
