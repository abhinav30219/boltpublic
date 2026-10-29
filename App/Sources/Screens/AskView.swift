import SwiftUI
import BoltCore

struct AskView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""
    @FocusState private var focused: Bool
    @EnvironmentObject var speech: SpeechService
    /// Set by the Home Talk button: start dictation as soon as Chat shows.
    @Binding var dictateRequest: Bool
    @State private var showHistory = false

    init(dictateRequest: Binding<Bool> = .constant(false)) { _dictateRequest = dictateRequest }

    var body: some View {
        chatStack
            .sheet(isPresented: $showHistory) { ChatHistoryView().environmentObject(model) }
            .dismissesOnFallAlert { showHistory = false }
            #if DEBUG
            .onAppear { if CommandLine.arguments.contains("-openChatHistory") { showHistory = true } }
            #endif
    }

    private var chatStack: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.chat.isEmpty { intro }
                        ForEach(model.chat) { msg in
                            ChatBubble(message: msg).id(msg.id)
                        }
                    }
                    .padding(16)
                }
                // Swipe down or tap the conversation to put the keyboard away (it was covering the tab bar).
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(TapGesture().onEnded { focused = false })
                .onChange(of: model.chat.last?.text) { _, _ in
                    if let id = model.chat.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            .background(ThemeBackground())
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Chat")
            .tint(.ink)
            .onAppear(perform: consumeDictateRequest)
            .onChange(of: dictateRequest) { _, _ in consumeDictateRequest() }
            .onDisappear { speech.stop() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { OnDeviceBadge(offline: model.isOffline) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { focused = false; showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Past chats")
                        .disabled(model.threads.isEmpty)
                    Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .disabled(model.chat.isEmpty)
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about your body right now. Gemma checks your live band data with tools, all on this phone.")
                .typo(.body).foregroundStyle(Color.inkSoft)
            ForEach(ChatPrompts.suggestions, id: \.self) { s in
                Button {
                    focused = false
                    Task { await model.send(s) }
                } label: {
                    Text(s).typo(.body, size: 17).multilineTextAlignment(.leading)
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .sticker(fill: .fillRelax, radius: 16)
                }
                .buttonStyle(.plain)
                .padding(.trailing, Sticker.shadowOffset)
            }
            Text("Tip: tell Gemma things like \"I slept 5 hours last night\" and it will remember them.")
                .typo(.body, size: 14).foregroundStyle(Color.inkSoft)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if speech.permissionDenied { permissionNotice }
            else if let why = speech.lastError, !speech.isListening {
                Text(why).typo(.body, size: 15).foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
            composerRow
        }
        .background(ThemeBarBackground())
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(companionName) can't hear you yet. Turn on Microphone and Speech Recognition for Bolt in Settings.")
                .typo(.body, size: 16).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .typo(.label, size: 17).foregroundStyle(Color.ink).underline()
            .frame(minHeight: 44)
        }
        .stickerPanel(fill: .fillEnergy)
        .padding(.leading, 12).padding(.trailing, 12 + Sticker.shadowOffset).padding(.top, 8)
    }

    private var companionName: String { model.companionProfile.displayName }

    private var composerRow: some View {
        HStack(spacing: 10) {
            TextField("Ask Gemma…", text: $draft, prompt: Color.softPrompt("Ask Gemma…"), axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .typo(.body, size: 18)
                .foregroundStyle(Color.ink)
                .submitLabel(.send)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(minHeight: Sticker.minButtonHeight)
                .sticker(fill: .card, radius: 24)
                .onSubmit(send)
            // A multi-line field turns Return into a newline instead of calling onSubmit; treat it as Send.
            .onChange(of: draft) { _, new in
                if new.contains("\n") {
                    draft = new.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                    send()
                }
            }
            if speech.isAvailable {
                Button(action: toggleMic) {
                    Image(systemName: speech.isListening ? "stop.fill" : "mic.fill").font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: Sticker.minButtonHeight, height: Sticker.minButtonHeight)
                        .sticker(fill: speech.isListening ? .coral : .fillRelax, radius: 32)
                }
                .accessibilityLabel(speech.isListening ? "Stop listening" : "Speak your question")
            }
            if isAnswering {
                Button { model.stopChat() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: Sticker.minButtonHeight, height: Sticker.minButtonHeight)
                        .sticker(fill: .fillEnergy, radius: 32)
                }
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: Sticker.minButtonHeight, height: Sticker.minButtonHeight)
                        .sticker(fill: canSend ? .coral : .card, radius: 32)
                }
                .accessibilityLabel("Send")
                .disabled(!canSend)
            }
        }
        .padding(.leading, 12).padding(.trailing, 12 + Sticker.shadowOffset).padding(.vertical, 8)
        .background(ThemeBarBackground())
    }

    private var canSend: Bool {
        !(draft.trimmingCharacters(in: .whitespaces).isEmpty || isAnswering)
    }

    private func consumeDictateRequest() {
        guard dictateRequest else { return }
        dictateRequest = false
        if !speech.isListening { toggleMic() }
    }

    private func toggleMic() {
        if speech.isListening { speech.stop(); return }
        focused = false
        speech.startDictation { draft = $0 }
    }

    private var isAnswering: Bool { model.chat.last?.isStreaming ?? false }

    private func send() {
        speech.stop()
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAnswering else { return }
        draft = ""
        focused = false   // put the keyboard away so the tab bar is reachable again
        Task { await model.send(q) }
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    @State private var showTools = false

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .typo(.body, size: 18)
                    .padding(12)
                    .foregroundStyle(Color.ink)
                    .sticker(fill: .coral, radius: 18)
                if !message.remembered.isEmpty {
                    Label("Remembered: \(message.remembered.joined(separator: "; "))", systemImage: "brain")
                        .typo(.body, size: 14).foregroundStyle(Color.inkSoft)
                }
            }
            .padding(.trailing, Sticker.shadowOffset)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty && message.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(message.toolCalls.isEmpty ? "Thinking on-device…" : "Checking \(message.toolCalls.last!.replacingOccurrences(of: "_", with: " "))…")
                            .typo(.body, size: 16).foregroundStyle(Color.inkSoft)
                    }
                } else if let err = message.error, message.text.isEmpty {
                    Label(err, systemImage: "exclamationmark.triangle").typo(.body, size: 16).foregroundStyle(Color.alertInk)
                } else {
                    Text(message.text).typo(.body, size: 18).fixedSize(horizontal: false, vertical: true)
                }
                if !message.isStreaming && (!message.toolCalls.isEmpty || message.totalMs != nil) {
                    Button { withAnimation { showTools.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver")
                            Text("How I got this")
                            if let ms = message.totalMs { Text("· \(msLabel(ms)) on-device") }
                        }
                        .typo(.label, size: 14).foregroundStyle(Color.ink)
                    }
                    if showTools {
                        VStack(alignment: .leading, spacing: 3) {
                            if message.toolCalls.isEmpty { Text("Answered without tools").typo(.body, size: 14) }
                            ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, t in
                                Label(t, systemImage: "function").font(.system(size: 14, design: .monospaced))
                            }
                            if let f = message.firstTokenMs { Text("First word after \(msLabel(f))").typo(.body, size: 14).foregroundStyle(Color.inkSoft) }
                        }
                        .padding(10)
                        .background(Color.paper, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(12)
            .foregroundStyle(Color.ink)
            .sticker(fill: .card, radius: 18)
            .padding(.trailing, Sticker.shadowOffset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Past chats, newest first. Tap to continue one; swipe to delete.
struct ChatHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.threads) { t in
                    Button {
                        model.openThread(t.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(t.title).typo(.heading, size: 18).lineLimit(1)
                                if t.id == model.currentThreadID { Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.coral) }
                            }
                            if !t.gist.isEmpty { Text(t.gist).typo(.body, size: 15).foregroundStyle(Color.inkSoft).lineLimit(2) }
                            Text(t.updatedAt.formatted(date: .abbreviated, time: .shortened)).typo(.body, size: 14).foregroundStyle(Color.inkSoft)
                        }
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .swipeActions { Button(role: .destructive) { model.deleteThread(t.id) } label: { Label("Delete", systemImage: "trash") } }
                }
            }
            .paperListStyle()
            .navigationTitle("Past chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.newChat(); dismiss() } label: { Label("New chat", systemImage: "square.and.pencil") }
                }
            }
        }
        .tint(.ink)
    }
}
