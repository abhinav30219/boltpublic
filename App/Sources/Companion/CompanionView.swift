import SwiftUI

struct CompanionView: View {
    @ObservedObject var driver: CompanionDriver
    var height: CGFloat = 220
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    @StateObject private var orbit = CompanionOrbit()
    @GestureState private var touching = false
    @State private var rotating: Bool?
    @State private var dragBaseline = 0.0
    @AppStorage(CompanionRendererKind.defaultsKey) private var renderer = CompanionRendererKind.sceneKit

    init(driver: CompanionDriver, height: CGFloat = 220) {
        self.driver = driver
        self.height = height
    }

    private var stack: some View {
        ZStack {
            if driver.loadIssue == nil {
                switch renderer {
                case .sceneKit: SceneKitCompanionView(driver: driver, orbit: orbit)
                case .realityKit:
                    // An ARView cannot be paused, so it is torn down while hidden (see RealityKitCompanionView).
                    if driver.isVisible { RealityKitCompanionView(driver: driver, orbit: orbit) }
                }
            } else {
                CompanionFallbackView(driver: driver)
            }
            CompanionOverlays(driver: driver)
        }
    }

    /// Mostly-horizontal drags turn Bolt; vertical ones are left to the enclosing ScrollView.
    private var interactive: some View {
        stack
            .frame(height: height)
            .contentShape(Rectangle())
            .simultaneousGesture(rotateGesture)
            .onChange(of: touching) { _, now in
                if !now { orbit.endDrag(); rotating = nil }
            }
            .onChange(of: driver.reduceMotion) { _, _ in configureOrbit() }
            .onChange(of: driver.tuning.companion.touchReturnSeconds) { _, _ in configureOrbit() }
    }

    var body: some View {
        interactive
        .onChange(of: renderer) { _, _ in driver.loadIssue = nil }
        .onAppear {
            onScreen = true; driver.isVisible = scenePhase == .active
            configureOrbit()
            #if DEBUG
            if UserDefaults.standard.object(forKey: "orbitTo") != nil {
                orbit.debugRelease(robotDegrees: UserDefaults.standard.double(forKey: "orbitTo"))
            }
            #endif
        }
        .onDisappear { onScreen = false; driver.isVisible = false }
        .onChange(of: scenePhase) { _, phase in driver.isVisible = onScreen && phase == .active }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your companion")
        .accessibilityHint("Drag sideways to turn Bolt around")
    }

    private var rotateGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { v in
                if rotating == nil {
                    rotating = abs(v.translation.width) > abs(v.translation.height)
                    if rotating == true { dragBaseline = v.translation.width; orbit.beginDrag() }
                }
                if rotating == true { orbit.drag(translationX: v.translation.width - dragBaseline) }
            }
    }

    private func configureOrbit() {
        orbit.configure(returnDelay: driver.tuning.companion.touchReturnSeconds, reduceMotion: driver.reduceMotion)
    }
}
