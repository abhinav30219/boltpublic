import SwiftUI
import Charts
import BoltCore

struct Sparkline: View {
    let points: [ScalarPoint]
    var color: Color
    var fill: Color = .card
    var body: some View {
        Chart(Array(points.enumerated()), id: \.offset) { item in
            LineMark(x: .value("t", item.element.t), y: .value("v", item.element.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
    }
}

struct MetricTile: View {
    let title: String
    let symbol: String
    let value: String
    let unit: String
    var caption: String? = nil
    var color: Color
    var fill: Color = .card
    var series: [ScalarPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .typo(.label, size: 14)
                .foregroundStyle(Color.ink)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .typo(.number, size: 32)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit).typo(.body, size: 15).foregroundStyle(Color.inkSoft)
            }
            if series.count > 2 {
                Sparkline(points: series, color: color).frame(height: 28)
            } else {
                Spacer().frame(height: 28)
            }
            if let caption {
                Text(caption).typo(.body, size: 14).foregroundStyle(Color.inkSoft).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stickerPanel(fill: fill)
    }
}

func fmt(_ v: Double?, _ digits: Int = 0) -> String {
    guard let v else { return "--" }
    return digits == 0 ? "\(Int(v.rounded()))" : String(format: "%.\(digits)f", v)
}
