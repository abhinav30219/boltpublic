import SwiftUI
import BoltCore

extension TriggerKind {
    var color: Color {
        switch self {
        case .exertion: return .coral
        case .recovery: return .dayWalk
        case .elevatedAtRest: return Color(hex: 0xFFC857)
        case .activityChange: return Color(hex: 0x8B6CF6)
        case .skinTempShift: return Color(hex: 0x36C2A0)
        case .bandOff: return .inkSoft
        case .safety: return .alertInk
        case .workoutFinished: return .dayWalk
        case .fall: return .alertInk
        case .wave: return .coral
        case .moment: return Color(hex: 0x8B6CF6)
        }
    }
}

func msLabel(_ ms: Double?) -> String {
    guard let ms else { return "" }
    return ms < 1000 ? "\(Int(ms)) ms" : String(format: "%.1f s", ms / 1000)
}
