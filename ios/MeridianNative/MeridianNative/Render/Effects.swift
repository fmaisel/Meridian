// Interaction feedback: tile rings, seam shimmer, handle pulses and dust bursts (port of Effects.ts).

import Foundation
import Metal
import simd

final class Effects {
    let group = Node("effects")
    private let anim: Animator
    private let r: Renderer
    private let ringMesh: GPUMesh

    init(anim: Animator, renderer: Renderer) {
        self.anim = anim
        r = renderer
        ringMesh = renderer.makeMesh(planeGeometry(1, 1).rotatedX(-Double.pi / 2))
    }

    private func spriteMat(_ hex: String) -> Material {
        let m = Material(.sprite, color: color(hex))
        m.map = r.textures.glyph("soft")
        m.transparent = true
        m.depthWrite = false
        m.depthTest = false
        m.blending = .additive
        return m
    }

    /// Square ring on a tile: confirms a tap (ok) or politely refuses (not ok).
    func ring(_ pos: V3, ok: Bool) {
        let mat = Material.basic(ok ? "#ffffff" : "#9a8a90", map: r.textures.glyph("ring"), transparent: true, depthWrite: false)
        mat.depthTest = false
        let m = Node(mesh: ringMesh, material: mat)
        m.position = (pos + V3(0, 0.02, 0)).f
        m.renderOrder = 6
        group.add(m)
        anim.add(duration: ok ? 0.6 : 0.45, ease: ease.outCubic, onUpdate: { k, _ in
            let s = Float(ok ? 0.75 + k * 0.35 : 1 - k * 0.45)
            m.scale = F3(s, 1, s)
            mat.opacity = Float((1 - k) * (ok ? 0.95 : 0.7))
        }, onDone: { [weak self] in self?.group.remove(m) })
    }

    /// Repeated ring pulse to point at a tile (hints).
    func beckon(_ pos: V3, times: Int = 3) {
        for i in 0..<times {
            anim.add(duration: 0.01, delay: Double(i) * 0.9, onDone: { [weak self] in self?.ring(pos, ok: true) })
        }
    }

    /// Soft light blooming at a point (connections, seams).
    func shimmer(_ pos: V3, color hex: String = "#fff6dc", scale: Double = 1.6) {
        let mat = spriteMat(hex)
        let s = Node(mesh: nil, material: mat)
        s.isSprite = true
        s.position = pos.f
        s.renderOrder = 7
        group.add(s)
        anim.add(duration: 1.6, ease: ease.linear, onUpdate: { _, t in
            let a = sin(Double.pi * min(1, t * 1.4))
            s.setScalar(Float(scale * (0.4 + t)))
            mat.opacity = Float(a * 0.9)
        }, onDone: { [weak self] in self?.group.remove(s) })
    }

    /// Glow pulse on a handle (touch, hint, refusal).
    func pulseHandle(_ h: HandleView, times: Int = 3) {
        anim.add(duration: 0.9 * Double(times), ease: ease.linear, onUpdate: { _, t in
            let v = Float(max(0, sin(t * Double(times) * Double.pi)) * 0.55)
            for m in h.materials { m.glow = max(m.glow, v) }
        }, onDone: { for m in h.materials { m.glow = 0 } })
    }

    /// Small refusal wiggle on a handle.
    func wiggle(_ h: HandleView) {
        let base = h.group.rotation
        anim.add(duration: 0.45, ease: ease.linear, onUpdate: { _, t in
            let a = Float(sin(t * Double.pi * 6) * (1 - t) * 0.12)
            h.group.rotation = F3(base.x, base.y + a, base.z + (h.kind == "knob" ? a : 0))
        }, onDone: { h.group.rotation = base })
    }

    /// A small light that travels from a plate to the part it moves — cause and effect made visible.
    func trail(_ from: V3, _ to: V3, duration: Double = 1.3, color hex: String = "#bff3e8") {
        let lift = max(from.y, to.y) + 1.2 + simd_distance(from, to) * 0.12
        func at(_ t: Double) -> V3 {
            var a = from + (to - from) * t
            a.y = (1 - t) * (1 - t) * from.y + 2 * (1 - t) * t * lift + t * t * to.y
            return a
        }
        for i in 0..<4 {
            let mat = spriteMat(hex)
            let s = Node(mesh: nil, material: mat)
            s.isSprite = true
            s.renderOrder = 7
            let size = i == 0 ? 0.7 : 0.45 - Double(i) * 0.08
            s.setScalar(Float(size))
            group.add(s)
            s.position = at(0).f
            anim.add(duration: duration, delay: Double(i) * 0.06, ease: ease.inOutSine, onUpdate: { k, _ in
                s.position = at(k).f
                mat.opacity = Float(min(1, k * 6) * (i == 0 ? 1 : 0.6) * (k > 0.92 ? (1 - k) / 0.08 : 1))
            }, onDone: { [weak self] in self?.group.remove(s) })
        }
        anim.add(duration: 0.01, delay: duration, onDone: { [weak self] in self?.shimmer(to, color: hex, scale: 1.6) })
    }

    func dust(_ pos: V3, spread: Double = 1.2, color hex: String = "#fff8ec") {
        let n = 36
        var p = [Float](repeating: 0, count: n * 3)
        var v: [F3] = []
        for i in 0..<n {
            p[i * 3] = Float(pos.x + (Double.random(in: 0..<1) - 0.5) * spread)
            p[i * 3 + 1] = Float(pos.y + Double.random(in: 0..<1) * 0.2)
            p[i * 3 + 2] = Float(pos.z + (Double.random(in: 0..<1) - 0.5) * spread)
            v.append(F3(Float((Double.random(in: 0..<1) - 0.5) * 0.6), Float(0.3 + Double.random(in: 0..<1) * 0.7), Float((Double.random(in: 0..<1) - 0.5) * 0.6)))
        }
        let pts = r.makePoints(count: n)
        let mat = Material(.points, color: color(hex))
        mat.map = r.textures.glyph("soft")
        mat.size = 0.12
        mat.k = 1
        mat.transparent = true
        mat.depthWrite = false
        mat.opacity = 0.9
        let node = Node(mesh: pts, material: mat)
        group.add(node)
        let write = { p.withUnsafeBytes { pts.buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        write()
        var last = 0.0
        anim.add(duration: 1.8, ease: ease.linear, onUpdate: { _, t in
            let dt = Float((t - last) * 1.8)
            last = t
            for i in 0..<n {
                p[i * 3] += v[i].x * dt
                p[i * 3 + 1] += v[i].y * dt
                p[i * 3 + 2] += v[i].z * dt
            }
            write()
            mat.opacity = Float(0.9 * (1 - t))
        }, onDone: { [weak self] in self?.group.remove(node) })
    }
}
