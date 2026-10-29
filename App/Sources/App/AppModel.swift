import Foundation
import SwiftUI
import Network
import Combine
import UserNotifications
import BoltCore

struct LiveSnapshot: Equatable {
    var hr: Double?
    var spo2: Double?
    var skinTemp: Double?
    var activity: ActivityClass?
    var worn = false
    var hasData = false
    var baselineHR: Double?
    var baselineTemp: Double?
    var calibration: Double = 0
    var hrSeries: [ScalarPoint] = []
    var spo2Series: [ScalarPoint] = []
    var tempSeries: [ScalarPoint] = []
    var motionSeries: [ScalarPoint] = []
    // Companion
    var steps = 0
    var kcal = 0.0
    var cadence = 0.0
    /// Today's average over walking windows only, so it doesn't drop to 0 when you stop.
    var walkingCadence: Double?
    var baselineSkinTemp: Double?
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var at = Date()
    var role: Role
    var text: String
    var toolCalls: [String] = []
    var isStreaming = false
    var firstTokenMs: Double?
    var totalMs: Double?
    var error: String?
    var remembered: [String] = []

    enum CodingKeys: String, CodingKey { case id, at, role, text, toolCalls, isStreaming, firstTokenMs, totalMs, error, remembered }
}

/// Tolerant decoding: a field missing from an older (or newer) saved message takes its default
/// instead of dropping the whole thread. Encoding is unchanged. In an extension so the memberwise init stays.
extension ChatMessage {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .user
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        toolCalls = try c.decodeIfPresent([String].self, forKey: .toolCalls) ?? []
        isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        firstTokenMs = try c.decodeIfPresent(Double.self, forKey: .firstTokenMs)
        totalMs = try c.decodeIfPresent(Double.self, forKey: .totalMs)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        remembered = try c.decodeIfPresent([String].self, forKey: .remembered) ?? []
    }
}

enum DataSource: Equatable {
    case none, band, demo, fallDemo, recording(String)
    var label: String {
        switch self {
        case .none: return "No data source"
        case .band: return "Your band"
        case .demo: return "Demo session (synthetic)"
        case .fallDemo: return "Fall demo (synthetic)"
        case .recording(let n): return "Replay: \(n)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // Persistent user state
    @Published var profile: UserProfile { didSet { saveProfile(); activityEngine.profile = fitnessProfile } }
    @Published var companionProfile: CompanionProfile { didSet { companionProfile.save() } }
    @Published var onboardingDone: Bool {
        didSet {
            UserDefaults.standard.set(onboardingDone, forKey: "onboardingDone")
            if onboardingDone { health.markOnboarded() }
        }
    }
    @AppStorage("settings.speculative") var speculativeDecoding = false
    @AppStorage("settings.cardsEnabled") var cardsEnabled = true
    @AppStorage("settings.preferGPU") var preferGPU = true

    // Live state for the UI
    @Published private(set) var snapshot = LiveSnapshot()
    @Published private(set) var cards: [InsightCard] = []
    @Published private(set) var chat: [ChatMessage] = []
    /// Saved chats, newest first. `chat` is the open one's messages.
    @Published private(set) var threads: [ChatThread] = []
    @Published private(set) var currentThreadID: UUID?
    private let chatStore: ChatStore

    // Fall and gesture detection (generic on-device heuristics; see Safety/FallDetector)
    let fallDetector = FallDetector()
    private let simDetector = FallDetector()
    let gestureDetector = GestureDetector()
    private let simGestureDetector = GestureDetector()
    private var lastInsightMemory: [TriggerKind: Date] = [:]
    @Published private(set) var trace = TraceLog()
    @Published private(set) var source: DataSource = .none
    @Published private(set) var isOffline = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var memoryFacts: [MemoryFact] = []

    // Activity (30 s windows from Core Motion)
    @Published private(set) var fitnessTotals = FitnessTotals()
    @Published private(set) var fitnessLatest: FitnessInterval?
    @Published private(set) var fitnessBouts: [FitnessBout] = []
    /// Newest windows, oldest first, for the strip in Live.
    @Published private(set) var fitnessTimeline: [FitnessInterval] = []
    @Published private(set) var fitnessWindowCount = 0

    // Model
    @Published private(set) var models: [ModelLocator.ModelFile] = []
    @Published private(set) var engineState: GemmaService.State = .idle
    @Published private(set) var engineStats = EngineStats()
    @Published var selectedModel: ModelLocator.ModelFile?

    let band = HeartRateBand()
    /// Phone accelerometer for fall and gesture detection (works with no band).
    let phoneMotion = PhoneMotionSource()
    let gemma = GemmaService()
    let store = MetricsStore()
    let triggers = TriggerEngine()
    let memory: MemoryStore
    /// On-device history: profile, 30 s windows, baselines, cards.
    let health: HealthDB
    private let history: HistoryRecorder
    /// Apple Core Motion activity + pedometer, producing 30 s activity windows.
    let activityEngine = MotionActivityEngine()
    let robot = RobotLink()
    /// Phone read-aloud, set by the app; the fall script uses it when no robot is connected.
    weak var speech: SpeechService?

    private let decoder = NotificationDecoder()
    private var recorder = SessionRecorder()
    private var ticker: Timer?
    private var tickCount = 0
    private var replayTask: Task<Void, Never>?
    private var cardQueue: [InsightEvent] = []
    private var cardWorkerBusy = false
    private let pathMonitor = NWPathMonitor()
    /// Last baseline written to `health`, so it is only rewritten when it moves.
    private var savedBaseline: Baseline?
    private var lastBaselineCheck: Date?

    // MARK: Companion (state)
    enum FallAlert: Equatable { case asking(since: Date), escalated(since: Date) }

    @Published private(set) var tuning = Tuning()
    @Published private(set) var tuningError: String?
    @Published private(set) var companion = CompanionState()
    @Published private(set) var isGenerating = false
    @Published private(set) var fallAlert: FallAlert? {
        didSet { if oldValue == nil, fallAlert != nil { dismissSheetsToken &+= 1 } }
    }
    /// Bumps when a fall alert opens. Every sheet presenter closes on it (`.dismissesOnFallAlert`),
    /// because a sheet open underneath would stop the root fall cover from presenting.
    @Published private(set) var dismissSheetsToken = 0
    /// Where the fall script is and the line for it (fixed text, see `FallScript`); the fall screen shows it.
    @Published private(set) var fallStage: FallStage = .asking
    @Published private(set) var fallLine = ""
    let companionEvents = PassthroughSubject<CompanionEvent, Never>()
    /// The 3D companion's body, mirroring commands sent to the robot (see `RobotLink.dispatched`).
    @Published private(set) var robotTwin = RobotTwin()
    private var robotTwinSink: AnyCancellable?
    private var bandStatusSink: AnyCancellable?

    private let companionEngine = CompanionEngine()
    private var pendingTriggers: [TriggerKind] = []
    private var pendingFallResolved = false
    private var lastLoggedLook: String?
    private static var tuningURL: URL { ModelLocator.documents.appendingPathComponent("tuning.json") }
    // MARK: end Companion (state)

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        memory = MemoryStore(url: support.appendingPathComponent("Bolt/memory.json"))
        var healthError: String?
        do {
            health = try HealthDB(url: support.appendingPathComponent("Bolt/Health/health.sqlite"))
        } catch {
            healthError = "\(error)"
            health = try! HealthDB(url: nil)
        }
        history = HistoryRecorder(db: health)
        LegacyHistory.removeObsoleteFiles(in: support.appendingPathComponent("Bolt", isDirectory: true))   // the old JSON history
        chatStore = ChatStore(directory: support.appendingPathComponent("Bolt/chats", isDirectory: true))
        let saved = health.loadProfile() ?? Self.importLegacyProfile(into: health)
        profile = saved
        companionProfile = CompanionProfile.load()
        onboardingDone = UserDefaults.standard.bool(forKey: "onboardingDone")
        memoryFacts = memory.facts
        cards = health.recentCards(limit: 20).reversed().filter { $0.event.kind != .bandOff }   // older builds saved these
        fitnessTotals = health.totals(on: Date())
        savedBaseline = health.latestBaseline()

        // Heart-rate band (standard Bluetooth HR service): decoded samples arrive as LiveInput.
        band.onInput = { [weak self] input in self?.feed(input) }
        band.onLog = { [weak self] title, detail in self?.log(.band, title, detail) }
        // Phone accelerometer feeds fall and gesture detection, with or without a band.
        phoneMotion.onInput = { [weak self] input in self?.feed(input) }
        // Core Motion activity windows.
        activityEngine.profile = Self.fitnessProfile(for: saved)
        activityEngine.onWindow = { [weak self] interval in self?.onActivityWindow(interval) }
        bandStatusSink = band.$status.removeDuplicates().sink { [weak self] s in
            self?.log(.band, "Band status", s.label)
        }
        robotTwinSink = robot.dispatched.sink { [weak self] command in
            guard let self, let motion = RobotMotionCommand.resolve(command, moves: self.robot.moves) else { return }  // companion-moves
            var twin = self.robotTwin
            twin.apply(motion, at: Date(), tuning: self.tuning.companion)
            self.robotTwin = twin
        }
        robot.onLog = { [weak self] kind, title, detail, ms in self?.log(kind, title, detail, ms: ms) }
        ToolBridge.shared.makeTools = { [weak self] in
            guard let self else { return HealthTools(store: MetricsStore(), memory: MemoryStore(url: nil), cards: []) }
            return HealthTools(store: self.store, memory: self.memory, cards: self.cards, db: self.health,
                               todayTotals: self.fitnessTotals)
        }
        ToolBridge.shared.onCall = { [weak self] name, args, result, ms in self?.recordToolCall(name, args: args, result: result, ms: ms) }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOffline = path.status != .satisfied }
        }
        pathMonitor.start(queue: DispatchQueue(label: "net"))

        loadTuning()
        refreshModels()
        refreshRecordings()
        if let healthError { log(.warning, "History not saved this launch", healthError) }
        log(.activity, "Activity model", MotionActivityEngine.isAvailable ? "Core Motion (CMMotionActivity + CMPedometer)" : "unavailable on this device")
        threads = chatStore.loadAll()
        // Pick up where you left off if the last chat was recent; otherwise start fresh (older chats stay in history).
        if let recent = threads.first, Date().timeIntervalSince(recent.updatedAt) < 12 * 3600 {
            currentThreadID = recent.id
            chat = recent.messages
        }
        #if DEBUG
        // Every movement burst (with its raw samples) goes to Library/Caches/gesture-bursts.jsonl,
        // so real waves can be pulled off the phone and the detector tuned on them. Debug builds
        // only, capped at 2 MB, written off the main thread.
        gestureDetector.onBurst = { b, pts in
            guard let t0 = pts.first?.t else { return }
            let samples = pts.map { [($0.t.timeIntervalSince(t0) * 1000).rounded() / 1000, ($0.x * 1000).rounded() / 1000, ($0.y * 1000).rounded() / 1000, ($0.z * 1000).rounded() / 1000] }
            let row: [String: Any] = ["at": b.at.timeIntervalSince1970, "verdict": b.verdict, "seconds": b.seconds, "cycles": b.cycles,
                                      "hz": b.frequencyHz, "swing_g": b.amplitudeG, "samples": samples]
            guard var line = try? JSONSerialization.data(withJSONObject: row) else { return }
            line.append(0x0A)
            Self.appendCapped(line, to: Self.burstsURL)
        }
        #endif
        watchEngineBusy()
        startTicker()
        // Returning wearer: the saved band reconnects by itself, so take its data without a trip to
        // the source picker (which also restores the saved baseline and today's totals).
        let last = UserDefaults.standard.string(forKey: Self.lastSourceKey)
        if onboardingDone, band.savedPeripheralID != nil, last != "demo", last != "recording" {
            useBand()
            log(.band, "Reconnecting to your band")
        }
        // Returning user: bring Gemma back without a trip to Under the hood.
        if onboardingDone, selectedModel != nil {
            Task { [weak self] in await self?.loadModel() }
        }
    }

    private var fitnessProfile: FitnessProfile { Self.fitnessProfile(for: profile) }

    /// Age from onboarding when known; mass and sex are not collected, so they stay at the defaults.
    private static func fitnessProfile(for p: UserProfile) -> FitnessProfile {
        FitnessProfile(age: Double(p.age ?? 40))
    }

    private func saveProfile() { health.saveProfile(profile) }

    /// Profiles saved before the database lived in UserDefaults: move one across, once.
    private static func importLegacyProfile(into health: HealthDB) -> UserProfile {
        guard let d = UserDefaults.standard.data(forKey: "profile"),
              let p = try? JSONDecoder().decode(UserProfile.self, from: d) else { return UserProfile() }
        health.saveProfile(p)
        UserDefaults.standard.removeObject(forKey: "profile")
        return p
    }

    func log(_ kind: TraceEntry.Kind, _ title: String, _ detail: String = "", ms: Double? = nil) {
        trace.add(TraceEntry(kind: kind, title: title, detail: detail, ms: ms))
        Self.appendTraceFile("\(kind) | \(title) | \(detail)" + (ms.map { String(format: " | %.0f ms", $0) } ?? ""))
    }

    /// The trace also goes to Library/Caches/bolt-trace.log so it can be pulled off a phone
    /// (devicectl copy from) or read in the Simulator's container when something hangs.
    nonisolated private static let traceURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("bolt-trace.log")
    nonisolated private static let traceTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    /// One serial queue for every file append, so writes from different threads never interleave.
    nonisolated private static let fileQueue = DispatchQueue(label: "bolt.file-log", qos: .utility)
    nonisolated static func appendTraceFile(_ line: String) {
        let text = traceTime.string(from: Date()) + " " + line.replacingOccurrences(of: "\n", with: " ") + "\n"
        appendCapped(Data(text.utf8), to: traceURL)
    }

    #if DEBUG
    nonisolated private static let burstsURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("gesture-bursts.jsonl")
    #endif

    /// Appends on the serial queue; once the file passes 2 MB it is truncated to just this write.
    nonisolated private static func appendCapped(_ data: Data, to url: URL) {
        fileQueue.async {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size < 2_000_000, let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    // MARK: model

    func refreshModels() {
        for note in ModelLocator.prepare() { log(.engine, "Model storage", note) }
        models = ModelLocator.available()
        if selectedModel == nil || !models.contains(where: { $0 == selectedModel }) {
            let last = UserDefaults.standard.string(forKey: "lastModel")
            selectedModel = models.first { $0.name == last } ?? models.first
        }
        // Debug hook: launch with -forceCPU to compare the CPU build against the GPU one.
        if ProcessInfo.processInfo.arguments.contains("-forceCPU"), let cpu = models.first(where: { !$0.isGPUBuild && $0.isE2B }) {
            selectedModel = cpu
        } else if preferGPU, let m = selectedModel, !m.isGPUBuild, let gpu = models.first(where: { $0.isGPUBuild && $0.isE2B == m.isE2B }) {
            // A CPU build saved by an earlier session's fallback shouldn't stick: start each launch on the GPU.
            selectedModel = gpu
        }
    }

    /// Set when a load was put off because the app was in the background (iOS relaunches it there to
    /// hand back the band); the GPU can't run Metal work in the background, so it would look "silent".
    private var loadWhenActive = false
    private var isInBackground: Bool { UIApplication.shared.applicationState == .background }

    func loadModel(attempt: Int = 1) async {
        guard let model = selectedModel else { return }
        if case .loading = engineState { return }
        if model.isGPUBuild, isInBackground {
            if !loadWhenActive { log(.engine, "Gemma waits for the app to open", "The GPU can't be used in the background") }
            loadWhenActive = true
            return
        }
        engineState = .loading
        emptyStreak = 0
        log(.engine, "Loading \(model.displayName)", model.name + (attempt > 1 ? " (attempt \(attempt))" : ""))
        do {
            try await gemma.load(model, preferGPU: preferGPU, speculativeDecoding: speculativeDecoding)
            engineStats = await gemma.stats
            log(.engine, "Engine ready", "\(engineStats.backend), \(String(format: "%.1f", engineStats.loadSeconds ?? 0)) s to load")
            // On the phone's GPU an engine sometimes comes up "dead": every generation ends at once
            // with no text (seen right after a fresh install). Check with the warm-up and reload if so.
            engineState = .ready
            if await warmUp().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                engineState = .failed("no output")
                if model.isGPUBuild, isInBackground {
                    // Went to the background mid-load: not a dead engine. Try again when the app opens.
                    log(.engine, "Gemma waits for the app to open", "Warm-up ran in the background")
                    loadWhenActive = true
                    return
                }
                if attempt == 1 {
                    log(.warning, "Gemma produced no text", "Reloading the engine")
                    await loadModel(attempt: 2)
                } else if model.isGPUBuild, let cpu = models.first(where: { !$0.isGPUBuild && $0.isE2B }) {
                    log(.warning, "Gemma still silent on GPU", "Switching to the CPU build")
                    selectedModel = cpu
                    await loadModel(attempt: 1)
                } else {
                    log(.warning, "Gemma produced no text", "Cards will use templates")
                }
                return
            }
            if attempt == 1 || model.isGPUBuild { UserDefaults.standard.set(model.name, forKey: "lastModel") }
            // Debug hook: launch with -autochat to ask two questions without touching the UI.
            if ProcessInfo.processInfo.arguments.contains("-autochat") {
                newChat()
                await send("I had two coffees this morning.")
                await send("I also went for a short walk after lunch.")
                await send("What did I drink today?")
                log(.chat, "Autochat memory check", "\(memory.facts.count) facts: " + memory.facts.suffix(4).map { $0.text }.joined(separator: " | "))
            }
        } catch {
            engineState = .failed(error.localizedDescription)
            log(.warning, "Engine failed", error.localizedDescription)
            // GPU build failed: try a CPU build automatically if there is one.
            if model.isGPUBuild, let cpu = models.first(where: { !$0.isGPUBuild && $0.isE2B }) {
                selectedModel = cpu
                log(.engine, "Retrying on CPU", cpu.name)
                await loadModel()
            }
        }
    }

    /// One tiny generation so the first real card doesn't pay first-run costs. Returns the text.
    @discardableResult
    func warmUp() async -> String {
        let t0 = Date()
        var text = ""
        do {
            try await consume(try await gemma.streamCard(system: CardPrompts.system, user: "Event: Test\n- Heart rate now: 70 bpm\nSay your one line.", maxTokens: 20),
                              first: 20, stall: 10) { text += $0 }
            let ms = Date().timeIntervalSince(t0) * 1000
            engineStats = await gemma.stats
            log(.engine, "Warm-up done", String(text.prefix(80)), ms: ms)
        } catch {
            log(.warning, "Warm-up failed", error.localizedDescription)
        }
        return text
    }

    /// Consecutive generations that ended with no text. Two in a row means the engine went silent; reload it.
    private var emptyStreak = 0
    private func noteGeneration(empty: Bool) {
        emptyStreak = empty ? emptyStreak + 1 : 0
        if emptyStreak >= 2, engineState == .ready {
            log(.warning, "Gemma went silent", "Reloading the engine")
            Task { await self.loadModel() }
        }
    }

    // MARK: data sources

    func useBand() {
        stopReplay()
        resetSession()
        source = .band
        UserDefaults.standard.set("band", forKey: Self.lastSourceKey)
        band.ensureConnected()
        // Phone sensors drive activity (Core Motion) and fall / gesture detection, band or not.
        activityEngine.start()
        phoneMotion.start()
        // A returning wearer keeps their resting baseline and today's totals.
        if let b = health.latestBaseline(maxAgeDays: Self.baselineMaxAgeDays), b.isEstablished {
            store.baseline = b
            log(.band, "Using your saved baseline", "resting \(Fmt.n(b.heartRate ?? 0, 0)) bpm")
        }   // else a provisional one forms from the first 30 s
        savedBaseline = store.baseline
        let now = Date()
        fitnessTotals = health.totals(on: now)
        // The first live window needs 30 s of new motion; until then show the last stored ones from today.
        let since = max(Calendar.current.startOfDay(for: now), now.addingTimeInterval(-10 * 60))
        fitnessTimeline = health.windows(from: since, to: now).map { $0.interval }
        fitnessLatest = fitnessTimeline.last
    }

    private static let lastSourceKey = "lastSource"
    /// A stored baseline older than this is not reused.
    private static let baselineMaxAgeDays = 14.0

    /// Called when the app comes to the foreground.
    func appBecameActive() {
        if source == .band { band.ensureConnected() }
        if loadWhenActive {
            loadWhenActive = false
            if engineState != .ready { Task { await self.loadModel() } }
        }
    }

    func startDemo(speed: Double = 1) {
        log(.band, "Demo session started", "Synthetic data: rest, jogging in place, recovery")
        runSynthetic(SyntheticSession.make(), source: .demo, finished: "Demo session finished", speed: speed)
    }

    func startFallDemo(speed: Double = 1) {
        log(.band, "Fall demo started", "Synthetic data: walking, a fall at \(Int(FallDemoSession.fallAt)) s, then lying still")
        runSynthetic(FallDemoSession.make(), source: .fallDemo, finished: "Fall demo finished", speed: speed)
    }

    private func runSynthetic(_ items: [SyntheticSession.Item], source newSource: DataSource, finished: String, speed: Double) {
        stopReplay()
        resetSession()
        source = newSource
        UserDefaults.standard.set("demo", forKey: Self.lastSourceKey)
        replayTask = Task { @MainActor [weak self] in
            var last = 0.0
            for item in items {
                if Task.isCancelled { return }
                let wait = (item.t - last) / speed
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                last = item.t
                self?.feed(item.input)
            }
            self?.log(.band, finished)
        }
    }

    func replay(_ url: URL) {
        stopReplay()
        resetSession()
        source = .recording(url.deletingPathExtension().lastPathComponent)
        UserDefaults.standard.set("recording", forKey: Self.lastSourceKey)
        guard let items = try? SessionRecorder.load(from: url) else { log(.warning, "Couldn't read recording", url.lastPathComponent); return }
        let dec = NotificationDecoder()
        log(.band, "Replaying recording", "\(items.count) notifications, \(Int(items.last?.t ?? 0)) s")
        replayTask = Task { @MainActor [weak self] in
            var last = 0.0
            for n in items {
                if Task.isCancelled { return }
                if n.t > last { try? await Task.sleep(nanoseconds: UInt64((n.t - last) * 1_000_000_000)) }
                last = n.t
                for input in dec.decode(n) { self?.feed(input) }
            }
            self?.log(.band, "Replay finished")
        }
    }

    func stopReplay() {
        replayTask?.cancel()
        replayTask = nil
    }

    func resetSession() {
        store.reset()
        triggers.reset()
        decoder.reset()
        cardQueue = []
        snapshot = LiveSnapshot()
        activityEngine.reset()
        fitnessTotals = FitnessTotals(); fitnessLatest = nil; fitnessBouts = []; fitnessTimeline = []; fitnessWindowCount = 0
        history.reset()
        resetCompanion()
    }

    func recalibrate() {
        store.resetBaseline(now: Date())
        triggers.reset()
        log(.band, "Baseline reset", "Recalibrating over the next 30 seconds of rest")
    }

    // Live samples (heart rate from the band, motion from the phone) record and feed through the
    // same path as the demo and replay. A standard Bluetooth HR band sends already-decoded
    // readings, so there is no wire-format parsing to do here.
    private func onLiveInput(_ input: LiveInput) {
        if isRecording { recorder.record(input) }
        feed(input)
    }

    /// Runs the robot's flip move (used by a shake gesture or the on-screen button). One flip at a
    /// time, and none while the robot is still moving, so repeated triggers don't stack up.
    /// Bolt on screen always flips; when the robot takes the move, Bolt flips via the dispatched
    /// command instead, so it never flips twice.
    func flipRobotForDoubleTap() {
        guard robot.isReady else {
            log(.robot, "Double tap: Bolt flips", "Robot not connected (\(robot.status.label))")
            flipTwinLocally()
            return
        }
        guard !robot.isBusy else {
            log(.robot, "Double tap: Bolt flips", "Robot is still doing \(robot.sending ?? "a command")")
            flipTwinLocally()
            return
        }
        robot.perform(RobotMove.Key.doubleTap)
    }

    private func flipTwinLocally() {
        var twin = robotTwin
        twin.apply(.flip, at: Date(), tuning: tuning.companion)
        robotTwin = twin
    }

    // MARK: activity windows

    /// The one funnel for band, demo and replay data: live metrics, fall and gesture detection.
    private func feed(_ input: LiveInput) {
        let now = Date()
        store.ingest(input, at: now)
        if case .imu(let samples) = input, !samples.isEmpty {
            detectFall(appended: samples.count, now: now)
            detectGesture(appended: samples.count)
        }
    }

    /// A finalized 30 s activity window from Core Motion (`MotionActivityEngine`).
    private func onActivityWindow(_ interval: FitnessInterval) {
        let now = Date()
        store.fitness.timeline.insert([interval], source: .live)
        store.fitness.latest = interval
        fitnessLatest = interval
        fitnessTotals = activityEngine.todayTotals
        fitnessWindowCount = activityEngine.windowCount
        let end = interval.end
        fitnessTimeline = store.fitness.timeline.windows(from: end - 20 * 30 - 1, to: end).map { $0.interval }
        if source == .band { recordHistory(store.fitness.timeline, now: now) }
        log(.activity, "Activity window: \(interval.label.rawValue)",
            "\(interval.metrics.steps) steps · \(Int(interval.metrics.cadence)) spm · \(String(format: "%.1f", interval.metrics.kcal)) kcal")
    }

    /// Writes today's windows Fitness added or relabelled, then reads today's totals back from the
    /// database so they include earlier sessions.
    private func recordHistory(_ timeline: FitnessTimeline, now: Date) {
        history.sync(timeline, store: store, since: Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        fitnessTotals = health.totals(on: now)
    }

    /// Saves the baseline when it is first set, recalibrated, or has drifted more than 2%.
    private func saveBaselineIfChanged(now: Date) {
        let b = store.baseline
        guard b.isEstablished else { return }
        if let last = lastBaselineCheck, now.timeIntervalSince(last) < 60 { return }   // at most once a minute
        lastBaselineCheck = now
        if let s = savedBaseline, s.isEstablished, s.establishedAt == b.establishedAt,
           !Self.moved(s.heartRate, b.heartRate), !Self.moved(s.hrv, b.hrv), !Self.moved(s.skinTemp, b.skinTemp) { return }
        health.recordBaseline(b, at: now)
        savedBaseline = b
    }

    private static func moved(_ a: Double?, _ b: Double?) -> Bool {
        guard let a, let b else { return (a == nil) != (b == nil) }
        return abs(b - a) > abs(a) * 0.02
    }

    // MARK: recording

    func toggleRecording() {
        if isRecording {
            isRecording = false
            guard !recorder.isEmpty else { return }
            let dir = ModelLocator.documents.appendingPathComponent("recordings", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "MMdd-HHmm"
            let url = dir.appendingPathComponent("session-\(f.string(from: Date())).jsonl")
            do {
                try recorder.write(to: url)
                log(.band, "Recording saved", "\(url.lastPathComponent), \(Int(recorder.duration)) s")
            } catch { log(.warning, "Recording failed", error.localizedDescription) }
            recorder = SessionRecorder()
            refreshRecordings()
        } else {
            recorder = SessionRecorder()
            isRecording = true
        }
    }

    func refreshRecordings() {
        let dir = ModelLocator.documents.appendingPathComponent("recordings", isDirectory: true)
        recordings = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: the 1 Hz loop

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        tickCount += 1
        let now = Date()
        refreshSnapshot(now: now)
        escalateFallIfUnanswered(now: now)
        driveFallScript(now: now)
        guard source != .none else {
            // No data source: a simulated fall must still reach the robot hook and the mood.
            if fallAlert != nil || pendingFallResolved { updateCompanion(now: now) }
            return
        }
        if source == .band { saveBaselineIfChanged(now: now) }

        // Activity comes from Core Motion's own classifier (MotionActivityEngine), sampled each tick.
        if tickCount % 2 == 0 { applyActivity(activityEngine.current) }
        handle(triggers.evaluate(store, now: now))
        updateCompanion(now: now)
    }

    private var lastActivity: ActivityClass?

    private func applyActivity(_ cls: ActivityClass) {
        let moving = [ActivityClass.walk, .run, .stairs, .cycle].contains(cls)
        rawMovingStreak = moving ? rawMovingStreak + 1 : 0
        let previous = lastActivity
        store.ingest(activity: ActivityPoint(t: Date(), activity: cls, probability: 1))
        if tickCount % 30 == 0 { log(.activity, "Activity: \(cls.label)", "from Core Motion") }
        if cls != previous {
            lastActivity = cls
            if previous != nil {
                log(.activity, "Activity changed to \(cls.label)", "from Core Motion")
                handle(triggers.evaluate(store, now: Date(), activityChangedTo: cls, previousActivity: previous))
            }
        }
    }

    private func refreshSnapshot(now: Date) {
        var s = LiveSnapshot()
        s.hr = store.stats(.heartRate, seconds: 5, now: now)?.latest
        // SpO2 comes rarely (the band only reports it with a clean optical signal): keep showing the last one.
        if let v = store.stats(.spo2, seconds: 15, now: now)?.mean { lastSpO2 = v }
        s.spo2 = lastSpO2
        s.skinTemp = store.stats(.skinTemp, seconds: 60, now: now)?.mean
        s.activity = store.currentActivity(now: now)
        s.worn = store.isWorn
        // Any band data counts: cardiac entries arrive in bursts several seconds apart, and keying this
        // on cardiac alone flipped the band chip to "waiting" between bursts.
        s.hasData = store.lastDataAt.map { now.timeIntervalSince($0) < 10 } ?? false
        s.baselineHR = store.baseline.heartRate
        s.baselineTemp = store.baseline.skinTemp
        s.calibration = store.calibrationProgress
        s.hrSeries = store.series(.heartRate, seconds: 300, maxPoints: 60, now: now)
        s.spo2Series = store.series(.spo2, seconds: 600, maxPoints: 30, now: now)
        s.tempSeries = store.series(.skinTemp, seconds: 600, maxPoints: 30, now: now)
        s.motionSeries = store.series(.motion, seconds: 120, maxPoints: 40, now: now)
        s.steps = fitnessTotals.steps
        s.kcal = fitnessTotals.activeKcal
        s.walkingCadence = fitnessTotals.walkingCadence
        s.baselineSkinTemp = store.baseline.skinTemp
        if let latest = fitnessLatest, abs(now.timeIntervalSince1970 - latest.end) <= 60 { s.cadence = latest.metrics.cadence }
        if s != snapshot { snapshot = s }
    }

    // MARK: Companion
    private func loadTuning() {
        let r = Tuning.load(from: Self.tuningURL)
        var loaded = r.tuning
        var error = r.error
        if error == nil {
            let (clean, fixed) = Self.sanitized(loaded)
            if fixed > 0 {
                loaded = clean
                error = "tuning.json had \(fixed) value(s) that were negative, not finite or above \(Int(Self.tuningMax)); those use their defaults."
            }
        }
        tuning = loaded
        tuningError = error
        companionEngine.tuning = loaded.companion
        if let e = error { log(.warning, "Tuning", e) }
    }

    /// Largest value a numeric tuning field may hold.
    static let tuningMax = 100_000.0

    /// Replaces every number that is negative, not finite or above `tuningMax` with that field's default.
    static func sanitized(_ t: Tuning) -> (Tuning, Int) {
        func walk(_ v: Any, _ d: Any, _ count: inout Int) -> Any {
            if let o = v as? [String: Any], let dd = d as? [String: Any] {
                var out = o
                for (k, val) in o { if let dv = dd[k] { out[k] = walk(val, dv, &count) } }
                return out
            }
            if let str = v as? String, ["nan", "inf", "-inf"].contains(str) { count += 1; return d }
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
                let x = n.doubleValue
                if !x.isFinite || x < 0 || x > tuningMax { count += 1; return d }
            }
            return v
        }
        let enc = JSONEncoder()
        enc.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let obj = (try? enc.encode(t)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }),
              let def = (try? enc.encode(Tuning())).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) else { return (t, 0) }
        var count = 0
        let cleaned = walk(obj, def, &count)
        guard count > 0, let out = try? JSONSerialization.data(withJSONObject: cleaned),
              let fixed = try? JSONDecoder().decode(Tuning.self, from: out) else { return (t, 0) }
        return (fixed, count)
    }

    func updateTuning(_ t: Tuning) {
        tuning = t
        companionEngine.tuning = t.companion
        do { try t.save(to: Self.tuningURL); tuningError = nil }
        catch { tuningError = "Could not save tuning: \(error.localizedDescription)" }
    }

    /// `isGenerating` mirrors GemmaService's engine lock, so it is true while any generation (card,
    /// chat or summary) holds the engine. The renderer drops to its lower frame rate meanwhile.
    private func watchEngineBusy() {
        Task { [weak self, gemma] in
            await gemma.setBusyObserver { [weak self] in
                Task { @MainActor in await self?.syncGenerating() }
            }
        }
    }

    private func syncGenerating() async {
        // Each sync takes a number before it reads; a read that comes back after a newer sync started
        // is stale and dropped, so a slow earlier answer can't overwrite a fresher one.
        generatingSeq += 1
        let seq = generatingSeq
        let busy = await gemma.isBusy
        guard seq > generatingApplied else { return }
        generatingApplied = seq
        if busy != isGenerating { isGenerating = busy }
    }
    private var generatingSeq = 0
    private var generatingApplied = 0

    private func resetCompanion() {
        if fallAlert != nil {
            // Close an open fall check properly instead of just dropping it.
            updateCompanion(now: Date())   // the engine sees the alert before it is resolved
            fallAlert = nil
            pendingFallResolved = true
            robot.dropQueued()
            finishFall(response: "interrupted", cardText: "The fall check was interrupted.")
            log(.warning, "Fall alert", "Interrupted by a reset")
            updateCompanion(now: Date())   // emits fallResolved
        }
        fallHelpRequested = false
        fallStage = .asking
        fallLine = ""
        companionEngine.resetSession()
        fallDetector.reset()
        fallAlert = nil
        fallScriptStart = nil
        fallContext = nil
        fallCooldownUntil = nil
        pendingTriggers = []
        pendingFallResolved = false
        lastLoggedLook = nil
        companion = CompanionState()
    }

    // MARK: Fall check (one path: detector or simulation -> beginFallAlert -> answer / escalation)

    /// What the open fall check is about, for the card and the memory writes.
    private struct FallContext {
        /// A real detection (not Simulate fall, not the Fall demo): only these arm the cooldown.
        var real: Bool = false
        var at: Date
        var cardID: UUID
        var simulated: Bool
        var memoryID: UUID?
    }
    private var fallContext: FallContext?
    private var fallCooldownUntil: Date?

    /// Feeds the detector exactly the points the last IMU ingest appended (ingest only trims from the front).
    private func detectFall(appended count: Int, now: Date) {
        guard count > 0, UserDefaults.standard.object(forKey: "settings.fallDetection") as? Bool ?? true else { return }
        guard let fall = fallDetector.feed(Array(store.accel.suffix(count))) else { return }
        guard fallAlert == nil else { return }
        if let until = fallCooldownUntil, now < until {
            log(.warning, "Fall ignored", "Within \(Int(tuning.fall.cooldownSeconds)) s of the last fall check")
            return
        }
        beginFallAlert(fall, simulated: false, now: now)
    }

    private func beginFallAlert(_ fall: FallEvent?, simulated: Bool, now: Date) {
        guard fallAlert == nil else { return }
        let at = fall?.at ?? now
        let time = at.formatted(date: .omitted, time: .shortened)
        var facts: [InsightFact] = []
        if let fall {
            facts = [.num("Impact", fall.peakG, "g", digits: 1),
                     .num("Wrist turned", fall.orientationChangeDeg, "degrees"),
                     .num("Fall probability", fall.probability * 100, "%")]
        }
        if let hr = store.latest(.heartRate, maxAge: 10) { facts.append(.num("Heart rate now", hr, "bpm")) }
        let text = "Possible fall at \(time)" + (simulated ? " (simulated)" : "") + "."
        let e = InsightEvent(kind: .fall, createdAt: at, facts: facts, fixedText: text)
        cards.append(InsightCard(event: e, text: text, source: .safety, isStreaming: false))
        fallContext = FallContext(real: !simulated && source != .fallDemo, at: at, cardID: e.id, simulated: simulated)
        fallAlert = .asking(since: now)
        fallScriptStart = now
        fallHelpRequested = false
        fallStage = .asking
        fallLastLineAt = nil
        if let fall {
            log(.warning, simulated ? "Simulated fall detected" : "Possible fall detected",
                String(format: "p=%.2f, impact %.1f g, wrist turned %.0f°, stillness %.2f g%@", fall.probability, fall.peakG, fall.orientationChangeDeg, fall.stillnessSD, fall.saturated ? ", hit sensor ceiling" : ""))
        } else {
            log(.warning, "Possible fall", "Asking the wearer if they are okay")
        }
        buzz()
        notifyFallIfBackground(time: time)
        driveFallScript(now: now)
    }

    func fallRespondOK() {
        guard fallAlert != nil else { return }
        // Let the engine see the alert first, so fallResolved is never emitted without fallSuspected.
        updateCompanion(now: Date())
        fallAlert = nil
        fallScriptStart = nil
        robot.dropQueued()   // an alarm line still waiting would play over the calm one
        sayFall(.resolvedOK, now: Date())
        pendingFallResolved = true
        // R24: an explicit "I'm okay" arms no cooldown; only the detector's own refractory applies.
        fallCooldownUntil = nil
        finishFall(response: "they are OK", cardText: "You said you were okay.")
        log(.warning, "Fall alert", "Wearer said they are okay")
        updateCompanion(now: Date())
    }

    func fallRequestHelp() {
        guard fallAlert != nil else { return }
        fallAlert = .escalated(since: Date())
        fallHelpRequested = true
        recordFallResponse("they needed help", cardText: "You asked for help.")
        log(.warning, "Fall alert", "Wearer asked for help")
        buzz()
        driveFallScript(now: Date())
    }

    /// Plays a synthetic fall through a separate detector, all at once, so it never disturbs the live
    /// stream. If the model somehow rejects it, the fall check is raised directly.
    func simulateFall() {
        simDetector.reset()
        let pts = FallDetector.syntheticFall(start: Date().addingTimeInterval(-10))
        if let fall = simDetector.feed(pts) {
            beginFallAlert(fall, simulated: true, now: Date())
        } else {
            log(.warning, "Simulated fall not detected by the model", "Raising the fall check directly")
            beginFallAlert(nil, simulated: true, now: Date())
        }
    }

    /// Runs every tick, even with no data source, so a simulated fall still escalates.
    private func escalateFallIfUnanswered(now: Date) {
        if case .asking(let since) = fallAlert, now.timeIntervalSince(since) >= tuning.fall.responseTimeoutSeconds {
            fallAlert = .escalated(since: now)
            // Unanswered: suppress repeat alerts for the cooldown (real falls only, never a simulation or the demo).
            if fallContext?.real == true { fallCooldownUntil = now.addingTimeInterval(tuning.fall.cooldownSeconds) }
            recordFallResponse("no response", cardText: "No response yet.")
            log(.warning, "Fall alert", "No response; escalated")
            buzz()
            if let c = fallContext { notifyFallIfBackground(time: c.at.formatted(date: .omitted, time: .shortened)) }
        }
    }

    // MARK: Fall script (what is said, and when)

    private let fallScript = FallScript()
    private var fallScriptStart: Date?
    private var fallHelpRequested = false
    private var fallLastLineAt: Date?

    /// Runs on the 1 Hz tick and after each button: moves to the stage the clock says and says its line;
    /// in the alarm stage, says it again every `alarmRepeatSeconds`.
    private func driveFallScript(now: Date) {
        guard let start = fallScriptStart, fallAlert != nil else { return }
        let stage = fallScript.stage(sinceAlert: now.timeIntervalSince(start), helpRequested: fallHelpRequested, resolved: false, tuning: tuning.fall)
        if stage != fallStage || fallLastLineAt == nil {
            sayFall(stage, now: now)
        } else if stage == .alarm, fallScript.alarmRepeatDue(secondsSinceLastLine: now.timeIntervalSince(fallLastLineAt ?? now), tuning: tuning.fall) {
            // Don't pile up: wait until the robot has written the last line, or the phone has finished it.
            let busy = robotSpeaks ? robot.isBusy : (speech?.isSpeaking ?? false)
            if !busy { sayFall(.alarm, now: now) }
        }
    }

    /// Says the stage's line: through the robot's `say` when it is connected, otherwise on the phone, never both.
    private func sayFall(_ stage: FallStage, now: Date) {
        let line = fallScript.line(for: stage, name: profile.name)
        fallStage = stage
        fallLine = line
        fallLastLineAt = now
        // Bolt's body reacts too: stands up when it asks, waves for attention with each alarm line.
        if robot.isReady, !robot.isBusy {
            switch stage {
            case .asking: robot.perform(RobotMove.Key.stand)
            case .alarm: robot.perform(RobotMove.Key.wave)
            default: break
            }
        }
        if robotSpeaks, let command = RobotCommand.say(line), robot.canDeliver(command) {
            robot.send(command)
            log(.robot, "Fall script (\(stage)): robot says", line)
        } else {
            speech?.speak(line, loud: stage == .alarm || stage == .reasked)
            log(.robot, "Fall script (\(stage)): Bolt says on the phone", line)
        }
    }

    /// Updates the fall card and writes (or rewrites) the one memory for this fall, worded from the
    /// computed facts. A simulated fall is saved too, tagged so Gemma's recent-falls line skips it.
    private func recordFallResponse(_ response: String, cardText: String) {
        guard var ctx = fallContext else { return }
        let time = ctx.at.formatted(date: .omitted, time: .shortened)
        var event: InsightEvent?
        if let i = cards.firstIndex(where: { $0.id == ctx.cardID }) {
            cards[i].text = "Possible fall at \(time)" + (ctx.simulated ? " (simulated)" : "") + ". " + cardText
            event = cards[i].event
        }
        guard var e = event else { return }
        e.facts.append(InsightFact(label: "Response", text: response))
        if var fact = InsightMemory.fact(for: e) {
            if ctx.simulated || source != .band { fact += " (simulated, not a real fall)" }
            if let old = ctx.memoryID { memory.remove(old) }
            ctx.memoryID = memory.add(fact, source: "insight")?.id
            fallContext = ctx
            memoryFacts = memory.facts
            log(.chat, "Fall written to memory", fact)
        }
    }

    private func finishFall(response: String, cardText: String) {
        recordFallResponse(response, cardText: cardText)
        fallContext = nil
        clearFallNotification()
    }

    private func clearFallNotification() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ["fall"])
        center.removePendingNotificationRequests(withIdentifiers: ["fall"])
    }

    private func buzz() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Reaches the person when the app is in the background or the phone is locked.
    private func notifyFallIfBackground(time: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Are you okay?"
        content.body = "Bolt noticed a possible fall at \(time). Open the app to tell it you're OK or call for help."
        content.sound = .default
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "fall", content: content, trigger: nil))
    }

    private var lastSpO2: Double?
    private var lastRobotWalkAt: Date?
    private var rawMovingStreak = 0

    /// While the user walks or runs, Bolt walks too: the Walk forward move (timed, the link stops
    /// it), repeated every `robotWalkRepeatSeconds` while the walking lasts. Not during a fall check.
    static let robotWalkRepeatSeconds: TimeInterval = 6
    private func walkRobotIfMoving(_ state: CompanionState, now: Date) {
        guard state.userWalking || rawMovingStreak >= 2, fallAlert == nil, robot.isReady, !robot.isBusy else { return }
        if let last = lastRobotWalkAt, now.timeIntervalSince(last) < Self.robotWalkRepeatSeconds { return }
        if lastRobotWalkAt == nil || now.timeIntervalSince(lastRobotWalkAt!) > 30 { log(.robot, "You're walking: Bolt walks", "\(state.motion)") }
        lastRobotWalkAt = now
        robot.perform(RobotMove.Key.walkForward)
    }

    private func updateCompanion(now: Date) {
        let s = snapshot
        let input = CompanionInput(
            hr: s.hr, hrv: nil, skinTemp: s.skinTemp,
            baselineHR: s.baselineHR, baselineHRV: nil, baselineSkinTemp: s.baselineSkinTemp,
            activity: s.activity, hasData: s.hasData, worn: s.worn, calibrating: s.calibration < 1,
            age: profile.age.map(Double.init), steps: s.steps, cadence: s.cadence,
            triggers: pendingTriggers, fallAlertActive: fallAlert != nil, fallResolved: pendingFallResolved)
        pendingTriggers = []
        pendingFallResolved = false
        let result = companionEngine.update(input, now: now)
        if result.state != companion { companion = result.state }
        walkRobotIfMoving(result.state, now: now)
        let look = "\(result.state.motion)/\(result.state.mood)"
        if look != lastLoggedLook {
            lastLoggedLook = look
            log(.activity, "Companion: \(look)")
        }
        for event in result.events {
            log(.activity, "Companion event: \(event)")
            #if DEBUG
            NSLog("[companion] event %@ mood=%@", "\(event)", "\(result.state.mood)")
            #endif
            companionEvents.send(event)
        }
    }
    // MARK: end Companion

    // MARK: insight cards

    private func handle(_ events: [InsightEvent]) {
        guard !events.isEmpty else { return }
        pendingTriggers += events.map(\.kind)  // Companion
        for e in events {
            // The demo assumes the band is worn: signal drop-outs go to the trace, not the card feed.
            if e.kind == .bandOff { continue }   // never shown or logged: signal drop-outs aren't meaningful to the user
            log(.card, "Trigger: \(e.kind.title)", e.facts.map { "\($0.label): \($0.text)" }.joined(separator: " · "))
            if e.kind == .safety || e.fixedText != nil {
                cards.append(InsightCard(event: e, text: CardPrompts.template(for: e), source: .safety, isStreaming: false))
                rememberInsight(e)
                if source == .band, let card = cards.last { health.save(card: card) }
            } else if cardsEnabled {
                cardQueue.append(e)
            }
        }
        Task { await drainCards() }
    }

    private func drainCards() async {
        guard !cardWorkerBusy else { return }
        cardWorkerBusy = true
        defer { cardWorkerBusy = false }
        while !cardQueue.isEmpty {
            let e = cardQueue.removeFirst()
            // A late card is worse than none.
            if Date().timeIntervalSince(e.createdAt) > 10 { log(.card, "Skipped stale card", e.kind.title); continue }
            await writeCard(e)
        }
    }

    private func writeCard(_ e: InsightEvent) async {
        cards.append(InsightCard(event: e))
        let idx = cards.count - 1
        guard engineState == .ready else {
            finishCard(idx, text: CardPrompts.template(for: e), source: .template, first: nil, total: nil, note: "model not loaded")
            return
        }
        let memoryHints = memory.recall(e.kind.title + " " + e.facts.map { $0.label }.joined(separator: " "), limit: 2).map { $0.text }
        let user = CardPrompts.userMessage(for: e, name: profile.name, memory: memoryHints)
        let t0 = Date()
        var first: Double?
        var text = ""
        do {
            try await consume(try await gemma.streamCard(system: CardPrompts.system, user: user), first: 15, stall: 10) { piece in
                if first == nil { first = Date().timeIntervalSince(t0) * 1000 }
                text += piece
                if idx < self.cards.count { self.cards[idx].text = NumberGuard.clean(text) }
            }
            let total = Date().timeIntervalSince(t0) * 1000
            await gemma.noteTotal(ms: total)
            engineStats = await gemma.stats
            let cleaned = NumberGuard.clean(text)
            noteGeneration(empty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if cleaned.isEmpty || !NumberGuard.isFaithful(cleaned, facts: e.facts) {
                log(.warning, "Card failed number check", cleaned)
                finishCard(idx, text: CardPrompts.template(for: e), source: .template, first: first, total: total, note: "replaced by template")
            } else {
                finishCard(idx, text: cleaned, source: .gemma, first: first, total: total, note: nil)
            }
        } catch {
            finishCard(idx, text: CardPrompts.template(for: e), source: .template, first: first, total: nil, note: error.localizedDescription)
        }
    }

    private func finishCard(_ idx: Int, text: String, source: InsightCard.Source, first: Double?, total: Double?, note: String?) {
        guard idx < cards.count else { return }
        cards[idx].text = text
        cards[idx].source = source
        cards[idx].firstTokenMs = first
        cards[idx].totalMs = total
        cards[idx].isStreaming = false
        if self.source == .band { health.save(card: cards[idx]) }
        log(.card, "Card (\(source == .gemma ? "Gemma" : "template"))", text + (note.map { " · \($0)" } ?? ""), ms: total)
        rememberInsight(cards[idx].event)
        speakCard(cards[idx])
    }

    func clearCards() { cards = []; health.deleteCards() }

    // MARK: chat

    func send(_ raw: String) async {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !(chat.last?.isStreaming ?? false) else { return }
        let priorTurns = ChatThread(title: "", messages: chat).turns
        var userMsg = ChatMessage(role: .user, text: question)
        let facts = MemoryStore.extractFacts(from: question)
        for f in facts { memory.add(f, source: "chat") }
        if !facts.isEmpty { memoryFacts = memory.facts; userMsg.remembered = facts }
        chat.append(userMsg)
        chat.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        let idx = chat.count - 1
        log(.chat, "Question", question)

        guard engineState == .ready else {
            chat[idx].isStreaming = false
            chat[idx].error = "Gemma isn't loaded. Open Under the hood to load a model."
            return
        }
        let t0 = Date()
        var text = ""
        // The chat can be cleared while this answer streams; look the message up by id after every await.
        let msgID = chat[idx].id
        func update(_ change: (inout ChatMessage) -> Void) {
            if let i = chat.firstIndex(where: { $0.id == msgID }) { change(&chat[i]) }
        }
        do {
            let current = currentThreadID.flatMap { id in threads.first { $0.id == id } }
            let context = ConversationContext.block(
                memories: ConversationContext.memories(for: question, store: memory),
                summary: current?.summary ?? "",
                recent: Array(priorTurns.suffix(ConversationContext.recentTurns)),
                otherChats: threads.filter { $0.id != currentThreadID && !$0.gist.isEmpty }.prefix(2).map { (title: $0.title, gist: $0.gist) },
                falls: ConversationContext.recentFalls(store: memory))
            let system = ChatPrompts.system(profile: profile, now: Date()) + (context.isEmpty ? "" : "\n\n" + context)
            let stream = try await gemma.streamChat(system: system, user: question, tools: ChatToolset.all())
            try await consume(stream, first: 45, stall: 20, register: { self.chatReader = $0 }) { piece in
                text += piece
                let cleaned = NumberGuard.clean(text)
                update { m in
                    if m.firstTokenMs == nil { m.firstTokenMs = Date().timeIntervalSince(t0) * 1000 }
                    m.text = cleaned
                }
            }
            let total = Date().timeIntervalSince(t0) * 1000
            update { $0.totalMs = total }
            engineStats = await gemma.stats
            let answer = NumberGuard.clean(text)
            if !chatStopped { noteGeneration(empty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            if chatStopped {
                if answer.isEmpty { update { $0.error = "Stopped." } }
                log(.chat, "Stopped", answer)
            } else if answer.isEmpty || NumberGuard.looksGarbled(answer, strict: false) {
                update { $0.text = ""; $0.error = "Gemma's answer came out garbled. Try asking again." }
                log(.warning, "Garbled answer", String(text.prefix(300)), ms: total)
            } else {
                log(.chat, "Answer", answer, ms: total)
            }
        } catch {
            update { $0.error = error.localizedDescription }
            log(.warning, "Chat failed", error.localizedDescription)
            if case GemmaError.stalled = error { noteGeneration(empty: true) }
        }
        chatReader = nil
        chatStopped = false
        update { $0.isStreaming = false }
        persistCurrentChat()
        Task { await self.updateSummaryIfNeeded() }
    }

    // MARK: saved chats

    /// Writes the open chat to disk, creating its thread on the first message.
    private func persistCurrentChat() {
        guard !chat.isEmpty else { return }
        if currentThreadID == nil {
            let first = chat.first { $0.role == .user }?.text ?? "Chat"
            let t = ChatThread(title: first.count <= 60 ? first : String(first.prefix(60)) + "…")
            threads.insert(t, at: 0)
            currentThreadID = t.id
        }
        guard let i = threads.firstIndex(where: { $0.id == currentThreadID }) else { return }
        threads[i].messages = chat
        threads[i].updatedAt = Date()
        chatStore.save(threads[i])
        threads.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Folds turns that left the recent window into the chat's running summary (Gemma writes it when
    /// the engine is free; a plain list of the questions is the fallback).
    private func updateSummaryIfNeeded() async {
        guard let id = currentThreadID, let t = threads.first(where: { $0.id == id }) else { return }
        let turns = t.turns
        let older = max(0, turns.count - ConversationContext.recentTurns)
        guard older > t.summarizedTurns else { return }
        let newTurns = Array(turns[t.summarizedTurns ..< older])
        let p = ConversationContext.summaryPrompt(previous: t.summary, turns: newTurns)
        guard let raw = await gemma.summarize(system: p.system, user: p.user) else { return }   // engine busy: next answer retries
        let cleaned = NumberGuard.clean(raw)
        let good = !cleaned.isEmpty && !NumberGuard.leaksMarkup(cleaned) && !NumberGuard.looksGarbled(cleaned, strict: false)
        guard let i = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[i].summary = good ? cleaned : ConversationContext.fallbackSummary(previous: t.summary, turns: newTurns)
        threads[i].summarizedTurns = older
        chatStore.save(threads[i])
        log(.chat, "Chat summary updated", threads[i].summary)
    }

    // MARK: gestures

    private func detectGesture(appended count: Int) {
        guard count > 0, fallAlert == nil, UserDefaults.standard.object(forKey: "settings.gestures") as? Bool ?? true,
              let g = gestureDetector.feed(Array(store.accel.suffix(count))) else { return }
        handleGesture(g, simulated: false)
    }

    /// Wave: Gemma waves back with a one-line status. Shake: marks the moment in memory.
    private func handleGesture(_ g: GestureEvent, simulated: Bool) {
        log(.activity, simulated ? "Simulated \(g.gesture.rawValue)" : "Gesture: \(g.gesture.rawValue)",
            String(format: "%.1f cycles at %.1f Hz, %.1f g", g.cycles, g.frequencyHz, g.amplitudeG))
        var facts: [InsightFact] = []
        if let hr = store.latest(.heartRate, maxAge: 10) { facts.append(.num("Heart rate now", hr, "bpm")) }
        if let a = store.currentActivity() { facts.append(InsightFact(label: "Activity", text: a.label.lowercased())) }
        let today = fitnessTotals
        if today.steps > 0 { facts.append(.num("Steps today", Double(today.steps), "")) }
        switch g.gesture {
        case .wave:
            waveRobot(now: Date())
            handle([InsightEvent(kind: .wave, createdAt: g.at, facts: waveFacts(base: facts, now: g.at))])
        case .shake:
            let e = InsightEvent(kind: .moment, createdAt: g.at, facts: facts)
            cards.append(InsightCard(event: e, text: CardPrompts.template(for: e), source: .template, isStreaming: false))
            if !simulated, let fact = InsightMemory.fact(for: e) {
                memory.add(fact, source: "insight")
                memoryFacts = memory.facts
            }
        }
    }

    private var lastRobotWave: Date?

    /// What Bolt can talk about after waving back: today's numbers, a recent heart rate, a fall
    /// earlier (so Bolt asks how they feel), something the user told Bolt, and the latest insight.
    /// Gemma picks one. Every number here comes from the band or from what the user said.
    private func waveFacts(base: [InsightFact], now: Date) -> [InsightFact] {
        var facts = base
        if !facts.contains(where: { $0.label == "Heart rate now" }),
           let p = store.points(.heartRate, since: now.addingTimeInterval(-20 * 60)).last {
            let mins = max(1, Int(now.timeIntervalSince(p.t) / 60))
            facts.append(.num("Heart rate \(mins) min ago", p.value, "bpm"))
        }
        if facts.contains(where: { $0.label.hasPrefix("Heart rate") }), let b = store.baseline.heartRate, store.baseline.isEstablished {
            facts.append(.num("Their usual resting heart rate", b, "bpm"))
        }
        if fitnessTotals.walkingMinutes >= 1 { facts.append(.num("Minutes walking today", fitnessTotals.walkingMinutes, "min")) }
        let hour = Calendar.current.component(.hour, from: now)
        facts.append(InsightFact(label: "Time of day", text: hour < 12 ? "morning" : hour < 17 ? "afternoon" : "evening"))
        if let fall = memory.facts.filter({ $0.source == "insight" && $0.text.contains("possible fall detected") && !$0.text.contains("(simulated")
                                            && now.timeIntervalSince($0.createdAt) < 12 * 3600 }).max(by: { $0.createdAt < $1.createdAt }) {
            let answer = fall.text.contains("they are OK") ? "they said they were okay" : fall.text.contains("help") ? "they asked for help" : "no answer recorded"
            facts.append(InsightFact(label: "Fall earlier", text: "at \(fall.createdAt.formatted(date: .omitted, time: .shortened)), \(answer)"))
        }
        if let told = memory.facts.filter({ $0.source != "insight" && now.timeIntervalSince($0.createdAt) < 12 * 3600 }).max(by: { $0.createdAt < $1.createdAt }) {
            facts.append(InsightFact(label: "They told you earlier", text: told.text))
        }
        if let card = cards.last(where: { ![TriggerKind.wave, .moment, .bandOff, .fall].contains($0.event.kind) && !$0.isStreaming && !$0.text.isEmpty
                                          && now.timeIntervalSince($0.event.createdAt) < 2 * 3600 }) {
            facts.append(InsightFact(label: "Your last insight for them", text: card.text))
        }
        return facts
    }

    // MARK: Bolt's voice

    private var lastSpokenCardAt: Date?

    /// Our Quaddle relays `say` to an AI Core speaker it doesn't have (it echoes the command, no
    /// sound), so Bolt's voice is the phone unless Settings > "Robot has a speaker" is on.
    var robotSpeaks: Bool { robot.isReady && UserDefaults.standard.bool(forKey: "settings.robotSpeaker") }

    /// Bolt says a card out loud: a wave reply always, other model-written insights from real band
    /// data when "Bolt reads insights aloud" is on, at most one per `spokenCardGapSeconds`. Never
    /// during a fall check (the fall script owns Bolt's voice then).
    private func speakCard(_ card: InsightCard) {
        guard fallAlert == nil, !card.text.isEmpty else { return }
        let isWave = card.event.kind == .wave
        if !isWave {
            guard source == .band, card.source == .gemma, card.event.kind != .safety,
                  UserDefaults.standard.object(forKey: "settings.speakCards") as? Bool ?? true,
                  Date().timeIntervalSince(lastSpokenCardAt ?? .distantPast) >= Self.spokenCardGapSeconds else { return }
        }
        lastSpokenCardAt = Date()
        boltSay(card.text, why: isWave ? "wave" : card.event.kind.title, interruptListening: isWave)
    }
    static let spokenCardGapSeconds: TimeInterval = 90

    /// Through the robot's speaker (`say`) when the robot is connected and can take the line,
    /// otherwise the phone reads it. Never both.
    private func boltSay(_ text: String, why: String, interruptListening: Bool) {
        let line = text.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if robotSpeaks, let command = RobotCommand.say(line), robot.canDeliver(command) {
            robot.send(command)
            log(.robot, "Bolt says (\(why)): robot", line)
            return
        }
        guard let speech else { return }
        if speech.isListening && !interruptListening { log(.robot, "Bolt says (\(why)): skipped", "You were talking to Gemma"); return }
        speech.speak(line)
        log(.robot, "Bolt says (\(why)): phone", line)
    }

    /// A wrist wave makes the robot wave back ("Wave hi"), at most once per `waveRobotCooldownSeconds`.
    /// Dispatched commands resolve through the move config, so the 3D twin waves too.
    private func waveRobot(now: Date) {
        let gap = tuning.companion.waveRobotCooldownSeconds
        if let last = lastRobotWave, now.timeIntervalSince(last) < gap {
            log(.robot, "Wave: robot not waved", "Within \(Int(gap)) s of the last robot wave")
            return
        }
        lastRobotWave = now
        log(.robot, "Wave: robot waves back", RobotMove.Key.wave)
        robot.perform(RobotMove.Key.wave)
    }

    /// Plays a synthetic wave or shake in real time through a separate detector.
    func simulateGesture(_ g: WristGesture) {
        simGestureDetector.reset()
        let pts = GestureDetector.synthetic(g, start: Date())
        Task { @MainActor [weak self] in
            var i = 0
            while i < pts.count {
                let chunk = Array(pts[i ..< min(i + 5, pts.count)])
                i += 5
                if let wait = chunk.last.map({ $0.t.timeIntervalSinceNow }), wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                guard let self else { return }
                if let e = self.simGestureDetector.feed(chunk) { self.handleGesture(e, simulated: true); return }
            }
            self?.log(.warning, "Simulated \(g.rawValue) not detected")
        }
    }

    /// New chat button. The current one stays in history.
    func newChat() {
        stopChat()
        persistCurrentChat()
        chat = []
        currentThreadID = nil
    }

    func openThread(_ id: UUID) {
        guard !(chat.last?.isStreaming ?? false), let t = threads.first(where: { $0.id == id }) else { return }
        persistCurrentChat()
        chat = t.messages
        currentThreadID = id
    }

    func deleteThread(_ id: UUID) {
        chatStore.delete(id)
        threads.removeAll { $0.id == id }
        if currentThreadID == id { stopChat(); chat = []; currentThreadID = nil }
    }

    /// Important insights become memories (worded from the computed facts, real band data only).
    private func rememberInsight(_ e: InsightEvent) {
        guard source == .band, let fact = InsightMemory.fact(for: e) else { return }
        if let last = lastInsightMemory[e.kind], e.createdAt.timeIntervalSince(last) < 30 * 60, e.kind != .safety { return }
        lastInsightMemory[e.kind] = e.createdAt
        memory.add(fact, source: "insight")
        memory.prune(source: "insight", keep: 40)
        memoryFacts = memory.facts
        log(.chat, "Remembered insight", fact)
    }

    /// Stop button in Ask Gemma.
    func stopChat() {
        guard let reader = chatReader else { return }
        chatStopped = true
        reader.cancel()
    }

    private var chatReader: Task<Void, Error>?
    private var chatStopped = false

    /// Reads a Gemma stream on the main actor and gives up if it goes quiet: `first` seconds to the
    /// first piece, then `stall` seconds between pieces. A stuck stream is cancelled (which also
    /// cancels the conversation and frees the engine) and surfaces as `GemmaError.stalled`.
    private func consume(_ stream: AsyncThrowingStream<String, Error>, first: Double, stall: Double,
                         register: ((Task<Void, Error>) -> Void)? = nil,
                         onPiece: @escaping @MainActor (String) -> Void) async throws {
        let progress = StreamProgress()
        let reader = Task { @MainActor in
            for try await piece in stream {
                progress.gotAny = true
                progress.last = Date()
                onPiece(piece)
            }
        }
        register?(reader)
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Date().timeIntervalSince(progress.last) > (progress.gotAny ? stall : first) {
                    progress.stalled = true
                    reader.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        try await reader.value
        if progress.stalled { throw GemmaError.stalled }
    }

    private func recordToolCall(_ name: String, args: String, result: String, ms: Double) {
        if let i = chat.lastIndex(where: { $0.role == .assistant }) { chat[i].toolCalls.append(name) }
        if name == "save_memory" {
            memoryFacts = memory.facts
            if let data = result.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["saved"] as? Bool == true, let fact = obj["fact"] as? String,
               let u = chat.lastIndex(where: { $0.role == .user }) {
                chat[u].remembered.append(fact)
            }
        }
        log(.tool, "\(name)(\(args))", String(result.prefix(600)), ms: ms)
    }

    func clearChat() async { newChat() }

    // MARK: memory

    func addMemory(_ text: String) {
        memory.add(text, source: "manual")
        memoryFacts = memory.facts
    }

    func deleteMemory(_ id: UUID) {
        memory.remove(id)
        memoryFacts = memory.facts
    }

    /// Deletes saved chats from disk. Health data goes with `health.wipe()`; memory with `memory.removeAll()`.
    private func wipeStoredData() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bolt/chats", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        log(.warning, "Reset everything", "Deleted chats, memory and the health database")
    }

    func resetEverything() {
        stopReplay()
        band.forget()
        memory.removeAll()
        memoryFacts = []
        cards = []
        chat = []
        currentThreadID = nil
        threads = []
        resetSession()
        wipeStoredData()
        source = .none
        UserDefaults.standard.removeObject(forKey: Self.lastSourceKey)
        profile = UserProfile()
        companionProfile = CompanionProfile()
        onboardingDone = false
        health.wipe()
        savedBaseline = nil
        robot.forget()
        for key in ["lastModel", "profile", "settings.speculative", "settings.cardsEnabled", "settings.preferGPU"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: ModelLocator.documents.appendingPathComponent("fitness-debug.jsonl"))
    }
}

@MainActor private final class StreamProgress {
    var last = Date()
    var gotAny = false
    var stalled = false
}
