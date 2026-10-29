import SwiftUI
import BoltCore

/// Live editor for every field of `Tuning`. Each valid edit is applied and saved immediately.
struct TuningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            if let err = model.tuningError {
                Section { Text(err).font(.callout).foregroundStyle(.red) }
            }
            Section {
                ForEach(Self.companionDoubles, id: \.0) { NumberRow(title: $0.0, value: doubleBinding(\.companion, $0.1)) }
                ForEach(Self.companionInts, id: \.0) { IntRow(title: $0.0, value: intBinding(\.companion, $0.1)) }
            } header: { Text("Companion") } footer: { Text("Moods, motion timing, thresholds and gait geometry.") }

            Section {
                ForEach(Self.fallDoubles, id: \.0) { NumberRow(title: $0.0, value: doubleBinding(\.fall, $0.1)) }
                HStack {
                    Text("emergencyNumber").font(.callout)
                    Spacer()
                    TextField("911", text: stringBinding(\.fall, \.emergencyNumber))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.phonePad)
                }
            } header: { Text("Fall") }

            Section {
                ForEach(Self.renderDoubles, id: \.0) { NumberRow(title: $0.0, value: doubleBinding(\.render, $0.1)) }
                Toggle("reduceAnimation", isOn: boolBinding(\.render, \.reduceAnimation)).font(.callout)
            } header: { Text("Render") }

            Section {
                Button("Reset to defaults", role: .destructive) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    model.updateTuning(Tuning())
                }
            } footer: { Text("Edits apply as you type and are saved to tuning.json.") }
        }
.scrollDismissesKeyboard(.interactively)
.keyboardDoneButton()
        .paperListStyle()
        .navigationTitle("Tuning")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Bindings (read the model every time, write the whole Tuning back)

    private func doubleBinding<G>(_ g: WritableKeyPath<Tuning, G>, _ f: WritableKeyPath<G, Double>) -> Binding<Double> {
        Binding(get: { model.tuning[keyPath: g.appending(path: f)] },
                set: { var t = model.tuning; t[keyPath: g.appending(path: f)] = $0; model.updateTuning(t) })
    }
    private func intBinding<G>(_ g: WritableKeyPath<Tuning, G>, _ f: WritableKeyPath<G, Int>) -> Binding<Int> {
        Binding(get: { model.tuning[keyPath: g.appending(path: f)] },
                set: { var t = model.tuning; t[keyPath: g.appending(path: f)] = $0; model.updateTuning(t) })
    }
    private func stringBinding<G>(_ g: WritableKeyPath<Tuning, G>, _ f: WritableKeyPath<G, String>) -> Binding<String> {
        Binding(get: { model.tuning[keyPath: g.appending(path: f)] },
                set: { var t = model.tuning; t[keyPath: g.appending(path: f)] = $0; model.updateTuning(t) })
    }
    private func boolBinding<G>(_ g: WritableKeyPath<Tuning, G>, _ f: WritableKeyPath<G, Bool>) -> Binding<Bool> {
        Binding(get: { model.tuning[keyPath: g.appending(path: f)] },
                set: { var t = model.tuning; t[keyPath: g.appending(path: f)] = $0; model.updateTuning(t) })
    }

    // MARK: Field tables

    private typealias C = CompanionTuning
    private static let companionDoubles: [(String, WritableKeyPath<C, Double>)] = [
        ("motionHoldSeconds", \.motionHoldSeconds), ("moodHoldSeconds", \.moodHoldSeconds),
        ("relievedSeconds", \.relievedSeconds), ("concernedSeconds", \.concernedSeconds), ("happySeconds", \.happySeconds),
        ("blushStartAboveBaselineBpm", \.blushStartAboveBaselineBpm), ("blushFullFractionOfMax", \.blushFullFractionOfMax),
        ("steamFractionOfMax", \.steamFractionOfMax), ("elevatedAboveBaselineBpm", \.elevatedAboveBaselineBpm),
        ("belowBaselineBpm", \.belowBaselineBpm), ("highFractionOfMax", \.highFractionOfMax),
        ("calmHRVAboveBaseline", \.calmHRVAboveBaseline), ("tiredHRVBelowBaseline", \.tiredHRVBelowBaseline),
        ("tempShiftC", \.tempShiftC),
        ("frontKneeMaxDeg", \.frontKneeMaxDeg), ("backKneeMaxDeg", \.backKneeMaxDeg),
        ("walkHipDeg", \.walkHipDeg), ("trotHipDeg", \.trotHipDeg), ("backKneeWalkDeg", \.backKneeWalkDeg),
        ("bodyBobMeters", \.bodyBobMeters), ("idleLookYawDeg", \.idleLookYawDeg),
        ("breathPeriodSeconds", \.breathPeriodSeconds), ("transitionSeconds", \.transitionSeconds),
        ("celebrationSeconds", \.celebrationSeconds),
        ("meaningBusyAboveBaselineBpm", \.meaningBusyAboveBaselineBpm), ("meaningActiveKcal", \.meaningActiveKcal),
        ("meaningOxygenLowPct", \.meaningOxygenLowPct),
        ("meaningRestedFractionOfBaseline", \.meaningRestedFractionOfBaseline),
    ]
    private static let companionInts: [(String, WritableKeyPath<C, Int>)] = [
        ("milestoneSteps", \.milestoneSteps), ("dailyStepGoal", \.dailyStepGoal), ("defaultAge", \.defaultAge),
    ]
    private static let fallDoubles: [(String, WritableKeyPath<FallTuning, Double>)] = [
        ("cooldownSeconds", \.cooldownSeconds), ("responseTimeoutSeconds", \.responseTimeoutSeconds),
        ("reaskSeconds", \.reaskSeconds), ("alarmRepeatSeconds", \.alarmRepeatSeconds),
    ]
    private static let renderDoubles: [(String, WritableKeyPath<RenderTuning, Double>)] = [
        ("visibleFPS", \.visibleFPS), ("generatingFPS", \.generatingFPS), ("outlineWidth", \.outlineWidth),
    ]
}

/// Decimal field. Keeps its own text so partial input ("0.") isn't rewritten while typing;
/// only text that parses is applied.
private struct NumberRow: View {
    let title: String
    @Binding var value: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .frame(maxWidth: 110)
                .focused($focused)
                .onChange(of: text) { new in
                    if let d = Double(new.replacingOccurrences(of: ",", with: ".")), d.isFinite, d >= 0 {
                        let v = min(d, AppModel.tuningMax)
                        if v != value { value = v }
                    }
                }
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { new in if !focused { text = Self.format(new) } }
        .onChange(of: focused) { f in if !f { text = Self.format(value) } }
    }
    static func format(_ d: Double) -> String { d.formatted(.number.grouping(.never).precision(.fractionLength(0...4))) }
}

private struct IntRow: View {
    let title: String
    @Binding var value: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            TextField("0", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
                .frame(maxWidth: 110)
                .focused($focused)
                .onChange(of: text) { new in
                    if let i = Int(new), i >= 0 { let v = min(i, Int(AppModel.tuningMax)); if v != value { value = v } }
                }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { new in if !focused { text = String(new) } }
        .onChange(of: focused) { f in if !f { text = String(value) } }
    }
}
