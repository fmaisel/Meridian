// The closing sequence: the light is set in the summit lamp, a beam rises, slender spires grow out
// of the mist around the monument, and the camera withdraws to a composed view of the whole
// (port of src/game/Finale.ts).

import Foundation
import simd

private let SPIRES: [(x: Double, z: Double, top: Double, w: Double, pal: String, roof: String)] = [
    (11, -7, 9, 1.1, "ivory", "roof"),
    (-9, 11, 6, 1.3, "sand", "roof"),
    (13, 4, 3, 1.6, "coral", "roofCoral"),
    (-17, -3, 12, 1.0, "dusk", "roofViolet"),
    (6, -14, 15, 0.9, "dusk", "roofViolet"),
    (-4, 15, 1, 1.8, "ivory", "roof"),
    (17, -1, 7, 0.8, "sand", "roof"),
]

func runFinale(_ game: Game, done: @escaping () -> Void) {
    let anim = game.anim, audio = game.audio, env = game.env, rig = game.rig, effects = game.effects
    let charView = game.charView, view = game.view, mats = game.mats, scene = game.scene, r = game.renderer
    audio.finale()
    game.haptics.plate()
    env.setMood("radiant")
    let goal = game.nodeWorld(game.logic.def.goal)

    // the lamp catches the light
    let lamp = view.lamp
    let lampPos = lamp.map { $0.computeWorld().translationPart.d } ?? goal + V3(0, 1.3, 0)
    let glowMat = Material(.sprite, color: color("#ffe3a0"))
    glowMat.map = r.textures.glyph("soft")
    glowMat.transparent = true
    glowMat.depthWrite = false
    glowMat.blending = .additive
    glowMat.opacity = 0
    let glow = Node(mesh: nil, material: glowMat)
    glow.isSprite = true
    glow.position = lampPos.f
    glow.renderOrder = 8
    scene.add(glow)
    game.finaleObjects.append(glow)
    effects.shimmer(goal + V3(0, 0.5, 0), color: "#fff1c4", scale: 3)
    let lampFrom = color("#d8c7a6"), lampTo = color("#fff6d8")
    anim.add(duration: 2.4, ease: ease.inOutSine, onUpdate: { k, _ in
        charView.glowBoost = k * 1.2
        env.setBrighten(k * 0.6)
        lamp?.material?.color = mix(lampFrom, lampTo, Float(k))
        glowMat.opacity = Float(k)
        glow.setScalar(Float(0.5 + k * 2.6))
    }, onDone: {
        // a beam of light rises into the sky
        let beamMat = Material(.beam, color: color("#fff1c8"))
        beamMat.transparent = true
        beamMat.depthWrite = false
        beamMat.blending = .additive
        let beam = Node(mesh: r.makeMesh(cylinderGeometry(0.16, 0.06, 40, 16, 1, openEnded: true)), material: beamMat)
        beam.position = (lampPos + V3(0, 20, 0)).f
        beam.renderOrder = 8
        scene.add(beam)
        game.finaleObjects.append(beam)
        anim.add(duration: 3, ease: ease.outCubic, onUpdate: { k, _ in beamMat.k = Float(k) })

        // every window in the monument and the city below catches the light
        let windows = view.windowMaterials()
        let base = windows.map { $0.color }
        let warm = color("#ffd98a")
        anim.add(duration: 4, delay: 0.5, ease: ease.inOutSine, onUpdate: { k, _ in
            for (i, m) in windows.enumerated() {
                m.color = mix(base[i], warm, Float(k))
                m.glow = Float(k * 0.55)
                m.glowColor = color("#ffe7a8")
            }
        })

        // spires grow from the mist
        let spires = Node("spires")
        scene.add(spires)
        game.finaleObjects.append(spires)
        for (i, s) in SPIRES.enumerated() {
            let h = s.w / 2
            let m = Node(mesh: r.makeMesh(merge([boxGeo(V3(s.x - h, -40, s.z - h), V3(s.x + h, s.top, s.z + h), fade: 6),
                                                boxGeo(V3(s.x - h - 0.12, s.top - 0.4, s.z - h - 0.12), V3(s.x + h + 0.12, s.top - 0.15, s.z + h + 0.12))])),
                         material: mats.get(s.pal, "stone"))
            let dome = Node(mesh: r.makeMesh(domeGeo(s.x, s.top, s.z, h * 0.9, .onion)), material: mats.get(s.pal, s.roof))
            let g = Node()
            g.add(m, dome)
            g.position.y = -26
            spires.add(g)
            anim.add(duration: 5.5, delay: 0.4 + Double(i) * 0.45, ease: ease.inOutCubic, onUpdate: { k, _ in g.position.y = Float(-26 * (1 - k)) })
        }
        audio.rumble(4)

        // withdraw to the whole monument from the front
        rig.followRate = 0.55
        rig.zoomRate = 0.4
        rig.setQuadrant(0, animate: true, duration: 5)
        let fit = game.overviewFit(yaw: CameraRig.yawFor(0))
        rig.frame(fit.target, fit.size)
        anim.wait(7.5) {
            rig.followRate = 2.2
            rig.zoomRate = 1.6
            done()
        }
    })
}

/// The quieter close of a small chapter: the shrine's lamp takes the light, a short beam rises, the windows
/// warm and the camera steps back to see the whole diorama before the chapter card returns.
func runChapterFinale(_ game: Game, done: @escaping () -> Void) {
    let anim = game.anim, env = game.env, rig = game.rig, effects = game.effects
    let charView = game.charView, view = game.view, scene = game.scene, r = game.renderer
    game.audio.finale()
    game.haptics.plate()
    let goal = game.nodeWorld(game.logic.def.goal)
    let lamp = view.lamp
    let lampPos = lamp.map { $0.computeWorld().translationPart.d } ?? goal + V3(0, 1.3, 0)
    let glowMat = Material(.sprite, color: color("#ffe3a0"))
    glowMat.map = r.textures.glyph("soft")
    glowMat.transparent = true
    glowMat.depthWrite = false
    glowMat.blending = .additive
    glowMat.opacity = 0
    let glow = Node(mesh: nil, material: glowMat)
    glow.isSprite = true
    glow.position = lampPos.f
    glow.renderOrder = 8
    scene.add(glow)
    game.finaleObjects.append(glow)
    effects.shimmer(goal + V3(0, 0.5, 0), color: "#fff1c4", scale: 2.6)
    let lampFrom = color("#d8c7a6"), lampTo = color("#fff6d8")
    anim.add(duration: 1.8, ease: ease.inOutSine, onUpdate: { k, _ in
        charView.glowBoost = k
        env.setBrighten(k * 0.35)
        lamp?.material?.color = mix(lampFrom, lampTo, Float(k))
        glowMat.opacity = Float(k)
        glow.setScalar(Float(0.5 + k * 1.9))
    }, onDone: {
        let beamMat = Material(.beam, color: color("#fff1c8"))
        beamMat.transparent = true
        beamMat.depthWrite = false
        beamMat.blending = .additive
        let beam = Node(mesh: r.makeMesh(cylinderGeometry(0.12, 0.05, 30, 16, 1, openEnded: true)), material: beamMat)
        beam.position = (lampPos + V3(0, 15, 0)).f
        beam.renderOrder = 8
        scene.add(beam)
        game.finaleObjects.append(beam)
        anim.add(duration: 2.4, ease: ease.outCubic, onUpdate: { k, _ in beamMat.k = Float(k) })
        let windows = view.windowMaterials()
        let base = windows.map { $0.color }
        let warm = color("#ffd98a")
        anim.add(duration: 2.6, ease: ease.inOutSine, onUpdate: { k, _ in
            for (i, m) in windows.enumerated() {
                m.color = mix(base[i], warm, Float(k))
                m.glow = Float(k * 0.5)
                m.glowColor = color("#ffe7a8")
            }
        })
        let fit = game.overviewFit(yaw: rig.yaw)
        rig.followRate = 0.7
        rig.zoomRate = 0.6
        rig.frame(fit.target + game.sideShift(fit.size), fit.size)
        anim.wait(3.6) {
            rig.followRate = 2.2
            rig.zoomRate = 1.6
            done()
        }
    })
}
