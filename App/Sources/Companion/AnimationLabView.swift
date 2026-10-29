import BoltCore
import SwiftUI

/// Try every companion animation on the phone: robot moves, idle fidgets, moods, celebrations, the fall
/// script (preview only) and render settings. Reached from More, and with the `-companionLab` launch argument
/// in DEBUG builds, which can preset the controls: `-lab.motion trot -lab.mood determined -lab.cadence 160
/// -lab.blush 1 -lab.overlays steam -lab.palette mint -lab.playAfter 2 -lab.play flip`.
struct AnimationLabView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var speech: SpeechService
    @StateObject private var driver = CompanionDriver(tuning: Tuning())

    private enum Mode: String, CaseIterable { case robot = "Robot moves", manual = "Manual" }

    @State private var mode: Mode = .robot
    @State private var twin = RobotTwin()
    @State private var sendToRobot = false
    @State private var lastMove = "Standing"
    @State private var motion: CompanionMotion = .idle
    @State private var mood: CompanionMood = .neutral
    @State private var cadence = 100.0
    @State private var blush = 0.0
    @State private var overlays: Set<CompanionOverlay> = []
    @State private var fallStage: FallStage?
    @State private var fallLine = ""
    @State private var viewToken = 0
    @AppStorage(CompanionRendererKind.defaultsKey) private var renderer = CompanionRendererKind.sceneKit

    private static let motions: [(String, CompanionMotion)] = [("Idle", .idle), ("Walk", .walk), ("Trot", .trot), ("Sleep", .sleep)]
    private static let moods: [(String, CompanionMood)] = [
        ("Neutral", .neutral), ("Happy", .happy), ("Calm", .calm), ("Tired", .tired), ("Concerned", .concerned),
        ("Determined", .determined), ("Relieved", .relieved), ("Scanning", .scanning), ("Sleeping", .sleeping)]
    private static let idles: [(String, PoseSolver.IdleFidget)] = [
        ("Paw lift", .pawLift), ("Back shuffle", .shuffle), ("Settle", .settle),
        ("Head tilt", .headTilt), ("Look around", .look), ("Sway", .sway)]
    private static let falls: [(String, FallStage)] = [
        ("Asking", .asking), ("Re-ask", .reasked), ("Alarm", .alarm), ("Resolved OK", .resolvedOK)]
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            // Bolt stays pinned on top; only the controls scroll, so every animation stays in view.
            VStack(spacing: 4) {
                CompanionView(driver: driver, height: 240).id(viewToken)
                if let issue = driver.loadIssue { Text(issue).typo(.label).foregroundStyle(Color.alertInk) }
            }
            .padding(.horizontal, 16).padding(.top, 4)
            .background(ThemeBackground())
            Rectangle().fill(Color.ink.opacity(0.15)).frame(height: 1)
            ScrollView {
            VStack(spacing: 18) {
                modeSection
                if mode == .robot { robotSection } else { manualSection }
                idleSection
                moodSection
                celebrateSection
                fallSection
                renderSection
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24)
            .padding(.trailing, Sticker.shadowOffset)
            }
        }
        .background(ThemeBackground())
        .navigationTitle("Animation lab")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: preset)
        .onChange(of: mode) { _, _ in applyMode() }
        .onChange(of: motion) { _, _ in push() }
        .onChange(of: mood) { _, _ in push() }
        .onChange(of: cadence) { _, _ in push() }
        .onChange(of: blush) { _, _ in push() }
        .onChange(of: overlays) { _, _ in push() }
    }

    // MARK: sections

    private func section<C: View>(_ title: String, fill: Color = .card, @ViewBuilder _ content: () -> C) -> some View {
        StickerCard(fill: fill) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).typo(.heading, size: 21)
                content()
            }
        }
    }

    private func chip(_ title: String, fill: Color = .fillOxygen, id: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).typo(.label, size: 16).multilineTextAlignment(.center)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: Sticker.minButtonHeight)
                .sticker(fill: fill, radius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id ?? "lab.\(title)")
    }

    private var modeSection: some View {
        section("Mode", fill: .fillEnergy) {
            Picker("Mode", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
            Text(mode == .robot ? "Bolt follows the robot moves below: \(lastMove)."
                                : "Bolt is posed by hand with the motion picker.")
                .typo(.label, size: 15).foregroundStyle(Color.inkSoft)
        }
    }

    private var robotSection: some View {
        section("Robot moves", fill: .fillSteps) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.robot.moves.moves) { move in
                    chip(move.title, id: "lab.move.\(move.id)") { play(move) }
                }
                chip("Stop", fill: .fillHeart, id: "lab.move.stop") { stop() }
            }
            Toggle("Send to robot too", isOn: $sendToRobot).typo(.body, size: 17).frame(minHeight: 44)
            Text(model.robot.status.label).typo(.label, size: 15).foregroundStyle(Color.inkSoft)
                .accessibilityIdentifier("lab.robotStatus")
        }
    }

    private var manualSection: some View {
        section("Manual motion", fill: .fillSteps) {
            Picker("Motion", selection: $motion) { ForEach(Self.motions, id: \.0) { Text($0.0).tag($0.1) } }
                .pickerStyle(.segmented)
            HStack { Text("Cadence \(Int(cadence))").typo(.body, size: 16); Slider(value: $cadence, in: 60...200) }
        }
    }

    private var idleSection: some View {
        section("Idle", fill: .fillRelax) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Self.idles, id: \.0) { item in chip(item.0, fill: .card) { fidget(item.1) } }
            }
            Text("Idle plays these on its own every few seconds.").typo(.label, size: 15).foregroundStyle(Color.inkSoft)
        }
    }

    private var moodSection: some View {
        section("Mood and face", fill: .fillTemp) {
            Picker("Mood", selection: $mood) { ForEach(Self.moods, id: \.0) { Text($0.0).tag($0.1) } }
                .frame(minHeight: 44)
            HStack { Text(String(format: "Blush %.1f", blush)).typo(.body, size: 16); Slider(value: $blush, in: 0...1) }
            Picker("Palette", selection: $driver.appearance.palette) { ForEach(BodyPalette.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            Picker("Face", selection: $driver.appearance.face) { ForEach(FaceStyle.allCases, id: \.self) { Text($0.title).tag($0) } }
                .frame(minHeight: 44)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(CompanionOverlay.allCases, id: \.self) { o in
                    let on = overlays.contains(o)
                    chip(o.rawValue.capitalized, fill: on ? .fillEnergy : .card) {
                        if on { overlays.remove(o) } else { overlays.insert(o) }
                    }
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .typo(.body)
    }

    private var celebrateSection: some View {
        section("Celebrations", fill: .fillActivity) {
            LazyVGrid(columns: columns, spacing: 10) {
                chip("Celebrate hop", fill: .card) { driver.celebrate() }
                chip("Wave", fill: .card) { oneShot(.wave) }
                chip("Flip", fill: .card) { oneShot(.flip) }
            }
        }
    }

    private var fallSection: some View {
        section("Fall preview", fill: .fillHeart) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Self.falls, id: \.0) { item in
                    chip(item.0, fill: fallStage == item.1 ? .fillEnergy : .card, id: "lab.fall.\(item.0)") { previewFall(item.1) }
                }
            }
            if fallStage != nil {
                Text(fallLine).typo(.body, size: 17).accessibilityIdentifier("lab.fallLine")
                chip("Speak line", fill: .fillOxygen) { speakFall() }
            }
            Text("Preview only: no fall alert, notification or memory is created.").typo(.label, size: 15).foregroundStyle(Color.inkSoft)
        }
    }

    private var renderSection: some View {
        section("Render", fill: .fillOxygen) {
            Text(String(format: "%.0f fps  %.2f ms/frame", driver.fps, driver.lastFrameMs))
                .typo(.label, size: 16).accessibilityIdentifier("lab.stats")
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text("frames \(driver.frameCount)").typo(.label, size: 16).foregroundStyle(Color.inkSoft)
            }
            Toggle("Generating (20 fps)", isOn: $driver.isGenerating).typo(.body, size: 17).frame(minHeight: 44)
            Toggle("Reduce animation", isOn: Binding(get: { driver.tuning.render.reduceAnimation },
                                                     set: { driver.tuning.render.reduceAnimation = $0 }))
                .typo(.body, size: 17).frame(minHeight: 44)
            Picker("Renderer", selection: $renderer) { ForEach(CompanionRendererKind.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
            chip("Reset view", fill: .card) { viewToken += 1 }
        }
    }

    // MARK: actions

    private func applyMode() {
        driver.followsTwin = mode == .robot
        if mode == .robot { driver.twin = twin }
        push()
    }

    private func apply(_ cmd: RobotMotionCommand) {
        twin.apply(cmd, at: Date(), tuning: driver.tuning.companion)
        driver.twin = twin
    }

    private func play(_ move: RobotMove) {
        lastMove = move.title
        if let cmd = RobotMotionCommand.resolve(move.robotCommand, moves: model.robot.moves) { apply(cmd) }
        if sendToRobot && model.robot.isReady { model.robot.perform(move) }
    }

    private func stop() {
        lastMove = "Stopped"
        apply(.stand)
        if sendToRobot && model.robot.isReady { model.robot.send(.text(model.robot.moves.stop)) }
    }

    private func oneShot(_ shot: PoseSolver.OneShot) {
        if mode == .robot { apply(shot == .wave ? .wave : .flip) } else { driver.play(shot) }
    }

    private func fidget(_ kind: PoseSolver.IdleFidget) {
        // Idle fidgets only show while standing, so stand first.
        if mode == .robot { apply(.stand) } else if motion != .idle { motion = .idle; push() }
        driver.forceIdle(kind)
    }

    private func previewFall(_ stage: FallStage) {
        fallStage = stage
        fallLine = FallScript().line(for: stage, name: model.profile.name)
        mood = stage == .resolvedOK ? .relieved : .concerned
    }

    private func speakFall() {
        guard !fallLine.isEmpty else { return }
        speech.speak(fallLine)
        if sendToRobot, let cmd = RobotCommand.say(fallLine), model.robot.canDeliver(cmd) { model.robot.send(cmd) }
    }

    private func push() {
        var s = CompanionState()
        s.motion = motion; s.mood = mood; s.cadence = cadence; s.blush = blush; s.overlays = overlays
        driver.state = s
    }

    private func preset() {
        driver.tuning = model.tuning
        let d = UserDefaults.standard
        if d.string(forKey: "lab.motion") != nil { mode = .manual }
        applyMode()
        if let m = d.string(forKey: "lab.motion"), let v = Self.motions.first(where: { $0.0.lowercased() == m }) { motion = v.1 }
        if let m = d.string(forKey: "lab.mood"), let v = Self.moods.first(where: { $0.0.lowercased() == m }) { mood = v.1 }
        if d.object(forKey: "lab.cadence") != nil { cadence = d.double(forKey: "lab.cadence") }
        if d.object(forKey: "lab.blush") != nil { blush = d.double(forKey: "lab.blush") }
        if let o = d.string(forKey: "lab.overlays") { overlays = Set(o.split(separator: ",").compactMap { CompanionOverlay(rawValue: String($0)) }) }
        if let p = d.string(forKey: "lab.palette"), let v = BodyPalette(rawValue: p) { driver.appearance.palette = v }
        if let f = d.string(forKey: "lab.face"), let v = FaceStyle(rawValue: f) { driver.appearance.face = v }
        push()
        #if DEBUG
        if d.object(forKey: "lab.pauseAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + d.double(forKey: "lab.pauseAfter")) { driver.isVisible = false }
        }
        if d.object(forKey: "lab.celebrateSeconds") != nil { driver.tuning.companion.celebrationSeconds = d.double(forKey: "lab.celebrateSeconds") }
        if d.object(forKey: "lab.celebrateAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + d.double(forKey: "lab.celebrateAfter")) { driver.celebrate() }
        }
        // `-lab.flipSeconds 6` slows the flip so a screenshot can catch it mid-air.
        if d.object(forKey: "lab.flipSeconds") != nil { driver.tuning.companion.robotFlipSeconds = d.double(forKey: "lab.flipSeconds") }
        if d.object(forKey: "lab.waveSeconds") != nil { driver.tuning.companion.robotWaveSeconds = d.double(forKey: "lab.waveSeconds") }
        if d.object(forKey: "lab.playAfter") != nil {
            let shot: PoseSolver.OneShot = d.string(forKey: "lab.play") == "flip" ? .flip : .wave
            DispatchQueue.main.asyncAfter(deadline: .now() + d.double(forKey: "lab.playAfter")) { oneShot(shot) }
        }
        if d.bool(forKey: "lab.reduce") { driver.tuning.render.reduceAnimation = true }
        if d.object(forKey: "lab.resumeAfter") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + d.double(forKey: "lab.resumeAfter")) { driver.isVisible = true }
        }
        #endif
    }
}
