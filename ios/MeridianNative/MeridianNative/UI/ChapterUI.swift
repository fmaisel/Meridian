// The book of chapters: a gallery of floating shrines under a night sky (each carries its chapter's
// emblem — an octagonal rosette with the numeral — and a star that lights once the chapter is walked),
// the chapter card that opens a chapter ("In which …"), the card that closes it, and the pause and
// leave screens with round outlined icons.

import SwiftUI

private let paper = Color(red: 0.96, green: 0.97, blue: 0.965)
private let nightTop = Color(red: 0x10 / 255, green: 0x17 / 255, blue: 0x16 / 255)
private let nightMid = Color(red: 0x1d / 255, green: 0x24 / 255, blue: 0x22 / 255)
private let nightLow = Color(red: 0x6a / 255, green: 0x70 / 255, blue: 0x6c / 255)
private let starCyan = Color(red: 0x6f / 255, green: 0xf1 / 255, blue: 0xf0 / 255)

func hexColor(_ hex: String) -> Color {
    let c = color(hex)
    return Color(.sRGB, red: Double(linearToSrgb(c.x)), green: Double(linearToSrgb(c.y)), blue: Double(linearToSrgb(c.z)))
}

// ───────────────────────── gallery ─────────────────────────

struct ChapterGallery: View {
    @Bindable var ui: UIState
    let w: CGFloat
    let h: CGFloat
    @State private var position: Int?
    @State private var refused: Int?
    @State private var shown = false

    var body: some View {
        ZStack {
            NightSky().ignoresSafeArea()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(ui.chapters.enumerated()), id: \.element.id) { i, c in
                        ShrinePage(card: c, w: w, h: h, focused: (position ?? ui.selectIndex) == i,
                                   leaving: ui.selectLeaving && (position ?? ui.selectIndex) == i, refused: refused == i)
                            .containerRelativeFrame(.horizontal)
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(1 - abs(phase.value) * 0.2)
                                    .rotation3DEffect(.degrees(phase.value * -32), axis: (0, 1, 0), perspective: 0.55)
                                    .offset(x: -phase.value * w * 0.5)
                                    .opacity(1 - abs(phase.value) * 0.3)
                                    .brightness(-abs(phase.value) * 0.12)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { tap(i) }
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $position)
            .scrollDisabled(ui.selectLeaving)
            .ignoresSafeArea()

            // the chapter's name beneath the shadow, and diamonds marking where in the book we are
            VStack(spacing: 14) {
                Spacer()
                if let c = ui.chapters[safe: position ?? ui.selectIndex] {
                    VStack(spacing: 6) {
                        Text("CHAPTER \(c.numeral)")
                            .font(serif(15, light: false)).tracking(15 * 0.3)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(c.unlocked ? c.title.uppercased() : "· · ·")
                            .font(serif(23, light: false)).tracking(23 * 0.14)
                            .foregroundStyle(.white.opacity(c.unlocked ? 0.95 : 0.5))
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(c.completed ? "walked" : c.inProgress ? "begun" : c.unlocked ? "tap to enter" : "sealed")
                            .font(sans(11)).tracking(11 * 0.32)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .id(c.id)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.4), value: c.id)
                }
                HStack(spacing: 12) {
                    ForEach(Array(ui.chapters.enumerated()), id: \.element.id) { i, c in
                        Diamond()
                            .fill(i == (position ?? ui.selectIndex) ? .white : .clear)
                            .overlay(Diamond().stroke(.white.opacity(c.unlocked ? 0.8 : 0.35), lineWidth: 1))
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.bottom, h * 0.045)
            }
            .padding(.horizontal, 24)
            .allowsHitTesting(false)

            // corners: settings (top left) and the title (top right)
            VStack {
                HStack {
                    IconButton(label: "Settings") { StarGlyph() } action: { ui.openSettings(from: "select") }
                    Spacer()
                    IconButton(label: "Title") { CompassGlyph() } action: { ui.handlers.toTitle() }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .opacity(ui.selectLeaving ? 0 : 1)
        }
        .opacity(shown ? 1 : 0)
        .onAppear {
            position = ui.selectIndex
            withAnimation(.easeOut(duration: 0.7)) { shown = true }
        }
        .onChange(of: ui.selectIndex) { _, i in withAnimation(.smooth) { position = i } }
    }

    private func tap(_ i: Int) {
        guard !ui.selectLeaving else { return }
        if i != (position ?? ui.selectIndex) {
            withAnimation(.smooth) { position = i }
            return
        }
        if ui.chapters[i].unlocked {
            ui.selectIndex = i
            ui.handlers.openChapter(ui.chapters[i].id)
        } else {
            refused = i
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { refused = nil }
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Deep green-black night with a pale horizon and slowly twinkling diamond stars.
struct NightSky: View {
    private struct Star { let x: CGFloat; let y: CGFloat; let r: CGFloat; let phase: Double; let speed: Double }
    private static let stars: [Star] = {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<70).map { _ in
            Star(x: rnd(), y: pow(rnd(), 1.35) * 0.7, r: 1.1 + rnd() * rnd() * 3.2, phase: rnd() * 6.28, speed: 0.4 + rnd() * 1.2)
        }
    }()

    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: nightTop, location: 0), .init(color: nightMid, location: 0.48),
                                   .init(color: nightLow, location: 0.78), .init(color: Color(red: 0.46, green: 0.49, blue: 0.47), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 420)
            TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    for s in Self.stars {
                        let a = 0.55 + 0.45 * sin(t * s.speed + s.phase)
                        let p = CGPoint(x: s.x * size.width, y: s.y * size.height)
                        var d = Path()
                        d.move(to: CGPoint(x: p.x, y: p.y - s.r))
                        d.addLine(to: CGPoint(x: p.x + s.r, y: p.y))
                        d.addLine(to: CGPoint(x: p.x, y: p.y + s.r))
                        d.addLine(to: CGPoint(x: p.x - s.r, y: p.y))
                        d.closeSubpath()
                        ctx.fill(d, with: .color(.white.opacity(a)))
                    }
                }
            }
        }
    }
}

/// One page: the shrine floating above its soft shadow.
private struct ShrinePage: View {
    let card: ChapterCard
    let w: CGFloat
    let h: CGFloat
    let focused: Bool
    let leaving: Bool
    let refused: Bool
    @State private var bob = false

    var body: some View {
        let sw = min(w * 0.62, h * 0.36, 360)
        VStack(spacing: 0) {
            Shrine(card: card)
                .frame(width: sw, height: sw * 1.32)
                .offset(x: refused ? 6 : 0, y: bob ? -sw * 0.025 : sw * 0.02)
                .animation(refused ? .spring(response: 0.08, dampingFraction: 0.2).repeatCount(3) : .default, value: refused)
            Ellipse()
                .fill(RadialGradient(colors: [.black.opacity(0.42), .black.opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: sw * 0.5))
                .frame(width: sw * (bob ? 0.82 : 0.9), height: sw * 0.13)
                .padding(.top, sw * 0.06)
        }
        .scaleEffect(leaving ? 1.18 : 1)
        .animation(.easeIn(duration: 0.9), value: leaving)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -h * 0.04)
        .onAppear { withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { bob = true } }
        .accessibilityElement()
        .accessibilityLabel("Chapter \(card.numeral), \(card.unlocked ? card.title : "sealed")")
        .accessibilityAddTraits(.isButton)
    }
}

/// The white gate-shrine: two minarets with onion domes, a domed upper wall with the chapter's star, a
/// pointed arch holding the emblem, and a stepped plinth on a keel. Drawn in a 100 × 132 frame.
struct Shrine: View {
    let card: ChapterCard

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 100
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path { Path(CGRect(x: x * k, y: y * k, width: w * k, height: h * k)) }
            func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var p = Path()
                p.move(to: P(pts[0].0, pts[0].1))
                for q in pts.dropFirst() { p.addLine(to: P(q.0, q.1)) }
                p.closeSubpath()
                return p
            }
            let dim = card.unlocked ? 1.0 : 0.72
            let front = Color(white: 0.93 * dim), side = Color(white: 0.78 * dim), top = Color(white: 0.985 * dim)
            let line = Color(white: 0.72 * dim).opacity(0.9), dark = Color(red: 0.07, green: 0.1, blue: 0.1)
            let lw = 0.45 * k

            // back dome
            var dome = Path()
            dome.addArc(center: P(50, 34), radius: 15 * k, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            dome.closeSubpath()
            ctx.fill(dome, with: .linearGradient(Gradient(colors: [top, Color(white: 0.84 * dim)]), startPoint: P(40, 20), endPoint: P(62, 34)))
            ctx.fill(poly([(49, 15.5), (50, 13.6), (51, 15.5), (50, 17.4)]), with: .color(top))

            // upper wall with a carved frieze and a soft pointed opening
            ctx.fill(rect(19, 31, 62, 26), with: .color(front))
            ctx.fill(rect(19, 31, 62, 1.6), with: .color(top))
            for i in 0..<3 {
                let o = CGFloat(i) * 2.4
                var fr = Path()
                fr.move(to: P(22 + o, 54 - o))
                fr.addLine(to: P(22 + o, 36 + o))
                fr.addLine(to: P(78 - o, 36 + o))
                fr.addLine(to: P(78 - o, 54 - o))
                ctx.stroke(fr, with: .color(line), lineWidth: lw)
            }
            // the star socket and the chapter's star
            let sc = P(50, 41.5)
            ctx.fill(Path(ellipseIn: CGRect(x: sc.x - 6.6 * k, y: sc.y - 6.6 * k, width: 13.2 * k, height: 13.2 * k)), with: .color(dark))
            let star = hexagram(sc, 3.9 * k)
            if card.completed {
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 3.2 * k))
                    l.fill(star, with: .color(starCyan.opacity(0.9)))
                }
                ctx.fill(star, with: .color(starCyan))
                ctx.fill(hexagram(sc, 1.8 * k), with: .color(.white.opacity(0.8)))
            } else {
                ctx.stroke(star, with: .color(.white.opacity(card.unlocked ? 0.34 : 0.14)), lineWidth: 0.5 * k)
            }

            // the arch opening (pointed), dark like the sky behind
            var arch = Path()
            arch.move(to: P(26, 100))
            arch.addLine(to: P(26, 70))
            arch.addQuadCurve(to: P(50, 51.5), control: P(27, 56))
            arch.addQuadCurve(to: P(74, 70), control: P(73, 56))
            arch.addLine(to: P(74, 100))
            arch.closeSubpath()
            ctx.fill(arch, with: .color(Color(red: 0.11, green: 0.14, blue: 0.14)))
            // the arch's lit soffit on the right
            ctx.fill(poly([(72.2, 100), (72.2, 68.5), (74, 68), (74, 100)]), with: .color(side.opacity(0.5)))

            // towers with recessed panels, little arched windows, caps and onion domes
            for x0 in [CGFloat(10), 74] {
                ctx.fill(rect(x0, 46, 16, 54), with: .color(front))
                ctx.fill(rect(x0 + 13.4, 46, 2.6, 54), with: .color(side))
                var panel = Path()
                panel.move(to: P(x0 + 3, 79))
                panel.addLine(to: P(x0 + 3, 52))
                panel.addLine(to: P(x0 + 6.7, 49.5))
                panel.addLine(to: P(x0 + 10.4, 52))
                panel.addLine(to: P(x0 + 10.4, 79))
                panel.addLine(to: P(x0 + 6.7, 81.5))
                panel.closeSubpath()
                ctx.stroke(panel, with: .color(line), lineWidth: lw)
                var win = Path()
                win.move(to: P(x0 + 4.9, 99))
                win.addLine(to: P(x0 + 4.9, 90))
                win.addLine(to: P(x0 + 6.7, 87.5))
                win.addLine(to: P(x0 + 8.5, 90))
                win.addLine(to: P(x0 + 8.5, 99))
                win.closeSubpath()
                ctx.fill(win, with: .color(dark))
                ctx.fill(rect(x0 - 1, 43, 18, 3), with: .color(top))
                ctx.fill(rect(x0 + 15, 43, 2, 3), with: .color(side))
                // onion dome
                var onion = Path()
                let cx = (x0 + 8) * k, base = 43 * k
                onion.move(to: CGPoint(x: cx - 7.6 * k, y: base))
                onion.addCurve(to: CGPoint(x: cx, y: base - 13 * k), control1: CGPoint(x: cx - 9.6 * k, y: base - 7 * k), control2: CGPoint(x: cx - 1.4 * k, y: base - 9 * k))
                onion.addCurve(to: CGPoint(x: cx + 7.6 * k, y: base), control1: CGPoint(x: cx + 1.4 * k, y: base - 9 * k), control2: CGPoint(x: cx + 9.6 * k, y: base - 7 * k))
                onion.closeSubpath()
                ctx.fill(onion, with: .linearGradient(Gradient(colors: [top, Color(white: 0.8 * dim)]), startPoint: CGPoint(x: cx - 6 * k, y: base - 10 * k), endPoint: CGPoint(x: cx + 7 * k, y: base)))
                ctx.fill(poly([(x0 + 7.2, 29.5), (x0 + 8, 25), (x0 + 8.8, 29.5), (x0 + 8, 31.5)]), with: .color(top))
            }

            // plinth: tower bases with nested squares, the middle panel with its notch and woven lines
            ctx.fill(rect(6, 100, 88, 1.8), with: .color(top))
            for x0 in [CGFloat(7), 73] {
                ctx.fill(rect(x0, 101.8, 20, 13), with: .color(front))
                ctx.stroke(Path(CGRect(x: (x0 + 3) * k, y: 104 * k, width: 14 * k, height: 8.6 * k)), with: .color(line), lineWidth: lw)
                ctx.stroke(Path(CGRect(x: (x0 + 6.4) * k, y: 106 * k, width: 7.2 * k, height: 4.6 * k)), with: .color(line), lineWidth: lw)
            }
            ctx.fill(rect(27, 101.8, 46, 13), with: .color(Color(white: 0.89 * dim)))
            ctx.fill(poly([(44, 101.8), (50, 106.5), (56, 101.8)]), with: .color(Color(red: 0.11, green: 0.14, blue: 0.14)))
            var weave = Path()
            weave.move(to: P(29, 108)); weave.addLine(to: P(42, 108)); weave.addLine(to: P(47, 112)); weave.addLine(to: P(53, 108)); weave.addLine(to: P(58, 112)); weave.addLine(to: P(71, 112))
            weave.move(to: P(29, 112)); weave.addLine(to: P(42, 112)); weave.addLine(to: P(47, 108)); weave.addLine(to: P(53, 112)); weave.addLine(to: P(58, 108)); weave.addLine(to: P(71, 108))
            ctx.stroke(weave, with: .color(line), lineWidth: lw)
            ctx.fill(rect(4.5, 114.8, 91, 1.6), with: .color(top))
            ctx.fill(rect(29, 116.4, 42, 4.6), with: .color(Color(white: 0.86 * dim)))
            ctx.stroke(Path(CGRect(x: 31 * k, y: 117.4 * k, width: 38 * k, height: 2.4 * k)), with: .color(line), lineWidth: lw)
            // the keel beneath
            ctx.fill(poly([(29, 121), (71, 121), (50, 131)]), with: .linearGradient(Gradient(colors: [Color(white: 0.3 * dim), Color(white: 0.16 * dim)]), startPoint: P(50, 121), endPoint: P(50, 131)))

            // the emblem in the arch
            drawEmblem(&ctx, center: P(50, 80), r: 19.5 * k, card: card, k: k)
        }
    }

    private func hexagram(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        for t in 0..<2 {
            for i in 0..<3 {
                let a = (Double(i) / 3 + Double(t) / 6) * 2 * .pi - .pi / 2
                let q = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
        }
        return p
    }
}

/// Octagonal rosette: eight two-tone petals with pale tips around a dark heart with the numeral.
func drawEmblem(_ ctx: inout GraphicsContext, center c: CGPoint, r: CGFloat, card: ChapterCard, k: CGFloat) {
    let lit = card.unlocked
    let petals = lit ? hexColor(card.petals) : Color(white: 0.22)
    let tips = lit ? hexColor(card.tips) : Color(white: 0.34)
    let heart = lit ? hexColor(card.centre) : Color(white: 0.06)
    func pt(_ a: Double, _ rr: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr) }
    let n = 8
    let rot = -Double.pi / 2 + Double.pi / 8
    var outer = Path()
    for i in 0..<n {
        let q = pt(rot + Double(i) / Double(n) * 2 * .pi, r * 1.06)
        if i == 0 { outer.move(to: q) } else { outer.addLine(to: q) }
    }
    outer.closeSubpath()
    ctx.fill(outer, with: .color(Color(red: 0.06, green: 0.08, blue: 0.08)))
    let ri = r * 0.5
    for i in 0..<n {
        let a0 = rot + Double(i) / Double(n) * 2 * .pi
        let a1 = rot + Double(i + 1) / Double(n) * 2 * .pi
        let am = (a0 + a1) / 2
        // two halves of the petal, light and shade
        var left = Path()
        left.move(to: pt(a0, ri)); left.addLine(to: pt(a0, r)); left.addLine(to: pt(am, r * 0.97)); left.addLine(to: pt(am, ri * 1.02)); left.closeSubpath()
        var right = Path()
        right.move(to: pt(am, ri * 1.02)); right.addLine(to: pt(am, r * 0.97)); right.addLine(to: pt(a1, r)); right.addLine(to: pt(a1, ri)); right.closeSubpath()
        ctx.fill(left, with: .color(petals))
        ctx.fill(right, with: .color(petals.opacity(0.7)))
        // a pale kite at the tip, and a fine vein
        var kite = Path()
        kite.move(to: pt(am, r * 0.95)); kite.addLine(to: pt(am - 0.11, r * 0.8)); kite.addLine(to: pt(am, r * 0.68)); kite.addLine(to: pt(am + 0.11, r * 0.8)); kite.closeSubpath()
        ctx.fill(kite, with: .color(tips.opacity(0.92)))
        var vein = Path()
        vein.move(to: pt(a0, ri)); vein.addLine(to: pt(am + 0.2, r * 0.9))
        ctx.stroke(vein, with: .color(.black.opacity(0.25)), lineWidth: 0.35 * k)
    }
    var inner = Path()
    for i in 0..<n {
        let q = pt(rot + Double(i) / Double(n) * 2 * .pi, ri)
        if i == 0 { inner.move(to: q) } else { inner.addLine(to: q) }
    }
    inner.closeSubpath()
    ctx.fill(inner, with: .color(heart))
    var ring = Path()
    for i in 0..<n {
        let q = pt(rot + Double(i) / Double(n) * 2 * .pi, ri * 0.9)
        if i == 0 { ring.move(to: q) } else { ring.addLine(to: q) }
    }
    ring.closeSubpath()
    ctx.stroke(ring, with: .color(.white.opacity(lit ? 0.85 : 0.3)), lineWidth: 0.45 * k)
    let numeral = Text(card.numeral).font(serif(ri * 0.95, light: false)).foregroundStyle(.white.opacity(lit ? 0.95 : 0.35))
    ctx.draw(numeral, at: c)
    for s in [-1.0, 1.0] {
        let d = CGPoint(x: c.x + CGFloat(s) * ri * 0.55, y: c.y)
        ctx.fill(Path(ellipseIn: CGRect(x: d.x - 0.6 * k, y: d.y - 0.6 * k, width: 1.2 * k, height: 1.2 * k)), with: .color(.white.opacity(lit ? 0.8 : 0.3)))
    }
}

struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }
}

/// Top-corner glyph button (44 pt target).
private struct IconButton<Glyph: View>: View {
    let label: String
    @ViewBuilder let glyph: Glyph
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            glyph.frame(width: 34, height: 34).frame(width: 52, height: 52).contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}

/// Eight-pointed star outline with a diamond at its heart (settings).
private struct StarGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width * 0.46
            var p = Path()
            for i in 0..<16 {
                let a = Double(i) / 16 * 2 * .pi - .pi / 2
                let rr = i % 2 == 0 ? r : r * 0.78
                let q = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
            ctx.stroke(p, with: .color(.white.opacity(0.9)), lineWidth: 1.4)
            ctx.stroke(Diamond().path(in: CGRect(x: c.x - r * 0.4, y: c.y - r * 0.4, width: r * 0.8, height: r * 0.8)), with: .color(.white.opacity(0.9)), lineWidth: 1.4)
        }
    }
}

/// Diamond with four studs and a cross (back to the title).
private struct CompassGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width * 0.42
            ctx.stroke(Diamond().path(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.9)), lineWidth: 1.4)
            for (dx, dy) in [(0.0, -1.0), (1, 0), (0, 1), (-1, 0)] {
                let q = CGPoint(x: c.x + dx * r, y: c.y + dy * r)
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2.6, y: q.y - 2.6, width: 5.2, height: 5.2)), with: .color(.white))
            }
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - r * 0.38, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r * 0.38, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - r * 0.38)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.38))
            ctx.stroke(cross, with: .color(.white.opacity(0.9)), lineWidth: 1.4)
        }
    }
}

// ───────────────────────── chapter cards ─────────────────────────

/// Horizontal rule with a little mountain of zigzags and two interlocking diamonds at its centre.
private struct Ornament: View {
    var flipped = false

    var body: some View {
        Canvas { ctx, size in
            let y = flipped ? size.height * 0.22 : size.height * 0.78
            let cx = size.width / 2, s = flipped ? -1.0 : 1.0
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: cx - 46, y: y))
            p.addLine(to: CGPoint(x: cx - 30, y: y - 13 * s))
            p.addLine(to: CGPoint(x: cx - 14, y: y))
            p.addLine(to: CGPoint(x: cx, y: y - 15 * s))
            p.addLine(to: CGPoint(x: cx + 14, y: y))
            p.addLine(to: CGPoint(x: cx + 30, y: y - 13 * s))
            p.addLine(to: CGPoint(x: cx + 46, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(.white.opacity(0.92)), lineWidth: 1.2)
            for (dx, dy) in [(0.0, -27.0), (0, -12)] {
                let c = CGPoint(x: cx + dx, y: y + dy * s)
                ctx.stroke(Diamond().path(in: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)), with: .color(.white.opacity(0.92)), lineWidth: 1.2)
            }
        }
        .frame(height: 46)
    }
}

/// The white ring that starts (or closes) a chapter.
private struct RingButton: View {
    let label: String
    let action: () -> Void
    @State private var breathe = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(0.35), lineWidth: 10).frame(width: 74, height: 74).blur(radius: 6)
                Circle().stroke(.white, lineWidth: 6.5).frame(width: 62, height: 62)
            }
            .scaleEffect(breathe ? 1.04 : 0.97)
            .frame(width: 96, height: 96)
            .contentShape(Circle())
        }
        .accessibilityLabel(label)
        .onAppear { withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true } }
    }
}

private struct CardText: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 10)
            .shadow(color: .black.opacity(0.3), radius: 2)
    }
}

/// "Chapter II · The Garden · In which …" over the slowly turning diorama.
struct ChapterIntro: View {
    @Bindable var ui: UIState
    let w: CGFloat
    let h: CGFloat
    @State private var shown = false

    var body: some View {
        let L = CardLayout(w: w, h: h)
        ZStack {
            L.veil
            VStack(spacing: 0) {
                Spacer(minLength: L.wide ? 8 : h * 0.1)
                Ornament().frame(width: L.ornament)
                Text("CHAPTER \(ui.introNumeral)")
                    .font(serif(L.big * 0.6, light: false)).tracking(L.big * 0.6 * 0.24)
                    .padding(.top, 26 * L.k)
                Text(ui.introTitle.uppercased())
                    .font(serif(L.big, light: false)).tracking(L.big * 0.12)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    .padding(.top, 10 * L.k).padding(.horizontal, 20)
                Rectangle().fill(.white.opacity(0.9)).frame(width: 64, height: 1.2).padding(.vertical, 26 * L.k)
                Text("IN WHICH").font(sans(14)).tracking(14 * 0.24)
                VStack(spacing: 8 * L.k) {
                    ForEach(Array(ui.introLines.enumerated()), id: \.offset) { _, l in
                        Text(l.uppercased()).font(serif(L.big * 0.56, light: false)).tracking(L.big * 0.56 * 0.14)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.top, 22 * L.k)
                if !L.wide { Ornament(flipped: true).frame(width: L.ornament).padding(.top, 26) }
                Spacer(minLength: 4)
                RingButton(label: ui.introResume ? "Continue the chapter" : "Begin the chapter") { ui.handlers.startChapter() }
                    .scaleEffect(L.wide ? 0.8 : 1)
                Text(ui.introResume ? "continue" : " ").font(sans(11)).tracking(11 * 0.3).opacity(0.7).padding(.top, L.wide ? -8 : 2)
                    .padding(.bottom, L.wide ? 6 : h * 0.04)
            }
            .modifier(CardText())
            .modifier(L.place)
            VStack {
                HStack {
                    if L.wide { Spacer() }  // in landscape the card's ornament runs along the top left
                    Button { ui.handlers.leave() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .light)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.2))
                            .frame(width: 52, height: 52).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Back to the chapters")
                    if !L.wide { Spacer() }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 6)
        }
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeInOut(duration: 1.4).delay(0.3)) { shown = true } }
    }
}

/// The closing card of a small chapter.
struct ChapterComplete: View {
    @Bindable var ui: UIState
    let w: CGFloat
    let h: CGFloat
    @State private var shown = false

    var body: some View {
        let L = CardLayout(w: w, h: h)
        ZStack {
            L.veil
            VStack(spacing: 0) {
                Spacer()
                Ornament().frame(width: L.ornament)
                Text("CHAPTER \(ui.completeNumeral)").font(serif(L.big * 0.6, light: false)).tracking(L.big * 0.6 * 0.24).padding(.top, 26 * L.k)
                Text(ui.completeTitle.uppercased()).font(serif(L.big, light: false)).tracking(L.big * 0.12)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6).padding(.top, 10 * L.k).padding(.horizontal, 20)
                Rectangle().fill(.white.opacity(0.9)).frame(width: 64, height: 1.2).padding(.vertical, 24 * L.k)
                Text("THE LIGHT HAS FOUND ITS PLACE").font(sans(13)).tracking(13 * 0.24).multilineTextAlignment(.center)
                Ornament(flipped: true).frame(width: L.ornament).padding(.top, 24 * L.k)
                Spacer()
                RingButton(label: "Return to the chapters") { ui.handlers.complete() }
                    .scaleEffect(L.wide ? 0.8 : 1)
                    .padding(.bottom, L.wide ? 8 : h * 0.05)
            }
            .modifier(CardText())
            .modifier(L.place)
        }
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeInOut(duration: 1.6)) { shown = true } }
    }
}

/// Chapter cards stand centred in portrait; in landscape they keep to the left half, leaving the right half
/// to the diorama (the camera frames it there), with type sized to the short side.
private struct CardLayout {
    let w: CGFloat
    let h: CGFloat
    var wide: Bool { w > h * 1.15 }
    var k: CGFloat { wide ? min(1, h / 760) : 1 }
    var big: CGFloat { wide ? min(40, h * 0.085) : min(46, w * 0.105) }
    var column: CGFloat { wide ? w * 0.5 : w }
    var ornament: CGFloat { min(column * 0.8, 380) }

    var veil: some View {
        RadialGradient(colors: [.black.opacity(0.5), .black.opacity(0.24), .clear],
                       center: UnitPoint(x: wide ? 0.27 : 0.5, y: 0.42), startRadius: 0, endRadius: (wide ? h : max(w, h)) * 0.62)
            .ignoresSafeArea().allowsHitTesting(false)
    }

    struct Place: ViewModifier {
        let wide: Bool
        let column: CGFloat
        func body(content: Content) -> some View {
            if wide {
                content.frame(width: column).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                content.frame(maxWidth: .infinity)
            }
        }
    }

    var place: Place { Place(wide: wide, column: column) }
}

// ───────────────────────── pause & leave ─────────────────────────

/// Round outlined icon with a spaced caption beneath.
private struct CircleAction: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .light))
                    .frame(width: 48, height: 48)
                    .overlay(Circle().stroke(.white, lineWidth: 1.6))
                Text(label.uppercased()).font(sans(13)).tracking(13 * 0.22).fixedSize()
            }
            .foregroundStyle(.white)
            .frame(minWidth: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
    }
}

private struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1).scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

/// Dim, cool veil over the paused world.
private struct Veil: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(0.55)
            LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.3).opacity(0.62), Color(red: 0.1, green: 0.14, blue: 0.34).opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

struct PauseScreen: View {
    @Bindable var ui: UIState
    let chapterLabel: String
    @State private var shown = false

    var body: some View {
        ZStack {
            Veil()
            VStack(spacing: 0) {
                Text(chapterLabel.uppercased()).font(sans(12)).tracking(12 * 0.32).opacity(0.75)
                Text("PAUSED").font(serif(32, light: false)).tracking(32 * 0.18).padding(.top, 10).padding(.bottom, 44)
                HStack(spacing: 14) {
                    CircleAction(symbol: "play", label: "Resume") { ui.handlers.pause(false) }
                    CircleAction(symbol: "sparkle", label: "Hint") { ui.handlers.pause(false); ui.handlers.hint() }
                    CircleAction(symbol: "arrow.counterclockwise", label: "Restart") { ui.confirm("Start this chapter again?") { ui.handlers.restart() } }
                }
                HStack(spacing: 14) {
                    CircleAction(symbol: "slider.horizontal.3", label: "Settings") { ui.openSettings(from: "pause") }
                    CircleAction(symbol: "rectangle.portrait.and.arrow.right", label: "Leave") { ui.askLeave() }
                }
                .padding(.top, 30)
            }
            .foregroundStyle(.white)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
        }
        .onAppear { withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.6)) { shown = true } }
    }
}

/// "Leave this chapter?" — cancel or exit, as two round icons.
struct LeaveScreen: View {
    @Bindable var ui: UIState
    var title = "Leave this chapter?"
    var yesLabel = "Exit"
    var yesSymbol = "rectangle.portrait.and.arrow.right"
    var onYes: (() -> Void)?
    var onNo: (() -> Void)?
    @State private var shown = false

    var body: some View {
        ZStack {
            Veil()
            VStack(spacing: 46) {
                Text(title.uppercased()).font(sans(17)).tracking(17 * 0.16).multilineTextAlignment(.center).padding(.horizontal, 24)
                HStack(spacing: 70) {
                    CircleAction(symbol: "xmark", label: "Cancel") { (onNo ?? ui.cancelLeave)() }
                    CircleAction(symbol: yesSymbol, label: yesLabel) { (onYes ?? ui.handlers.leave)() }
                }
            }
            .foregroundStyle(.white)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
        }
        .onAppear { withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.6)) { shown = true } }
    }
}
