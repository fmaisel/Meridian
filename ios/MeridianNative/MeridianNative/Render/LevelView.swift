// ArchitectureSystem (visual side): turns body definitions into merged meshes, one group per body,
// and poses the groups from continuous mechanism parameters every frame (port of LevelView.ts).

import Foundation
import Metal
import simd

final class HandleView {
    let mech: String
    let body: String
    let group: Node
    let materials: [Material]
    let pick: [Node]
    /// Handle anchor in body-local coordinates.
    let local: V3
    let axis: V3
    let kind: String
    /// Radius of the grip in world units (crank arm length; knob disc).
    let reach: Double

    init(mech: String, body: String, group: Node, materials: [Material], pick: [Node], local: V3, axis: V3, kind: String, reach: Double) {
        self.reach = reach
        self.mech = mech
        self.body = body
        self.group = group
        self.materials = materials
        self.pick = pick
        self.local = local
        self.axis = axis
        self.kind = kind
    }
}

struct GlyphView {
    let node: Node
    let mat: Material
    let kind: String
}

let GLYPH_COLORS: [String: String] = ["plate": "#2fa89a", "eye": "#2fa89a", "step": "#2fa89a", "start": "#ffffff", "goal": "#f2b44f", "pressed": "#f4c46a"]

func glyphKey(_ body: String, _ p: V3) -> String { "\(body)@\(p.x),\(p.y),\(p.z)" }

final class LevelView {
    let root = Node("level")
    private(set) var groups: [String: Node] = [:]
    private(set) var groupOrder: [String] = []
    private(set) var handles: [HandleView] = []
    private(set) var glyphs: [String: GlyphView] = [:]
    /// Meshes that can be tapped to walk (raycast targets).
    private(set) var pickables: [Node] = []
    /// The summit lamp, lit in the finale.
    private(set) var lamp: Node?

    private let logic: LevelLogic
    private let mats: MaterialLibrary
    private let r: Renderer
    private var bodyMats: [String: [Material]] = [:]
    private var bodyMatOrder: [String] = []
    private var fades: [String: Float] = [:]
    private var staggered: [String: [Node]] = [:]
    private var staggeredOrder: [String] = []

    init(logic: LevelLogic, mats: MaterialLibrary, renderer: Renderer) {
        self.logic = logic
        self.mats = mats
        self.r = renderer
        for b in logic.order { buildBody(b) }
    }

    /// All window materials (they glow warmly at the end).
    func windowMaterials() -> [Material] {
        var out: [Material] = []
        for id in bodyMatOrder { for m in bodyMats[id]! where m.isWindow { out.append(m) } }
        return out
    }

    private typealias Buckets = (keys: [String], map: [String: (mat: Material, geos: [MeshData])])

    private func buildBody(_ b: BodyDef) {
        let group = Node(b.id)
        group.matrixAutoUpdate = false
        group.body = b.id
        var buckets: Buckets = ([], [:])
        func add(_ into: inout Buckets, _ key: String, _ mat: Material, _ g: MeshData) {
            if into.map[key] == nil {
                into.keys.append(key)
                into.map[key] = (mat, [])
            }
            into.map[key]!.geos.append(g)
        }
        let M: (String) -> Material = { key in self.track(b.id, self.mats.forBody(b.id, b.palette, key)) }

        // stairs that rise from the clouds come up step by step
        let md = b.mech.flatMap { logic.mechs[$0] }
        let stairCount = b.visuals.filter { if case .stairs = $0.kind { return true } else { return false } }.count
        let stagger = (md?.isLift ?? false) && stairCount >= 2
        for v in b.visuals {
            let isStairs: Bool = { if case .stairs = v.kind { return true } else { return false } }()
            if stagger && isStairs {
                var sub: Buckets = ([], [:])
                visual(b, v, { key, mat, g in add(&sub, key, mat, g) }, M, group)
                let child = Node()
                child.matrixAutoUpdate = false
                for key in sub.keys {
                    let e = sub.map[key]!
                    let mesh = Node(mesh: r.makeMesh(merge(e.geos), pickable: true), material: e.mat)
                    mesh.castShadow = true
                    mesh.receiveShadow = true
                    mesh.body = b.id
                    child.add(mesh)
                    pickables.append(mesh)
                }
                group.add(child)
                if staggered[b.id] == nil { staggered[b.id] = []; staggeredOrder.append(b.id) }
                staggered[b.id]!.append(child)
            } else {
                let mist = v.mist
                visual(b, v, { key, mat, g in add(&buckets, key, mat, mist > 0 ? g.liftedMist(mist) : g) }, M, group)
            }
        }

        for key in buckets.keys {
            let e = buckets.map[key]!
            let mesh = Node(mesh: r.makeMesh(merge(e.geos), pickable: true), material: e.mat)
            mesh.castShadow = true
            mesh.receiveShadow = true
            mesh.body = b.id
            group.add(mesh)
            pickables.append(mesh)
        }
        root.add(group)
        groups[b.id] = group
        groupOrder.append(b.id)
    }

    private func visual(_ b: BodyDef, _ v: VisualDef, _ add: (String, Material, MeshData) -> Void, _ M: (String) -> Material, _ group: Node) {
        switch v.kind {
        case let .box(mn, mx, mat, cap, capMat):
            add(mat, M(mat), boxGeo(mn, mx))
            if cap { add("cap", track(b.id, mats.forBody(b.id, b.palette, capMat ?? "cap", cap: true)), capGeo(mn, mx)) }
        case let .stairs(x, z, dir, h0, rise, base, mat, steps):
            add("stairs", M("cap"), stairsGeo(x, z, dir, h0, rise, h0 - 0.12, steps))
            if base < h0 - 0.12 { add(mat, M(mat), boxGeo(V3(x - 0.5, base, z - 0.5), V3(x + 0.5, h0 - 0.12, z + 0.5))) }
        case let .pillar(x, z, y0, y1, rr, mat):
            add(mat, M(mat), pillarGeo(x, z, y0, y1, rr))
        case let .column(x, z, y0, y1, rr, mat):
            add(mat, M(mat), columnGeo(x, z, y0, y1, rr))
        case let .arch(x, z, axis, y0, y1, span, thick, openW, openH, mat, count):
            add(mat, M(mat), archGeo(x: x, z: z, axis: axis, y0: y0, y1: y1, span: span, thick: thick, openW: openW, openH: openH, count: count))
        case let .dome(x, y, z, rr, mat, style):
            add(mat, M(mat), domeGeo(x, y, z, rr, style))
        case let .tree(x, y, z, h, mat):
            add(mat, M(mat), treeGeo(x, y, z, h))
            add("trunk", M("window"), trunkGeo(x, y, z, h))
        case let .window(x, y, z, face, w, h):
            let wm = M("window")
            wm.isWindow = true
            if wm.baseColor == nil { wm.baseColor = wm.color }
            add("window", wm, windowGeo(x, y, z, face, w, h))
        case let .banner(x, y, z, face, len, w, mat):
            let g = planeGeometry(w, len, 3, 12).translated(0, -len / 2, 0)
            let bm = Material(.banner, color: color(paletteColor(b.palette, mat)))
            bm.extra = F4(color("#fbf1e2"), 0)
            bm.extra2 = F4(color("#f2c46b"), 0)
            bm.phase = Float(x * 1.7 + z)
            bm.side = .double
            let mesh = Node(mesh: r.makeMesh(g), material: bm)
            mesh.position = F3(Float(x + face.x * 0.03), Float(y), Float(z + face.z * 0.03))
            mesh.rotation.y = Float(atan2(face.x, face.z))
            mesh.castShadow = true
            group.add(mesh)
            // the rod it hangs from
            let rodLen = w + 0.12
            let rod = boxGeo(V3(-rodLen / 2, y - 0.03, -0.025), V3(rodLen / 2, y + 0.03, 0.025))
            let rm = Node(mesh: r.makeMesh(rod), material: M("trim"))
            let holder = Node()
            holder.position = F3(Float(x + face.x * 0.05), 0, Float(z + face.z * 0.05))
            holder.rotation.y = Float(atan2(face.x, face.z))
            holder.add(rm)
            group.add(holder)
        case let .lily(x, y, z, rr, flower):
            let pad = cylinderGeometry(rr, rr, 0.02, 14, 1, openEnded: false, thetaStart: 0.3, thetaLength: Double.pi * 2 - 0.6).translated(x, y, z)
            add("lily", track(b.id, mats.forBody(b.id, "lily", "lily")), pad.withMist())
            if flower {
                let fl = cylinderGeometry(0, 0.07, 0.09, 6).translated(x + 0.03, y + 0.05, z - 0.02)
                add("flower", track(b.id, mats.forBody(b.id, "lily", "flower")), fl.withMist())
            }
        case let .shrine(x, y, z):
            for (dx, dz) in [(-0.42, -0.42), (0.42, -0.42), (-0.42, 0.42), (0.42, 0.42)] {
                add("trim", M("trim"), pillarGeo(x + dx, z + dz, y, y + 1.9, 0.065))
            }
            add("trim", M("trim"), boxGeo(V3(x - 0.55, y + 1.9, z - 0.55), V3(x + 0.55, y + 2.12, z + 0.55)))
            add("shrineRoof", M("shrineRoof"), domeGeo(x, y + 2.12, z, 0.5, .onion))
            add("trim", M("trim"), pillarGeo(x, z, y + 1.42, y + 1.9, 0.012))
            let lampNode = Node(mesh: r.makeMesh(sphereGeometry(0.12, 16, 10)), material: .basic("#d8c7a6"))
            lampNode.position = F3(Float(x), Float(y + 1.32), Float(z))
            group.add(lampNode)
            lamp = lampNode
        case let .water(mn, mx):
            let wm = Material(.water)
            wm.extra = F4(color("#3faea4"), 0)
            wm.extra2 = F4(color("#86dccd"), 0)
            group.add(Node(mesh: r.makeMesh(planeXZ(mn, mx)), material: wm))
        case let .fall(x, z, y0, y1, w, face):
            let g = planeGeometry(w, y1 - y0, 1, 8).rotatedY(atan2(face.x, face.z)).translated(x, (y0 + y1) / 2, z)
            let fm = Material(.fall)
            fm.extra = F4(color("#e9fbf6"), 0)
            fm.extra2 = F4(color("#7fd3c6"), 0)
            fm.transparent = true
            fm.depthWrite = false
            fm.side = .double
            group.add(Node(mesh: r.makeMesh(g), material: fm))
        case let .glyph(x, y, z, kind):
            let mat = Material.basic(GLYPH_COLORS[kind] ?? "#ffffff", map: r.textures.glyph(kind), transparent: true,
                                     opacity: kind == "start" ? 0.55 : 0.9, depthWrite: false)
            mat.polygonOffset = true
            mat.baseOpacity = mat.opacity
            _ = track(b.id, mat)
            let g = planeGeometry(0.86, 0.86).rotatedX(-Double.pi / 2)
            let mesh = Node(mesh: r.makeMesh(g), material: mat)
            mesh.position = F3(Float(x), Float(y + 0.006), Float(z))
            mesh.renderOrder = 2
            group.add(mesh)
            glyphs[glyphKey(b.id, V3(x, y, z))] = GlyphView(node: mesh, mat: mat, kind: kind)
        case let .faceCap(mn, mx, up):
            add("cap", track(b.id, mats.forBody(b.id, b.palette, "cap", cap: true)), faceCapGeo(mn, mx, up))
        case let .gear(x, y, z, axis, rr, mat):
            add(mat, M(mat), gearGeo(x, y, z, axis, rr))
        case let .crank(x, y, z, axis, rr, mech):
            buildHandle(b, group, kind: "crank", x: x, y: y, z: z, axis: axis, parts: crankParts(rr), mech: mech, reach: rr)
        case let .knob(x, y, z, mech):
            buildHandle(b, group, kind: "knob", x: x, y: y, z: z, axis: V3(0, 1, 0), parts: knobParts(), mech: mech, reach: 0.25)
        }
    }

    private func buildHandle(_ b: BodyDef, _ group: Node, kind: String, x: Double, y: Double, z: Double, axis: V3,
                             parts: (body: MeshData, pins: MeshData), mech: String, reach: Double) {
        let hg = Node()
        let mBody = mats.unique(b.palette, "handle")
        let mPin = mats.unique(b.palette, "handlePin")
        let bodyMesh = r.makeMesh(parts.body, pickable: true)
        let pinMesh = r.makeMesh(parts.pins, pickable: true)
        let m1 = Node(mesh: bodyMesh, material: mBody)
        let m2 = Node(mesh: pinMesh, material: mPin)
        for m in [m1, m2] { m.castShadow = true; m.handle = mech }
        // faint silhouette that stays visible through any architecture in front of the handle
        let ghostBody = Material.basic("#fff8ee", transparent: true, opacity: 0.42, depthWrite: false)
        ghostBody.depthFunc = .greater
        let ghostPin = Material.basic("#f08a72", transparent: true, opacity: 0.55, depthWrite: false)
        ghostPin.depthFunc = .greater
        for (m, gm) in [(m1, ghostBody), (m2, ghostPin)] {
            let g = Node(mesh: m.mesh, material: gm)
            g.renderOrder = 9
            m.add(g)
        }
        let ax = simd_normalize(axis)
        var pick = [m1, m2]
        var spin = hg
        if kind == "crank" {
            // setFromUnitVectors(+Y, axis), then rotateY(π/4) so the arms never hide under a bridge; a lying
            // wheel (drawbridge hinge, tumbling axle) gets its own aligned frame so it still spins about its axle
            if ax.y > 0.99 {
                hg.add(m1, m2)
                hg.rotation = F3(0, Float.pi / 4, 0)
            } else {
                let align = Node()
                align.matrixAutoUpdate = false
                align.matrix = M4(alignY(to: ax))
                spin = Node()
                spin.rotation = F3(0, Float.pi / 4, 0)
                spin.add(m1, m2)
                align.add(spin)
                hg.add(align)
            }
        } else {
            hg.add(m1, m2)
            // pendant knob: rod hanging below the platform with a disc
            let rod = Node(mesh: r.makeMesh(pillarGeo(0, 0, -0.75, 0, 0.04), pickable: true), material: mBody)
            rod.handle = mech
            hg.add(rod)
            m1.position.y = -0.8
            m2.position.y = -0.8
            m1.rotation.z = Float.pi / 2
            m2.rotation.z = Float.pi / 2
            pick.append(rod)
        }
        hg.position = F3(Float(x), Float(y), Float(z))
        group.add(hg)
        handles.append(HandleView(mech: mech, body: b.id, group: spin, materials: [mBody, mPin], pick: pick,
                                  local: V3(x, y + (kind == "knob" ? -0.8 : 0), z), axis: ax, kind: kind, reach: reach))
    }

    private func track(_ body: String, _ m: Material) -> Material {
        if bodyMats[body] == nil { bodyMats[body] = []; bodyMatOrder.append(body) }
        if !bodyMats[body]!.contains(where: { $0 === m }) { bodyMats[body]!.append(m) }
        return m
    }

    /// Cutaway amount for a body (0 = solid, 1 = window fully open around the current foci).
    func setFade(_ body: String, _ cut: Float) {
        let prev = fades[body] ?? 0
        if abs(prev - cut) < 1e-4 { return }
        fades[body] = cut
        let open = cut > 0.001
        for m in bodyMats[body] ?? [] {
            if m.kind == .lit {
                m.cut = cut
                m.transparent = open
            } else {
                m.opacity = m.baseOpacity ?? 1
            }
        }
    }

    func fadeOf(_ body: String) -> Float { fades[body] ?? 0 }

    /// Body matrices (Double precision) of the last pose — used for node positions and handles.
    private(set) var matrices: [String: simd_double4x4] = [:]

    /// Apply continuous mechanism parameters.
    func pose(_ params: [String: Double]) {
        let mats = logic.bodyMatrices(params)
        matrices = mats
        for id in groupOrder { groups[id]!.matrix = mats[id]!.f }
        for id in staggeredOrder {
            let children = staggered[id]!
            let b = logic.bodies[id]!
            let md = logic.mechs[b.mech!]!
            let p = params[md.id]!
            let lo = Double(md.states.min()!), hi = Double(md.states.max()!)
            let t = (p - lo) / max(1e-6, hi - lo)
            let body = translationOf(logic.mechMatrix(md, p))
            let n = Double(children.count)
            let gap = 0.45
            for (i, c) in children.enumerated() {
                let ti = min(1, max(0, t * (1 + gap * (n - 1)) - gap * Double(i)))
                let pi = lo + (hi - lo) * (ti * ti * (3 - 2 * ti))
                let own = translationOf(logic.mechMatrix(md, pi))
                c.matrix = M4.translation((own - body).f)
            }
        }
    }

    func setPressed(_ bodyId: String, _ pos: V3, _ pressed: Bool) {
        guard let gv = glyphs[glyphKey(bodyId, pos)] else { return }
        gv.mat.color = color(pressed ? GLYPH_COLORS["pressed"]! : GLYPH_COLORS[gv.kind] ?? "#ffffff")
    }

    func glyphAt(_ bodyId: String, _ pos: V3) -> GlyphView? { glyphs[glyphKey(bodyId, pos)] }
}

func translationOf(_ m: simd_double4x4) -> V3 { V3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
