// AnimationSystem: easing curves and time-based tweens (port of src/core/anim.ts).

import Foundation

typealias Ease = (Double) -> Double

enum ease {
    static let linear: Ease = { $0 }
    static let inOutSine: Ease = { 0.5 - 0.5 * cos(Double.pi * $0) }
    static let outSine: Ease = { sin(($0 * Double.pi) / 2) }
    static let inOutCubic: Ease = { t in t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static let outCubic: Ease = { 1 - pow(1 - $0, 3) }
    static let inCubic: Ease = { $0 * $0 * $0 }
    static let outQuart: Ease = { 1 - pow(1 - $0, 4) }
    static let inOutQuart: Ease = { t in t < 0.5 ? 8 * pow(t, 4) : 1 - pow(-2 * t + 2, 4) / 2 }
    /// Gentle overshoot, used for snapping architecture into place.
    static let outBack: Ease = { t in
        let s = 1.25
        return 1 + (s + 1) * pow(t - 1, 3) + s * pow(t - 1, 2)
    }
    static let outExpo: Ease = { $0 >= 1 ? 1 : 1 - pow(2, -10 * $0) }
}

final class Tween {
    var duration: Double
    var delay: Double
    var ease: Ease
    var tag: String?
    var onUpdate: ((Double, Double) -> Void)?
    var onDone: (() -> Void)?
    var elapsed = 0.0
    var done = false

    init(duration: Double, delay: Double, ease: @escaping Ease, tag: String?, onUpdate: ((Double, Double) -> Void)?, onDone: (() -> Void)?) {
        self.duration = duration
        self.delay = delay
        self.ease = ease
        self.tag = tag
        self.onUpdate = onUpdate
        self.onDone = onDone
    }
}

final class Animator {
    private var list: [Tween] = []

    @discardableResult
    func add(duration: Double, delay: Double = 0, ease e: @escaping Ease = ease.inOutCubic, tag: String? = nil,
             onUpdate: ((Double, Double) -> Void)? = nil, onDone: (() -> Void)? = nil) -> () -> Void {
        let t = Tween(duration: duration, delay: delay, ease: e, tag: tag, onUpdate: onUpdate, onDone: onDone)
        list.append(t)
        return { t.done = true }
    }

    /// Call `then` after a pause.
    func wait(_ seconds: Double, then: @escaping () -> Void) {
        add(duration: seconds, onDone: then)
    }

    func cancel(_ tag: String) {
        for t in list where t.tag == tag { t.done = true }
    }

    func has(_ tag: String) -> Bool {
        list.contains { $0.tag == tag && !$0.done }
    }

    func update(_ dt: Double) {
        if list.isEmpty { return }
        let active = list
        list = []
        for t in active {
            if t.done { continue }
            t.elapsed += dt
            let local = t.elapsed - t.delay
            if local < 0 { list.append(t); continue }
            let k = min(1, local / max(1e-6, t.duration))
            t.onUpdate?(t.ease(k), k)
            if k >= 1 {
                t.done = true
                t.onDone?()
            } else {
                list.append(t)
            }
        }
    }
}
