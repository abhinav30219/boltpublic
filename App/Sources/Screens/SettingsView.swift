import SwiftUI
import BoltCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settings.cardsEnabled") private var cardsEnabled = true
    @AppStorage("settings.speculative") private var speculative = false
    @AppStorage("settings.preferGPU") private var preferGPU = true
    @AppStorage("settings.fallDetection") private var fallDetection = true
    @AppStorage("settings.gestures") private var gestures = true
    @AppStorage("settings.speakCards") private var speakCards = true
    @AppStorage("settings.robotSpeaker") private var robotSpeaker = false
    @State private var confirmReset = false
    @State private var ageText = ""

    var body: some View {
        Group {
            Form {
                Section("Profile") {
                    TextField("First name", text: $model.profile.name)
                        .submitLabel(.done).onSubmit { KeyboardDismiss.resign() }
                    TextField("Age", text: $ageText).keyboardType(.numberPad)
                        .onChange(of: ageText) { _, v in model.profile.age = Int(v) }
                }
                Section {
                    Toggle("Insight cards", isOn: $cardsEnabled)
                    Button("Recalibrate resting baseline") { model.recalibrate(); dismiss() }
                } header: { Text("Insights") } footer: { Text("Recalibrate while sitting still for 30 seconds. Otherwise your baseline keeps adapting on its own.") }

                Section {
                    Toggle("Fall detection", isOn: $fallDetection)
                    Button("Simulate a fall") { dismiss(); model.simulateFall() }
                    NavigationLink("Motion test") { MotionTestView().environmentObject(model) }
                    Toggle("Gestures", isOn: $gestures)
                    Toggle("Bolt reads insights aloud", isOn: $speakCards)
                    Toggle("Robot has a speaker", isOn: $robotSpeaker)
                    Button("Simulate a wave") { dismiss(); model.simulateGesture(.wave) }
                    Button("Simulate a shake") { dismiss(); model.simulateGesture(.shake) }
                } header: { Text("Safety and gestures") } footer: {
                    Text("Fall: a model fitted on recorded falls and fall-like daily activities judges every hard impact 3 seconds later (hard hit, wrist turned, lying still, calm before). Gestures start and end with your wrist still: wave (raise your hand, wave 3 or 4 times, stop) and Bolt waves back and says one thing about your day; shake your wrist fast to mark the moment in memory. Simulations run through the same detectors.")
                }

                Section {
                    Toggle("Prefer GPU", isOn: $preferGPU)
                    Toggle("Speculative decoding (experimental)", isOn: $speculative)
                } header: { Text("Engine") } footer: { Text("Changes apply the next time the model loads (Under the hood > Reload model).") }

                Section {
                    Button("Stop data source") { model.stopReplay(); model.band.disconnect() }
                } header: { Text("Band data") }

                Section {
                    Text("Fall check is a demo feature, not a medical device.")
                }

                Section {
                    LabeledContent("Days recorded", value: "\(model.health.dayCount)")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: model.health.fileSize, countStyle: .file))
                } header: { Text("Your data") } footer: {
                    Text("Your profile, heart rate, HRV, skin temperature, baseline, steps and energy are stored on this iPhone only. Nothing is sent to a server.")
                }

                Section {
                    Button("Clear insight cards") { model.clearCards() }
                    Button("Reset app and onboarding", role: .destructive) { confirmReset = true }
                }
            }
.scrollDismissesKeyboard(.interactively)
.keyboardDoneButton()
            .paperListStyle()
            .navigationTitle("Settings")
            .onAppear { ageText = model.profile.age.map(String.init) ?? "" }
            .confirmationDialog("Reset everything?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { model.resetEverything(); dismiss() }
            } message: { Text("Deletes your profile, health history, memory, cards and band pairing from this phone.") }
        }
    }
}
