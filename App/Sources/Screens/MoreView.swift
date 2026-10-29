import SwiftUI

/// Everything that is not a daily tab: companion, settings, data source, recording, diagnostics.
struct MoreView: View {
    @EnvironmentObject var model: AppModel
    /// Kept in scene storage so switching theme (which rebuilds the views) stays on the same screen.
    @SceneStorage("moreRoute") private var route = ""

    var body: some View {
        NavigationStack(path: Binding(get: { route.isEmpty ? [] : [route] },
                                      set: { route = $0.last ?? "" })) {
            ScrollView {
                VStack(spacing: 18) {
                    NavigationLink(value: "companion") {
                        MoreRow(title: "Companion", symbol: "pawprint.fill", fill: .fillHeart)
                    }
                    NavigationLink(value: "lab") {
                        MoreRow(title: "Animation lab", symbol: "figure.walk.motion", fill: .fillEnergy,
                                detail: "Try every Bolt animation")
                    }
                    NavigationLink(value: "settings") {
                        MoreRow(title: "Settings", symbol: "gearshape.fill", fill: .fillRelax)
                    }
                    NavigationLink(value: "source") {
                        MoreRow(title: "Data source", symbol: "applewatch.radiowaves.left.and.right", fill: .fillOxygen)
                    }
                    Button { model.toggleRecording() } label: {
                        MoreRow(title: model.isRecording ? "Stop and save recording" : "Record session",
                                symbol: model.isRecording ? "stop.circle.fill" : "record.circle",
                                fill: .fillEnergy,
                                detail: model.isRecording ? "Recording raw band data…" : nil)
                    }
                    .disabled(model.source != .band && !model.isRecording)
                    NavigationLink(value: "hood") {
                        MoreRow(title: "Under the hood", symbol: "cpu", fill: .fillSteps)
                    }
                    Text("Recordings save to Files > Bolt > recordings and can be replayed as a data source if Bluetooth misbehaves during a demo.")
                        .typo(.body, size: 16).foregroundStyle(Color.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 20)
                .padding(.trailing, Sticker.shadowOffset)
            }
            .background(ThemeBackground())
            .navigationTitle("More")
            .navigationDestination(for: String.self) { key in
                switch key {
                case "companion": CompanionSettingsView()
                case "lab": AnimationLabView()
                case "settings": SettingsView()
                case "source": SourcePicker()
                default: HoodView()
                }
            }
        }
.scrollDismissesKeyboard(.interactively)
        .tint(.ink)
    }
}

private struct MoreRow: View {
    let title: String
    let symbol: String
    let fill: Color
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 24, weight: .bold)).frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).typo(.heading, size: 21)
                if let detail { Text(detail).typo(.label, size: 14).foregroundStyle(Color.inkSoft) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .bold)).accessibilityHidden(true)
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: Sticker.minButtonHeight, alignment: .leading)
        .padding(.vertical, 6)
        .sticker(fill: fill)
        .contentShape(Rectangle())
    }
}
