import SwiftUI

@main
struct BoltApp: App {
    @StateObject private var model: AppModel
    @StateObject private var speech: SpeechService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel(), speech = SpeechService()
        model.speech = speech   // the fall script speaks through the phone when no robot is connected
        speech.onLog = { [weak model] title, detail in model?.log(.chat, title, detail) }
        #if DEBUG
        // -theme stickerBook|candyPop|cozyNight (screenshot hook)
        if let raw = UserDefaults.standard.string(forKey: "theme"), let t = AppTheme(rawValue: raw) {
            model.companionProfile.theme = t
        }
        #endif
        _model = StateObject(wrappedValue: model)
        _speech = StateObject(wrappedValue: speech)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if CommandLine.arguments.contains("-companionLab") {
                    NavigationStack { AnimationLabView() }
                } else if CommandLine.arguments.contains("-logoOptions") {
                    LogoOptionsView()
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
                .dismissKeyboardOnOutsideTap()
                .keyboardDoneButton()
                .environmentObject(model)
                .environmentObject(speech)
                .id(model.companionProfile.theme)   // rebuild so every screen re-reads the theme tokens
                .tint(Color.accent)
                .preferredColorScheme(model.companionProfile.theme.colorScheme)
                .fullScreenCover(isPresented: Binding(get: { model.fallAlert != nil }, set: { _ in })) {
                    FallCheckView().environmentObject(model).environmentObject(speech)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.appBecameActive() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Group {
            if model.onboardingDone {
                MainTabView()
                    .transition(.opacity)
                    .onAppear { model.requestNotificationPermission() }
            } else {
                OnboardingFlow()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.onboardingDone)
        #if DEBUG
        .task {
            // Screenshot/verification hooks: -fallAtLaunch, -fallDemoAtLaunch, -fallHelpAfter <s>, -fallOKAfter <s>, -fallAgainAfter <s>
            let d = UserDefaults.standard
            // -robotCmds "kwkF 3;krest;kup": sends each to the robot link (no robot needed), 4 s apart.
            if let list = d.string(forKey: "robotCmds") {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    for raw in list.split(separator: ";") {
                        let c = raw.trimmingCharacters(in: .whitespaces)
                        if !c.isEmpty { model.robot.send(.text(c)) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                }
            }
            // -robotMoves "walkForward;wave;doubleTap;walkBack;rest;stand": performs each move key through the link, 4 s apart.
            if let list = d.string(forKey: "robotMoves") {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    for raw in list.split(separator: ";") {
                        let k = raw.trimmingCharacters(in: .whitespaces)
                        if !k.isEmpty { model.robot.perform(k) }
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                    }
                }
            }
            if CommandLine.arguments.contains("-demoAtLaunch") { model.startDemo(speed: max(d.double(forKey: "demoSpeed"), 1)) }
            if d.double(forKey: "milestoneAfter") > 0 {
                try? await Task.sleep(nanoseconds: UInt64(d.double(forKey: "milestoneAfter") * 1e9)); model.companionEvents.send(.stepMilestone)
            }
            if CommandLine.arguments.contains("-fallDemoAtLaunch") { model.startFallDemo() }
            if CommandLine.arguments.contains("-waveAtLaunch") { model.simulateGesture(.wave) }
            if CommandLine.arguments.contains("-fallAtLaunch") { model.simulateFall() }
            if d.double(forKey: "waveAfter") > 0 {
                try? await Task.sleep(nanoseconds: UInt64(d.double(forKey: "waveAfter") * 1e9)); model.simulateGesture(.wave)
            }
            if d.double(forKey: "fallHelpAfter") > 0 {
                try? await Task.sleep(nanoseconds: UInt64(d.double(forKey: "fallHelpAfter") * 1e9)); model.fallRequestHelp()
            }
            if d.double(forKey: "fallAgainAfter") > 0 {
                try? await Task.sleep(nanoseconds: UInt64(d.double(forKey: "fallAgainAfter") * 1e9)); model.simulateFall()
            }
            if d.double(forKey: "fallOKAfter") > 0 {
                try? await Task.sleep(nanoseconds: UInt64(d.double(forKey: "fallOKAfter") * 1e9)); model.fallRespondOK()
            }
        }
        #endif
    }
}
