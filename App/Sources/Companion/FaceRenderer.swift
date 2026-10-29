import BoltCore
import SpriteKit
import UIKit

/// Draws the companion's face into a 2D scene. The scene is used as a texture on the 3D front panel
/// and directly by the 2D fallback. Nodes are rebuilt only when mood, blush bucket or style change.
final class FaceRenderer {
    let scene: SKScene
    /// Bumps whenever the drawn face visibly changed (rebuild, blink, gaze step, scan bar). Renderers that copy
    /// the face into a texture redraw only when this moves.
    private(set) var revision = 0
    private var lastLook: Look?

    private let size: CGSize
    private let gaze = SKNode()
    private let eyes = SKNode()
    private let brows = SKNode()
    private let mouth = SKNode()
    private let blushL = SKShapeNode(ellipseOf: CGSize(width: 44, height: 24))
    private let blushR = SKShapeNode(ellipseOf: CGSize(width: 44, height: 24))
    private let scanBar = SKShapeNode(rectOf: CGSize(width: 10, height: 64), cornerRadius: 5)

    private var key: Key?
    private var eyeColor = UIColor.white
    private var nextBlinkAt = 0.0
    private var blinkUntil = 0.0
    private var gazeTarget = CGPoint.zero
    private var nextGazeAt = 0.0
    private var closedEyes = false
    private var scanning = false
    private var rng = SystemRandomNumberGenerator()

    private struct Look: Equatable {
        var gazeX: Int, gazeY: Int, eyeScale: CGFloat, scanX: Int, key: Key?
    }

    private struct Key: Equatable {
        var mood: CompanionMood
        var blushBucket: Int
        var style: FaceStyle
        var color: UIColor
    }

    private static let background = UIColor(companionHex: 0x2B1D18)
    private static let blushColor = UIColor(companionHex: 0xFF8FA3)
    private static let eyeOffsetX: CGFloat = 52
    private static let eyeY: CGFloat = 0.56
    private static let blinkSeconds = 0.12
    private static let blinkInterval = 3.0...5.0
    private static let gazeInterval = 1.5...3.5
    private static let gazeRange: CGFloat = 7

    init(size: CGSize = CGSize(width: 256, height: 128)) {
        self.size = size
        scene = SKScene(size: size)
        scene.scaleMode = .aspectFill
        scene.backgroundColor = Self.background
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        gaze.position = .zero
        scene.addChild(gaze)
        gaze.addChild(eyes); gaze.addChild(brows); gaze.addChild(mouth)
        for (node, dx) in [(blushL, -78.0), (blushR, 78.0)] {
            node.position = CGPoint(x: center.x + dx, y: size.height * 0.34)
            node.lineWidth = 0
            node.fillColor = Self.blushColor
            node.alpha = 0
            scene.addChild(node)
        }
        scanBar.fillColor = .white
        scanBar.lineWidth = 0
        scanBar.position = CGPoint(x: center.x, y: size.height * Self.eyeY)
        scanBar.isHidden = true
        scene.addChild(scanBar)
    }

    func update(mood: CompanionMood, blush: Double, style: FaceStyle, eyeColor: UIColor, time: TimeInterval) {
        let k = Key(mood: mood, blushBucket: Int((max(0, min(1, blush)) * 10).rounded()), style: style, color: eyeColor)
        if k != key {
            key = k
            self.eyeColor = eyeColor
            rebuild(k)
        }

        // Gaze drift.
        if time >= nextGazeAt {
            nextGazeAt = time + Double.random(in: Self.gazeInterval, using: &rng)
            gazeTarget = CGPoint(x: .random(in: -Self.gazeRange...Self.gazeRange, using: &rng),
                                 y: .random(in: -Self.gazeRange / 2...Self.gazeRange / 2, using: &rng))
        }
        gaze.position = CGPoint(x: gaze.position.x + (gazeTarget.x - gaze.position.x) * 0.08,
                                y: gaze.position.y + (gazeTarget.y - gaze.position.y) * 0.08)

        // Blink.
        if time >= nextBlinkAt {
            blinkUntil = time + Self.blinkSeconds
            nextBlinkAt = time + Double.random(in: Self.blinkInterval, using: &rng)
        }
        eyes.yScale = (!closedEyes && time < blinkUntil) ? 0.1 : 1

        if scanning {
            let sweep = sin(time * 2.4)
            scanBar.position.x = size.width / 2 + CGFloat(sweep) * size.width * 0.3
        }

        // Quarter-point buckets: the gaze easing settles, so a still face stops bumping the revision.
        let look = Look(gazeX: Int((gaze.position.x * 4).rounded()), gazeY: Int((gaze.position.y * 4).rounded()),
                        eyeScale: eyes.yScale, scanX: scanning ? Int(scanBar.position.x.rounded()) : 0, key: key)
        if look != lastLook { lastLook = look; revision += 1 }
    }

    // MARK: Drawing

    private func rebuild(_ k: Key) {
        eyes.removeAllChildren(); brows.removeAllChildren(); mouth.removeAllChildren()
        let alpha = CGFloat(k.blushBucket) / 10
        blushL.alpha = alpha; blushR.alpha = alpha
        scanning = k.mood == .scanning
        scanBar.isHidden = !scanning
        scanBar.fillColor = eyeColor
        closedEyes = k.mood == .sleeping || k.mood == .happy || k.mood == .relieved
        eyes.yScale = 1

        let cx = size.width / 2, cy = size.height * Self.eyeY
        eyes.position = CGPoint(x: cx, y: cy)
        if scanning { return }
        for side in [-1.0, 1.0] {
            let node = eyeNode(mood: k.mood, style: k.style, side: CGFloat(side))
            node.position = CGPoint(x: CGFloat(side) * Self.eyeOffsetX, y: 0)
            eyes.addChild(node)
        }

        switch k.mood {
        case .concerned:
            for side in [-1.0, 1.0] {
                // Worried: inner ends raised (\ / shape), not angry.
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -16 * side, y: 7)); p.addLine(to: CGPoint(x: 16 * side, y: -5))
                brows.addChild(stroke(p, at: CGPoint(x: cx + CGFloat(side) * Self.eyeOffsetX, y: cy + 36), width: 6))
            }
            // Small wavy mouth.
            let w = CGMutablePath()
            w.move(to: CGPoint(x: -16, y: 0))
            w.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: -11, y: 6), control2: CGPoint(x: -6, y: 6))
            w.addCurve(to: CGPoint(x: 16, y: 0), control1: CGPoint(x: 6, y: -6), control2: CGPoint(x: 11, y: -6))
            mouth.addChild(stroke(w, at: CGPoint(x: cx, y: size.height * 0.30), width: 4))
        case .determined:
            for side in [-1.0, 1.0] {
                let p = CGMutablePath()
                // Focused V: inner ends LOW (opposite of worried).
                p.move(to: CGPoint(x: -17 * side, y: -6)); p.addLine(to: CGPoint(x: 17 * side, y: 6))
                brows.addChild(stroke(p, at: CGPoint(x: cx + CGFloat(side) * Self.eyeOffsetX, y: cy + 34), width: 6))
            }
        case .relieved:
            let p = CGMutablePath()
            p.addArc(center: .zero, radius: 14, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
            mouth.addChild(stroke(p, at: CGPoint(x: cx, y: size.height * 0.30), width: 5))
        default: break
        }
    }

    private func eyeNode(mood: CompanionMood, style: FaceStyle, side: CGFloat) -> SKNode {
        let root = SKNode()
        let r: CGFloat = 19
        switch mood {
        case .happy:
            let p = CGMutablePath()
            p.addArc(center: CGPoint(x: 0, y: -8), radius: 19, startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: false)
            root.addChild(stroke(p, at: .zero, width: 8))
        case .sleeping:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -17, y: 0)); p.addLine(to: CGPoint(x: 17, y: 0))
            root.addChild(stroke(p, at: .zero, width: 7))
        case .relieved:
            let p = CGMutablePath()
            p.addArc(center: CGPoint(x: 0, y: 10), radius: 17, startAngle: .pi * 1.2, endAngle: .pi * 1.8, clockwise: false)
            root.addChild(stroke(p, at: .zero, width: 7))
        case .tired:
            root.addChild(clipped(style: style, radius: r, keep: 0.5))
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: -22, y: 3 * side)); lid.addLine(to: CGPoint(x: 22, y: -3 * side))
            root.addChild(stroke(lid, at: CGPoint(x: 0, y: 0), width: 5))
        case .calm:
            root.addChild(clipped(style: style, radius: r, keep: 0.7))
        case .determined:
            root.addChild(clipped(style: style, radius: r, keep: 0.8))
        case .concerned:
            // Slightly softer: a touch of lid on top.
            root.addChild(clipped(style: style, radius: r, keep: 0.92))
        default:
            root.addChild(fullEye(style: style, radius: r))
        }
        return root
    }

    /// The style's eye with the top (1 - keep) cut off by a flat lid.
    private func clipped(style: FaceStyle, radius: CGFloat, keep: CGFloat) -> SKNode {
        let crop = SKCropNode()
        let mask = SKShapeNode(rectOf: CGSize(width: radius * 3, height: radius * 2 * keep))
        mask.fillColor = .white
        mask.lineWidth = 0
        mask.position = CGPoint(x: 0, y: -radius * (1 - keep))
        crop.maskNode = mask
        crop.addChild(fullEye(style: style, radius: radius))
        return crop
    }

    private func fullEye(style: FaceStyle, radius r: CGFloat) -> SKNode {
        let n = SKNode()
        switch style {
        case .roundDots:
            n.addChild(fill(SKShapeNode(circleOfRadius: r)))
        case .sleepyArcs:
            // Wide, soft, slightly flattened eye with a heavy upper lid.
            let e = SKShapeNode(ellipseOf: CGSize(width: r * 2.3, height: r * 1.5))
            n.addChild(fill(e))
        case .sparkly:
            n.addChild(fill(SKShapeNode(circleOfRadius: r * 1.05)))
            let h1 = SKShapeNode(circleOfRadius: r * 0.34); h1.fillColor = .white; h1.lineWidth = 0
            h1.position = CGPoint(x: -r * 0.35, y: r * 0.4); n.addChild(h1)
            let h2 = SKShapeNode(circleOfRadius: r * 0.16); h2.fillColor = .white; h2.lineWidth = 0
            h2.position = CGPoint(x: r * 0.4, y: -r * 0.35); n.addChild(h2)
        case .pixelLED:
            let cell: CGFloat = r * 0.5
            let rows = ["0110", "1111", "1111", "0110"]
            for (j, row) in rows.enumerated() {
                for (i, c) in row.enumerated() where c == "1" {
                    let px = SKShapeNode(rectOf: CGSize(width: cell - 2, height: cell - 2))
                    px.position = CGPoint(x: (CGFloat(i) - 1.5) * cell, y: (1.5 - CGFloat(j)) * cell)
                    n.addChild(fill(px))
                }
            }
        }
        return n
    }

    private func fill(_ s: SKShapeNode) -> SKShapeNode { s.fillColor = eyeColor; s.lineWidth = 0; return s }

    private func stroke(_ path: CGPath, at p: CGPoint, width: CGFloat) -> SKShapeNode {
        let s = SKShapeNode(path: path)
        s.strokeColor = eyeColor; s.lineWidth = width; s.lineCap = .round
        s.position = p
        return s
    }
}
