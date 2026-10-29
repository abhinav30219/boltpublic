import BoltCore
import SwiftUI

/// Sprites drawn over the 3D view. The robot is centred and the camera fixed, so everything sits at
/// fixed fractions of the view.
struct CompanionOverlays: View {
    @ObservedObject var driver: CompanionDriver
    @State private var confettiStart: Date?
    @State private var glow = false

    private static let confettiSeconds = 1.6
    private static let confettiCount = 28
    private static let confettiColors: [Color] = [.coral, .fillEnergy, .fillSteps, .fillRelax, .fillOxygen, .fillTemp]

    private var reduceMotion: Bool { driver.reduceMotion }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                if !reduceMotion {
                    if driver.state.overlays.contains(.sweat) { sweat.position(x: w * 0.36, y: h * 0.26) }
                    if driver.state.overlays.contains(.steam) { steam.position(x: w * 0.5, y: h * 0.12) }
                    if driver.state.overlays.contains(.frost) { frost(w: w, h: h) }
                    if driver.state.overlays.contains(.zzz) { zzz.position(x: w * 0.5, y: h * 0.14) }
                    if let start = confettiStart { confetti(start: start, w: w, h: h) }
                } else if glow {
                    Circle().fill(Color.fillEnergy.opacity(0.5)).blur(radius: 24).frame(width: w * 0.7).position(x: w / 2, y: h * 0.5)
                }
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: driver.celebrationCount) { _, _ in celebrate() }
    }

    private func celebrate() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) { glow = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { withAnimation { glow = false } }
        } else {
            confettiStart = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confettiSeconds) { confettiStart = nil }
        }
    }

    // MARK: Pieces

    private var sweat: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !driver.isVisible)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    let phase = (t * 0.7 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                    Image(systemName: "drop.fill").font(.system(size: 18 - CGFloat(i) * 3))
                        .foregroundStyle(Color.fillOxygen)
                        .shadow(color: .overlayInk, radius: 0, x: 1, y: 1)
                        .offset(x: CGFloat(i) * 16, y: CGFloat(phase) * 26)
                        .opacity(1 - phase * 0.8)
                }
            }
        }
    }

    private var steam: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !driver.isVisible)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().fill(Color.white.opacity(0.9 * (1 - phase)))
                        .overlay(Circle().stroke(Color.ink.opacity(0.5 * (1 - phase)), lineWidth: 2))
                        .frame(width: 14 + CGFloat(phase) * 14)
                        .offset(x: CGFloat(i - 1) * 20 + CGFloat(sin(t * 2 + Double(i))) * 4, y: -CGFloat(phase) * 36)
                }
            }
        }
    }

    private func frost(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            ForEach(Array([(0.3, 0.55, 20.0), (0.72, 0.5, 16.0), (0.5, 0.82, 14.0), (0.62, 0.7, 12.0)].enumerated()), id: \.offset) { _, f in
                Image(systemName: "snowflake").font(.system(size: f.2, weight: .bold))
                    .foregroundStyle(Color.fillOxygen)
                    .shadow(color: .overlayInk, radius: 0, x: 1, y: 1)
                    .position(x: w * f.0, y: h * f.1)
            }
        }
    }

    private var zzz: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !driver.isVisible)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t * 0.35 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Text("Z").font(.system(size: 16 + CGFloat(i) * 6, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.fillRelax)
                        .shadow(color: .overlayInk, radius: 0, x: 1.5, y: 1.5)
                        .offset(x: CGFloat(phase) * 30, y: -CGFloat(phase) * 44)
                        .opacity(phase < 0.8 ? 1 : (1 - phase) * 5)
                }
            }
        }
    }

    private func confetti(start: Date, w: CGFloat, h: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !driver.isVisible)) { ctx in
            let p: Double = min(1, ctx.date.timeIntervalSince(start) / Self.confettiSeconds)
            ZStack {
                ForEach(0..<Self.confettiCount, id: \.self) { i in
                    piece(index: i, progress: p, w: w, h: h)
                }
            }
        }
    }

    private func piece(index i: Int, progress p: Double, w: CGFloat, h: CGFloat) -> some View {
        let a: Double = Double(i) * 2.399963
        let spread: Double = 0.15 + 0.35 * abs(sin(Double(i) * 1.7))
        let x: Double = 0.5 + cos(a) * spread * p * 1.4
        let arc: Double = 0.25 * sin(p * Double.pi) * (0.5 + abs(cos(a)))
        let y: Double = 0.35 - arc + p * p * 0.6
        let fade: Double = 1 - max(0, p - 0.7) / 0.3
        let color: Color = Self.confettiColors[i % Self.confettiColors.count]
        let shape = RoundedRectangle(cornerRadius: 2)
        return shape.fill(color)
            .overlay(shape.stroke(Color.ink, lineWidth: 1))
            .frame(width: 8, height: 12)
            .rotationEffect(.degrees(p * 540 + Double(i) * 30))
            .position(x: w * CGFloat(x), y: h * CGFloat(y))
            .opacity(fade)
    }
}
