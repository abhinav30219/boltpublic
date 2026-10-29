import SwiftUI
import BoltCore

/// The day as one bar. Only real data is painted: still activity as Resting, any moving activity
/// as Walking. Times with no data (before the session, band off) and the future stay blank.
/// The bar spans 24 h from `dayStart`.
struct DayTimeline: View {
    typealias Segment = (start: Date, end: Date, activity: ActivityClass)
    let segments: [Segment]
    let dayStart: Date
    let now: Date

    init(segments: [(start: Date, end: Date, activity: ActivityClass)], dayStart: Date, now: Date) {
        self.segments = segments; self.dayStart = dayStart; self.now = now
    }

    private let daySeconds: TimeInterval = 24 * 3600

    private func fraction(_ d: Date) -> CGFloat {
        CGFloat(min(max(d.timeIntervalSince(dayStart) / daySeconds, 0), 1))
    }

    private func color(_ a: ActivityClass) -> Color {
        a == .stationary ? .dayRest : .dayWalk
    }

    var body: some View {
        StickerCard {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let w = geo.size.width, nowX = w * fraction(now)
                    ZStack(alignment: .leading) {
                        Color.card
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                            let x0 = w * fraction(min(s.start, now)), x1 = w * fraction(min(s.end, now))
                            color(s.activity).frame(width: max(x1 - x0, 0)).offset(x: x0)
                        }
                        Rectangle().fill(Color.ink).frame(width: 3).offset(x: max(nowX - 1.5, 0))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.ink, lineWidth: 2.5))
                }
                .frame(height: 26)

                ViewThatFits(in: .horizontal) {
                    ticks([0, 6, 12, 18])
                    ticks([0, 12])
                }
                .typo(.label, size: 14).foregroundStyle(Color.inkSoft)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { legendItems }
                    VStack(alignment: .leading, spacing: 6) { legendItems }
                }
                .typo(.label, size: 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private func ticks(_ hours: [Int]) -> some View {
        HStack {
            ForEach(hours, id: \.self) { h in
                Text(tick(hours: h)).lineLimit(1).fixedSize()
                if h != hours.last { Spacer(minLength: 16) }
            }
        }
    }

    @ViewBuilder private var legendItems: some View {
        legend("Resting", .dayRest); legend("Walking", .dayWalk)
    }

    private func tick(hours: Int) -> String {
        dayStart.addingTimeInterval(Double(hours) * 3600)
            .formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }

    private func legend(_ name: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4).fill(c).frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.ink, lineWidth: 2))
            Text(name).lineLimit(1).fixedSize()
        }
    }

    private var spokenSummary: String {
        let walking = segments.filter { $0.activity != .stationary }
            .reduce(0.0) { $0 + min($1.end, now).timeIntervalSince($1.start) }
        return "Your day. Walking for about \(Int(walking / 60)) minutes so far. Times with no data are left blank."
    }
}

#if DEBUG
extension DayTimeline {
    static var sample: DayTimeline {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        func t(_ h: Double) -> Date { start.addingTimeInterval(h * 3600) }
        return DayTimeline(segments: [
            (t(6.5), t(8), .stationary), (t(8), t(8.4), .walk), (t(8.4), t(9.5), .stationary),
            (t(9.5), t(9.8), .walk), (t(9.8), t(11), .stationary),
        ], dayStart: start, now: t(11))
    }
}
#endif

#Preview { DayTimeline.sample.padding(16).background(Color.paper) }
#Preview("Accessibility 3") {
    DayTimeline.sample.padding(16).background(Color.paper).dynamicTypeSize(.accessibility3)
}
