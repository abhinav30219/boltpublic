import CoreGraphics
import Foundation
import UIKit

/// Shared numbers and textures for the in-scene ground (soft blob + contact patch) used by both 3D renderers.
enum CompanionGround {
    /// Where the soles rest, in world space: the lowest rest-pose foot point and the feet's X/Z footprint.
    struct Layout {
        var floorY: Float
        var centerX: Float, centerZ: Float
        var extentX: Float, extentZ: Float
    }

    /// Ground disc and contact patch colours follow the theme.
    static var blobColor: UInt32 { ThemeStore.current.pick(0xF0D6BE, 0xD9C2F0, 0x2E6B68) }
    static var inkColor: UInt32 { ThemeStore.current.pick(0xE2BFA3, 0xB79BE0, 0x7CF0CB) }
    static let blobAlpha: CGFloat = 0.88
    static let blobScale: Float = 1.4
    static let contactScale: Float = 0.32
    /// Centre alpha of the contact patch at rest (45%). The texture is baked at `contactHeadroom` times that so
    /// a crouch can darken it; node opacity is the pose multiplier divided by the headroom.
    static let contactAlpha: CGFloat = 0.45
    static let contactHeadroom: Float = 1.3

    static let hopReference = 0.03 // meters of lift at which the patch is fully shrunk
    static let crouchReference = 0.03 // sleepLift magnitude

    /// Contact patch scale and opacity multipliers for a pose lift (positive = airborne, negative = crouch/sleep).
    static func contact(forLift lift: Double) -> (scale: Float, opacity: Float) {
        if lift >= 0 {
            let t = Float(min(1, lift / hopReference))
            return (1 - 0.55 * t, 1 - 0.8 * t)
        }
        let c = Float(min(1, -lift / crouchReference))
        return (1 + 0.3 * c, 1 + 0.6 * c)
    }

    /// A square image whose alpha is `centerAlpha` at the centre, fading smoothly to zero at the edge.
    /// `hex` is the colour baked into the RGB channels (used directly by RealityKit; SceneKit uses it as an alpha mask).
    static func blobImage(hex: UInt32, centerAlpha: CGFloat, size: Int = 256) -> CGImage? {
        let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let stops: [(CGFloat, CGFloat)] = [(0, 1), (0.85, 1), (0.9, 0.78), (0.95, 0.4), (0.98, 0.1), (1, 0)]
        let colors = stops.map { UIColor(red: r, green: g, blue: b, alpha: centerAlpha * $0.1).cgColor } as CFArray
        let locations = stops.map { $0.0 }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return nil }
        let c = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2, options: [])
        return ctx.makeImage()
    }

    /// SceneKit variant: straight-alpha pixels with rgb = colour x a and alpha = a, where a = sqrt(wanted alpha).
    /// SceneKit's alpha blend also multiplies the alpha channel by itself and the view is composited as
    /// premultiplied, so this is what makes the on-screen colour equal the hex value with the wanted alpha.
    static func sceneKitImage(hex: UInt32, centerAlpha: CGFloat, size: Int = 128, squareRoot: Bool = true, premultiply: Bool = true, gain: Double = 1) -> CGImage? {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        let stops: [(Double, Double)] = [(0, 1), (0.85, 1), (0.9, 0.78), (0.95, 0.4), (0.98, 0.1), (1, 0)]
        func profile(_ t: Double) -> Double {
            for i in 1..<stops.count where t <= stops[i].0 {
                let f = (t - stops[i - 1].0) / (stops[i].0 - stops[i - 1].0)
                return stops[i - 1].1 + (stops[i].1 - stops[i - 1].1) * f
            }
            return 0
        }
        func decode(_ v: Double) -> Double { let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func encode(_ l: Double) -> UInt8 {
            let c = min(1, max(0, l))
            return UInt8((c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255 + 0.5)
        }
        var data = [UInt8](repeating: 0, count: size * size * 4)
        let half = Double(size) / 2
        for y in 0..<size { for x in 0..<size {
            let dx = (Double(x) + 0.5 - half) / half, dy = (Double(y) + 0.5 - half) / half
            let wanted = Double(centerAlpha) * profile(min(1, (dx * dx + dy * dy).squareRoot()))
            let a = squareRoot ? wanted.squareRoot() : wanted
            let k = (premultiply ? a : 1) * gain // premultiplied by hand, or straight
            let i = (y * size + x) * 4
            // The GPU decodes sRGB textures to linear before blending, so premultiply in linear light and re-encode.
            // Multiplying the encoded value instead darkens every feathered pixel (the grey halo).
            data[i] = encode(decode(r) * k); data[i + 1] = encode(decode(g) * k); data[i + 2] = encode(decode(b) * k)
            data[i + 3] = UInt8(a * 255)
        } }
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
