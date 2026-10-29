import SwiftUI
import BoltCore

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var newFact = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        TextField("e.g. I slept 5 hours last night", text: $newFact, prompt: Color.softPrompt("e.g. I slept 5 hours last night"))
                            .typo(.body, size: 17)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .typo(.label, size: 17)
                            .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .stickerPanel()
                    Text("Bolt uses these in cards and answers. They're stored only on this phone.")
                        .typo(.body, size: 15).foregroundStyle(Color.inkSoft)
                    Text("What Bolt remembers").typo(.heading, size: 22)
                    if model.memoryFacts.isEmpty {
                        Text("Nothing yet. Tell Gemma about your sleep, caffeine or training in Chat.")
                            .typo(.body, size: 17).foregroundStyle(Color.inkSoft)
                    }
                    ForEach(model.memoryFacts.sorted { $0.createdAt > $1.createdAt }) { f in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.text).typo(.body, size: 17)
                                Text("\(Self.origin(f.source)) · \(f.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .typo(.body, size: 14).foregroundStyle(Color.inkSoft)
                            }
                            Spacer(minLength: 8)
                            Button { model.deleteMemory(f.id) } label: {
                                Image(systemName: "trash").font(.system(size: 18, weight: .bold))
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Forget")
                        }
                        .stickerPanel(fill: .fillEnergy)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 20)
                .padding(.trailing, Sticker.shadowOffset)
                .foregroundStyle(Color.ink)
            }
            .background(ThemeBackground())
            .navigationTitle("Memory")
        }
.scrollDismissesKeyboard(.interactively)
        .tint(.ink)
    }

    static func origin(_ source: String) -> String {
        switch source {
        case "insight": return "From an insight"
        case "chat": return "From Ask Gemma"
        case "manual": return "Added by you"
        default: return source.capitalized
        }
    }

    private func add() {
        model.addMemory(newFact)
        newFact = ""
    }
}
