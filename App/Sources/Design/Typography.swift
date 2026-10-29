import SwiftUI
import UIKit

/// The single place to swap fonts later (e.g. bundled Fredoka / Atkinson Hyperlegible).
enum Typo {
    enum Style {
        case heading, number, body, label

        var textStyle: Font.TextStyle {
            switch self {
            case .heading: return .title2
            case .number: return .largeTitle
            case .body: return .body
            case .label: return .callout
            }
        }
        var uiTextStyle: UIFont.TextStyle {
            switch self {
            case .heading: return .title2
            case .number: return .largeTitle
            case .body: return .body
            case .label: return .callout
            }
        }
        var defaultSize: CGFloat {
            switch self {
            case .heading: return 27
            case .number: return 38
            case .body: return 18
            case .label: return 16
            }
        }
        func font(size: CGFloat) -> Font {
            switch self {
            case .heading: return .system(size: size, weight: .bold, design: .rounded)
            case .number: return .system(size: size, weight: .bold, design: .rounded)
            case .body: return .system(size: size, weight: .regular)
            case .label: return .system(size: size, weight: .bold)
            }
        }
    }

    // These follow the device's Dynamic Type setting. Views that must also respond to a
    // `.dynamicTypeSize` override in the environment use `.typo(_:size:)` instead.
    static func heading(_ size: CGFloat = 27) -> Font { scaled(.heading, size) }
    static func number(_ size: CGFloat = 38) -> Font { scaled(.number, size) }
    static func body(_ size: CGFloat = 18) -> Font { scaled(.body, size) }
    static func label(_ size: CGFloat = 16) -> Font { scaled(.label, size) }

    private static func scaled(_ style: Style, _ size: CGFloat) -> Font {
        style.font(size: UIFontMetrics(forTextStyle: style.uiTextStyle).scaledValue(for: size))
    }
}

private struct TypoModifier: ViewModifier {
    let style: Typo.Style
    @ScaledMetric private var size: CGFloat

    init(style: Typo.Style, size: CGFloat) {
        self.style = style
        _size = ScaledMetric(wrappedValue: size, relativeTo: style.textStyle)
    }

    func body(content: Content) -> some View { content.font(style.font(size: size)) }
}

extension View {
    /// Sticker Book font that scales with the environment's Dynamic Type size.
    func typo(_ style: Typo.Style, size: CGFloat? = nil) -> some View {
        modifier(TypoModifier(style: style, size: size ?? style.defaultSize))
    }
}
