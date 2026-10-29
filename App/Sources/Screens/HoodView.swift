import SwiftUI
import BoltCore

/// The proof screen: which models run where, how fast, and every call they made.
struct HoodView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: TraceEntry.Kind? = nil
    #if DEBUG
    @AppStorage(CompanionRendererKind.defaultsKey) private var companionRenderer = CompanionRendererKind.sceneKit
    #endif

    var body: some View {
        Group {
            List {
                Section {
                    HStack { Text("Network"); Spacer(); OnDeviceBadge(offline: model.isOffline) }
                    LabeledContent("Language model", value: model.engineStats.modelName.isEmpty ? "not loaded" : model.engineStats.modelName)
                    LabeledContent("Runtime", value: "LiteRT-LM · \(model.engineStats.backend.isEmpty ? "-" : model.engineStats.backend)")
                    LabeledContent("Load time", value: model.engineStats.loadSeconds.map { String(format: "%.1f s", $0) } ?? "-")
                    LabeledContent("Last first token", value: msLabel(model.engineStats.lastFirstTokenMs).isEmpty ? "-" : msLabel(model.engineStats.lastFirstTokenMs))
                    LabeledContent("Decode speed", value: model.engineStats.lastTokensPerSecond.map { String(format: "%.0f tokens/s", $0) } ?? "-")
                    LabeledContent("Median card time", value: msLabel(model.trace.medianMs(.card)).isEmpty ? "-" : msLabel(model.trace.medianMs(.card)))
                    LabeledContent("Activity model", value: "Core Motion")
                } header: { Text("On this phone") }

                Section {
                    LabeledContent("Source", value: "Apple Core Motion")
                    LabeledContent("Windows processed", value: "\(model.fitnessWindowCount)")
                } header: { Text("Activity") } footer: {
                    Text("Activity (walking, running, still) and steps come from the iPhone's own Core Motion classifier and pedometer.")
                }

                Section {
                    if model.models.isEmpty {
                        Text("No models found. On your Mac, open Finder, select this iPhone, go to Files > Bolt and drag in gemma-4-E2B-it-gpu.litertlm.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Picker("Model", selection: $model.selectedModel) {
                        ForEach(model.models) { m in Text("\(m.displayName) · \(String(format: "%.1f", m.sizeGB)) GB").tag(Optional(m)) }
                    }
                    Button {
                        Task { await model.loadModel() }
                    } label: {
                        HStack {
                            Text(loadLabel)
                            Spacer()
                            if case .loading = model.engineState { ProgressView() }
                        }
                    }
                    .disabled(model.selectedModel == nil || model.engineState == .loading)
                    Button("Refresh model list") { model.refreshModels() }
                    if case .failed(let msg) = model.engineState { Text(msg).font(.caption).foregroundStyle(.red) }
                } header: { Text("Model") }

                Section {
                    NavigationLink("Tuning") { TuningView() }
                } header: { Text("Companion") }

                Section {
                    NavigationLink {
                        RobotView(robot: model.robot)
                    } label: {
                        RobotStatusRow(robot: model.robot)
                    }
                } header: { Text("Robot") }

                #if DEBUG
                Section {
                    NavigationLink("Design gallery") { DesignGalleryView() }
                    Picker("Companion renderer", selection: $companionRenderer) {
                        ForEach(CompanionRendererKind.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Simulate fall") { model.simulateFall() }
                } header: { Text("Debug") }
                #endif

                Section {
                    Picker("Show", selection: $filter) {
                        Text("All").tag(TraceEntry.Kind?.none)
                        Text("Cards").tag(TraceEntry.Kind?.some(.card))
                        Text("Tools").tag(TraceEntry.Kind?.some(.tool))
                        Text("Chat").tag(TraceEntry.Kind?.some(.chat))
                        Text("Engine").tag(TraceEntry.Kind?.some(.engine))
                        Text("Robot").tag(TraceEntry.Kind?.some(.robot))
                    }
                    .pickerStyle(.segmented)
                    ForEach(model.trace.entries.reversed().filter { filter == nil || $0.kind == filter }) { e in
                        TraceRow(entry: e)
                    }
                } header: { Text("Trace") }
            }
            .paperListStyle()
            .navigationTitle("Under the hood")
        }
    }

    private var loadLabel: String {
        switch model.engineState {
        case .ready: return "Reload model"
        case .loading: return "Loading… (first load compiles shaders)"
        default: return "Load model"
        }
    }
}

struct RobotStatusRow: View {
    @ObservedObject var robot: RobotLink
    var body: some View { LabeledContent("Quaddle", value: robot.status.label) }
}

struct TraceRow: View {
    let entry: TraceEntry
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                Text(entry.title).font(.callout.weight(.medium)).lineLimit(expanded ? nil : 1)
                Spacer()
                if let ms = entry.ms { Text(msLabel(ms)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if !entry.detail.isEmpty {
                Text(entry.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
            }
            Text(entry.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { expanded.toggle() } }
    }
    private var icon: String {
        switch entry.kind {
        case .engine: return "cpu"
        case .card: return "rectangle.stack"
        case .chat: return "bubble.left"
        case .tool: return "function"
        case .activity: return "figure.walk"
        case .band: return "applewatch"
        case .robot: return "pawprint"
        case .warning: return "exclamationmark.triangle"
        }
    }
    private var color: Color {
        switch entry.kind {
        case .warning: return .orange
        case .tool: return .teal
        case .card: return .coral
        default: return Color(hex: 0x8B6CF6)
        }
    }
}
