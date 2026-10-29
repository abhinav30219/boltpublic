import SwiftUI

/// The "Bolt" logo wordmark: heavy rounded lettering with a thick ink outline, a Sticker Book
/// offset shadow and a warm coral fill. For the default name the "o" is Bolt's face; for a
/// renamed companion the same lettering is used with a small face badge before the word.
struct BoltWordmark: View {
    enum Style: String, CaseIterable { case faceO, lightningT, robotBadge, dieCutSticker }

    var text: String = "Bolt"
    var size: CGFloat = 36
    var style: Style = .faceO

    @ScaledMetric(relativeTo: .title) private var metric: CGFloat = 36

    /// Dynamic Type scale, capped so the header row doesn't explode.
    private var scale: CGFloat { min(max(metric / 36, 1), 1.4) }
    private var s: CGFloat { size * scale }

    private var isBolt: Bool { text == "Bolt" }

    var body: some View {
        Group {
            switch style {
            case .faceO: faceO
            case .lightningT: lightningT
            case .robotBadge: robotBadge
            case .dieCutSticker: dieCutSticker
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: 0 Face O

    private var faceO: some View {
        Group {
            if isBolt {
                HStack(alignment: .lastTextBaseline, spacing: s * 0.03) {
                    letters("B")
                    BoltFace(diameter: s * 0.62, outline: s * 0.05)
                        .padding(.horizontal, s * 0.02)
                        .alignmentGuide(.lastTextBaseline) { d in d[.bottom] - s * 0.015 }
                    letters("lt")
                }
            } else {
                HStack(alignment: .center, spacing: s * 0.12) {
                    BoltFace(diameter: s * 0.7, outline: s * 0.05)
                    letters(text)
                }
            }
        }
        .padding(.trailing, s * 0.12) // room for the shadow
        .padding(.bottom, s * 0.12)
    }

    private func letters(_ t: String) -> some View {
        InkLetters(text: t, size: s)
    }

    // MARK: 1 Lightning t

    private var lightningT: some View {
        let l = { (t: String) in
            InkLetters(text: t, size: s, colors: [Color.coral, Color.coral])
        }
        return Group {
            if isBolt {
                HStack(alignment: .lastTextBaseline, spacing: s * 0.02) {
                    l("Bol")
                    LightningGlyph(height: s * 0.8, outline: s * 0.055, shadow: max(3, s * 0.085))
                        .alignmentGuide(.lastTextBaseline) { d in d[.bottom] - s * 0.045 }
                }
            } else {
                l(text)
            }
        }
        .padding(.trailing, s * 0.12)
        .padding(.bottom, s * 0.12)
    }

    // MARK: 2 Robot badge

    private var robotBadge: some View {
        HStack(alignment: .center, spacing: s * 0.14) {
            RobotHeadBadge(side: s * 0.82)
            Text(isBolt ? "bolt" : text)
                .font(.system(size: s, weight: .black, design: .rounded))
                .tracking(-s * 0.04)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.top, s * 0.06)
    }

    // MARK: 3 Die-cut sticker

    private var dieCutSticker: some View {
        let pad = s * 0.2
        let border = s * 0.11
        let r = s * 0.3
        return InkLetters(text: text, size: s * 0.86, colors: [Color.paper, Color.paper],
                          shadow: false)
            .padding(.horizontal, pad).padding(.vertical, pad * 0.7)
            .background(RoundedRectangle(cornerRadius: r, style: .continuous).fill(Color.coral))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Color.ink.opacity(0.12), lineWidth: 1.5))
            .padding(border)
            .background(RoundedRectangle(cornerRadius: r + border, style: .continuous).fill(Color.white))
            .overlay(alignment: .bottomTrailing) { PeelCurl(size: s * 0.34, radius: r + border) }
            .shadow(color: Color.ink.opacity(0.28), radius: s * 0.1, x: s * 0.03, y: s * 0.07)
            .rotationEffect(.degrees(-4))
            .padding(s * 0.14)
    }
}

/// Folded-up corner on the sticker: a small lighter wedge with a highlight.
private struct PeelCurl: View {
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Path { p in
                p.move(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size))
                p.addLine(to: CGPoint(x: size, y: size))
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color.white, Color.fillActivity.opacity(0.9)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            Path { p in
                p.move(to: CGPoint(x: size, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size))
            }
            .stroke(Color.ink.opacity(0.25), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius * 0.25, style: .continuous))
        .offset(x: -radius * 0.02, y: -radius * 0.02)
        .shadow(color: Color.ink.opacity(0.25), radius: 2, x: -1, y: -1)
    }
}

/// A zig-zag lightning bolt standing in for the "t".
private struct LightningShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var p = Path()
        p.move(to: pt(0.70, 0.02))
        p.addLine(to: pt(0.10, 0.56))
        p.addLine(to: pt(0.48, 0.56))
        p.addLine(to: pt(0.28, 0.98))
        p.addLine(to: pt(0.92, 0.40))
        p.addLine(to: pt(0.52, 0.40))
        p.closeSubpath()
        return p
    }
}

private struct LightningGlyph: View {
    let height: CGFloat
    let outline: CGFloat
    let shadow: CGFloat

    var body: some View {
        let w = height * 0.78
        ZStack {
            LightningShape().fill(Color.ink)
                .overlay(LightningShape().stroke(Color.ink, style: StrokeStyle(lineWidth: outline * 2, lineJoin: .round)))
                .offset(x: shadow, y: shadow)
            LightningShape().stroke(Color.ink, style: StrokeStyle(lineWidth: outline * 2, lineJoin: .round))
            LightningShape().fill(LinearGradient(colors: [Color.fillEnergy, Color(hex: 0xFFC83D)],
                                                 startPoint: .top, endPoint: .bottom))
        }
        .frame(width: w, height: height)
        .padding(outline)
    }
}

/// Little robot head: mint rounded square, dark screen, two dot eyes and an antenna nub.
private struct RobotHeadBadge: View {
    let side: CGFloat
    var body: some View {
        let o = side * 0.075
        ZStack {
            // antenna
            VStack(spacing: 0) {
                Circle().fill(Color.coral).overlay(Circle().strokeBorder(Color.ink, lineWidth: o * 0.7))
                    .frame(width: side * 0.17, height: side * 0.17)
                Rectangle().fill(Color.ink).frame(width: o * 0.9, height: side * 0.1)
                Spacer(minLength: 0)
            }
            .frame(height: side * 1.25)
            .offset(y: -side * 0.06)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.28, style: .continuous).fill(Color.ink)
                    .offset(x: o * 0.9, y: o * 0.9)
                RoundedRectangle(cornerRadius: side * 0.28, style: .continuous).fill(Color.fillSteps)
                    .overlay(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous)
                        .strokeBorder(Color.ink, lineWidth: o))
                RoundedRectangle(cornerRadius: side * 0.16, style: .continuous).fill(Color.ink)
                    .frame(width: side * 0.7, height: side * 0.42)
                HStack(spacing: side * 0.17) {
                    Circle().fill(Color.fillSteps).frame(width: side * 0.14, height: side * 0.14)
                    Circle().fill(Color.fillSteps).frame(width: side * 0.14, height: side * 0.14)
                }
            }
            .frame(width: side, height: side)
            .offset(y: side * 0.1)
        }
        .frame(width: side + o, height: side * 1.25 + o)
    }
}

/// Outlined, shadowed, gradient-filled lettering.
private struct InkLetters: View {
    let text: String
    let size: CGFloat
    var colors: [Color] = [Color.fillActivity, Color.coral, Color.coral]
    var shadow: Bool = true

    private var outline: CGFloat { size * 0.055 }
    private var shadowOff: CGFloat { shadow ? max(3, size * 0.085) : 0 }

    private func glyph(_ color: Color, dx: CGFloat = 0, dy: CGFloat = 0) -> some View {
        Text(text)
            .font(.system(size: size, weight: .black, design: .rounded))
            .tracking(-size * 0.02)
            .foregroundStyle(color)
            .lineLimit(1)
            .offset(x: dx, y: dy)
    }

    var body: some View {
        let dirs: [(CGFloat, CGFloat)] = (0..<12).map { i in
            let a = Double(i) / 12 * 2 * .pi
            return (CGFloat(cos(a)), CGFloat(sin(a)))
        }
        ZStack {
            if shadow {
                ForEach(0..<dirs.count, id: \.self) { i in
                    glyph(.ink, dx: dirs[i].0 * outline + shadowOff, dy: dirs[i].1 * outline + shadowOff)
                }
            }
            ForEach(0..<dirs.count, id: \.self) { i in
                glyph(.ink, dx: dirs[i].0 * outline, dy: dirs[i].1 * outline)
            }
            glyph(.clear)
                .overlay(
                    LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
                        .mask(glyph(.black))
                )
        }
        .fixedSize()
        .padding(outline)
    }
}

/// Bolt's face as a disc: cream body, ink outline, dot eyes with glints, blush.
private struct BoltFace: View {
    let diameter: CGFloat
    let outline: CGFloat

    var body: some View {
        let d = diameter
        ZStack {
            Circle().fill(Color.ink).frame(width: d + outline * 2, height: d + outline * 2)
                .offset(x: outline * 1.4, y: outline * 1.4)
            Circle().fill(Color.ink).frame(width: d + outline * 2, height: d + outline * 2)
            Circle().fill(Color.paper).frame(width: d, height: d)
            // blush
            Ellipse().fill(Color.fillTemp).frame(width: d * 0.2, height: d * 0.13)
                .offset(x: -d * 0.3, y: d * 0.16)
            Ellipse().fill(Color.fillTemp).frame(width: d * 0.2, height: d * 0.13)
                .offset(x: d * 0.3, y: d * 0.16)
            // eyes
            eye.offset(x: -d * 0.19, y: -d * 0.02)
            eye.offset(x: d * 0.19, y: -d * 0.02)
        }
        .frame(width: d + outline * 2, height: d + outline * 2)
    }

    private var eye: some View {
        let e = diameter * 0.2
        return ZStack {
            Circle().fill(Color.ink).frame(width: e, height: e)
            Circle().fill(Color.white).frame(width: e * 0.38, height: e * 0.38)
                .offset(x: e * 0.15, y: -e * 0.17)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ForEach(BoltWordmark.Style.allCases, id: \.self) { st in
            BoltWordmark(size: 36, style: st)
            BoltWordmark(text: "Pixel", size: 36, style: st)
        }
    }
    .padding().background(Color.paper)
}
