import UIKit

extension UIColor {
    /// 0xRRGGBB
    convenience init(companionHex hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum BodyPalette: String, Codable, CaseIterable {
    case peach, mint, lavender

    var shell: UIColor { UIColor(companionHex: hexes.shell) }
    var joint: UIColor { UIColor(companionHex: hexes.joint) }
    var limb: UIColor { UIColor(companionHex: hexes.limb) }
    var foot: UIColor { UIColor(companionHex: hexes.foot) }

    var title: String {
        switch self {
        case .peach: return "Peach"
        case .mint: return "Mint"
        case .lavender: return "Lavender"
        }
    }

    private var hexes: (shell: UInt32, joint: UInt32, limb: UInt32, foot: UInt32) {
        switch self {
        case .peach: return (0xFFF1E2, 0xFF7F6E, 0xFFB48F, 0x6FCFB0)
        case .mint: return (0xE9FFF6, 0x36C2A0, 0x9BE7CF, 0xFFC857)
        case .lavender: return (0xF4EEFF, 0x8B6CF6, 0xC7B6FF, 0xFF9EC4)
        }
    }
}

enum FaceStyle: String, Codable, CaseIterable {
    case roundDots, sleepyArcs, sparkly, pixelLED

    var title: String {
        switch self {
        case .roundDots: return "Round dots"
        case .sleepyArcs: return "Sleepy arcs"
        case .sparkly: return "Sparkly"
        case .pixelLED: return "Pixel LED"
        }
    }

    var defaultEyeColor: UIColor {
        switch self {
        case .roundDots: return UIColor(companionHex: 0x8FF0FF)
        case .sleepyArcs: return UIColor(companionHex: 0xFFE9A8)
        case .sparkly: return UIColor(companionHex: 0xFFC2EA)
        case .pixelLED: return UIColor(companionHex: 0x7CFF9E)
        }
    }
}

struct Appearance: Codable, Equatable {
    var palette: BodyPalette = .peach
    var face: FaceStyle = .roundDots
}
