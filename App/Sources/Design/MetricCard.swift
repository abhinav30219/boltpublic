import SwiftUI
import BoltCore

struct MetricCard: View {
    let icon: String          // SF Symbol name
    let label: String
    let value: String
    let unit: String?
    let meaning: Meaning
    let fill: Color
    var sparkline: [ScalarPoint]? = nil
    /// What VoiceOver says in place of `meaning.word` when the printed text reads badly aloud.
    var spokenMeaning: String? = nil

    init(icon: String, label: String, value: String, unit: String?, meaning: Meaning,
         fill: Color, sparkline: [ScalarPoint]? = nil, spokenMeaning: String? = nil) {
        self.icon = icon; self.label = label; self.value = value; self.unit = unit
        self.meaning = meaning; self.fill = fill; self.sparkline = sparkline
        self.spokenMeaning = spokenMeaning
    }

    var body: some View {
        StickerCard(fill: Color.metricFill(fill)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon).accessibilityHidden(true)
                    Text(label)
                }
                .typo(.label)

                // Unit sits beside the value, and drops below it when there is no room.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) { valueText; unitText }
                    VStack(alignment: .leading, spacing: 0) { valueText; unitText }
                }

                HStack(spacing: 4) {
                    Text(meaning.word)
                    Image(systemName: meaning.isAlert ? "exclamationmark.triangle.fill" : "checkmark")
                        .accessibilityHidden(true)
                }
                .typo(.label, size: 15)
                .foregroundStyle(meaning.isAlert ? Color.alertInk : Color.ink)

                if let sparkline, sparkline.count > 1 {
                    InkSparkline(points: sparkline).frame(height: 22).padding(.top, 4)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var valueText: some View {
        Text(value).typo(.number, size: 36).foregroundStyle(Color.numberStyle(icon: icon)).minimumScaleFactor(0.5).lineLimit(1)
    }

    @ViewBuilder private var unitText: some View {
        if let unit { Text(unit).typo(.label, size: 15) }
    }

    private var spokenLabel: String {
        let spokenUnit = unit.map { " " + Self.spoken(unit: $0) } ?? ""
        return "\(label), \(value)\(spokenUnit), \(spokenMeaning ?? meaning.word)"
    }

    static func spoken(unit: String) -> String {
        switch unit {
        case "bpm": return "beats per minute"
        case "ms": return "milliseconds"
        case "%": return "percent"
        case "°C": return "degrees Celsius"
        case "°F": return "degrees Fahrenheit"
        case "kcal": return "calories"
        default: return unit
        }
    }
}

private struct InkSparkline: View {
    let points: [ScalarPoint]
    var body: some View {
        GeometryReader { geo in
            let vals = points.map(\.value)
            let lo = vals.min() ?? 0, hi = vals.max() ?? 1
            let span = max(hi - lo, 0.0001)
            Path { p in
                for (i, v) in vals.enumerated() {
                    let pt = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(vals.count - 1, 1)),
                                     y: geo.size.height * (1 - CGFloat((v - lo) / span)))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            .stroke(Color.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Two columns normally, one column at accessibility text sizes so words never break mid-word.
struct MetricGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: cols, spacing: 12) { content }
            .padding(.trailing, Sticker.shadowOffset)
    }
}

#if DEBUG
extension MetricCard {
    static var sample: some View {
        let now = Date()
        let pts = [15, 14, 9, 5, 7, 12, 14, 15].enumerated().map {
            ScalarPoint(t: now.addingTimeInterval(Double($0.offset) * 60), value: Double($0.element))
        }
        return MetricGrid {
            MetricCard(icon: "heart.fill", label: "Heart", value: "72", unit: "bpm",
                       meaning: Meaning(word: "Calm"), fill: .fillHeart, sparkline: pts)
            MetricCard(icon: "figure.walk", label: "Steps", value: "3,240", unit: nil,
                       meaning: Meaning(word: "Good day"), fill: .fillSteps)
            MetricCard(icon: "flame.fill", label: "Energy", value: "146", unit: "kcal",
                       meaning: Meaning(word: "Active"), fill: .fillEnergy)
            MetricCard(icon: "lungs.fill", label: "Oxygen", value: "97", unit: "%",
                       meaning: Meaning(word: "Normal"), fill: .fillOxygen)
            MetricCard(icon: "thermometer.medium", label: "Skin temp", value: "33.1", unit: "°C",
                       meaning: Meaning(word: "Steady"), fill: .fillTemp)
            MetricCard(icon: "heart.fill", label: "Heart", value: "131", unit: "bpm",
                       meaning: Meaning(word: "Check", isAlert: true), fill: .fillHeart)
        }
    }
}
#endif

#Preview {
    MetricCard.sample.padding(16).background(ThemeBackground())
}
#Preview("Accessibility 3") {
    ScrollView { MetricCard.sample.padding(16) }.background(ThemeBackground())
        .dynamicTypeSize(.accessibility3)
}
