// SwiftUI rebuild of index.html + style.css: title, HUD, pause, settings, confirm, ending, fade and
// vignette — same typography, spacing, colours and timings, laid out with safe areas.

import SwiftUI

private let ink = Color(red: 0x5b / 255, green: 0x4a / 255, blue: 0x52 / 255)
private let inkSoft = ink.opacity(0.62)
private let accent = Color(red: 0xe9 / 255, green: 0x73 / 255, blue: 0x5c / 255)

/// The stylesheet's typefaces, bundled (SIL Open Font License): Cormorant Garamond for display, Jost for text.
/// Weights follow style.css — headings at 300, whispers at 400 italic.
func serif(_ size: CGFloat, italic: Bool = false, light: Bool = true) -> Font {
    let name = switch (italic, light) {
    case (false, true): "CormorantGaramond-Light"
    case (false, false): "CormorantGaramond-Regular"
    case (true, true): "CormorantGaramond-LightItalic"
    case (true, false): "CormorantGaramond-Italic"
    }
    return .custom(name, size: size)
}

func sans(_ size: CGFloat, light: Bool = false) -> Font {
    .custom(light ? "JostRoman-Light" : "Jost-Regular", size: size)
}

private func clampV(_ lo: CGFloat, _ v: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }

struct GameUI: View {
    @Bindable var ui: UIState

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Vignette().allowsHitTesting(false)
                GroundMist(color: ui.groundColor)
                    .opacity(ui.groundFade ? 1 : 0)
                    .animation(.easeInOut(duration: 1.6), value: ui.groundFade)
                    .allowsHitTesting(false)
                if ui.titleShown { TitleScreen(ui: ui, w: w, h: h).opacity(ui.titleFading ? 0 : 1).animation(.easeInOut(duration: 1.2), value: ui.titleFading) }
                if ui.selectShown { ChapterGallery(ui: ui, w: w, h: h) }
                if ui.introShown { ChapterIntro(ui: ui, w: w, h: h) }
                if ui.hudShown { HUD(ui: ui, w: w, h: h) }
                if ui.completeShown { ChapterComplete(ui: ui, w: w, h: h) }
                if ui.pauseShown { PauseScreen(ui: ui, chapterLabel: ui.playingLabel) }
                if ui.leaveShown { LeaveScreen(ui: ui) }
                if ui.confirmShown {
                    LeaveScreen(ui: ui, title: ui.confirmText, yesLabel: "Again", yesSymbol: "arrow.counterclockwise",
                                onYes: { ui.confirmYes() }, onNo: { ui.confirmNo() })
                }
                if ui.settingsShown { Panel { SettingsMenu(ui: ui) } }
                if ui.endingShown { EndingScreen(ui: ui, w: w, h: h) }
                Color(red: 0xfb / 255, green: 0xf4 / 255, blue: 0xe8 / 255)
                    .opacity(ui.fadeClear ? 0 : 1)
                    .animation(.easeInOut(duration: 1.6), value: ui.fadeClear)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                if let text = ui.debugText { DebugPanel(text: text, next: ui.handlers.nextStep) }
            }
        }
    }
}

private struct Vignette: View {
    var body: some View {
        GeometryReader { geo in
            EllipticalGradient(stops: [.init(color: .clear, location: 0.58), .init(color: Color(red: 70 / 255, green: 40 / 255, blue: 60 / 255).opacity(0.13), location: 1)],
                               center: UnitPoint(x: 0.5, y: 0.46))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

/// Fades its content in after a delay (CSS `animation: fadein … forwards`).
private struct FadeIn: ViewModifier {
    let duration: Double
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).onAppear {
            withAnimation(.easeInOut(duration: duration).delay(delay)) { shown = true }
        }
    }
}

private extension View {
    func fadeIn(_ duration: Double, delay: Double) -> some View { modifier(FadeIn(duration: duration, delay: delay)) }
}

/// One letter of the logo rising out of a blur.
private struct RiseLetter: View {
    let char: String
    let size: CGFloat
    let delay: Double
    @State private var up = false

    var body: some View {
        Text(char)
            .font(serif(size))
            .foregroundStyle(ink)
            .opacity(up ? 1 : 0)
            .offset(y: up ? 0 : 14)
            .blur(radius: up ? 0 : 6)
            .onAppear { withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 1.6).delay(delay)) { up = true } }
    }
}

private struct Logo: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.32) {
            ForEach(Array("MERIDIAN".enumerated()), id: \.offset) { i, c in
                RiseLetter(char: String(c), size: size, delay: 0.25 + Double(i) * 0.1)
            }
        }
        .padding(.leading, size * 0.32)
    }
}

/// `.link` buttons: lowercase, widely spaced, with an underline that grows while pressed.
private struct LinkButton: View {
    let title: String
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.lowercased())
                .font(sans(small ? 14 : 19, light: true))
                .tracking((small ? 14 : 19) * 0.28)
                .foregroundStyle(small ? inkSoft : ink)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(LinkStyle())
    }
}

private struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(alignment: .bottom) {
                Rectangle().fill(ink.opacity(0.55)).frame(height: 1).scaleEffect(x: configuration.isPressed ? 1 : 0)
                    .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.5), value: configuration.isPressed)
            }
            .scaleEffect(configuration.isPressed ? 1.03 : 1)
            .animation(.easeOut(duration: 0.3), value: configuration.isPressed)
    }
}

private struct TitleScreen: View {
    @Bindable var ui: UIState
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let logoSize = clampV(44, w * 0.082, 112)
        ZStack {
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Color(red: 1, green: 248 / 255, blue: 238 / 255).opacity(0.35), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            HStack {
                VStack(spacing: 0) {
                    Logo(size: logoSize)
                    Text("a quiet geometry")
                        .font(serif(clampV(17, w * 0.019, 24), italic: true))
                        .tracking(clampV(17, w * 0.019, 24) * 0.12)
                        .foregroundStyle(inkSoft)
                        .padding(.top, 8)
                        .padding(.bottom, 44)
                        .fadeIn(1.6, delay: 1.3)
                    VStack(spacing: 6) {
                        LinkButton(title: ui.hasSave ? "Continue" : "Begin") { ui.handlers.begin() }
                        LinkButton(title: "Settings", small: true) { ui.openSettings(from: "title") }
                    }
                    .fadeIn(1.4, delay: 1.9)
                }
                .background {
                    EllipticalGradient(stops: [.init(color: Color(red: 1, green: 252 / 255, blue: 245 / 255).opacity(0.78), location: 0),
                                               .init(color: Color(red: 1, green: 252 / 255, blue: 245 / 255).opacity(0.45), location: 0.4 / 0.7),
                                               .init(color: .clear, location: 1)])
                        .frame(width: logoSize * 14, height: logoSize * 8)
                        .fadeIn(2, delay: 0.2)
                        .allowsHitTesting(false)
                }
                .offset(y: -h * 0.04)
                .padding(.leading, ui.wide ? w * 0.09 : 0)
                if ui.wide { Spacer() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                Spacer()
                Text("tap to walk  ·  drag the handles  ·  headphones recommended")
                    .font(sans(12))
                    .tracking(12 * 0.22)
                    .foregroundStyle(inkSoft)
                    .multilineTextAlignment(ui.wide ? .leading : .center)
                    .frame(maxWidth: .infinity, alignment: ui.wide ? .leading : .center)
                    .padding(.leading, ui.wide ? w * 0.09 : 16)
                    .padding(.trailing, 16)
                    .padding(.bottom, h * 0.04)
                    .fadeIn(2, delay: 2.6)
            }
        }
    }
}

private struct HUD: View {
    @Bindable var ui: UIState
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack {
            // chapter card
            VStack(spacing: 0) {
                Text(ui.chapterNum)
                    .font(sans(12)).tracking(12 * 0.5).foregroundStyle(inkSoft)
                    .padding(.bottom, 7)
                Text(ui.chapterName)
                    .font(serif(clampV(24, w * 0.026, 36), italic: true))
                    .tracking(clampV(24, w * 0.026, 36) * 0.08)
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
            }
            .shadow(color: .white.opacity(0.95), radius: 11)
            .shadow(color: .white.opacity(0.8), radius: 3)
            .opacity(ui.chapterShow ? 1 : 0)
            .offset(y: ui.chapterShow ? 0 : 6)
            .animation(.easeInOut(duration: 1.6), value: ui.chapterShow)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, h * 0.09)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)

            // whisper
            Text(ui.hintText)
                .font(serif(clampV(17, w * 0.016, 22), italic: true, light: false))
                .tracking(clampV(17, w * 0.016, 22) * 0.05)
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .shadow(color: .white.opacity(0.7), radius: 9)
                .opacity(ui.hintShow ? 0.85 : 0)
                .animation(.easeInOut(duration: 1.4), value: ui.hintShow)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, h * 0.07)
                .padding(.horizontal, 20)
                .allowsHitTesting(false)

            if ui.turnHintShown {
                TurnHint()
                    .opacity(ui.turnHintShow ? 1 : 0)
                    .animation(.easeInOut(duration: 1.4), value: ui.turnHintShow)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, h * 0.12)
                    .allowsHitTesting(false)
            }

            // pause ring
            Button { ui.handlers.pause(true) } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1.5).frame(width: 44, height: 44)
                    Circle().fill(.white.opacity(0.95)).frame(width: 12, height: 12)
                }
                .opacity(0.85)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
            }
            .accessibilityLabel("Pause")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, w < 640 ? 10 : 18)
            .padding(.top, 10)

            if ui.turnButtonsShown {
                HStack(spacing: 10) {
                    TurnButton(symbol: "arrow.counterclockwise", label: "Turn world left") { ui.handlers.turn(-1) }
                    TurnButton(symbol: "arrow.clockwise", label: "Turn world right") { ui.handlers.turn(1) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 26)
                .padding(.bottom, 26)
            }
        }
    }
}

private struct TurnButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
                .opacity(0.8)
        }
        .accessibilityLabel(label)
    }
}

private struct TurnHint: View {
    @State private var sway = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Arc(arrowLeft: true).offset(x: sway ? 3 : -3)
                Capsule().stroke(ink, lineWidth: 1.5).frame(width: 34, height: 18)
                    .overlay(Circle().fill(ink).frame(width: 7, height: 7))
                Arc(arrowLeft: false).offset(x: sway ? -3 : 3)
            }
            Text("swipe the sky or twist two fingers to turn the world")
                .font(sans(13)).tracking(13 * 0.24).foregroundStyle(inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { sway = true } }
    }
}

private struct Arc: View {
    let arrowLeft: Bool

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.addArc(center: CGPoint(x: size.width / 2, y: size.height), radius: size.width / 2, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            ctx.stroke(p, with: .color(ink), lineWidth: 1.5)
            var a = Path()
            let x: CGFloat = arrowLeft ? 0 : size.width
            let dir: CGFloat = arrowLeft ? 1 : -1
            a.move(to: CGPoint(x: x + dir * 6, y: size.height - 1))
            a.addLine(to: CGPoint(x: x, y: size.height - 8))
            a.addLine(to: CGPoint(x: x - dir * 5, y: size.height - 1))
            ctx.stroke(a, with: .color(ink), lineWidth: 1.5)
        }
        .frame(width: 46, height: 22)
    }
}

/// `.panel-screen`: soft frosted veil over the game.
private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(0.75).ignoresSafeArea()
            Color(red: 250 / 255, green: 240 / 255, blue: 232 / 255).opacity(0.38).ignoresSafeArea()
            VStack(spacing: 10) { content }
                .frame(minWidth: 280)
                .padding(.vertical, 36)
                .padding(.horizontal, 24)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 8)
                .onAppear { withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.7)) { shown = true } }
        }
    }
}

private struct PanelTitle: View {
    let text: String
    var body: some View {
        Text(text).font(serif(34, italic: true)).tracking(34 * 0.08).foregroundStyle(ink).padding(.bottom, 20)
    }
}

private struct SettingsMenu: View {
    @Bindable var ui: UIState
    var body: some View {
        PanelTitle(text: "Settings")
        SettingRow(label: "Music") { Slider(value: $ui.settings.music, in: 0...1).tint(ink).frame(width: 150) }
        SettingRow(label: "Sounds") { Slider(value: $ui.settings.sfx, in: 0...1).tint(ink).frame(width: 150) }
        SettingRow(label: "Soft shadows") { Toggle("", isOn: $ui.settings.shadows).labelsHidden().tint(accent) }
        SettingRow(label: "Turn buttons") { Toggle("", isOn: $ui.settings.turnButtons).labelsHidden().tint(accent) }
        SettingRow(label: "Haptics") { Toggle("", isOn: $ui.settings.haptics).labelsHidden().tint(accent) }
        LinkButton(title: "Back") { ui.closeSettings() }.padding(.top, 8)
    }
}

private struct SettingRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack {
            Text(label.lowercased()).font(sans(14)).tracking(14 * 0.18).foregroundStyle(ink)
            Spacer(minLength: 24)
            control
        }
        .frame(width: 290)
        .padding(.vertical, 3)
    }
}

private struct EndingScreen: View {
    let ui: UIState
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack {
            EllipticalGradient(stops: [.init(color: .clear, location: 0.3), .init(color: Color(red: 1, green: 246 / 255, blue: 230 / 255).opacity(0.55), location: 1)])
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Logo(size: clampV(36, w * 0.06, 80))
                Text("the light has found its height")
                    .font(serif(clampV(17, w * 0.019, 24), italic: true))
                    .tracking(clampV(17, w * 0.019, 24) * 0.12)
                    .foregroundStyle(inkSoft)
                    .padding(.top, 8).padding(.bottom, 44)
                    .fadeIn(1.6, delay: 1.3)
                Text("design · code · sound — made with care\nthank you for walking")
                    .font(sans(12)).tracking(12 * 0.3).lineSpacing(14)
                    .foregroundStyle(inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 44)
                    .fadeIn(2, delay: 2.4)
                VStack(spacing: 6) {
                    LinkButton(title: "The chapters") { ui.handlers.complete() }
                    LinkButton(title: "Walk again", small: true) { ui.handlers.again() }
                }
                .fadeIn(1.4, delay: 1.9)
            }
            .background {
                // the title's soft halo keeps the closing words legible over the monument on a phone
                EllipticalGradient(stops: [.init(color: Color(red: 1, green: 252 / 255, blue: 245 / 255).opacity(0.78), location: 0),
                                           .init(color: Color(red: 1, green: 252 / 255, blue: 245 / 255).opacity(0.45), location: 0.57),
                                           .init(color: .clear, location: 1)])
                    .frame(width: max(w * 1.3, 520), height: 560)
                    .fadeIn(2, delay: 0.2)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 16)
            .offset(y: -h * 0.04)
        }
    }
}

private struct DebugPanel: View {
    let text: String
    let next: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(red: 0x3a / 255, green: 0x2d / 255, blue: 0x33 / 255))
            Button("next solver step", action: next).font(.system(size: 11, design: .monospaced))
        }
        .padding(10)
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(12)
    }
}

#Preview("Title") {
    GameUI(ui: UIState(settings: Settings()))
        .background(LinearGradient(colors: [Color(red: 0.75, green: 0.89, blue: 0.85), Color(red: 0.97, green: 0.93, blue: 0.86)], startPoint: .top, endPoint: .bottom))
}

/// The mood's fog rising from the bottom of the screen, so the monument's columns dissolve before the edge.
private struct GroundMist: View {
    let color: SIMD3<Float>

    var body: some View {
        let c = Color(.sRGB, red: Double(linearToSrgb(color.x)), green: Double(linearToSrgb(color.y)), blue: Double(linearToSrgb(color.z)))
        LinearGradient(stops: [.init(color: c.opacity(0), location: 0.6), .init(color: c.opacity(0.75), location: 0.82), .init(color: c, location: 0.97)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}
