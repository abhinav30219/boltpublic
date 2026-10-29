import Foundation
import LiteRTLM
import BoltCore

/// Finds .litertlm files the user copied into the app's Documents folder (Finder > iPhone > Files > Bolt)
/// or that were bundled with the app.
enum ModelLocator {
    struct ModelFile: Identifiable, Hashable {
        var url: URL
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        var sizeGB: Double {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
            return bytes / 1_000_000_000
        }
        var isGPUBuild: Bool { name.contains("-gpu") }
        var isE2B: Bool { name.lowercased().contains("e2b") }
        var displayName: String {
            var s = name.contains("E4B") ? "Gemma 4 E4B" : name.contains("E2B") ? "Gemma 4 E2B" : name.lowercased().contains("medgemma") ? "MedGemma 1.5 4B" : name
            s += isGPUBuild ? " · GPU" : " · CPU"
            return s
        }
    }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Where models live: Library/Application Support/Models. Survives app updates, isn't shown in Files,
    /// and nothing that writes into Documents (Finder, devicectl, our own logs) can touch it.
    static var modelsDir: URL {
        let fm = FileManager.default
        var url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true   // 4.6 GB has no business in iCloud backups
        try? url.setResourceValues(values)
        return url
    }

    /// Run before listing models. Repairs Documents if something replaced the folder with a file,
    /// then moves any model dropped into Documents (Finder > Files > Bolt) into `modelsDir`.
    /// Returns one line per thing it did, for the trace.
    @discardableResult
    static func prepare() -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: documents.path, isDirectory: &isDir), !isDir.boolValue {
            let aside = modelsDir.deletingLastPathComponent().appendingPathComponent("Documents-was-a-file-\(Int(Date().timeIntervalSince1970))")
            do {
                try fm.moveItem(at: documents, to: aside)
                notes.append("Documents had been replaced by a file; moved it to \(aside.lastPathComponent)")
            } catch {
                notes.append("Documents is a file, not a folder, and couldn't be repaired: \(error.localizedDescription)")
            }
        }
        if !fm.fileExists(atPath: documents.path) { try? fm.createDirectory(at: documents, withIntermediateDirectories: true) }

        let dest = modelsDir
        let items = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for src in items where src.pathExtension == "litertlm" {
            // Leave a file alone while Finder may still be copying it in.
            let modified = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) < 15 { notes.append("Waiting for \(src.lastPathComponent) to finish copying"); continue }
            let target = dest.appendingPathComponent(src.lastPathComponent)
            do {
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: src, to: target)   // same volume: a rename, instant even for 2.6 GB
                notes.append("Moved \(src.lastPathComponent) into app storage")
            } catch {
                notes.append("Couldn't move \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return notes
    }

    static func available() -> [ModelFile] {
        var urls: [URL] = []
        for dir in [modelsDir, documents] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            urls += items.filter { $0.pathExtension == "litertlm" }
        }
        urls += Bundle.main.urls(forResourcesWithExtension: "litertlm", subdirectory: nil) ?? []
        var seen = Set<String>()
        let files = urls.filter { seen.insert($0.lastPathComponent).inserted }.map { ModelFile(url: $0) }
        // Best first: E2B GPU, E2B CPU, then the rest.
        return files.sorted { a, b in
            func score(_ m: ModelFile) -> Int { (m.isE2B ? 0 : 10) + (m.isGPUBuild ? 0 : 1) + (m.name.lowercased().contains("medgemma") ? 20 : 0) }
            return score(a) < score(b)
        }
    }
}

struct EngineStats: Equatable {
    var loadSeconds: Double?
    var lastFirstTokenMs: Double?
    var lastTotalMs: Double?
    var lastTokensPerSecond: Double?
    var backend: String = ""
    var modelName: String = ""
}

/// One LiteRT-LM engine, loaded once, shared by every "agent" (card writer, chat). Agents are just
/// conversations with different system prompts and tools; they share the weights in memory.
actor GemmaService {
    enum State: Equatable { case idle, loading, ready, failed(String) }

    private var engine: Engine?
    private(set) var state: State = .idle
    private(set) var stats = EngineStats()
    /// One conversation on the engine at a time. Cards and chat used to overlap (a long-lived chat
    /// conversation plus a fresh one per card); on the phone's GPU that could leave chat stuck on
    /// "Thinking" forever. Now every generation holds this lock until its stream ends.
    /// The latest conversation (card, chat or summary), kept so LiteRT-LM never frees it itself.
    /// Same cause Shobhit found for cards on main (7fb3569): if a stream's final callback drops the last
    /// reference, `Conversation.deinit` runs on LiteRT-LM's callback thread, waits on that same thread,
    /// times out (DEADLINE_EXCEEDED in 'callback_thread_pool') and every later generation stalls. That
    /// matches the "engine went silent" we saw on the phone. Generations are serialized by the lock
    /// below, so one slot is enough: the next conversation replaces (and frees) the previous one here.
    private var retainedConversation: Conversation?
    private var engineBusy = false { didSet { if engineBusy != oldValue { onBusyChange?() } } }
    /// Tells the app when the engine goes busy or idle (it drives the renderer's frame budget).
    private var onBusyChange: (@Sendable () -> Void)?
    func setBusyObserver(_ f: (@Sendable () -> Void)?) { onBusyChange = f }
    var isBusy: Bool { engineBusy }
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    /// How long a chat waits for the engine before giving up with `busy`.
    private let acquireTimeout: TimeInterval = 10

    /// Waits for the engine, but only up to `timeout`; a stuck holder must not hang the next caller.
    private func acquire(timeout: TimeInterval) async throws {
        if !engineBusy { engineBusy = true; return }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { await self?.expireWaiter(id) }
        }
        let got: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                waiters.append((id: id, continuation: cont))   // ownership is handed over in release()
            }
        } onCancel: {
            Task { [weak self] in await self?.expireWaiter(id) }
        }
        timer.cancel()
        if !got { throw GemmaError.busy }
    }

    private func expireWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(returning: false)
    }

    private func tryAcquire() -> Bool {
        if engineBusy { return false }
        engineBusy = true
        return true
    }

    fileprivate func release() {
        AppModel.appendTraceFile("gemma | engine released (queued=\(waiters.count))")
        if waiters.isEmpty { engineBusy = false } else { waiters.removeFirst().continuation.resume(returning: true) }
    }

    var isReady: Bool { state == .ready }

    /// Loads the model. The first load compiles GPU shaders and can take tens of seconds;
    /// the cache directory makes later launches fast.
    func load(_ model: ModelLocator.ModelFile, preferGPU: Bool = true, speculativeDecoding: Bool = false) async throws {
        state = .loading
        retainedConversation = nil   // free the old engine's last conversation here, before replacing it
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("litertlm", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        if speculativeDecoding && model.isGPUBuild { ExperimentalFlags.enableSpeculativeDecoding = true }
        let useGPU = preferGPU && model.isGPUBuild
        let t0 = Date()
        do {
            let config = try EngineConfig(modelPath: model.url.path, backend: useGPU ? .gpu : .cpu(), maxNumTokens: 4096, cacheDir: cache.path)
            let e = Engine(engineConfig: config)
            try await e.initialize()
            engine = e
            stats = EngineStats(loadSeconds: Date().timeIntervalSince(t0), backend: useGPU ? "GPU (Metal)" : "CPU", modelName: model.displayName)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func sampler(_ temperature: Float) -> SamplerConfig? {
        try? SamplerConfig(topK: 40, topP: 0.95, temperature: temperature)
    }

    /// Streams a card. Each card is a fresh, short conversation so history never grows.
    /// Cards never wait: if chat is using the engine, this throws `busy` and the caller shows the template.
    func streamCard(system: String, user: String, maxTokens: Int = 45) async throws -> AsyncThrowingStream<String, Error> {
        guard let engine else { throw GemmaError.notLoaded }
        guard tryAcquire() else { throw GemmaError.busy }
        do {
            let config = ConversationConfig(systemMessage: Message(system, role: .system), samplerConfig: sampler(0.3),
                                            thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0))
            let conversation = try await engine.createConversation(with: config)
            retainedConversation = conversation
            AppModel.appendTraceFile("gemma | card conversation created")
            let stream = conversation.sendMessageStream(Message(user), maxOutputTokens: maxTokens,
                                                        thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0))
            return mapStream(stream, conversation: conversation)
        } catch {
            AppModel.appendTraceFile("gemma | card setup failed: \(error)")
            release()
            throw error
        }
    }

    /// Folds old chat turns into a running summary. Never waits: returns nil if the engine is busy.
    func summarize(system: String, user: String) async -> String? {
        guard let engine, tryAcquire() else { return nil }
        let releaser = Releaser(service: self)
        let box = SummarizeBox()
        let sampler = sampler(0.2)
        // The stream is raced against a timer that does not depend on chunks arriving: on timeout the
        // conversation is cancelled and the engine lock is released even if the stream never yields.
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            box.continuation = cont
            let work = Task {
                do {
                    let config = ConversationConfig(systemMessage: Message(system, role: .system), samplerConfig: sampler,
                                                    thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0))
                    let conversation = try await engine.createConversation(with: config)
                    box.conversation = conversation
                    await self.retain(conversation)
                    for try await chunk in conversation.sendMessageStream(Message(user), maxOutputTokens: 140,
                                                                          thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0)) {
                        box.append(chunk.toString)
                    }
                    box.finish(box.text)
                } catch {
                    box.finish(nil)
                }
                await releaser.fire()
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                AppModel.appendTraceFile("gemma | summarize timed out, cancelling")
                try? box.conversation?.cancel()
                work.cancel()
                box.finish(box.text.isEmpty ? nil : box.text)
                await releaser.fire()
            }
            box.onFinish = { timer.cancel() }
        }
    }

    private func retain(_ c: Conversation) { retainedConversation = c }

    /// Each question gets a fresh conversation (with tools) that is closed when the answer ends,
    /// so nothing stays open on the engine between questions. The chat's context (memories, summary,
    /// recent turns) arrives already folded into `system` by the app.
    func streamChat(system: String, user: String, tools: [Tool], maxTokens: Int = 220) async throws -> AsyncThrowingStream<String, Error> {
        guard let engine else { throw GemmaError.notLoaded }
        AppModel.appendTraceFile("gemma | chat waiting for engine (busy=\(engineBusy), queued=\(waiters.count))")
        do { try await acquire(timeout: acquireTimeout) } catch {
            AppModel.appendTraceFile("gemma | chat gave up waiting for engine")
            throw error
        }
        AppModel.appendTraceFile("gemma | chat has engine")
        do {
            let prompt = system
            let config = ConversationConfig(systemMessage: Message(prompt, role: .system), tools: tools, samplerConfig: sampler(0.4),
                                            thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0))
            let conversation = try await engine.createConversation(with: config)
            retainedConversation = conversation
            AppModel.appendTraceFile("gemma | chat conversation created, system prompt \(prompt.count) chars, \(tools.count) tools")
            let stream = conversation.sendMessageStream(Message(user), maxOutputTokens: maxTokens,
                                                        thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0))
            return mapStream(stream, conversation: conversation)
        } catch {
            AppModel.appendTraceFile("gemma | chat setup failed: \(error)")
            release()
            throw error
        }
    }

    /// Forwards text and releases the engine lock exactly once, however the stream ends
    /// (finished, failed, or cancelled by the caller's timeout or Stop button).
    private func mapStream(_ stream: AsyncThrowingStream<Message, Error>, conversation: Conversation) -> AsyncThrowingStream<String, Error> {
        let releaser = Releaser(service: self)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        let text = chunk.toString
                        AppModel.appendTraceFile("gemma | chunk: \(text.prefix(120))")
                        if !text.isEmpty { continuation.yield(text) }
                    }
                    if let info = try? conversation.getBenchmarkInfo() {
                        await self.record(info)
                    }
                    continuation.finish()
                } catch {
                    AppModel.appendTraceFile("gemma | stream error: \(error)")
                    continuation.finish(throwing: error)
                }
                AppModel.appendTraceFile("gemma | stream ended, releasing engine")
                await releaser.fire()
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    try? conversation.cancel()
                    task.cancel()
                    Task { await releaser.fire() }
                }
            }
        }
    }

    private func record(_ info: BenchmarkInfo) {
        stats.lastFirstTokenMs = info.timeToFirstTokenInSecond * 1000
        stats.lastTokensPerSecond = info.lastDecodeTokensPerSecond
    }

    func noteTotal(ms: Double) { stats.lastTotalMs = ms }
}

/// Shared state between summarize's stream task and its timeout task; resumes the caller exactly once.
private final class SummarizeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private var finished = false
    var continuation: CheckedContinuation<String?, Never>?
    var conversation: Conversation? {
        get { lock.withLock { _conversation } }
        set { lock.withLock { _conversation = newValue } }
    }
    private var _conversation: Conversation?
    var onFinish: (() -> Void)? {
        get { lock.withLock { _onFinish } }
        set {
            let already = lock.withLock { () -> Bool in _onFinish = newValue; return finished }
            if already { newValue?() }
        }
    }
    private var _onFinish: (() -> Void)?
    var text: String { lock.withLock { _text } }
    func append(_ t: String) { lock.withLock { _text += t } }
    func finish(_ result: String?) {
        let (cont, cb): (CheckedContinuation<String?, Never>?, (() -> Void)?) = lock.withLock {
            if finished { return (nil, nil) }
            finished = true
            let c = continuation; continuation = nil
            return (c, _onFinish)
        }
        cont?.resume(returning: result)
        cb?()
    }
}

/// Makes sure a stream gives the engine back exactly once.
private actor Releaser {
    let service: GemmaService
    private var done = false
    init(service: GemmaService) { self.service = service }
    func fire() async {
        guard !done else { return }
        done = true
        await service.release()
    }
}

enum GemmaError: LocalizedError {
    case notLoaded, busy, stalled
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Gemma isn't loaded yet."
        case .busy: return "Gemma is busy answering a question."
        case .stalled: return "Gemma stopped responding. Try asking again."
        }
    }
}
