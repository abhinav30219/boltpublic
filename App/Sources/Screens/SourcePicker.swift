import SwiftUI

/// Pick where live data comes from: the band, the synthetic demo, or a saved recording.
struct SourcePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            List {
                Section {
                    BandConnectView(band: model.band) {
                        model.useBand()
                        dismiss()
                    }
                } header: { Text("Your band") }

                Section {
                    Button {
                        model.startDemo()
                        dismiss()
                    } label: {
                        Label("Run the demo session", systemImage: "play.circle")
                    }
                    Button {
                        model.startFallDemo()
                        dismiss()
                    } label: {
                        Label("Fall demo (synthetic)", systemImage: "figure.fall")
                    }
                } header: { Text("No band?") } footer: {
                    Text("Synthetic data: 2.5 min rest, 60 s of jogging in place, recovery, then a slow wrist-temperature drop. Useful for testing without a band.")
                }

                if !model.recordings.isEmpty {
                    Section("Recorded sessions") {
                        ForEach(model.recordings, id: \.self) { url in
                            Button {
                                model.replay(url)
                                dismiss()
                            } label: {
                                Label(url.deletingPathExtension().lastPathComponent, systemImage: "record.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Data source")
            .navigationBarTitleDisplayMode(.inline)
            .paperListStyle()
            .onAppear { model.refreshRecordings() }
        }
    }
}

/// Scan, pick and connect. Used in onboarding and in the source picker.
struct BandConnectView: View {
    @ObservedObject var band: HeartRateBand
    var onStreaming: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(band.status.label).font(.subheadline)
                Spacer()
                if band.status == .scanning { ProgressView() }
            }
            if band.status == .streaming {
                BigButton("Use this band", fill: .coral) { onStreaming() }
            } else {
                ForEach(band.found) { d in
                    Button {
                        band.connect(d.id)
                    } label: {
                        HStack {
                            Image(systemName: "applewatch")
                            Text(HeartRateBand.displayName(d.name))
                            Spacer()
                            Text("\(d.rssi) dBm").typo(.body, size: 14).foregroundStyle(Color.inkSoft)
                        }
                    }
                }
                HStack(spacing: 10) {
                    if band.savedPeripheralID != nil {
                        BigButton("Reconnect", fill: .fillSteps) { band.reconnectSaved() }
                    }
                    BigButton(band.status == .scanning ? "Stop" : "Scan", fill: .fillRelax) {
                        band.status == .scanning ? band.stopScan() : band.startScan()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onChange(of: band.status) { _, new in
            if new == .streaming { onStreaming() }
        }
    }
}
