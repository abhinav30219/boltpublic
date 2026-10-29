#if DEBUG
import SwiftUI

/// Debug-only screen (launch arg -logoOptions) for comparing the Bolt wordmark styles in context.
struct LogoOptionsView: View {
    private let names = ["0 Face O", "1 Lightning t", "2 Robot badge", "3 Die-cut sticker"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(BoltWordmark.Style.allCases.enumerated()), id: \.offset) { i, st in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(names[i]).font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkSoft)
                        HStack {
                            BoltWordmark(size: 36, style: st)
                            Spacer()
                            StatusChip(text: "Band on", ok: true)
                        }
                        HStack(spacing: 24) {
                            BoltWordmark(size: 20, style: st)
                            BoltWordmark(text: "Pixel", size: 20, style: st)
                        }
                    }
                    Divider()
                }
            }
            .padding(16)
        }
        .background(Color.paper.ignoresSafeArea())
    }
}
#endif
