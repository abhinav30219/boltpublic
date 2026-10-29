import SwiftUI

struct GoalBar: View {
    let steps: Int
    let goal: Int

    init(steps: Int, goal: Int) { self.steps = steps; self.goal = goal }

    private var progress: Double {
        goal > 0 ? min(max(Double(steps) / Double(goal), 0), 1) : 0
    }

    var body: some View {
        StickerCard {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack { title; Spacer(minLength: 8); count }
                    VStack(alignment: .leading, spacing: 2) { title; count }
                }
                .typo(.body, size: 17).fontWeight(.bold)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.paper)
                        Capsule().fill(Color.coral).frame(width: geo.size.width * progress)
                    }
                    .overlay(Capsule().strokeBorder(Color.ink, lineWidth: 2.5))
                    .clipShape(Capsule())
                }
                .frame(height: 18)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's walking goal, \(steps) of \(goal) steps")
    }

    private var title: some View { Text("Today's walking goal") }
    private var count: some View {
        Text("\(steps.formatted()) / \(goal.formatted())").monospacedDigit()
    }
}

#Preview {
    VStack(spacing: 20) { GoalBar(steps: 3240, goal: 8000); GoalBar(steps: 9000, goal: 8000) }
        .padding(16).background(ThemeBackground())
}
#Preview("Accessibility 3") {
    GoalBar(steps: 3240, goal: 8000).padding(16).background(ThemeBackground())
        .dynamicTypeSize(.accessibility3)
}
