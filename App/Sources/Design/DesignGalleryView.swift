#if DEBUG
import SwiftUI
import BoltCore

/// Every Sticker Book component at default size and at accessibility3, for visual checks on device.
struct DesignGalleryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Default size").typo(.heading)
                GalleryContent()
                Divider().padding(.vertical, 8)
                Text("Accessibility 3").typo(.heading)
                GalleryContent().dynamicTypeSize(.accessibility3)
            }
            .padding(16)
        }
        .background(ThemeBackground())
        .navigationTitle("Design gallery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GalleryContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack { StatusChip(text: "Bolt connected", ok: true); StatusChip(text: "Not found", ok: false) }
                VStack(alignment: .leading) { StatusChip(text: "Bolt connected", ok: true); StatusChip(text: "Not found", ok: false) }
            }
            CompanionBubble(text: "That was a lovely walk! Your heart is calm again. Time for a glass of water?",
                            onReadAloud: {})
            MetricCard.sample
            GoalBar(steps: 3240, goal: 8000)
            DayTimeline.sample
            NoteRow.samples
            BigButton("Call my daughter", fill: .fillSteps) {}
            TalkButton(name: "Bolt") {}
        }
        .padding(.trailing, Sticker.shadowOffset)
    }
}
#endif
