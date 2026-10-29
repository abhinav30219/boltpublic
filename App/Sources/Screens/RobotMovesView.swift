import SwiftUI
import BoltCore

/// The commands behind each robot move, editable and saved on the phone.
struct RobotMovesView: View {
    @ObservedObject var robot: RobotLink
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                TextField("kup", text: $robot.moves.stop)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Stop command") } footer: { Text("Sent after a timed move and by Stop.") }

            Section {
                ForEach($robot.moves.moves) { $move in
                    NavigationLink {
                        RobotMoveEditor(robot: robot, move: $move)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(move.title)
                            Text(move.summary(stop: robot.moves.stop)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .deleteDisabled(move.isBuiltIn)
                }
                .onDelete { robot.moves.moves.remove(atOffsets: $0) }
                .onMove { robot.moves.moves.move(fromOffsets: $0, toOffset: $1) }
                Button("Add move") {
                    robot.moves.moves.append(RobotMove(title: "New move", command: "khi"))
                }
            } header: { Text("Moves") } footer: {
                Text("The app triggers Stand, Rest, Wave hi, Double tap and the walks by name; change their commands but they can't be deleted.")
            }

            Section {
                Button("Reset to defaults", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Edit moves")
        .toolbar { EditButton() }
        .confirmationDialog("Reset every move to its default command?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { robot.resetMoves() }
        }
    }
}

/// One move: its command, contract and count or seconds, with a test button.
struct RobotMoveEditor: View {
    @ObservedObject var robot: RobotLink
    @Binding var move: RobotMove

    var body: some View {
        Form {
            Section("Name") {
                TextField("Title", text: $move.title)
            }
            Section {
                TextField("e.g. khi", text: $move.command)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                NavigationLink("Pick from all commands") {
                    RobotCatalogView(robot: robot) { entry in
                        move.command = entry.command
                        move.contract = entry.contract
                    }
                }
                if let entry = RobotCatalog.entry(move.command) {
                    LabeledContent("Table", value: "\(entry.function) · \(entry.contract.label)")
                }
            } header: { Text("Command") } footer: { Text("Sent as text with a newline. Arguments can be typed in, e.g. m0 30.") }

            Section {
                Picker("Contract", selection: $move.contract) {
                    ForEach(RobotContract.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                switch move.contract {
                case .once:
                    EmptyView()
                case .steps:
                    Stepper("Steps: \(move.count)", value: $move.count, in: 1...20)
                case .timed:
                    Stepper("Stop after \(String(format: "%.1f", move.seconds)) s", value: $move.seconds, in: 0.5...30, step: 0.5)
                }
            } header: { Text("How it runs") } footer: { Text(contractHelp) }

            Section {
                LabeledContent("Sends", value: move.summary(stop: robot.moves.stop)).font(.body.monospaced())
                Button("Try it") { robot.perform(move) }.disabled(!robot.isReady)
                Button("Stop", role: .destructive) { robot.sendStop() }.disabled(!robot.isReady)
            }
        }
        .navigationTitle(move.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var contractHelp: String {
        switch move.contract {
        case .once: return "Sent once; the skill ends on its own."
        case .steps: return "The step count is added to the command: \(move.text)."
        case .timed: return "The robot keeps going, so \(robot.moves.stop) is sent after the seconds."
        }
    }
}

/// Every command from the robot's tables. Tapping sends it once, or with
/// `onPick`, picks it for a move.
struct RobotCatalogView: View {
    @ObservedObject var robot: RobotLink
    var onPick: ((RobotCatalog.Entry) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List {
            ForEach(RobotCatalog.groups) { group in
                let entries = group.entries.filter(matches)
                if !entries.isEmpty {
                    Section(group.title) {
                        ForEach(entries) { e in
                            Button { tap(e) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(e.command).font(.body.monospaced())
                                        Spacer()
                                        Text(e.contract.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(e.function).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(onPick == nil && !robot.isReady)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if onPick == nil {
                Text("Tap to try: steps run 1 step, timed run 3 s then \(robot.moves.stop).")
                    .font(.caption).foregroundStyle(.secondary).padding(8)
                    .frame(maxWidth: .infinity).background(.bar)
            }
        }
        .searchable(text: $search)
        .navigationTitle(onPick == nil ? "All commands" : "Pick a command")
        .toolbar {
            if onPick == nil {
                Button("Stop", role: .destructive) { robot.sendStop() }.disabled(!robot.isReady)
            }
        }
    }

    private func matches(_ e: RobotCatalog.Entry) -> Bool {
        search.isEmpty || e.command.localizedCaseInsensitiveContains(search) || e.function.localizedCaseInsensitiveContains(search)
    }

    /// Tries the command: steps with a count of 1, timed for 3 s then the stop command.
    private func tap(_ e: RobotCatalog.Entry) {
        if let onPick {
            onPick(e)
            dismiss()
        } else {
            robot.perform(RobotMove(title: e.function, command: e.command, contract: e.contract, count: 1, seconds: 3))
        }
    }
}
