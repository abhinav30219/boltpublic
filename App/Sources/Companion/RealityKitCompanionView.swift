import BoltCore
import Combine
import Metal
import QuartzCore
import RealityKit
import SpriteKit
import SwiftUI

/// The RealityKit twin of `SceneKitCompanionView`. It consumes the same things: `CompanionDriver`
/// (`nextPose`, `renderSnapshot`, `targetFPS`, `recordFrame`), `Robot.usdz` and `FaceRenderer`.
/// Toon bands and the ink hull come from `ToonMaterial.metal` through `CustomMaterial`; the face is a
/// `TextureResource.DrawableQueue` that `SKRenderer` draws the `FaceRenderer` scene into.
/// If a `CustomMaterial` cannot be built (no Metal library, unsupported device), parts fall back to a lit
/// `PhysicallyBasedMaterial` in the palette colour and `Coordinator.usesToonShader` is false.
struct RealityKitCompanionView: UIViewRepresentable {
    @ObservedObject var driver: CompanionDriver
    let orbit: CompanionOrbit

    func makeCoordinator() -> Coordinator { Coordinator(driver: driver, orbit: orbit) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.environment.background = .color(.clear)
        view.renderOptions.formUnion([.disableMotionBlur, .disableDepthOfField, .disableGroundingShadows,
                                      .disableCameraGrain, .disableAREnvironmentLighting])
        context.coordinator.build(into: view)
        applyPlayback(view, context.coordinator)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.appearanceChanged(driver.appearance)
        applyPlayback(view, context.coordinator)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    private func applyPlayback(_ view: ARView, _ coordinator: Coordinator) {
        // targetFPS 0 means hidden. RealityKit has no public pause or frame cap for a non-AR ARView (hiding it
        // or `__preferredFrameRate` did not stop updates), so `CompanionView` removes the view while hidden;
        // this only gates stepping between the 60 Hz draws while visible.
        coordinator.setTargetFPS(driver.targetFPS)
    }

    @MainActor
    final class Coordinator {
        let driver: CompanionDriver
        let orbit: CompanionOrbit
        private let face = FaceRenderer()
        private var arView: ARView?
        private var updateSub: Cancellable?
        private var joints: [JointID: Entity] = [:]
        private var body: Entity?
        private var bodyRestPosition = SIMD3<Float>.zero
        private var feet: [Entity] = []
        private var restFootMinY: Float = 0
        private var contact: ModelEntity?
        private var contactTexture: TextureResource?
        private var contactHex: UInt32 = 0, contactCenterAlpha: Float = 0
        private var contactLibrary: MTLLibrary?
        private var contactOpacity: Float = -1
        private var cameraPivot = Entity()
        private var camera = PerspectiveCamera()
        private var cameraRestPosition = SIMD3<Float>.zero
        private var toonParts: [ToonPart] = []
        private var appliedAppearance: Appearance?
        private var targetFPS = 0
        private var lastStep: TimeInterval?
        private var startTime: TimeInterval?
        private var faceOutput: FaceOutput?
        private(set) var usesToonShader = true

        // Camera and face placement match SceneKitCompanionView.
        private static let cameraFOV: Float = 35
        private static let cameraTarget = SIMD3<Float>(0, 0.25, 0)
        private static let cameraPosition = SIMD3<Float>(0.93, 1.02, 1.75)
        private static let driftDegrees = 3.0, driftSeconds = 14.0
        private static let facePlane = SIMD2<Float>(0.26, 0.13)
        private static let faceStandoff: Float = 0.012
        private static let maxDt = 0.1
        /// Measured on the simulator: unlit emissive output comes out about 0.69 of the palette value in linear terms.
        static let outputGain: Float = 1.4
        private static let faceMaxHz = 30.0
        /// Slack so a 30 fps target still steps on every second 60 Hz vsync despite timer jitter.
        private static let stepSlack = 0.004

        init(driver: CompanionDriver, orbit: CompanionOrbit) { self.driver = driver; self.orbit = orbit }

        // MARK: Loading

        func build(into view: ARView) {
            arView = view
            guard let url = Bundle.main.url(forResource: "Robot", withExtension: "usdz"),
                  let loaded = try? Entity.load(contentsOf: url) else { report("Missing: Robot.usdz"); return }

            var missing: [String] = []
            func find(_ name: String) -> Entity? {
                if let e = loaded.findEntity(named: name) { return e }
                missing.append(name); return nil
            }
            let required = RobotNodes.required
            let found = required.compactMap { name in find(name).map { (name, $0) } }
            let byName = Dictionary(uniqueKeysWithValues: found)
            guard missing.isEmpty, let robot = byName["robot"], let body = byName["body"],
                  let anchor = byName["face_anchor"] else {
                report("Missing: " + missing.joined(separator: ", ")); return
            }
            self.body = body
            bodyRestPosition = body.position
            for leg in Leg.allCases { for kind in JointKind.allCases {
                let id = JointID(kind: kind, leg: leg)
                joints[id] = byName[id.nodeName]
            } }
            feet = Leg.allCases.compactMap { robot.findEntity(named: "foot_\($0.rawValue)_mesh") }
            restFootMinY = lowestFootY()

            applyToon(to: robot, appearance: driver.appearance)
            appliedAppearance = driver.appearance
            addFace(to: anchor)

            let anchorRoot = AnchorEntity(world: .zero)
            anchorRoot.addChild(loaded)
            cameraPivot.position = Self.cameraTarget
            camera.camera.fieldOfViewInDegrees = Self.cameraFOV
            camera.camera.near = 0.1; camera.camera.far = 20
            cameraPivot.addChild(camera)
            camera.look(at: Self.cameraTarget, from: Self.cameraPosition, relativeTo: nil)
            cameraRestPosition = camera.position   // local to the pivot, which sits on the target
            anchorRoot.addChild(cameraPivot)
            addGround(to: anchorRoot)
            if !usesToonShader { anchorRoot.addChild(Self.fallbackLight()) }
            view.scene.addAnchor(anchorRoot)
            fixLightInWorld()

            updateSub = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.frame() }
            }
        }

        func teardown() {
            updateSub?.cancel(); updateSub = nil
            arView?.scene.anchors.removeAll()
            arView = nil
        }

        private func report(_ issue: String) {
            DispatchQueue.main.async { [driver] in driver.loadIssue = issue }
        }

        // MARK: Materials

        /// One mesh entity that carries a toon material, with its outline hull child.
        private struct ToonPart {
            var entity: ModelEntity
            var role: Role
        }
        private enum Role { case shell, limb, joint, foot }

        private static func role(forMesh name: String) -> Role? {
            let part = name.hasSuffix("_mesh") ? String(name.dropLast(5)) : name
            if part == "body" { return .shell }
            if part.hasPrefix("upperLeg") { return .limb }
            if part.hasPrefix("lowerLeg") || part.hasPrefix("kneeSleeve") { return .joint }
            if part.hasPrefix("foot") { return .foot }
            return nil
        }

        private static func color(_ role: Role, _ palette: BodyPalette) -> UIColor {
            switch role {
            case .shell: return palette.shell
            case .limb: return palette.limb
            case .joint: return palette.joint
            case .foot: return palette.foot
            }
        }

        private static let outlineHullName = "outline_hull"

        private func applyToon(to root: Entity, appearance: Appearance) {
            var meshes: [ModelEntity] = []
            func walk(_ e: Entity) {
                if let m = e as? ModelEntity, m.model != nil, e.name != Self.outlineHullName { meshes.append(m) }
                e.children.forEach(walk)
            }
            walk(root)

            var library = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
            #if DEBUG
            // `-rk.fallback 1` forces the PhysicallyBasedMaterial path for testing.
            if UserDefaults.standard.bool(forKey: "rk.fallback") { library = nil }
            #endif
            let outline = library.flatMap { Self.makeOutlineMaterial(library: $0, width: driver.tuning.render.outlineWidth) }
            let light = Self.lightDirectionWorld(camera: nil)
            for mesh in meshes {
                guard let role = Self.role(forMesh: mesh.name), let model = mesh.model else { continue }
                let count = max(1, model.materials.count)
                let color = Self.color(role, appearance.palette)
                if let library, let toon = Self.makeToonMaterial(library: library, color: color, light: light) {
                    mesh.model?.materials = Array(repeating: toon, count: count)
                } else {
                    usesToonShader = false
                    mesh.model?.materials = Array(repeating: Self.fallbackMaterial(color), count: count)
                }
                if let outline {
                    let hull = ModelEntity(mesh: model.mesh, materials: Array(repeating: outline, count: count))
                    hull.name = Self.outlineHullName
                    mesh.addChild(hull)
                }
                toonParts.append(ToonPart(entity: mesh, role: role))
            }
        }

        private static func makeToonMaterial(library: MTLLibrary, color: UIColor, light: SIMD3<Float>) -> CustomMaterial? {
            let shader = CustomMaterial.SurfaceShader(named: "toonSurface", in: library)
            var made: CustomMaterial?
            do { made = try CustomMaterial(from: UnlitMaterial(), surfaceShader: shader) } catch { dbg("toon: \(error)") }
            guard var m = made else { return nil }
            m.faceCulling = .back
            m.baseColor = .init(tint: color)
            m.custom.value = SIMD4<Float>(light, outputGain)
            return m
        }

        private static func makeOutlineMaterial(library: MTLLibrary, width: Double) -> CustomMaterial? {
            let surface = CustomMaterial.SurfaceShader(named: "outlineSurface", in: library)
            let geometry = CustomMaterial.GeometryModifier(named: "outlineGeometry", in: library)
            var made: CustomMaterial?
            do { made = try CustomMaterial(from: UnlitMaterial(), surfaceShader: surface, geometryModifier: geometry) } catch { dbg("outline: \(error)") }
            guard var m = made else { return nil }
            m.faceCulling = .front
            m.baseColor = .init(tint: ToonShading.outlineInk)
            m.custom.value = SIMD4<Float>(Float(width), 0, 0, 0)
            return m
        }

        private static func fallbackMaterial(_ color: UIColor) -> PhysicallyBasedMaterial {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: color)
            m.roughness = 0.9
            m.metallic = 0.0
            return m
        }

        private static func fallbackLight() -> Entity {
            let light = DirectionalLight()
            light.look(at: .zero, from: lightDirectionWorld(camera: nil), relativeTo: nil)
            light.light.intensity = 2500
            return light
        }

        /// The fixed view-space light of `ToonShading.lightDirection`, rotated into world space by the camera.
        private static func lightDirectionWorld(camera: Entity?) -> SIMD3<Float> {
            let l = ToonShading.lightDirection
            let view = simd_normalize(SIMD3<Float>(l.x, l.y, l.z))
            guard let camera else { return view }
            return simd_normalize(camera.orientation(relativeTo: nil).act(view))
        }

        @MainActor func appearanceChanged(_ a: Appearance) {
            guard a != appliedAppearance else { return }
            if a.palette != appliedAppearance?.palette { recolor(a.palette) }
            appliedAppearance = a
        }

        private func recolor(_ palette: BodyPalette) {
            for part in toonParts {
                let color = Self.color(part.role, palette)
                part.entity.model?.materials = (part.entity.model?.materials ?? []).map { material in
                    if var toon = material as? CustomMaterial { toon.baseColor = .init(tint: color); return toon }
                    return Self.fallbackMaterial(color)
                }
            }
        }

        // MARK: Face

        /// How the SpriteKit face scene reaches the plane's texture.
        /// `drawables`: `SKRenderer` draws straight into a `TextureResource.DrawableQueue` (GPU only).
        /// `images`: the scene is snapshotted to a `CGImage` and copied into one texture with `replace(withImage:)`.
        /// The simulator never recycles queue drawables (`nextDrawable` times out after three frames), so it
        /// starts in `images`; a device starts in `drawables` and drops to `images` if a drawable ever times out.
        /// Either way the face is redrawn only when `FaceRenderer.revision` moved, at most `faceMaxHz` times a second.
        private enum FaceMode { case drawables, images }

        private struct FaceOutput {
            var mode: FaceMode
            var texture: TextureResource
            var queue: TextureResource.DrawableQueue?
            var renderer: SKRenderer?
            var commands: MTLCommandQueue?
            /// Created on first use, only in image mode.
            var snapshotView: SKView?
            var size: CGSize
            var lastDraw: TimeInterval = 0
            var drawnRevision = -1
        }

        private static let faceTextureOptions = TextureResource.CreateOptions(semantic: .color)
        private var facePlane: ModelEntity?

        private func addFace(to anchor: Entity) {
            let pixel = face.scene.size
            guard let first = Self.snapshot(face.scene, in: SKView(frame: CGRect(origin: .zero, size: pixel))),
                  let texture = try? TextureResource.generate(from: first, options: Self.faceTextureOptions) else {
                report("RealityKit face texture unavailable"); return
            }
            var out = FaceOutput(mode: .images, texture: texture, size: pixel)
            #if !targetEnvironment(simulator)
            if let device = MTLCreateSystemDefaultDevice(), let commands = device.makeCommandQueue(),
               let queue = try? TextureResource.DrawableQueue(.init(
                   pixelFormat: .bgra8Unorm, width: Int(pixel.width), height: Int(pixel.height),
                   usage: [.renderTarget, .shaderRead], mipmapsMode: .none)) {
                // A short bound: a drawable that does not come back means RealityKit is not recycling them.
                queue.allowsNextDrawableTimeout = true
                let renderer = SKRenderer(device: device)
                renderer.scene = face.scene
                texture.replace(withDrawables: queue)
                out.mode = .drawables
                out.queue = queue; out.renderer = renderer; out.commands = commands
            }
            #endif
            faceOutput = out
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            let plane = ModelEntity(mesh: .generatePlane(width: Self.facePlane.x, height: Self.facePlane.y), materials: [material])
            plane.name = "face_plane"
            // generatePlane faces +Z; the anchor's face direction is local -Y.
            plane.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            // Sit just proud of the panel so the model's own eye discs do not poke through.
            plane.position = SIMD3<Float>(0, -Self.faceStandoff, 0)
            anchor.addChild(plane)
            facePlane = plane
        }

        private static func snapshot(_ scene: SKScene, in view: SKView) -> CGImage? {
            view.texture(from: scene)?.cgImage()
        }

        private func drawFace(now: TimeInterval) {
            guard var out = faceOutput, out.drawnRevision != face.revision,
                  now - out.lastDraw >= 1 / Self.faceMaxHz - Self.stepSlack else { return }
            defer { faceOutput = out }
            if out.mode == .drawables, let queue = out.queue, let renderer = out.renderer, let commands = out.commands {
                if let drawable = try? queue.nextDrawable(), let buffer = commands.makeCommandBuffer() {
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = drawable.texture
                    pass.colorAttachments[0].loadAction = .clear
                    pass.colorAttachments[0].storeAction = .store
                    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    renderer.update(atTime: now)
                    renderer.render(withViewport: CGRect(origin: .zero, size: out.size), commandBuffer: buffer, renderPassDescriptor: pass)
                    // Present on every outcome so a failed command buffer cannot leak the drawable. The closure
                    // runs on a Metal thread and captures only the drawable.
                    buffer.addCompletedHandler { @Sendable _ in drawable.present() }
                    buffer.commit()
                    out.lastDraw = now
                    out.drawnRevision = face.revision
                    return
                }
                // No drawable (timed out) or no command buffer: stop using the queue.
                out.mode = .images
                dbg("drawable queue unavailable, switching to image snapshots")
            }
            let view = out.snapshotView ?? SKView(frame: CGRect(origin: .zero, size: out.size))
            out.snapshotView = view
            guard let image = Self.snapshot(face.scene, in: view) else { return }
            try? out.texture.replace(withImage: image, options: Self.faceTextureOptions)
            out.lastDraw = now
            out.drawnRevision = face.revision
        }

        // MARK: Frame loop

        func setTargetFPS(_ fps: Int) {
            guard fps != targetFPS else { return }
            targetFPS = fps
            face.scene.isPaused = fps == 0
            if fps == 0 { lastStep = nil }
        }

        /// Soft blob plus a darker contact patch on the plane the rest-pose soles touch. Both hang off the scene
        /// anchor (not the body) so they never bob. Unlit transparent materials do not write depth, so they cannot
        /// hide legs; they sit a hair below the soles to avoid z-fighting.
        /// Unlit output comes out darker than the texture; this brings the ground back to its hex colours.
        private static let groundGain = 1.45

        private func addGround(to anchorRoot: Entity) {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for foot in feet {
                let b = foot.visualBounds(recursive: false, relativeTo: nil)
                lo = simd_min(lo, b.min); hi = simd_max(hi, b.max)
            }
            guard lo.x <= hi.x else { return }
            let center = SIMD3<Float>((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
            let extent = SIMD2<Float>(hi.x - lo.x, hi.z - lo.z)
            let library = UserDefaults.standard.bool(forKey: "rk.fallback") ? nil : MTLCreateSystemDefaultDevice()?.makeDefaultLibrary()
            func disc(_ name: String, hex: UInt32, alpha: CGFloat, scale: Float, dy: Float) -> (ModelEntity, TextureResource?)? {
                var m: RealityKit.Material
                var texture: TextureResource?
                if let library, let g = Self.makeGroundMaterial(library: library, hex: hex, alpha: Float(alpha), opacity: 1) {
                    m = g
                } else {
                    guard let image = CompanionGround.sceneKitImage(hex: hex, centerAlpha: alpha, size: 256, squareRoot: false, premultiply: true, gain: Self.groundGain),
                          let t = try? TextureResource.generate(from: image, options: .init(semantic: .color)) else { return nil }
                    var u = UnlitMaterial()
                    u.color = .init(tint: .white, texture: .init(t))
                    u.blending = .transparent(opacity: .init(floatLiteral: 1))
                    m = u; texture = t
                }
                let e = ModelEntity(mesh: .generatePlane(width: extent.x * scale, depth: extent.y * scale), materials: [m])
                e.name = name
                e.position = SIMD3<Float>(center.x, center.y + dy, center.z)
                anchorRoot.addChild(e)
                return (e, texture)
            }
            _ = disc("ground_blob", hex: CompanionGround.blobColor, alpha: CompanionGround.blobAlpha, scale: CompanionGround.blobScale, dy: -0.0012)
            let contactAlpha = CompanionGround.contactAlpha * CGFloat(CompanionGround.contactHeadroom)
            if let (e, t) = disc("ground_contact", hex: CompanionGround.inkColor, alpha: contactAlpha,
                                 scale: CompanionGround.contactScale, dy: -0.0006) {
                contact = e; contactTexture = t; contactHex = CompanionGround.inkColor; contactCenterAlpha = Float(contactAlpha)
                contactLibrary = library
            }
        }

        private static func makeGroundMaterial(library: MTLLibrary, hex: UInt32, alpha: Float, opacity: Float) -> CustomMaterial? {
            let shader = CustomMaterial.SurfaceShader(named: "groundSurface", in: library)
            guard var m = try? CustomMaterial(from: UnlitMaterial(), surfaceShader: shader) else { return nil }
            m.baseColor = .init(tint: UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                                              blue: CGFloat(hex & 0xFF) / 255, alpha: 1))
            m.custom.value = SIMD4<Float>(alpha * opacity, 0, 0, outputGain)
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            m.faceCulling = .none
            return m
        }

        private func updateContact(lift: Double) {
            guard let contact else { return }
            let c = CompanionGround.contact(forLift: lift)
            contact.scale = SIMD3<Float>(c.scale, 1, c.scale)
            let opacity = min(1, c.opacity / CompanionGround.contactHeadroom)
            if abs(opacity - contactOpacity) > 0.01 {
                contactOpacity = opacity
                if let library = contactLibrary,
                   let g = Self.makeGroundMaterial(library: library, hex: contactHex, alpha: contactCenterAlpha, opacity: opacity) {
                    contact.model?.materials = [g]
                } else if let texture = contactTexture {
                    var m = UnlitMaterial()
                    m.color = .init(tint: .white, texture: .init(texture))
                    m.blending = .transparent(opacity: .init(floatLiteral: opacity))
                    contact.model?.materials = [m]
                }
            }
        }

        /// World-space Y of the lowest point of any foot mesh.
        private func lowestFootY() -> Float {
            feet.map { $0.visualBounds(recursive: false, relativeTo: nil).min.y }.min() ?? 0
        }

        /// RealityKit calls this every display frame; the driver's fps cap is applied by skipping frames.
        private func frame() {
            guard targetFPS > 0 else { return }
            let now = CACurrentMediaTime()
            if let last = lastStep, now - last < 1 / Double(targetFPS) - Self.stepSlack { return }
            let t0 = now
            let dt = min(max(0, now - (lastStep ?? now)), Self.maxDt)
            lastStep = now
            if startTime == nil { startTime = now }
            step(time: now, dt: dt)
            driver.recordFrame(workMs: (CACurrentMediaTime() - t0) * 1000, now: t0)
        }

        private func step(time: TimeInterval, dt: Double) {
            let pose = driver.nextPose(dt: dt)
            for (id, joint) in joints {
                joint.orientation = simd_quatf(angle: Float(pose.angles[id] ?? 0), axis: [1, 0, 0])
            }
            if let body {
                // Body-local Z is world up, local X is world right, local Y is world back.
                // The body sits where the lowest foot touches the ground line (so a crouch or the
                // sleep pose does not sink the feet); only upward lift (bob, bounce, hop) leaves it.
                body.position = bodyRestPosition
                let pitch = simd_quatf(angle: Float(pose.bodyPitch), axis: [1, 0, 0])
                let roll = simd_quatf(angle: Float(-pose.bodyRoll), axis: [0, 1, 0])
                let yaw = simd_quatf(angle: Float(pose.bodyYaw), axis: [0, 0, 1])
                body.orientation = pitch * roll * yaw
                let grounding = restFootMinY - lowestFootY()
                body.position.z = bodyRestPosition.z + grounding + Float(max(0, pose.bodyLift))
            }
            updateContact(lift: pose.bodyLift)
            let drift = Self.driftDegrees * .pi / 180 * sin(2 * .pi * (time - (startTime ?? time)) / Self.driftSeconds)
            let o = orbit.advance(dt: dt)
            cameraPivot.orientation = simd_quatf(angle: Float(o.yaw + drift * o.driftWeight), axis: [0, 1, 0])
            camera.position = cameraRestPosition * Float(driver.cameraDistanceScale)   // pulled back during a flip
            let (a, state) = driver.renderSnapshot
            face.update(mood: state.mood, blush: state.blush, style: a.face, eyeColor: a.face.defaultEyeColor, time: time)
            drawFace(now: time)
        }

        /// The light is fixed in world space, taken from the rest camera. The camera only drifts a few degrees,
        /// so the bands move by less than that; this runs once instead of rewriting every material per step.
        private func fixLightInWorld() {
            guard usesToonShader else { return }
            let light = SIMD4<Float>(Self.lightDirectionWorld(camera: camera), Self.outputGain)
            for part in toonParts {
                guard var model = part.entity.model else { continue }
                model.materials = model.materials.map { material in
                    guard var toon = material as? CustomMaterial else { return material }
                    toon.custom.value = light
                    return toon
                }
                part.entity.model = model
            }
        }
    }
}

private func dbg(_ s: String) {
    #if DEBUG
    print("RKDBG " + s)
    #endif
}

/// Contract node names the renderer needs (same list as the SceneKit renderer).
private enum RobotNodes {
    static let legs = Leg.allCases
    static var required: [String] {
        ["robot", "body", "face_anchor"]
            + legs.flatMap { l in JointKind.allCases.map { JointID(kind: $0, leg: l).nodeName } }
            + legs.flatMap { l in ["upperLeg", "lowerLeg", "foot"].map { "\($0)_\(l.rawValue)" } }
            + ["kneeSleeve_FL", "kneeSleeve_FR"]
    }
}
