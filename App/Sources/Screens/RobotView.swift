import SwiftUI
import BoltCore

/// Connect to the Quaddle robot over Bluetooth and drive it with the moves saved on the phone.
struct RobotView: View {
    @ObservedObject var robot: RobotLink
    @State private var custom = ""
    @State private var speech = ""
    @State private var prompt = ""

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: robot.status.label)
                if let cmd = robot.sending { LabeledContent("Sending", value: cmd) }
                switch robot.status {
                case .scanning:
                    Button("Stop looking") { robot.stopScan() }
                case .ready, .connecting, .discovering, .away:
                    Button("Disconnect") { robot.disconnect() }
                    Button("Forget robot", role: .destructive) { robot.forget() }
                default:
                    Button("Connect to \(RobotUUIDs.defaultName)") { robot.startScan(autoConnect: true) }
                }
            } footer: { Text("Uses Bluetooth, no Wi-Fi. The robot is remembered and reconnects on its own.") }

            if case .scanning = robot.status, !robot.found.isEmpty {
                Section("Robots nearby") {
                    ForEach(robot.found) { f in
                        Button { robot.connect(f.id) } label: {
                            LabeledContent(f.name, value: "\(f.rssi) dBm")
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) { robot.sendStop() } label: {
                    Label("Stop (\(robot.moves.stop))", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                ForEach(robot.moves.moves) { move in
                    Button { robot.perform(move) } label: {
                        LabeledContent(move.title, value: move.summary(stop: robot.moves.stop))
                    }
                }
            } header: { Text("Moves") } footer: {
                Text("Stop clears anything queued. Timed moves send \(robot.moves.stop) after their seconds; the robot doesn't stop them itself.")
            }
            .disabled(!robot.isReady)

            Section {
                NavigationLink("Edit moves") { RobotMovesView(robot: robot) }
                NavigationLink("All commands") { RobotCatalogView(robot: robot) }
            } footer: { Text("Commands are saved on this phone, so they can be changed for testing without a new build.") }

            Section {
                TextField("e.g. Hello, I'm Bolt", text: $speech)
                    .onSubmit(sendSpeech)
                Button("Say it", action: sendSpeech).disabled(RobotCommand.say(speech) == nil)
            } header: { Text("Speak") } footer: {
                Text(speech.contains("\"") ? "Remove the double quotes; the robot can't speak them." : "The robot says this out loud, word for word.")
            }
            .disabled(!robot.isReady)

            Section {
                TextField("e.g. Hello, how are you?", text: $prompt)
                    .onSubmit(sendPrompt)
                Button("Ask", action: sendPrompt).disabled(RobotCommand.ask(prompt) == nil)
            } header: { Text("Ask the robot") } footer: { Text("Goes to the robot's own AI, which answers out loud and may move.") }
            .disabled(!robot.isReady)

            Section {
                TextField("e.g. kmarchF", text: $custom)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(sendCustom)
                Button("Send", action: sendCustom).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("Custom command") } footer: { Text("Sent as text with a newline, exactly as typed.") }
            .disabled(!robot.isReady)

            if !robot.lastReplies.isEmpty {
                Section("Last reply") {
                    ForEach(Array(robot.lastReplies.enumerated()), id: \.offset) { _, r in
                        Text(r).font(.caption.monospaced())
                    }
                }
            }
        }
.scrollDismissesKeyboard(.interactively)
.keyboardDoneButton()
        .navigationTitle("Robot")
    }

    private func sendSpeech() {
        guard let command = RobotCommand.say(speech) else { return }
        robot.send(command)
    }

    private func sendPrompt() {
        guard let command = RobotCommand.ask(prompt) else { return }
        robot.send(command)
    }

    private func sendCustom() {
        let text = custom.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        robot.send(.text(text))
    }
}
