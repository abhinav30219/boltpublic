import BoltCore
import SceneKit
import SpriteKit
import SwiftUI

/// Contract node names the renderer needs. Missing ones become `loadIssue` and show the fallback.
private enum RobotNodes {
    static let legs = Leg.allCases
    static var joints: [String] { legs.flatMap { l in JointKind.allCases.map { JointID(kind: $0, leg: l).nodeName } } }
    static var required: [String] {
        ["robot", "body", "face_anchor"] + joints
            + legs.flatMap { l in ["upperLeg", "lowerLeg", "foot"].map { "\($0)_\(l.rawValue)" } }
            + ["kneeSleeve_FL", "kneeSleeve_FR"]
    }
}

struct SceneKitCompanionView: UIViewRepresentable {
    @ObservedObject var driver: CompanionDriver
    let orbit: CompanionOrbit

    func makeCoordinator() -> Coordinator { Coordinator(driver: driver, orbit: orbit) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        context.coordinator.build(into: view)
        view.delegate = context.coordinator
        applyPlayback(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.appearanceChanged(driver.appearance)
        applyPlayback(view, context.coordinator)
    }

    private func applyPlayback(_ view: SCNView, _ coordinator: Coordinator) {
        // targetFPS 0 means hidden: no frames at all.
        let fps = driver.targetFPS
        view.rendersContinuously = fps > 0
        view.isPlaying = fps > 0
        // The face SKScene is a live texture; it must stop too or SceneKit keeps redrawing.
        coordinator.setFacePaused(fps == 0)
        if fps == 0 { view.pause(nil) } else { view.play(nil) }
        if fps > 0 { view.preferredFramesPerSecond = fps }
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let driver: CompanionDriver
        let orbit: CompanionOrbit
        private let face = FaceRenderer()
        private var joints: [JointID: SCNNode] = [:]
        private var body: SCNNode?
        private var bodyRestPosition = SCNVector3Zero
        private var feet: [SCNNode] = []
        private var faceNode: SCNNode?
        private var facePaused = false
        private var restFootMinY: Float = 0
        private var contactNode: SCNNode?
        private var cameraPivot = SCNNode()
        private var cameraNode: SCNNode?
        private var cameraRestPosition = SCNVector3Zero
        private var root: SCNNode?
        private var appliedAppearance: Appearance?
        private var lastTime: TimeInterval?
        private var startTime: TimeInterval?

        // Camera: 3/4 front view, slow drift.
        private static let cameraFOV = 35.0
        private static let cameraTarget = SCNVector3(0, 0.25, 0)
        private static let cameraPosition = SCNVector3(0.93, 1.02, 1.75)
        private static let driftDegrees = 3.0, driftSeconds = 14.0
        private static let facePlane = CGSize(width: 0.26, height: 0.13)
        private static let faceStandoff: Float = 0.012
        private static let maxDt = 0.1

        init(driver: CompanionDriver, orbit: CompanionOrbit) { self.driver = driver; self.orbit = orbit }

        @MainActor func build(into view: SCNView) {
            let scene = (SCNScene(named: "Robot.usdz")) ?? Bundle.main.url(forResource: "Robot", withExtension: "usdz")
                .flatMap { try? SCNScene(url: $0, options: nil) }
            guard let scene else { report("Missing: Robot.usdz"); return }

            var missing: [String] = []
            var found: [String: SCNNode] = [:]
            for name in RobotNodes.required {
                if let n = scene.rootNode.childNode(withName: name, recursively: true) { found[name] = n } else { missing.append(name) }
            }
            guard missing.isEmpty, let robot = found["robot"], let body = found["body"], let anchor = found["face_anchor"] else {
                report("Missing: " + missing.joined(separator: ", ")); return
            }
            root = robot
            self.body = body
            bodyRestPosition = body.position
            for leg in Leg.allCases { for kind in JointKind.allCases {
                let id = JointID(kind: kind, leg: leg)
                joints[id] = found[id.nodeName]
            } }

            feet = Leg.allCases.compactMap { scene.rootNode.childNode(withName: "foot_\($0.rawValue)_mesh", recursively: true) }
            restFootMinY = lowestFootY()
            ToonShading.apply(to: robot, appearance: driver.appearance)
            appliedAppearance = driver.appearance
            ToonShading.addOutline(to: robot, width: driver.tuning.render.outlineWidth)
            addFace(to: anchor)

            let sceneRoot = scene.rootNode
            cameraPivot.position = Self.cameraTarget
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = Self.cameraFOV
            camera.camera?.zNear = 0.1; camera.camera?.zFar = 20
            camera.position = SCNVector3(Self.cameraPosition.x - Self.cameraTarget.x,
                                         Self.cameraPosition.y - Self.cameraTarget.y,
                                         Self.cameraPosition.z - Self.cameraTarget.z)
            cameraPivot.addChildNode(camera)
            cameraNode = camera
            cameraRestPosition = camera.position
            let look = SCNLookAtConstraint(target: cameraPivot)
            look.isGimbalLockEnabled = true
            camera.constraints = [look]
            sceneRoot.addChildNode(cameraPivot)
            addGround(to: sceneRoot)

            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .directional
            light.eulerAngles = SCNVector3(-0.8, -0.5, 0)
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
            sceneRoot.addChildNode(light); sceneRoot.addChildNode(ambient)

            view.scene = scene
            view.pointOfView = camera
        }

        /// Soft blob plus a darker contact patch lying on the plane the rest-pose soles touch. Both hang off
        /// the scene root (not the body) so they never bob; they draw first and never write depth.
        private func addGround(to sceneRoot: SCNNode) {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for foot in feet {
                let (mn, mx) = foot.boundingBox
                for x in [mn.x, mx.x] { for y in [mn.y, mx.y] { for z in [mn.z, mx.z] {
                    let p = foot.convertPosition(SCNVector3(x, y, z), to: nil)
                    lo = simd_min(lo, SIMD3(p.x, p.y, p.z)); hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
                } } }
            }
            guard lo.x <= hi.x else { return }
            let layout = CompanionGround.Layout(floorY: lo.y, centerX: (lo.x + hi.x) / 2, centerZ: (lo.z + hi.z) / 2,
                                                extentX: hi.x - lo.x, extentZ: hi.z - lo.z)
            func disc(_ name: String, hex: UInt32, alpha: CGFloat, scale: Float, dy: Float, order: Int) -> SCNNode? {
                guard let image = CompanionGround.sceneKitImage(hex: hex, centerAlpha: alpha, squareRoot: true, premultiply: true) else { return nil }
                let plane = SCNPlane(width: CGFloat(layout.extentX * scale), height: CGFloat(layout.extentZ * scale))
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = image
                m.blendMode = .alpha
                m.writesToDepthBuffer = false
                m.isDoubleSided = true
                plane.materials = [m]
                let node = SCNNode(geometry: plane)
                node.name = name
                node.renderingOrder = order
                // SCNPlane faces +Z; lay it flat facing up.
                node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
                node.position = SCNVector3(layout.centerX, layout.floorY + dy, layout.centerZ)
                node.castsShadow = false
                sceneRoot.addChildNode(node)
                return node
            }
            _ = disc("ground_blob", hex: CompanionGround.blobColor, alpha: CompanionGround.blobAlpha, scale: CompanionGround.blobScale, dy: -0.0006, order: -20)
            contactNode = disc("ground_contact", hex: CompanionGround.inkColor, alpha: CompanionGround.contactAlpha * CGFloat(CompanionGround.contactHeadroom),
                               scale: CompanionGround.contactScale, dy: -0.0003, order: -10)
        }

        /// World-space Y of the lowest point of any foot mesh.
        private func lowestFootY() -> Float {
            var low = Float.greatestFiniteMagnitude
            for foot in feet {
                let (mn, mx) = foot.boundingBox
                for x in [mn.x, mx.x] { for y in [mn.y, mx.y] { for z in [mn.z, mx.z] {
                    low = min(low, foot.convertPosition(SCNVector3(x, y, z), to: nil).y)
                } } }
            }
            return low
        }

        private func addFace(to anchor: SCNNode) {
            let plane = SCNPlane(width: Self.facePlane.width, height: Self.facePlane.height)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = face.scene
            // SpriteKit textures arrive upside down on a plane.
            m.diffuse.contentsTransform = SCNMatrix4Translate(SCNMatrix4MakeScale(1, -1, 1), 0, 1, 0)
            m.diffuse.wrapT = .clamp
            m.isDoubleSided = false
            plane.materials = [m]
            let node = SCNNode(geometry: plane)
            node.name = "face_plane"
            // SCNPlane faces +Z; the anchor's face direction is local -Y.
            node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            // Sit just proud of the panel so the model's own eye discs do not poke through.
            node.position = SCNVector3(0, -Self.faceStandoff, 0)
            anchor.addChildNode(node)
            faceNode = node
        }

        private func report(_ issue: String) {
            DispatchQueue.main.async { [driver] in driver.loadIssue = issue }
        }

        /// A live SKScene texture makes SceneKit render every frame no matter what, so while hidden the
        /// face is swapped for a still image of its last state.
        func setFacePaused(_ paused: Bool) {
            guard paused != facePaused, let material = (faceNode?.geometry as? SCNPlane)?.firstMaterial else { return }
            facePaused = paused
            face.scene.isPaused = paused
            if paused {
                let image = SKView().texture(from: face.scene)?.cgImage()
                material.diffuse.contents = image ?? UIColor(companionHex: 0x2B1D18)
            } else {
                material.diffuse.contents = face.scene
            }
        }

        @MainActor func appearanceChanged(_ a: Appearance) {
            guard let root, a != appliedAppearance else { return }
            if a.palette != appliedAppearance?.palette { ToonShading.apply(to: root, appearance: a) }
            appliedAppearance = a
        }

        // Render thread.
        nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let t0 = CACurrentMediaTime()
            step(time: time)
            driver.recordFrame(workMs: (CACurrentMediaTime() - t0) * 1000, now: t0)
        }

        private func step(time: TimeInterval) {
            let dt = min(max(0, time - (lastTime ?? time)), Self.maxDt)
            lastTime = time
            if startTime == nil { startTime = time }
            let pose = driver.nextPose(dt: dt)
            for (id, node) in joints { node.eulerAngles.x = Float(pose.angles[id] ?? 0) }
            if let body {
                // Body-local Z is world up, local X is world right, local Y is world back.
                // The body sits where the lowest foot touches the ground line (so a crouch or the
                // sleep pose does not sink the feet); only upward lift (bob, bounce, hop) leaves it.
                body.position = bodyRestPosition
                body.eulerAngles = SCNVector3(Float(pose.bodyPitch), Float(-pose.bodyRoll), Float(pose.bodyYaw))
                let grounding = restFootMinY - lowestFootY()
                body.position.z = bodyRestPosition.z + grounding + Float(max(0, pose.bodyLift))
            }
            if let contactNode {
                let c = CompanionGround.contact(forLift: pose.bodyLift)
                contactNode.scale = SCNVector3(c.scale, c.scale, 1)
                contactNode.opacity = CGFloat(min(1, c.opacity / CompanionGround.contactHeadroom))
            }
            let drift = Self.driftDegrees * .pi / 180 * sin(2 * .pi * (time - (startTime ?? time)) / Self.driftSeconds)
            let o = orbit.advance(dt: dt)
            cameraPivot.eulerAngles.y = Float(o.yaw + drift * o.driftWeight)
            if let cameraNode {   // pulled back while a flip plays, so the body is not clipped at the top
                let k = Float(driver.cameraDistanceScale)
                cameraNode.position = SCNVector3(cameraRestPosition.x * k, cameraRestPosition.y * k, cameraRestPosition.z * k)
            }
            let (a, state) = driver.renderSnapshot
            face.update(mood: state.mood, blush: state.blush, style: a.face, eyeColor: a.face.defaultEyeColor, time: time)
        }
    }
}
