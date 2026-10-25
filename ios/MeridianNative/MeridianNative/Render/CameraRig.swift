// CameraController: exact isometric orthographic camera with zone framing, smooth follow and
// world rotation in 90° steps (port of src/render/CameraRig.ts).

import Foundation
import simd

private let ELEV = atan(1 / 2.0.squareRoot()) // 35.264° — true isometric

final class CameraRig {
    var target = V3.zero
    private var goalTarget = V3.zero
    var size = 8.0
    private var goalSize = 8.0
    /// yaw of the view vector; quadrant q ↔ 45° + q·90°
    var yaw = Double.pi / 4
    private var yawFrom = Double.pi / 4
    private var yawTo = Double.pi / 4
    private var yawT = 1.0
    private var yawDur = 1.2
    /// Temporary yaw offset while the player drags the sky.
    var dragYaw = 0.0
    private var dragYawSmoothed = 0.0
    var aspect = 1.0
    var followRate = 2.2
    var zoomRate = 1.6
    /// Gentle breathing drift for life while idle.
    var drift = 1.0
    private var vel = V3.zero
    private var sizeVel = 0.0

    // camera state for rendering / picking
    private(set) var position = V3.zero
    private(set) var lookAt = V3.zero
    private(set) var left = -10.0, right = 10.0, top = 10.0, bottom = -10.0
    let near = -200.0, far = 400.0

    static func yawFor(_ q: Int) -> Double { Double.pi / 4 + Double(q) * (Double.pi / 2) }

    func setQuadrant(_ q: Int, animate: Bool, duration: Double = 1.2) {
        let to = CameraRig.yawFor(q)
        if !animate {
            yaw = to; yawFrom = to; yawTo = to
            yawT = 1
            return
        }
        var delta = to - yaw
        while delta > Double.pi { delta -= Double.pi * 2 }
        while delta < -Double.pi { delta += Double.pi * 2 }
        yawFrom = yaw + dragYawSmoothed
        dragYaw = 0
        dragYawSmoothed = 0
        yawTo = yaw + delta
        yawT = 0
        yawDur = duration
    }

    var rotating: Bool { yawT < 1 }

    func frame(_ t: V3, _ size: Double, snap: Bool = false) {
        goalTarget = t
        goalSize = size
        if snap {
            target = goalTarget
            self.size = size
            vel = .zero
            sizeVel = 0
        }
    }

    /// View direction (from target toward camera).
    func viewDir() -> V3 {
        let y = yaw + dragYawSmoothed
        return simd_normalize(V3(sin(y) * cos(ELEV), sin(ELEV), cos(y) * cos(ELEV)))
    }

    func update(_ dt: Double, _ time: Double) {
        if yawT < 1 {
            yawT = min(1, yawT + dt / yawDur)
            yaw = yawFrom + (yawTo - yawFrom) * ease.inOutQuart(yawT)
        }
        dragYawSmoothed += (dragYaw - dragYawSmoothed) * damp(14, dt)
        let tFollow = 1.6 / max(0.1, followRate)
        let tZoom = 1.6 / max(0.1, zoomRate)
        for ax in 0..<3 {
            let r = smoothDamp(target[ax], goalTarget[ax], vel[ax], tFollow, dt)
            target[ax] = r.0
            vel[ax] = r.1
        }
        let zs = smoothDamp(size, goalSize, sizeVel, tZoom, dt)
        size = zs.0
        sizeVel = zs.1
        let breatheOut = yawT < 1 ? sin(Double.pi * yawT) * 0.06 : 0

        let dir = viewDir()
        let t = target
        let breathe = sin(time * 0.35) * 0.04 * drift
        position = V3(t.x + dir.x * 120, t.y + breathe + dir.y * 120, t.z + dir.z * 120)
        lookAt = V3(t.x, t.y + breathe, t.z)

        let base = size * (1 + breatheOut)
        let s = aspect < 1 ? base / max(0.62, aspect) : base
        top = s
        bottom = -s
        left = -s * aspect
        right = s * aspect
    }

    var worldMatrix: M4 { M4.lookAtWorld(eye: position.f, target: lookAt.f, up: F3(0, 1, 0)) }
    var viewMatrix: M4 { worldMatrix.inverse }
    var projMatrix: M4 { M4.orthographic(left: Float(left), right: Float(right), top: Float(top), bottom: Float(bottom), near: Float(near), far: Float(far)) }
}

/// Unity-style SmoothDamp (critically damped spring). Returns (value, velocity).
private func smoothDamp(_ cur: Double, _ target: Double, _ vel: Double, _ smoothTime: Double, _ dt: Double) -> (Double, Double) {
    let omega = 2 / smoothTime
    let x = omega * dt
    let e = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
    let change = cur - target
    let temp = (vel + omega * change) * dt
    let v = (vel - omega * temp) * e
    return (target + (change + temp) * e, v)
}
