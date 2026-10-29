import SwiftUI
import BoltCore

/// Live view of what the fall and gesture detectors see, for testing on the band.
struct MotionTestView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            List {
                Section {
                    LabeledContent("Accelerometer", value: model.fallDetector.estimatedRateHz > 0
                                   ? String(format: "%.0f Hz", model.fallDetector.estimatedRateHz) : "no data yet")
                    LabeledContent("Right now", value: String(format: "%.2f g", model.store.accel.last?.magnitude ?? 0))
                    LabeledContent("Hardest hit this session", value: String(format: "%.1f g", model.fallDetector.maxMagnitudeSeen))
                } footer: { Text("Resting should read close to 1.00 g. The band's encoding tops out at about 3.3 g per axis.") }

                Section {
                    let ds = model.fallDetector.recentDecisions.reversed()
                    if ds.isEmpty { Text("No impacts over 2 g yet.").foregroundStyle(.secondary) }
                    ForEach(Array(ds.enumerated()), id: \.offset) { _, d in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(d.isFall ? "Fall" : "Not a fall").font(.headline).foregroundStyle(d.isFall ? .red : .primary)
                                Spacer()
                                Text(String(format: "p = %.2f", d.probability)).monospacedDigit()
                            }
                            Text(String(format: "impact %.1f g · wrist turned %.0f° · stillness %.2f g · energy %.2f · moving before %.2f g",
                                        d.features.peak, d.features.turn, d.features.postSD, d.features.energy, d.features.preSD))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(d.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                } header: { Text("Impacts judged by the fall model") } footer: {
                    Text("Every spike over 2 g is judged 3 s later. A fall needs p ≥ 0.50: a hard hit, the wrist ending up turned, lying still afterwards, and calm before.")
                }

                Section {
                    let bs = model.gestureDetector.recentBursts.reversed()
                    if bs.isEmpty { Text("No movement bursts yet.").foregroundStyle(.secondary) }
                    ForEach(Array(bs.enumerated()), id: \.offset) { _, b in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.verdict.capitalized).font(.headline)
                            Text(String(format: "%.1f s · %.1f cycles at %.1f Hz · %.1f g swing", b.seconds, b.cycles, b.frequencyHz, b.amplitudeG))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Movement bursts") } footer: {
                    Text("Start and end with your wrist still. Wave: 3 or 4 side-to-side swings at a normal pace. Shake: fast, about a second.")
                }
            }
            .paperListStyle()
        }
        .navigationTitle("Motion test")
    }
}
