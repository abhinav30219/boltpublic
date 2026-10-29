// Draws the Bolt app icon: the companion robot, front-on as a "Sticker Book" sticker.
// Colors come from the design spec (docs/superpowers/specs/2026-10-24-companion-robot-design.md):
// paper background, ink outline + hard offset ink shadow, Peach body palette, happy-arc face.
// Usage: swift scripts/make_app_icon.swift [out.png] [size]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "App/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
let size = args.count > 2 ? Int(args[2])! : 1024

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let paper = rgb(0xFFF6E9), groundShadow = rgb(0xF0D6BE)
let ink = rgb(0x2B1D18)
let shell = rgb(0xFFF1E2), joint = rgb(0xFF7F6E), limb = rgb(0xFFB48F), foot = rgb(0x6FCFB0)
let eye = rgb(0x7FE3D4), blush = rgb(0xFF8FA3), white = rgb(0xFFFFFF)

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!  // icons must be opaque
// Design in a 1024 canvas with a top-left origin.
let k = CGFloat(size) / 1024
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: k, y: -k)

let stroke: CGFloat = 26       // 3 pt sticker border, scaled to icon size
let shadow: CGFloat = 20       // 4 pt offset ink shadow, scaled

enum Shape { case rrect(CGRect, CGFloat), ellipse(CGRect) }
func path(_ s: Shape, dx: CGFloat = 0) -> CGPath {
    switch s {
    case let .rrect(r, rad): return CGPath(roundedRect: r.offsetBy(dx: dx, dy: dx), cornerWidth: rad, cornerHeight: rad, transform: nil)
    case let .ellipse(r): return CGPath(ellipseIn: r.offsetBy(dx: dx, dy: dx), transform: nil)
    }
}
func rr(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ r: CGFloat) -> Shape { .rrect(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), r) }
func el(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Shape { .ellipse(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)) }

// Robot parts back to front: (shape, fill). Mirrored legs are generated from the left side.
var legs: [(Shape, CGColor)] = []
func mirror(_ s: Shape) -> Shape {
    switch s {
    case let .rrect(r, rad): return .rrect(CGRect(x: 1024 - r.maxX, y: r.minY, width: r.width, height: r.height), rad)
    case let .ellipse(r): return .ellipse(CGRect(x: 1024 - r.maxX, y: r.minY, width: r.width, height: r.height))
    }
}
func pair(_ s: Shape, _ c: CGColor) { legs.append((s, c)); legs.append((mirror(s), c)) }

// Back legs, peeking out between the front legs.
pair(rr(318, 560, 384, 742, 30), joint)
pair(rr(296, 716, 404, 782, 33), foot)
// Front legs: upper, knee, lower, foot.
pair(rr(146, 356, 262, 640, 54), limb)
pair(rr(170, 600, 238, 800, 34), joint)
pair(el(204, 616, 92, 92), limb)
pair(rr(140, 768, 276, 846, 39), foot)
// Head: dome and body, tilted as one piece around the body's center.
let head: [(Shape, CGColor)] = [(el(512, 300, 128, 112), limb), (rr(214, 290, 810, 618, 96), shell)]
let headPivot = CGPoint(x: 512, y: 454)
let headTilt: CGFloat = -7 * .pi / 180  // negative tips the top to the left
func tilted(_ draw: () -> Void) {
    ctx.saveGState()
    ctx.translateBy(x: headPivot.x, y: headPivot.y); ctx.rotate(by: headTilt); ctx.translateBy(x: -headPivot.x, y: -headPivot.y)
    draw()
    ctx.restoreGState()
}

// Background and ground shadow.
ctx.setFillColor(paper); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
ctx.translateBy(x: 0, y: -26)  // optically center the robot
ctx.setFillColor(groundShadow); ctx.addPath(path(el(512, 846, 780, 78))); ctx.fillPath()

// Sticker shadow: the whole silhouette in ink, offset down-right (the head's shadow stays straight down-right).
ctx.setFillColor(ink)
ctx.setLineWidth(stroke); ctx.setStrokeColor(ink); ctx.setLineJoin(.round)
for (s, _) in legs { ctx.addPath(path(s, dx: shadow)); ctx.drawPath(using: .fillStroke) }
ctx.saveGState(); ctx.translateBy(x: shadow, y: shadow)
tilted { for (s, _) in head { ctx.addPath(path(s)); ctx.drawPath(using: .fillStroke) } }
ctx.restoreGState()

// Parts with ink outlines.
for (s, c) in legs { ctx.setFillColor(c); ctx.addPath(path(s)); ctx.drawPath(using: .fillStroke) }
tilted {
    for (s, c) in head { ctx.setFillColor(c); ctx.addPath(path(s)); ctx.drawPath(using: .fillStroke) }

    // Face: dark panel with the app's happy eyes (upward arcs) and blush.
    ctx.setFillColor(ink); ctx.addPath(path(rr(298, 364, 726, 552, 74))); ctx.fillPath()
    ctx.setStrokeColor(eye); ctx.setLineWidth(30); ctx.setLineCap(.round)
    for cx in [418.0, 606.0] {
        ctx.addArc(center: CGPoint(x: cx, y: 470), radius: 44, startAngle: .pi * 1.12, endAngle: .pi * 1.88, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(blush)
    for cx in [350.0, 674.0] { ctx.addPath(path(el(cx, 500, 64, 34))); ctx.fillPath() }

    // Shine on the shell's top-left corner.
    ctx.setStrokeColor(white); ctx.setLineWidth(18)
    ctx.addArc(center: CGPoint(x: 330, y: 400), radius: 62, startAngle: .pi * 1.08, endAngle: .pi * 1.42, clockwise: false)
    ctx.strokePath()
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath) (\(size)x\(size))")
