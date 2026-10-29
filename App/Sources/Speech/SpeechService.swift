import AVFoundation
import Speech

/// On-device dictation and read-aloud. Nothing is sent anywhere: recognition requires on-device support,
/// and when the device lacks it `isAvailable` is false so the UI hides the mic.
@MainActor
final class SpeechService: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {
    @Published private(set) var isListening = false
    @Published private(set) var isAvailable = false
    /// True while an utterance is being read aloud (published so the fall chime can pause for it).
    @Published private(set) var speaking = false
    /// True after the person denied Speech Recognition or Microphone access.
    @Published private(set) var permissionDenied = false
    /// Why the last dictation ended on its own (shown under the Chat field); nil after a normal stop.
    @Published private(set) var lastError: String?
    /// Trace hook, set by AppModel.
    var onLog: ((String, String) -> Void)?

    /// Speaking rate for read-aloud (AVSpeechUtterance scale, default voice).
    static let speechRate: Float = 0.45

    private let recognizer: SFSpeechRecognizer?
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Incremented per session; callbacks from older sessions are dropped.
    private var session = 0

    override init() {
        recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        super.init()
        recognizer?.delegate = self
        synth.delegate = self
        refreshAvailability()
    }

    private func refreshAvailability() {
        isAvailable = recognizer?.supportsOnDeviceRecognition == true && recognizer?.isAvailable == true
    }

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor in
            self.refreshAvailability()
            if !self.isAvailable { self.stop() }
        }
    }

    /// Starts listening; `onText` receives the running transcript. Does nothing when unavailable.
    func startDictation(onText: @escaping (String) -> Void) {
        guard isAvailable, !isListening else { return }
        stopSpeaking()
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                Task { @MainActor in self?.permissionDenied = true }
                return
            }
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted { self.permissionDenied = false; self.begin(onText) }
                    else { self.permissionDenied = true }
                }
            }
        }
    }

    /// Always safe to call, any number of times.
    func stop() {
        session += 1
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isListening = false
        // Leave the session active while an utterance is still being read aloud (e.g. the fall read-aloud).
        if !synth.isSpeaking {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// `loud`: slower and a little higher, for the fall re-ask and alarm. Plays through the speaker
    /// even with the ring switch on silent (playback category), at full utterance volume.
    func speak(_ text: String, loud: Bool = false) {
        stop()
        stopSpeaking()
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audio.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.rate = loud ? Self.speechRate * 0.9 : Self.speechRate
        u.volume = 1
        if loud { u.pitchMultiplier = 1.15 }
        synth.speak(u)
        speaking = true
    }

    var isSpeaking: Bool { synth.isSpeaking }

    func stopSpeaking() { synth.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = self.synth.isSpeaking; self.deactivatePlayback() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = self.synth.isSpeaking; self.deactivatePlayback() }
    }

    private func deactivatePlayback() {
        guard !synth.isSpeaking, !isListening else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Plain-language reason for a recognition error. 201/1101/1700: Siri & Dictation disabled or the
    /// on-device model is missing; 203/1110: no speech heard; 216/301: cancelled by a normal stop.
    private static func explain(_ e: NSError) -> String? {
        switch e.code {
        case 216, 301: return nil
        case 203, 1110: return "I didn't hear anything. Tap the mic and speak a little louder."
        case 201, 1101, 1700, 1107:   // 201 = kLSRErrorDomain "Siri and Dictation are disabled"
            return "Dictation isn't available on this iPhone yet. Turn on Enable Dictation in Settings › General › Keyboard, then try again."
        default: return "Dictation stopped (\(e.code)). Try again, or type your question."
        }
    }

    private func begin(_ onText: @escaping (String) -> Void) {
        guard let recognizer, !isListening else { return }
        stop() // clears any leftover tap or task, and starts a fresh session token
        let token = session
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isListening = true
            lastError = nil
            onLog?("Dictation started", "on-device, \(recognizer.locale.identifier)")
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true || error != nil
                let ns = error.map { $0 as NSError }
                Task { @MainActor in
                    guard let self, self.session == token else { return }
                    if let text { onText(text) }
                    if let ns {
                        self.onLog?("Dictation stopped with an error", "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
                        self.lastError = Self.explain(ns)
                    }
                    if finished { self.stop() }
                }
            }
        } catch {
            let ns = error as NSError
            onLog?("Dictation couldn't start the mic", "\(ns.domain) \(ns.code): \(ns.localizedDescription)")
            lastError = "The microphone couldn't start. Close other apps using it and try again."
            stop()
        }
    }
}
