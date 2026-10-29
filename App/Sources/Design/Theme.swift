import SwiftUI

/// The app's look. Sticker Book is the original; the other two restyle every screen through the colour tokens.
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case stickerBook, candyPop, cozyNight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stickerBook: return "Sticker Book"
        case .candyPop: return "Candy Pop"
        case .cozyNight: return "Cozy Night"
        }
    }

    var blurb: String {
        switch self {
        case .stickerBook: return "Warm paper, bold outlines"
        case .candyPop: return "Soft pastel gradients"
        case .cozyNight: return "Dark and calm, easy on the eyes"
        }
    }

    func pick<T>(_ sticker: T, _ candy: T, _ night: T) -> T {
        switch self {
        case .stickerBook: return sticker
        case .candyPop: return candy
        case .cozyNight: return night
        }
    }

    var colorScheme: ColorScheme { self == .cozyNight ? .dark : .light }
}

/// The theme every colour token reads. The app sets it from the profile and rebuilds the view tree when it changes.
enum ThemeStore {
    static var current: AppTheme = .stickerBook
}

private func pick<T>(_ s: T, _ c: T, _ n: T) -> T { ThemeStore.current.pick(s, c, n) }

/// The screen background: paper, the Candy gradient, or the Night glow with a few faint stars.
struct ThemeBackground: View {
    var theme: AppTheme = ThemeStore.current
    var fullScreen = true

    var body: some View {
        Group {
            switch theme {
            case .stickerBook:
                Color(hex: 0xFFF6E9)
            case .candyPop:
                LinearGradient(stops: [.init(color: Color(hex: 0xFFD6C4), location: 0),
                                       .init(color: Color(hex: 0xFFC6DA), location: 0.45),
                                       .init(color: Color(hex: 0xD8C8FF), location: 1)],
                               startPoint: UnitPoint(x: 0.4, y: 0), endPoint: UnitPoint(x: 0.6, y: 1))
            case .cozyNight:
                ZStack {
                    RadialGradient(stops: [.init(color: Color(hex: 0x4A3670), location: 0),
                                           .init(color: Color(hex: 0x2A1F3D), location: 0.6),
                                           .init(color: Color(hex: 0x1E1630), location: 1)],
                                   center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 620)
                    Stars()
                }
            }
        }
        .ignoresSafeArea(edges: fullScreen ? .all : [])
    }
}

private struct Stars: View {
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<14 {
                let x = abs(sin(Double(i) * 12.9898)) * size.width
                let y = abs(sin(Double(i) * 78.233 + 1.7)) * size.height * 0.8
                let r = 1.0 + Double(i % 3) * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color(Color(hex: 0xFFF1E6).opacity(0.25 + 0.1 * Double(i % 3))))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Bar behind the chat composer: paper on Sticker Book, blurred glass on the other themes.
struct ThemeBarBackground: View {
    var body: some View {
        if ThemeStore.current == .stickerBook { Color.paper } else { Rectangle().fill(.ultraThinMaterial) }
    }
}

extension Color {
    // Text and surfaces.
    static var paper: Color { pick(Color(hex: 0xFFF6E9), Color.white.opacity(0.55), Color.white.opacity(0.06)) }
    static var ink: Color { pick(Color(hex: 0x2B1D18), Color(hex: 0x3A2763), Color(hex: 0xFFF1E6)) }
    /// Ink at reduced strength for secondary text. Still above 4.5:1 on every theme's surfaces.
    static var inkSoft: Color { ink.opacity(0.78) }
    static var card: Color { pick(Color.white, Color.white.opacity(0.75), Color.white.opacity(0.07)) }
    static var line: Color { pick(Color(hex: 0x2B1D18), Color.clear, Color.white.opacity(0.12)) }
    /// Buttons and primary fills. Text on it uses `ink`, so it stays dark enough (or light enough) for that.
    static var coral: Color { pick(Color(hex: 0xFF7F6E), Color(hex: 0xFF6FA5), Color(hex: 0xB0295F)) }
    /// Tint for switches, tab selection and links.
    static var accent: Color { pick(Color(hex: 0xFF7F6E), Color(hex: 0x9A4DDB), Color(hex: 0x9BF0D2)) }
    static var alertInk: Color { pick(Color(hex: 0xB3261E), Color(hex: 0xB3261E), Color(hex: 0xFF9E96)) }
    /// Shadow colour for glyphs drawn over the 3D view.
    static var overlayInk: Color { pick(Color(hex: 0x2B1D18), Color(hex: 0x3A2763), Color(hex: 0x1E1630)) }

    // Chips.
    static var chipOk: Color { pick(Color(hex: 0xCFF2E6), Color.white.opacity(0.6), Color(hex: 0x9BF0D2).opacity(0.18)) }
    static var chipOff: Color { card }

    // Speech bubble.
    static var bubbleFill: Color { pick(Color.white, Color.white.opacity(0.85), Color(hex: 0xFFF1E6)) }
    static var bubbleText: Color { pick(Color(hex: 0x2B1D18), Color(hex: 0x3A2763), Color(hex: 0x2A1F3D)) }

    // Card fills used by rows, buttons and chips.
    static var fillHeart: Color { pick(Color(hex: 0xFFD3CC), Color(hex: 0xFFD3CC), Color(hex: 0xFF9EB0).opacity(0.22)) }
    static var fillSteps: Color { pick(Color(hex: 0xCFF2E6), Color(hex: 0xCFF2E6), Color(hex: 0x9BF0D2).opacity(0.22)) }
    static var fillEnergy: Color { pick(Color(hex: 0xFFE7A8), Color(hex: 0xFFE7A8), Color(hex: 0xFFD27A).opacity(0.22)) }
    static var fillRelax: Color { pick(Color(hex: 0xE2D9FF), Color(hex: 0xE2D9FF), Color(hex: 0xC7B6FF).opacity(0.24)) }
    static var fillOxygen: Color { pick(Color(hex: 0xD6ECFF), Color(hex: 0xD6ECFF), Color(hex: 0x9CCBFF).opacity(0.22)) }
    static var fillTemp: Color { pick(Color(hex: 0xFFE0EC), Color(hex: 0xFFE0EC), Color(hex: 0xFFB8D6).opacity(0.22)) }
    static var fillActivity: Color { pick(Color(hex: 0xFFD9B8), Color(hex: 0xFFD9B8), Color(hex: 0xFFB88A).opacity(0.22)) }

    // Day timeline.
    static var daySleep: Color { pick(Color(hex: 0xE2D9FF), Color(hex: 0xD8C8FF), Color(hex: 0x4E3F7A)) }
    static var dayRest: Color { pick(Color(hex: 0xFFF6E9), Color(hex: 0xFFEFF5), Color(hex: 0x3A2D52)) }
    static var dayWalk: Color { pick(Color(hex: 0x7ED9B5), Color(hex: 0x7ED9B5), Color(hex: 0x9BF0D2)) }

    /// Metric cards share one surface on Candy and Night; Sticker Book keeps its per-metric colours.
    static func metricFill(_ fill: Color) -> Color { ThemeStore.current == .stickerBook ? fill : card }

    /// Colour (or gradient) of a big metric value.
    static func numberStyle(icon: String) -> AnyShapeStyle {
        switch ThemeStore.current {
        case .stickerBook:
            return AnyShapeStyle(Color.ink)
        case .candyPop:
            return AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xE2437F), Color(hex: 0x7B5CE6)],
                                                startPoint: .leading, endPoint: .trailing))
        case .cozyNight:
            let hex: UInt32
            if icon.hasPrefix("heart") { hex = 0xFF9EB0 }
            else if icon.contains("walk") || icon.contains("figure") { hex = 0x9BF0D2 }
            else if icon.hasPrefix("flame") { hex = 0xFFD27A }
            else if icon.hasPrefix("lungs") || icon.hasPrefix("waveform") { hex = 0xC7B6FF }
            else { hex = 0xFFB8D6 }
            return AnyShapeStyle(Color(hex: hex))
        }
    }
}

enum Sticker {
    static var border: CGFloat { pick(3, 0, 1) }
    /// Borders on small things: chips, icon circles, the read-aloud button.
    static var smallBorder: CGFloat { pick(2, 0, 1) }
    static var shadowOffset: CGFloat { pick(4, 0, 0) }
    static let minButtonHeight: CGFloat = 64
}

/// Fill, border and shadow of every card, button and bubble, per theme.
private struct ThemedSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    let glow: Bool

    func body(content: Content) -> some View {
        switch ThemeStore.current {
        case .stickerBook:
            content
                .background(fill, in: shape)
                .overlay(shape.strokeBorder(Color.ink, lineWidth: 3))
                .background(shape.fill(Color.ink).offset(x: 4, y: 4))
        case .candyPop:
            content
                .background { shape.fill(fill).shadow(color: Color(hex: 0x783CA0).opacity(0.14), radius: 16, x: 0, y: 6) }
        case .cozyNight:
            content
                .background { shape.fill(fill).shadow(color: glow ? Color(hex: 0xFFF1E6).opacity(0.28) : .clear, radius: 14) }
                .overlay(shape.strokeBorder(Color.line, lineWidth: 1))
        }
    }
}

extension View {
    func themedSurface<S: InsettableShape>(_ shape: S, fill: Color, glow: Bool = false) -> some View {
        modifier(ThemedSurface(shape: shape, fill: fill, glow: glow))
    }
}

extension Color {
    /// Placeholder text: the system default on Sticker Book, soft ink on the other themes so it stays readable.
    static func softPrompt(_ text: String) -> Text? {
        ThemeStore.current == .stickerBook ? nil : Text(text).foregroundColor(Color.inkSoft)
    }
}
