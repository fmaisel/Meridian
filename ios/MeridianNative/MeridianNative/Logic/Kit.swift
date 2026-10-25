// Level construction kit: authoring helpers that emit tiles, solids and visual descriptors together,
// so geometry, collision and navigation can never drift apart. Port of src/level/kit.ts.

import Foundation
import simd

enum DirName: String, CaseIterable {
    case px, nx, pz, nz

    var v: V3 {
        switch self {
        case .px: return DIR.px
        case .nx: return DIR.nx
        case .pz: return DIR.pz
        case .nz: return DIR.nz
        }
    }
}

enum DIR {
    static let px = V3(1, 0, 0)
    static let nx = V3(-1, 0, 0)
    static let pz = V3(0, 0, 1)
    static let nz = V3(0, 0, -1)
}

private let ALL: [DirName] = [.px, .nx, .pz, .nz]

private func sameDir(_ a: V3, _ b: V3) -> Bool {
    abs(a.x - b.x) < 1e-6 && abs(a.z - b.z) < 1e-6
}

/// `t${x}_${y}_${z}` with '-' → 'm' and '.' → 'p'.
private func tileIdString(_ prefix: String, _ a: Double, _ b: Double, _ c: Double) -> String {
    let s = prefix + jsNumberString(a) + "_" + jsNumberString(b) + "_" + jsNumberString(c)
    return s.replacingOccurrences(of: "-", with: "m").replacingOccurrences(of: ".", with: "p")
}

final class BodyBuilder {
    let def: BodyDef
    private var tileMap: [String: TileDef] = [:]

    init(_ id: String, palette: String, zone: String, mech: String? = nil, parent: String? = nil) {
        def = BodyDef(id: id, palette: palette, zone: zone, mech: mech, parent: parent)
    }

    private func key(_ x: Double, _ y: Double, _ z: Double) -> String {
        jsNumberString(x) + "," + jsNumberString(y) + "," + jsNumberString(z)
    }

    /// Walkable flat tile at cell (x,z) with surface height y.
    @discardableResult
    func tile(_ x: Double, _ y: Double, _ z: Double, dirs: [DirName]? = nil, tags: [String]? = nil) -> TileDef {
        let k = key(x, y, z)
        if let t = tileMap[k] {
            if let tags { t.tags.append(contentsOf: tags) }
            return t
        }
        let ds = dirs ?? ALL
        let t = TileDef(
            id: tileIdString("t", x, y, z),
            pos: V3(x, y, z),
            edges: ds.map { EdgeDef(dir: $0.v, h: y) },
            tags: tags ?? [])
        tileMap[k] = t
        def.tiles.append(t)
        return t
    }

    /// Walkable tile on a side face or the underside (body-local normal `up`). `dirs` are the open edges and lie
    /// in the face plane; the tile becomes part of the walkable world whenever the body turns that face to the sky.
    @discardableResult
    func faceTile(_ p: V3, up: V3, dirs: [V3], tags: [String] = []) -> TileDef {
        let k = "f:" + key(p.x, p.y, p.z)
        if let t = tileMap[k] { t.tags.append(contentsOf: tags); return t }
        let t = TileDef(id: tileIdString("f", p.x, p.y, p.z), pos: p, edges: dirs.map { EdgeDef(dir: $0, h: 0) }, tags: tags, up: up)
        tileMap[k] = t
        def.tiles.append(t)
        return t
    }

    func faceRef(_ p: V3) -> String {
        guard let t = tileMap["f:" + key(p.x, p.y, p.z)] else { fatalError("\(def.id): no face tile at \(p)") }
        return "\(def.id)/\(t.id)"
    }

    func getTile(_ x: Double, _ y: Double, _ z: Double) -> TileDef {
        guard let t = tileMap[key(x, y, z)] else { fatalError("\(def.id): no tile at \(x),\(y),\(z)") }
        return t
    }

    func ref(_ x: Double, _ y: Double, _ z: Double) -> String {
        "\(def.id)/\(getTile(x, y, z).id)"
    }

    @discardableResult
    func tag(_ x: Double, _ y: Double, _ z: Double, _ tag: String) -> Self {
        getTile(x, y, z).tags.append(tag)
        return self
    }

    @discardableResult
    func zoneOf(_ x: Double, _ y: Double, _ z: Double, _ zone: String) -> Self {
        def.tileZones[getTile(x, y, z).id] = zone
        return self
    }

    /// Mark an edge of a tile as a perspective seam.
    @discardableResult
    func seam(_ x: Double, _ y: Double, _ z: Double, _ d: DirName) -> Self {
        let t = getTile(x, y, z)
        guard let i = t.edges.firstIndex(where: { sameDir($0.dir, d.v) }) else {
            fatalError("\(def.id): tile \(x),\(y),\(z) has no \(d) edge")
        }
        t.edges[i].seam = true
        return self
    }

    /// Close an edge (wall, railing).
    @discardableResult
    func close(_ x: Double, _ y: Double, _ z: Double, _ ds: DirName...) -> Self {
        let t = getTile(x, y, z)
        t.edges = t.edges.filter { e in !ds.contains { sameDir(e.dir, $0.v) } }
        return self
    }

    /// Axis-aligned block covering cells x0..x1, z0..z1 from y0 to y1.
    @discardableResult
    func box(_ x0: Double, _ x1: Double, _ z0: Double, _ z1: Double, _ y0: Double, _ y1: Double,
             walk: Bool? = nil, mat: String? = nil, cap: Bool? = nil, solid: Bool? = nil, capMat: String? = nil) -> Self {
        let walk = walk ?? true
        let mn = V3(jsMin(x0, x1) - 0.5, y0, jsMin(z0, z1) - 0.5)
        let mx = V3(jsMax(x0, x1) + 0.5, y1, jsMax(z0, z1) + 0.5)
        if solid ?? true { def.solids.append(SolidDef(min: mn, max: mx)) }
        def.visuals.append(VisualDef(kind: .box(min: mn, max: mx, mat: mat ?? "stone", cap: cap ?? walk, capMat: capMat)))
        // a slim cornice just below the walking surface frames every platform
        if walk && y1 - y0 >= 0.5 && mat != "accent" {
            def.visuals.append(VisualDef(kind: .box(
                min: V3(mn.x - 0.045, y1 - 0.36, mn.z - 0.045), max: V3(mx.x + 0.045, y1 - 0.27, mx.z + 0.045),
                mat: "trim", cap: false, capMat: nil)))
        }
        if walk {
            var x = jsMin(x0, x1)
            while x <= jsMax(x0, x1) {
                var z = jsMin(z0, z1)
                while z <= jsMax(z0, z1) {
                    tile(x, y1, z)
                    z += 1
                }
                x += 1
            }
        }
        return self
    }

    /// Decorative / solid block in raw coordinates (no tiles).
    @discardableResult
    func block(_ min: V3, _ max: V3, _ mat: String = "stone", _ solid: Bool = true) -> Self {
        if solid { def.solids.append(SolidDef(min: min, max: max)) }
        def.visuals.append(VisualDef(kind: .box(min: min, max: max, mat: mat, cap: false, capMat: nil)))
        return self
    }

    /// One-cell staircase at (x,z) rising toward `d` from h0 to h0+rise. The stair connects a tile at h0
    /// on the low side with a tile at h0+rise on the high side.
    @discardableResult
    func stairs(_ x: Double, _ z: Double, _ d: DirName, _ h0: Double, _ rise: Double = 1,
                mat: String? = nil, base: Double? = nil, steps: Int? = nil) -> Self {
        let dir = d.v
        let back = V3(-dir.x, 0, -dir.z)
        let pos = V3(x, h0 + rise / 2, z)
        let edges = [EdgeDef(dir: back, h: h0), EdgeDef(dir: dir, h: h0 + rise)]
        let t = TileDef(id: tileIdString("s", x, h0, z), pos: pos, edges: edges, tags: ["stair"])
        def.tiles.append(t)
        let base = base ?? h0 - 0.5
        def.solids.append(SolidDef(min: V3(x - 0.5, base, z - 0.5), max: V3(x + 0.5, h0, z + 0.5)))
        def.visuals.append(VisualDef(kind: .stairs(
            x: x, z: z, dir: dir, h0: h0, rise: rise, base: base, mat: mat ?? "stone",
            steps: steps ?? Int(jsMax(3, jsRound(rise * 4))))))
        return self
    }

    /// A straight flight of stairs over several cells, rising `rise` per cell.
    @discardableResult
    func flight(_ x: Double, _ z: Double, _ d: DirName, _ h0: Double, _ cells: Int, _ rise: Double = 1,
                mat: String? = nil, base: Double? = nil) -> Self {
        let dir = d.v
        for i in 0..<cells {
            let fi = Double(i)
            stairs(x + dir.x * fi, z + dir.z * fi, d, h0 + fi * rise, rise, mat: mat, base: base)
        }
        return self
    }

    @discardableResult
    func visual(_ kind: VisualKind, mist: Double = 0) -> Self {
        def.visuals.append(VisualDef(kind: kind, mist: mist))
        return self
    }

    @discardableResult
    func pillar(_ x: Double, _ z: Double, _ y0: Double, _ y1: Double, _ r: Double = 0.12, _ mat: String = "stone") -> Self {
        visual(.pillar(x: x, z: z, y0: y0, y1: y1, r: r, mat: mat))
    }

    /// Arch wall: a slab spanning along `axis` with a round-topped opening.
    @discardableResult
    func arch(x: Double, z: Double, axis: ArchAxis, y0: Double, y1: Double, span: Double, thick: Double = 0.5,
              openW: Double, openH: Double, mat: String = "stone", count: Int = 1) -> Self {
        visual(.arch(x: x, z: z, axis: axis, y0: y0, y1: y1, span: span, thick: thick, openW: openW, openH: openH, mat: mat, count: count))
    }

    @discardableResult
    func dome(_ x: Double, _ y: Double, _ z: Double, _ r: Double = 0.45, _ mat: String = "roof", _ style: DomeStyle = .onion) -> Self {
        visual(.dome(x: x, y: y, z: z, r: r, mat: mat, style: style))
    }

    /// Small open pavilion on a tile: four columns and a dome.
    @discardableResult
    func pavilion(_ x: Double, _ y: Double, _ z: Double, h: Double? = nil, mat: String? = nil, roof: String? = nil, style: DomeStyle? = nil) -> Self {
        let h = h ?? 1.4
        let mat = mat ?? "stone"
        for (dx, dz) in [(-0.38, -0.38), (0.38, -0.38), (-0.38, 0.38), (0.38, 0.38)] {
            pillar(x + dx, z + dz, y, y + h, 0.06, mat)
        }
        visual(.box(min: V3(x - 0.5, y + h, z - 0.5), max: V3(x + 0.5, y + h + 0.18, z + 0.5), mat: mat, cap: false, capMat: nil))
        dome(x, y + h + 0.18, z, 0.42, roof ?? "roof", style ?? .onion)
        return self
    }

    @discardableResult
    func tree(_ x: Double, _ y: Double, _ z: Double, _ h: Double = 1.3, _ mat: String = "foliage") -> Self {
        visual(.tree(x: x, y: y, z: z, h: h, mat: mat))
    }

    @discardableResult
    func window(_ x: Double, _ y: Double, _ z: Double, _ face: DirName, _ w: Double = 0.18, _ h: Double = 0.5) -> Self {
        visual(.window(x: x, y: y, z: z, face: face.v, w: w, h: h))
    }

    /// Cloth banner hanging from an anchor point, facing `face`.
    @discardableResult
    func banner(_ x: Double, _ y: Double, _ z: Double, _ face: DirName, len: Double? = nil, w: Double? = nil, mat: String? = nil) -> Self {
        visual(.banner(x: x, y: y, z: z, face: face.v, len: len ?? 1.2, w: w ?? 0.34, mat: mat ?? "roofCoral"))
    }

    @discardableResult
    func gear(_ x: Double, _ y: Double, _ z: Double, axis: V3 = V3(0, 1, 0), r: Double = 0.5, mat: String = "trim") -> Self {
        visual(.gear(x: x, y: y, z: z, axis: axis, r: r, mat: mat))
    }

    @discardableResult
    func glyph(_ x: Double, _ y: Double, _ z: Double, _ kind: String) -> Self {
        visual(.glyph(x: x, y: y, z: z, kind: kind))
    }

    func build() -> BodyDef { def }
}
