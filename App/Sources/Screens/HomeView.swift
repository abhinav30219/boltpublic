import SwiftUI
import BoltCore

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var driver = CompanionDriver(tuning: Tuning())
    @EnvironmentObject var speech: SpeechService
    @State private var showSettings = false
    @State private var showSource = false
    @State private var detail: HomeMetric?
    /// Called when the floating Talk button is tapped; the tab view switches to Chat and starts dictation.
    var onTalk: () -> Void = {}

    private var companionName: String { model.companionProfile.displayName }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    greeting
                    CompanionView(driver: driver)
                    CompanionBubble(text: bubbleText, onReadAloud: { speech.speak(bubbleText) })
                    if model.source == .none {
                        BigButton("Choose a data source", fill: .coral) { showSource = true }
                    }
                    section("Right now")
                    activityCard
                    MetricGrid {
                        ForEach(HomeMetric.allCases) { m in
                            let v = model.homeValue(m)
                            Button { detail = m } label: {
                                MetricCard(icon: m.icon, label: m.label, value: v.value, unit: m.unit,
                                           meaning: v.meaning, fill: m.fill,
                                           sparkline: m == .heart ? model.snapshot.hrSeries
                                                : m == .skinTemp ? model.snapshot.tempSeries : nil)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Shows the chart")
                        }
                    }
                    GoalBar(steps: model.snapshot.steps, goal: model.tuning.companion.dailyStepGoal)
                        .padding(.trailing, Sticker.shadowOffset)
                    section("Your day")
                    dayTimeline.padding(.trailing, Sticker.shadowOffset)
                    section("\(companionName) noticed")
                    notes
                    Button("Change data source") { showSource = true }
                        .typo(.label, size: 16).foregroundStyle(Color.ink).underline()
                        .frame(minHeight: 44)
                }
                .padding(16)
            }
            .background(ThemeBackground())
            .safeAreaInset(edge: .bottom) {
                if model.companionProfile.showTalkButton {
                    TalkButton(name: companionName, action: onTalk)
                        .padding(.leading, 16).padding(.trailing, 16 + Sticker.shadowOffset).padding(.vertical, 8)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SheetStack { SettingsView() } }
            .sheet(isPresented: $showSource) { SheetStack { SourcePicker() } }
            .sheet(item: $detail) { MetricDetailSheet(metric: $0).environmentObject(model) }
        }
.scrollDismissesKeyboard(.interactively)
        .onAppear {
            #if DEBUG
            NSLog("[home] onAppear, attaching")
            #endif
            #if DEBUG
            if CommandLine.arguments.contains("-openHeartDetail") { detail = .heart }
            #endif
            driver.tuning = model.tuning
            driver.appearance = model.companionProfile.appearance
            driver.state = model.companion
            driver.twin = model.robotTwin
            driver.isGenerating = model.isGenerating
            driver.attach(events: model.companionEvents) // replaces any earlier subscription
        }
        .onChange(of: model.tuning) { _, t in driver.tuning = t }
        .onChange(of: model.companionProfile.appearance) { _, a in driver.appearance = a }
        .onChange(of: model.companion) { _, s in driver.state = s }
        .onChange(of: model.robotTwin) { _, t in driver.twin = t }
        .onChange(of: model.isGenerating) { _, g in driver.isGenerating = g }
        .onChange(of: driver.loadIssue) { _, issue in
            if let issue { model.log(.warning, "Companion renderer", issue) }
        }
        .dismissesOnFallAlert { showSettings = false; showSource = false; detail = nil }
    }

    // MARK: Pieces

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    wordmark
                    Spacer(minLength: 8)
                    bandButton
                    settingsButton
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        wordmark
                        Spacer(minLength: 8)
                        settingsButton
                    }
                    bandButton
                }
            }
            Text("\(greetingWord), \(friendName)")
                .typo(.heading, size: 22).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .typo(.body).foregroundStyle(Color.inkSoft)
            RobotChip(robot: model.robot)
        }
    }

    private var wordmark: some View {
        BoltWordmark(text: companionName, size: 34)
    }

    // Tapping the band chip opens the data source picker (connect the band, demo, replay).
    private var bandButton: some View {
        Button { showSource = true } label: {
            BandChip(band: model.band, source: model.source, hasData: model.snapshot.hasData,
                     hasPulse: model.snapshot.hr != nil)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Choose or connect your band")
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.ink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    private var friendName: String {
        let n = model.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "friend" : n
    }

    private var greetingWord: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private var bubbleText: String {
        let latest = model.cards.last { $0.source != .safety && !$0.isStreaming && !$0.text.isEmpty }
        return latest?.text ?? "Hi, I'm \(companionName). I'm right here with you."
    }

    /// Full-width Activity card: MetricCard fills the row, so it just needs the sticker shadow gutter.
    private var activityCard: some View {
        let s = model.snapshot
        let a = s.activity
        let walkingCadence = s.walkingCadence.map { Int($0.rounded()) }
        let meaningText = a == nil ? "Waiting" : walkingCadence.map { "\($0) steps/min avg" } ?? "Right now"
        return MetricCard(icon: a?.symbol ?? "figure.stand", label: "Activity", value: a?.label ?? "—", unit: nil,
                          meaning: Meaning(word: meaningText), fill: .fillActivity,
                          sparkline: s.motionSeries,
                          spokenMeaning: walkingCadence.map { "averaging \($0) steps per minute walking today" })
            .padding(.trailing, Sticker.shadowOffset)
    }

    private func section(_ title: String) -> some View {
        Text(title).typo(.heading, size: 24).foregroundStyle(Color.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var dayTimeline: some View {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        return DayTimeline(segments: model.store.activityTimeline(seconds: now.timeIntervalSince(start), now: now),
                           dayStart: start, now: now)
    }

    @ViewBuilder private var notes: some View {
        let shown = Array(model.cards.reversed().prefix(10))
        if shown.isEmpty {
            Text("Nothing yet. \(companionName) will leave notes here as your day goes on.")
                .typo(.body).foregroundStyle(Color.inkSoft)
        } else {
            VStack(spacing: 12) {
                ForEach(shown) { NoteRow(card: $0) }
            }
            .padding(.trailing, Sticker.shadowOffset)
        }
    }
}

/// The robot's link state next to the band chip on Home: a "Connect robot" button until it is
/// connected (tap again to stop looking), then a plain connected chip.
private struct RobotChip: View {
    @ObservedObject var robot: RobotLink

    var body: some View {
        switch robot.status {
        case .ready:
            StatusChip(text: "Robot connected", ok: true)
        case .poweredOff, .unauthorized:
            StatusChip(text: robot.status.label, ok: false)
        case .scanning:
            chipButton("Looking for robot…", busy: true) { robot.stopScan() }
                .accessibilityHint("Stops looking")
        case .connecting, .discovering:
            chipButton("Connecting robot…", busy: true) {}
                .disabled(true)
        case .idle, .away:
            chipButton("Connect robot", busy: false) { robot.startScan(autoConnect: true) }
        }
    }

    private func chipButton(_ text: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini).tint(Color.ink) }
                else { Image(systemName: "pawprint.fill").accessibilityHidden(true) }
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .typo(.label, size: 14)
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(minHeight: 28)
            .background(Color.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.line, lineWidth: Sticker.smallBorder))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }
}

/// Home's band chip. For the band it follows the real Bluetooth connection and needs a valid
/// pulse to say "live"; demo and replay sources keep the simple live/waiting wording.
private struct BandChip: View {
    @ObservedObject var band: HeartRateBand
    let source: DataSource
    let hasData: Bool
    let hasPulse: Bool

    var body: some View {
        let (text, ok) = state
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.alertInk).frame(width: 10, height: 10)
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

    private var state: (String, Bool) {
        switch source {
        case .none: return ("no band", false)
        case .band:
            switch band.status {
            case .streaming: return hasPulse ? ("band connected", true) : ("no pulse", false)
            case .scanning, .connecting, .discovering: return ("connecting…", false)
            case .poweredOff: return ("Bluetooth off", false)
            case .unauthorized: return ("Bluetooth needed", false)
            case .idle, .disconnected: return ("band disconnected", false)
            }
        default: return hasData ? ("demo · live", true) : ("demo · waiting", false)
        }
    }
}
