import SwiftUI
import Charts
import BoltCore

/// The five Home metrics (no HRV: the band never sends it), in display order.
enum HomeMetric: String, Identifiable, CaseIterable {
    case heart, steps, energy, oxygen, skinTemp
    var id: String { rawValue }

    var label: String {
        switch self {
        case .heart: return "Heart"
        case .steps: return "Steps"
        case .energy: return "Energy"
        case .oxygen: return "Oxygen"
        case .skinTemp: return "Skin temp"
        }
    }
    var icon: String {
        switch self {
        case .heart: return "heart.fill"
        case .steps: return "figure.walk"
        case .energy: return "flame.fill"
        case .oxygen: return "lungs.fill"
        case .skinTemp: return "thermometer.medium"
        }
    }
    var fill: Color {
        switch self {
        case .heart: return .fillHeart
        case .steps: return .fillSteps
        case .energy: return .fillEnergy
        case .oxygen: return .fillOxygen
        case .skinTemp: return .fillTemp
        }
    }
    var unit: String? {
        switch self {
        case .heart: return "bpm"
        case .steps: return nil
        case .energy: return "kcal"
        case .oxygen: return "%"
        case .skinTemp: return "°C"
        }
    }
    /// The stored series behind the metric, when there is one.
    var series: Metric? {
        switch self {
        case .heart: return .heartRate
        case .oxygen: return .spo2
        case .skinTemp: return .skinTemp
        case .steps, .energy: return nil
        }
    }
}

extension AppModel {
    /// Display value and plain-word meaning for a Home metric ("—" and "Waiting" when missing).
    func homeValue(_ m: HomeMetric) -> (value: String, meaning: Meaning) {
        let s = snapshot
        let waiting = Meaning(word: "Waiting")
        func f(_ v: Double, _ d: Int = 0) -> String { String(format: "%.\(d)f", v) }
        switch m {
        case .heart:
            guard let v = s.hr else { return ("—", waiting) }
            return (f(v), MetricMeaning.heart(v, baseline: s.baselineHR, tuning: tuning.companion))
        case .steps:
            // Steps and kcal are today's totals (earlier sessions plus this one), so they show even before live data.
            guard s.hasData || s.steps > 0 else { return ("—", waiting) }
            return (s.steps.formatted(), MetricMeaning.steps(s.steps, goal: tuning.companion.dailyStepGoal))
        case .energy:
            guard s.hasData || s.kcal > 0 else { return ("—", waiting) }
            return (f(s.kcal), MetricMeaning.energy(s.kcal, tuning: tuning.companion))
        case .oxygen:
            guard let v = s.spo2 else { return ("—", waiting) }
            return (f(v), MetricMeaning.oxygen(v, tuning: tuning.companion))
        case .skinTemp:
            guard let v = s.skinTemp else { return ("—", waiting) }
            return (f(v, 1), MetricMeaning.skinTemp(v, baseline: s.baselineSkinTemp, shift: tuning.companion.tempShiftC))
        }
    }
}

struct MetricDetailSheet: View {
    @EnvironmentObject var model: AppModel
    let metric: HomeMetric

    var body: some View {
        SheetStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let v = model.homeValue(metric)
                    MetricCard(icon: metric.icon, label: metric.label, value: v.value, unit: metric.unit,
                               meaning: v.meaning, fill: metric.fill)
                        .padding(.trailing, Sticker.shadowOffset)
                    if let series = metric.series {
                        chart("Last 5 minutes", series: series, since: Date().addingTimeInterval(-300))
                        chart("Today", series: series, since: Calendar.current.startOfDay(for: Date()))
                    } else {
                        Text("A chart for \(metric.label.lowercased()) is not kept yet. The number above is today's total so far.")
                            .typo(.body).foregroundStyle(Color.inkSoft)
                    }
                }
                .padding(16)
            }
            .background(ThemeBackground())
            .navigationTitle(metric.label)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func chart(_ title: String, series: Metric, since: Date) -> some View {
        let pts = model.store.points(series, since: since)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).typo(.heading, size: 22)
            if pts.count < 2 {
                Text("Not enough readings yet.").typo(.body).foregroundStyle(Color.inkSoft)
            } else {
                Chart(pts, id: \.t) { p in
                    LineMark(x: .value("Time", p.t), y: .value(metric.label, p.value))
                        .foregroundStyle(Color.ink)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(); AxisValueLabel().font(.system(size: 14))
                } }
                .chartYAxis { AxisMarks { _ in AxisGridLine(); AxisValueLabel().font(.system(size: 14)) } }
                .frame(height: 180)
                .accessibilityLabel("\(title) chart for \(metric.label)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.line, lineWidth: Sticker.border))
        .padding(.trailing, Sticker.shadowOffset)
    }
}
