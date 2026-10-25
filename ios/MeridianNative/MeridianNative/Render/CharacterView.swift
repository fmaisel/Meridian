// The wanderer: a small robed figure carrying a lantern-light (port of src/render/Character.ts).
// Purely visual; movement is driven by the CharacterController.

import Foundation
import Metal
import simd

final class CharacterView {
    let root = Node("character")
    let body = Node()
    let shadow: Node
    private let robe: Node
    private let head: Node
    private let hood: Node
    private let orb: Node
    private let halo: Node
    private var phase = 0.0
    private var yaw = 0.0
    private var targetYaw = 0.0
    private var walkBlend = 0.0
    private var overlayMats: [Material] = []
    private let ghostMat: Material
    var glowBoost = 0.0

    init(renderer r: Renderer) {
        let robeMat = Material.lit("#fbf7ef")
        let sash = Material.lit("#e9735c")
        let skin = Material.lit("#fbf7ef")
        let robeProfile: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(0.17, 0), SIMD2(0.165, 0.04), SIMD2(0.13, 0.2), SIMD2(0.095, 0.36), SIMD2(0.07, 0.42), SIMD2(0, 0.43)]
        robe = Node(mesh: r.makeMesh(latheGeometry(robeProfile, 18)), material: robeMat)
        head = Node(mesh: r.makeMesh(sphereGeometry(0.085, 18, 12)), material: skin)
        head.position.y = 0.49
        // tall pointed hood leaning back
        hood = Node(mesh: r.makeMesh(cylinderGeometry(0, 0.088, 0.3, 14, 1, openEnded: true)), material: robeMat)
        hood.position = F3(0, 0.6, -0.04)
        hood.rotation.x = -0.32
        let belt = Node(mesh: r.makeMesh(cylinderGeometry(0.105, 0.112, 0.035, 18)), material: sash)
        belt.position.y = 0.3
        // lantern orb on a short staff
        let staff = Node(mesh: r.makeMesh(cylinderGeometry(0.009, 0.009, 0.42, 6)), material: .lit("#b9876a"))
        staff.position = F3(0.14, 0.27, 0.03)
        orb = Node(mesh: r.makeMesh(sphereGeometry(0.04, 12, 8)), material: .basic("#fff3c9"))
        orb.position = F3(0.14, 0.5, 0.03)
        let haloMat = Material(.sprite, color: color("#ffe7a8"))
        haloMat.map = r.textures.glyph("soft")
        haloMat.transparent = true
        haloMat.opacity = 0.85
        haloMat.depthWrite = false
        halo = Node(mesh: nil, material: haloMat)
        halo.isSprite = true
        halo.scale = F3(0.32, 0.32, 1)
        halo.position = orb.position

        for m in [robe, head, hood, belt, staff] {
            m.castShadow = true
            m.receiveShadow = false
        }
        body.add(robe, head, hood, belt, staff, orb, halo)
        body.setScalar(1.18)
        root.add(body)

        let shMat = Material.basic("#ffffff", map: r.textures.glyph("shadow"), transparent: true, opacity: 0.5, depthWrite: false)
        shadow = Node(mesh: r.makeMesh(planeGeometry(0.5, 0.5).rotatedX(-Double.pi / 2)), material: shMat)
        shadow.position.y = 0.012
        shadow.renderOrder = 3
        root.add(shadow)

        var mats: [Material] = []
        root.traverse { o in
            if let m = o.material, !mats.contains(where: { $0 === m }) { mats.append(m) }
        }
        overlayMats = mats

        // faint silhouette visible through architecture in front of the wanderer
        ghostMat = Material.basic("#fffaf2", transparent: true, opacity: 0.38, depthWrite: false)
        ghostMat.depthFunc = .greater
        for m in [robe, head, hood] {
            let gm = Node(mesh: m.mesh, material: ghostMat)
            gm.renderOrder = 9
            m.add(gm)
        }
    }

    func face(_ dx: Double, _ dz: Double) {
        if abs(dx) + abs(dz) < 1e-4 { return }
        targetYaw = atan2(dx, dz)
    }

    /// Render on top of geometry (used while crossing perspective seams).
    func setOverlay(_ on: Bool) {
        for m in overlayMats { m.depthTest = !on }
        ghostMat.visible = !on
        root.traverse { o in o.renderOrder = on ? 10 : (o === shadow ? 3 : 0) }
    }

    func update(_ dt: Double, walking: Bool, speed: Double, time: Double) {
        walkBlend += ((walking ? 1 : 0) - walkBlend) * (1 - exp(-10 * dt))
        var d = targetYaw - yaw
        while d > Double.pi { d -= Double.pi * 2 }
        while d < -Double.pi { d += Double.pi * 2 }
        yaw += d * (1 - exp(-14 * dt))

        phase += dt * speed * 7.2
        let w = walkBlend
        let bob = abs(sin(phase)) * 0.035 * w
        let breathe = sin(time * 1.8) * 0.006 * (1 - w)
        body.position.y = Float(bob + breathe)
        body.rotation = F3(Float(0.1 * w), Float(yaw), Float(sin(phase) * 0.06 * w))
        robe.scale = F3(Float(1 + sin(phase * 2) * 0.03 * w), Float(1 - bob * 0.6), Float(1 + cos(phase * 2) * 0.03 * w))
        head.position.y = Float(0.49 + sin(phase * 2) * 0.005 * w)
        orb.position.y = Float(0.5 + sin(time * 2.4) * 0.012 + bob * 0.4)
        halo.position = orb.position
        let hs = Float(0.32 + sin(time * 2.1) * 0.03 + glowBoost * 0.6)
        halo.scale = F3(hs, hs, 1)
        shadow.setScalar(Float(1 - bob * 2.5))
    }
}
