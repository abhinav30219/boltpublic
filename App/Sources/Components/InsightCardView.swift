import SwiftUI
import BoltCore

struct InsightCardView: View {
    let card: InsightCard
    @State private var showFacts = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: card.event.kind.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 32, height: 32)
                    .background(card.event.kind.color.opacity(0.35), in: Circle())
                    .overlay(Circle().strokeBorder(Color.ink, lineWidth: 2))
                Text(card.event.kind.title).typo(.label, size: 16)
                Spacer()
                Text(card.event.createdAt, style: .time).typo(.label, size: 14).foregroundStyle(Color.inkSoft)
            }
            if card.text.isEmpty && card.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Gemma is writing…").typo(.body, size: 16).foregroundStyle(Color.inkSoft)
                }
            } else {
                Text(card.text)
                    .typo(.body, size: 17)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.15), value: card.text)
            }
            HStack(spacing: 8) {
                sourceBadge
                if let first = card.firstTokenMs { Text("first word \(msLabel(first))").typo(.body, size: 14).foregroundStyle(Color.inkSoft) }
                if let total = card.totalMs { Text("· done \(msLabel(total))").typo(.body, size: 14).foregroundStyle(Color.inkSoft) }
                Spacer()
                Button(showFacts ? "Hide facts" : "Facts") { withAnimation { showFacts.toggle() } }
                    .typo(.label, size: 14).foregroundStyle(Color.ink)
            }
            if showFacts {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(card.event.facts, id: \.label) { f in
                        HStack { Text(f.label).foregroundStyle(Color.inkSoft); Spacer(); Text(f.text).monospacedDigit() }
                            .typo(.body, size: 14)
                    }
                    Text("Computed by code from the band's data. Gemma only words it.")
                        .typo(.body, size: 14).foregroundStyle(Color.inkSoft).padding(.top, 2)
                }
                .padding(10)
                .background(Color.paper, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .stickerPanel()
        .overlay {
            if card.source == .safety {
                RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.alertInk, lineWidth: Sticker.border)
            }
        }
    }

    @ViewBuilder private var sourceBadge: some View {
        switch card.source {
        case .gemma:
            Label("Gemma 4 · on-device", systemImage: "cpu").typo(.label, size: 14).foregroundStyle(Color.ink)
        case .template:
            Label("Template", systemImage: "text.badge.checkmark").typo(.label, size: 14).foregroundStyle(Color.inkSoft)
        case .safety:
            Label("Safety rule", systemImage: "shield.lefthalf.filled").typo(.label, size: 14).foregroundStyle(Color.alertInk)
        }
    }
}
