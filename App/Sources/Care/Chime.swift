import AudioToolbox
import Foundation

/// Plays a system sound on a fixed interval until stopped. Used by the escalated fall screen.
@MainActor
final class Chime {
    private var timer: Timer?
    private let soundID: SystemSoundID
    private let interval: TimeInterval

    init(soundID: SystemSoundID = 1005, interval: TimeInterval = 2) {
        self.soundID = soundID; self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        AudioServicesPlaySystemSound(soundID)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [soundID] _ in
            AudioServicesPlaySystemSound(soundID)
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    deinit { timer?.invalidate() }
}
