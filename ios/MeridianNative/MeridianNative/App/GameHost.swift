// Native host: an MTKView driven by the display link at the panel's maximum refresh rate (120 Hz on
// ProMotion), rendering at native Retina resolution with adaptive scaling, and decoding touches into
// the original's intents — tap to walk, drag a handle, swipe the sky — plus a two-finger twist that
// turns the world.

import MetalKit
import UIKit


final class GameHost: NSObject, MTKViewDelegate {
    let view: GameMTKView
    let renderer: Renderer
    let game: Game
    private var last = CACurrentMediaTime()
    private var scale: CGFloat
    private let maxScale: CGFloat
    private let minScale: CGFloat
    private var slowTime = 0.0
    private var fastTime = 0.0
    private var drops = 0

    override init() {
        let v = GameMTKView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), device: MTLCreateSystemDefaultDevice())
        view = v
        renderer = Renderer(view: v)!
        renderer.prewarm()
        game = Game(renderer: renderer)
        let native = UIScreen.main.nativeScale
        maxScale = native
        minScale = min(native, max(1.5, native * 0.6))
        scale = native
        super.init()
        v.host = self
        v.delegate = self
        v.autoResizeDrawable = false
        v.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        v.isMultipleTouchEnabled = true
        v.backgroundColor = UIColor(red: 0.953, green: 0.918, blue: 0.851, alpha: 1)
    }

    var targetFPS: Double { Double(view.preferredFramesPerSecond) }

    func layout() {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let px = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        if view.drawableSize != px { view.drawableSize = px }
        renderer.pixelRatio = Float(scale)
        game.resize(size)
    }

    /// Adaptive resolution: step down gently when frames are missed, back up when there is headroom.
    private func adapt(_ dt: Double) {
        let fps = game.fpsAvg, target = targetFPS
        if fps > target * 0.97 && scale < maxScale && drops < 3 {
            fastTime += dt
            if fastTime > 6 { scale = min(maxScale, scale + 0.25); fastTime = 0; layout() }
        } else { fastTime = 0 }
        if fps < target * 0.78 && scale > minScale {
            slowTime += dt
            if slowTime > 2.5 { scale = max(minScale, scale - 0.25); slowTime = 0; drops += 1; layout() }
        } else { slowTime = max(0, slowTime - dt) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = now - last
        last = now
        adapt(min(dt, 0.1))
        game.frame(dt)
        if game.renderIdle { return }
        renderer.render(scene: game.scene, in: view)
    }

    func setActive(_ active: Bool) {
        if active {
            last = CACurrentMediaTime()
            view.isPaused = false
            game.resume()
        } else {
            game.suspend()
            view.isPaused = true
        }
    }
}

final class GameMTKView: MTKView {
    weak var host: GameHost?
    private var game: Game? { host?.game }

    private enum Mode: Equatable { case none, handle, sky, press, twist, nearHandle(String) }
    private var mode: Mode = .none
    private var tracked: UITouch?
    private var downX = 0.0, downY = 0.0, lastX = 0.0, lastT = 0.0, vx = 0.0

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        let twist = UIRotationGestureRecognizer(target: self, action: #selector(onTwist(_:)))
        twist.cancelsTouchesInView = false
        addGestureRecognizer(twist)
        let debugTap = UITapGestureRecognizer(target: self, action: #selector(onDebugTap))
        debugTap.numberOfTouchesRequired = 3
        debugTap.cancelsTouchesInView = false
        addGestureRecognizer(debugTap)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        host?.layout()
    }

    private func ms() -> Double { CACurrentMediaTime() * 1000 }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // a finger whose end we never saw (swallowed by a system gesture) must not block input forever
        if let t = tracked, t.phase == .ended || t.phase == .cancelled || !(event?.allTouches?.contains(t) ?? false) {
            finish([t], cancelled: true)
        }
        guard let game, game.inputEnabled, tracked == nil, mode != .twist, let t = touches.first else { return }
        tracked = t
        let p = t.location(in: self)
        downX = p.x; downY = p.y; lastX = p.x
        lastT = ms()
        vx = 0
        if let picked = game.pickHandle(p.x, p.y) {
            if !picked.precise {
                // near a wheel but not on it: a drag turns it, a tap still walks
                mode = .nearHandle(picked.mech)
                return
            }
            if game.pointerHandleDown(picked.mech, p.x, p.y) {
                mode = .handle
                return
            }
        }
        mode = .press
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let game, let t = tracked, touches.contains(t), mode != .twist else { return }
        let p = t.location(in: self)
        let now = ms()
        let dt = max(1, now - lastT)
        vx = 0.7 * vx + 0.3 * ((p.x - lastX) / dt)
        lastX = p.x
        lastT = now
        if case let .nearHandle(mech) = mode, hypot(p.x - downX, p.y - downY) > 6 {
            mode = game.pointerHandleDown(mech, downX, downY) ? .handle : .press
        }
        if mode == .handle {
            game.pointerHandleMove(p.x, p.y)
        } else if mode == .press {
            let dx = p.x - downX, dy = p.y - downY
            if hypot(dx, dy) > 10 && abs(dx) > abs(dy) * 0.8 { mode = .sky }
        }
        if mode == .sky { game.pointerSkyDrag(p.x - downX) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        guard let game, let t = tracked, touches.contains(t) else { return }
        tracked = nil
        let p = t.location(in: self)
        switch mode {
        case .handle: game.pointerHandleUp()
        case .sky: game.pointerSkyRelease(p.x - downX, vx)
        case .press, .nearHandle:
            if !cancelled && game.inputEnabled && hypot(p.x - downX, p.y - downY) < 10 { game.tap(p.x, p.y) }
        default: break
        }
        if mode != .twist { mode = .none }
    }

    /// Two-finger twist: a clockwise turn acts like dragging the sky to the right.
    @objc private func onTwist(_ g: UIRotationGestureRecognizer) {
        guard let game else { return }
        let k = 160.0
        switch g.state {
        case .began:
            guard game.inputEnabled, mode != .handle else { return }
            tracked = nil
            mode = .twist
        case .changed:
            if mode == .twist { game.pointerSkyDrag(g.rotation * k) }
        case .ended, .cancelled, .failed:
            if mode == .twist {
                game.pointerSkyRelease(g.rotation * k, g.velocity * k / 1000)
                mode = .none
            }
        default: break
        }
    }

    @objc private func onDebugTap() { game?.toggleDebug() }
}
