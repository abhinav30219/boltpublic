import SwiftUI
import BoltCore

/// One of the companion's notes ("Bolt noticed"). Safety cards use a red border and no friendly icon.
struct NoteRow: View {
    let card: InsightCard

    init(card: InsightCard) { self.card = card }

    private var isSafety: Bool { card.source == .safety }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSafety ? "exclamationmark.triangle.fill" : card.event.kind.symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(isSafety ? Color.alertInk : Color.ink)
                .frame(width: 40, height: 40)
                .background(isSafety ? Color.card : card.event.kind.color.opacity(0.3), in: Circle())
                .overlay(Circle().strokeBorder(isSafety ? Color.alertInk : Color.ink, lineWidth: 2.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.event.createdAt, style: .time)
                    .typo(.label, size: 14).foregroundStyle(Color.inkSoft)
                if card.text.isEmpty && card.isStreaming {
                    Text("Writing a note…").typo(.body, size: 17).foregroundStyle(Color.inkSoft)
                } else {
                    Text(card.text).typo(.body, size: 17).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sticker(fill: .card, radius: 18)
        .overlay {
            if isSafety {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.alertInk, lineWidth: max(Sticker.border, 2.5))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
extension NoteRow {
    static var samples: some View {
        let now = Date()
        var walk = InsightCard(event: InsightEvent(kind: .exertion, createdAt: now, facts: []),
                               text: "You walked for 18 minutes, your longest walk this week!",
                               source: .gemma, isStreaming: false)
        walk.isStreaming = false
        let safety = InsightCard(event: InsightEvent(kind: .safety, createdAt: now, facts: [],
                                                     fixedText: "Your heart rate is high while resting."),
                                 text: "Your heart rate is high while you are resting. Please sit down and call someone if you feel unwell.",
                                 source: .safety, isStreaming: false)
        return VStack(spacing: 14) { NoteRow(card: walk); NoteRow(card: safety) }
    }
}
#endif

#Preview { NoteRow.samples.padding(16).background(Color.paper) }
#Preview("Accessibility 3") {
    ScrollView { NoteRow.samples.padding(16) }.background(Color.paper).dynamicTypeSize(.accessibility3)
}
