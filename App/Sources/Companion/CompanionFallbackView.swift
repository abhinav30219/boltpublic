import SpriteKit
import SwiftUI

/// 2D companion shown when the 3D asset cannot be loaded.
struct CompanionFallbackView: View {
    @ObservedObject var driver: CompanionDriver
    @State private var face = FaceRenderer()

    var body: some View {
        StickerCard(fill: Color(driver.appearance.palette.shell)) {
            SpriteView(scene: face.scene, isPaused: !driver.isVisible,
                       preferredFramesPerSecond: max(driver.targetFPS, 1), options: [.allowsTransparency])
                .aspectRatio(2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
        // Face updates ride a timeline that stops while hidden.
        .background(
            TimelineView(.animation(minimumInterval: 1.0 / Double(max(driver.targetFPS, 1)), paused: !driver.isVisible)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, date in
                    let a = driver.appearance
                    face.update(mood: driver.state.mood, blush: driver.state.blush, style: a.face,
                                eyeColor: a.face.defaultEyeColor, time: date.timeIntervalSinceReferenceDate)
                }
            }
        )
        .accessibilityLabel("Companion")
    }
}
