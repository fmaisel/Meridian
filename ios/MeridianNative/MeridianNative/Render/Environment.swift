// Sky, drifting mist, light motes, birds and the light rig (port of src/render/Environment.ts).

import Foundation
import Metal
import simd

let SUN_DIR = simd_normalize(V3(0.3, 1, 0.68)) * 60

final class Environment {
    let group = Node("environment")
    private(set) var mood: Mood = MOODS["dawn"]!
    private var target: Mood = MOODS["dawn"]!
    private var mist: [Node] = []
    private let motes: Node
    private let motePoints: GPUMesh
    private var motePos: [Float]
    private var brighten = 0.0
    /// Camera yaw, for sky parallax.
    var yaw = 0.0
    private let r: Renderer

    private struct Bird { let g: Node; let l: Node; let rr: Node; let phase: Double; let radius: Double; let height: Double; let speed: Double }
    private var birds: [Bird] = []

    init(renderer: Renderer) {
        r = renderer
        // drifting cloud layers beneath the monument
        let mm = Material(.mist)
        mm.transparent = true
        mm.depthWrite = false
        mm.opacity = 0.5
        for (y, s) in [(-5.0, 90.0), (-7.5, 110.0), (-10.0, 130.0)] {
            let m = Node(mesh: r.makeMesh(planeGeometry(s, s).rotatedX(-Double.pi / 2)), material: mm)
            m.position.y = Float(y)
            m.renderOrder = 1
            mist.append(m)
            group.add(m)
        }

        // light motes — soft discs sized in world units (the browser drew them as single pixels)
        let n = 220
        motePos = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            motePos[i * 3] = Float((Double.random(in: 0..<1) - 0.5) * 50)
            motePos[i * 3 + 1] = Float(Double.random(in: 0..<1) * 40 - 8)
            motePos[i * 3 + 2] = Float((Double.random(in: 0..<1) - 0.5) * 50)
        }
        motePoints = r.makePoints(count: n)
        let pm = Material(.points, color: F3(1, 1, 1))
        pm.map = r.textures.glyph("soft")
        pm.size = 0.16
        pm.k = 1
        pm.transparent = true
        pm.depthWrite = false
        pm.opacity = 0.7
        motes = Node(mesh: motePoints, material: pm)
        group.add(motes)

        buildBirds()
        apply()
    }

    /// A small flock of pale birds circling the monument — slow, quiet life in the sky.
    private func buildBirds() {
        var wing = MeshData()
        wing.positions = [V3(0, 0, -0.05), V3(0, 0, 0.05), V3(0.22, 0, 0)]
        wing.normals = [V3(0, 1, 0), V3(0, 1, 0), V3(0, 1, 0)]
        wing.uvs = [.zero, .zero, .zero]
        wing.mist = [0, 0, 0]
        let mesh = r.makeMesh(wing)
        let mat = Material.basic("#fffaf2", transparent: true, opacity: 0.85, depthWrite: false)
        mat.side = .double
        for i in 0..<7 {
            let g = Node()
            let l = Node(mesh: mesh, material: mat)
            let rr = Node(mesh: mesh, material: mat)
            rr.scale.x = -1
            g.add(l, rr)
            g.setScalar(0.9 + Float(i % 3) * 0.2)
            group.add(g)
            birds.append(Bird(g: g, l: l, rr: rr, phase: Double(i) * 0.9, radius: 9 + Double(i % 4) * 1.6,
                              height: 3 + Double(i % 3) * 1.4, speed: 0.11 + Double(i % 2) * 0.03))
        }
    }

    func setMood(_ name: String) {
        if let m = MOODS[name] { target = m }
    }

    /// Extra radiance for the finale.
    func setBrighten(_ v: Double) { brighten = v }

    func update(_ dt: Double, focus: V3, time: Double, aspect: Double) {
        mood = Mood.blend(mood, target, Float(1 - exp(-1.2 * dt)))
        apply()
        r.frame.skyParams = F4(Float(aspect), Float(brighten), Float(yaw * 0.6 + (focus.x - focus.z) * 0.012), Float(focus.y * 0.018))
        // keep the shadow frustum centred on what we look at
        let eye = (focus + SUN_DIR).f
        let lightView = M4.lookAtWorld(eye: eye, target: focus.f, up: F3(0, 1, 0)).inverse
        let lightProj = M4.orthographic(left: -22, right: 22, top: 22, bottom: -22, near: 1, far: 120)
        r.frame.shadowVP = lightProj * lightView
        r.frame.sunDir = F4(simd_normalize(SUN_DIR).f, 0)
        for m in mist { m.position.x = Float(focus.x); m.position.z = Float(focus.z) }

        let fy = Float(focus.y)
        let fdt = Float(dt), ft = Float(time)
        motePos.withUnsafeMutableBufferPointer { arr in
            var i = 0
            while i < arr.count {
                arr[i + 1] += fdt * (0.18 + Float(i % 7) * 0.02)
                arr[i] += sin(ft * 0.3 + Float(i)) * fdt * 0.05
                if arr[i + 1] > fy + 22 { arr[i + 1] = fy - 16 }
                if arr[i + 1] < fy - 16 { arr[i + 1] = fy + 20 }
                i += 3
            }
        }
        motePos.withUnsafeBytes { src in
            motePoints.buffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        motes.position = F3(Float(focus.x), 0, Float(focus.z))

        for b in birds {
            let a = time * b.speed + b.phase
            let x = focus.x + cos(a) * b.radius
            let z = focus.z + sin(a) * b.radius
            b.g.position = F3(Float(x), Float(focus.y + b.height + sin(time * 0.6 + b.phase) * 0.4), Float(z))
            b.g.rotation.y = Float(-a)
            let flap = sin(time * 7 + b.phase * 3) * 0.55 * (0.5 + 0.5 * max(0, sin(time * 0.5 + b.phase)))
            b.l.rotation.z = Float(flap)
            b.rr.rotation.z = Float(-flap)
        }
    }

    private func apply() {
        let m = mood
        r.frame.skyTop = F4(m.skyTop, 0)
        r.frame.skyBottom = F4(m.skyBottom, 0)
        r.frame.skyGlow = F4(m.glow, m.stars)
        r.frame.fogColor = F4(m.fog, 0)
        // HemisphereLight(…, 1.55) and DirectionalLight(…, 2.15)
        r.frame.sunColor = F4(m.sun * 2.15, 0)
        r.frame.hemiSky = F4(m.hemiSky * 1.55, 0)
        r.frame.hemiGround = F4(m.hemiGround * 1.55, 0)
    }
}
