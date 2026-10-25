// Procedural geometry for the architectural kit — port of src/render/geometry.ts together with the
// three.js primitive generators it uses (Box, Cylinder, Sphere, Lathe, Plane, Extrude), reproduced
// vertex for vertex so shading matches. Every geometry carries a mist attribute
// (0 = clear, 1 = dissolved into the sky).

import Foundation
import simd

/// Non-indexed triangle list (like three's `toNonIndexed()`), built in Double and uploaded as Float.
struct MeshData {
    var positions: [V3] = []
    var normals: [V3] = []
    var uvs: [SIMD2<Double>] = []
    var mist: [Double] = []

    var count: Int { positions.count }

    mutating func append(_ o: MeshData) {
        positions += o.positions
        normals += o.normals
        uvs += o.uvs
        mist += o.mist
    }

    /// Build from an indexed three.js-style generator output.
    init(indices: [Int], positions p: [V3], normals n: [V3], uvs u: [SIMD2<Double>]) {
        positions.reserveCapacity(indices.count)
        for i in indices {
            positions.append(p[i])
            normals.append(n[i])
            uvs.append(u[i])
        }
        mist = Array(repeating: 0, count: indices.count)
    }

    init() {}

    func translated(_ x: Double, _ y: Double, _ z: Double) -> MeshData {
        var o = self
        let t = V3(x, y, z)
        for i in o.positions.indices { o.positions[i] += t }
        return o
    }

    /// Apply a rotation (or any linear map without translation) to positions and normals.
    func transformed(_ m: simd_double3x3) -> MeshData {
        var o = self
        let nm = m.inverse.transpose
        for i in o.positions.indices {
            o.positions[i] = m * o.positions[i]
            o.normals[i] = simd_normalize(nm * o.normals[i])
        }
        return o
    }

    func rotatedX(_ a: Double) -> MeshData { transformed(rot3X(a)) }
    func rotatedY(_ a: Double) -> MeshData { transformed(rot3Y(a)) }
    func rotatedZ(_ a: Double) -> MeshData { transformed(rot3Z(a)) }

    /// `setMist`: per-vertex mist from the vertex height.
    func withMist(_ f: (Double) -> Double = { _ in 0 }) -> MeshData {
        var o = self
        for i in o.positions.indices { o.mist[i] = f(o.positions[i].y) }
        return o
    }

    /// `liftMist`: never clearer than `m`.
    func liftedMist(_ m: Double) -> MeshData {
        var o = self
        for i in o.mist.indices { o.mist[i] = max(o.mist[i], m) }
        return o
    }

    var bounds: (min: V3, max: V3) {
        var lo = V3(repeating: .infinity), hi = V3(repeating: -.infinity)
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }
}

func rot3X(_ a: Double) -> simd_double3x3 {
    let c = cos(a), s = sin(a)
    return simd_double3x3(columns: (V3(1, 0, 0), V3(0, c, s), V3(0, -s, c)))
}

func rot3Y(_ a: Double) -> simd_double3x3 {
    let c = cos(a), s = sin(a)
    return simd_double3x3(columns: (V3(c, 0, -s), V3(0, 1, 0), V3(s, 0, c)))
}

func rot3Z(_ a: Double) -> simd_double3x3 {
    let c = cos(a), s = sin(a)
    return simd_double3x3(columns: (V3(c, s, 0), V3(-s, c, 0), V3(0, 0, 1)))
}

func merge(_ list: [MeshData]) -> MeshData {
    var out = MeshData()
    for g in list { out.append(g) }
    return out
}

// ───────────────────────── three.js primitives ─────────────────────────

func boxGeometry(_ width: Double, _ height: Double, _ depth: Double) -> MeshData {
    var idx: [Int] = [], pos: [V3] = [], nrm: [V3] = [], uv: [SIMD2<Double>] = []
    var nv = 0
    // u, v, w are axis indices
    func plane(_ u: Int, _ v: Int, _ w: Int, _ udir: Double, _ vdir: Double, _ width: Double, _ height: Double, _ depth: Double) {
        let wh = width / 2, hh = height / 2, dh = depth / 2
        var count = 0
        for iy in 0...1 {
            let y = Double(iy) * height - hh
            for ix in 0...1 {
                let x = Double(ix) * width - wh
                var p = V3.zero
                p[u] = x * udir
                p[v] = y * vdir
                p[w] = dh
                pos.append(p)
                var n = V3.zero
                n[w] = depth > 0 ? 1 : -1
                nrm.append(n)
                uv.append(SIMD2(Double(ix), 1 - Double(iy)))
                count += 1
            }
        }
        let a = nv + 0, b = nv + 2, c = nv + 3, d = nv + 1
        idx += [a, b, d, b, c, d]
        nv += count
    }
    plane(2, 1, 0, -1, -1, depth, height, width)   // px
    plane(2, 1, 0, 1, -1, depth, height, -width)   // nx
    plane(0, 2, 1, 1, 1, width, depth, height)     // py
    plane(0, 2, 1, 1, -1, width, depth, -height)   // ny
    plane(0, 1, 2, 1, -1, width, height, depth)    // pz
    plane(0, 1, 2, -1, -1, width, height, -depth)  // nz
    return MeshData(indices: idx, positions: pos, normals: nrm, uvs: uv)
}

func cylinderGeometry(_ radiusTop: Double, _ radiusBottom: Double, _ height: Double, _ radialSegments: Int, _ heightSegments: Int = 1,
                      openEnded: Bool = false, thetaStart: Double = 0, thetaLength: Double = .pi * 2) -> MeshData {
    var idx: [Int] = [], pos: [V3] = [], nrm: [V3] = [], uv: [SIMD2<Double>] = []
    var index = 0
    var indexArray: [[Int]] = []
    let halfHeight = height / 2
    let slope = (radiusBottom - radiusTop) / height
    for y in 0...heightSegments {
        var row: [Int] = []
        let v = Double(y) / Double(heightSegments)
        let radius = v * (radiusBottom - radiusTop) + radiusTop
        for x in 0...radialSegments {
            let u = Double(x) / Double(radialSegments)
            let theta = u * thetaLength + thetaStart
            let s = sin(theta), c = cos(theta)
            pos.append(V3(radius * s, -v * height + halfHeight, radius * c))
            nrm.append(simd_normalize(V3(s, slope, c)))
            uv.append(SIMD2(u, 1 - v))
            row.append(index)
            index += 1
        }
        indexArray.append(row)
    }
    for x in 0..<radialSegments {
        for y in 0..<heightSegments {
            let a = indexArray[y][x], b = indexArray[y + 1][x], c = indexArray[y + 1][x + 1], d = indexArray[y][x + 1]
            if radiusTop > 0 || y != 0 { idx += [a, b, d] }
            if radiusBottom > 0 || y != heightSegments - 1 { idx += [b, c, d] }
        }
    }
    func cap(_ top: Bool) {
        let centerStart = index
        let radius = top ? radiusTop : radiusBottom
        let sign: Double = top ? 1 : -1
        for _ in 1...radialSegments {
            pos.append(V3(0, halfHeight * sign, 0))
            nrm.append(V3(0, sign, 0))
            uv.append(SIMD2(0.5, 0.5))
            index += 1
        }
        let centerEnd = index
        for x in 0...radialSegments {
            let u = Double(x) / Double(radialSegments)
            let theta = u * thetaLength + thetaStart
            let c = cos(theta), s = sin(theta)
            pos.append(V3(radius * s, halfHeight * sign, radius * c))
            nrm.append(V3(0, sign, 0))
            uv.append(SIMD2(c * 0.5 + 0.5, s * 0.5 * sign + 0.5))
            index += 1
        }
        for x in 0..<radialSegments {
            let c = centerStart + x, i = centerEnd + x
            if top { idx += [i, i + 1, c] } else { idx += [i + 1, i, c] }
        }
    }
    if !openEnded {
        if radiusTop > 0 { cap(true) }
        if radiusBottom > 0 { cap(false) }
    }
    return MeshData(indices: idx, positions: pos, normals: nrm, uvs: uv)
}

func sphereGeometry(_ radius: Double, _ widthSegments: Int, _ heightSegments: Int,
                    phiStart: Double = 0, phiLength: Double = .pi * 2, thetaStart: Double = 0, thetaLength: Double = .pi) -> MeshData {
    let ws = max(3, widthSegments), hs = max(2, heightSegments)
    let thetaEnd = min(thetaStart + thetaLength, .pi)
    var idx: [Int] = [], pos: [V3] = [], nrm: [V3] = [], uv: [SIMD2<Double>] = []
    var grid: [[Int]] = []
    var index = 0
    for iy in 0...hs {
        var row: [Int] = []
        let v = Double(iy) / Double(hs)
        var uOffset = 0.0
        if iy == 0 && thetaStart == 0 { uOffset = 0.5 / Double(ws) } else if iy == hs && thetaEnd == .pi { uOffset = -0.5 / Double(ws) }
        for ix in 0...ws {
            let u = Double(ix) / Double(ws)
            let p = V3(-radius * cos(phiStart + u * phiLength) * sin(thetaStart + v * thetaLength),
                       radius * cos(thetaStart + v * thetaLength),
                       radius * sin(phiStart + u * phiLength) * sin(thetaStart + v * thetaLength))
            pos.append(p)
            let l = simd_length(p)
            nrm.append(l > 0 ? p / l : V3.zero)
            uv.append(SIMD2(u + uOffset, 1 - v))
            row.append(index)
            index += 1
        }
        grid.append(row)
    }
    for iy in 0..<hs {
        for ix in 0..<ws {
            let a = grid[iy][ix + 1], b = grid[iy][ix], c = grid[iy + 1][ix], d = grid[iy + 1][ix + 1]
            if iy != 0 || thetaStart > 0 { idx += [a, b, d] }
            if iy != hs - 1 || thetaEnd < .pi { idx += [b, c, d] }
        }
    }
    return MeshData(indices: idx, positions: pos, normals: nrm, uvs: uv)
}

func latheGeometry(_ points: [SIMD2<Double>], _ segments: Int, phiStart: Double = 0, phiLength: Double = .pi * 2) -> MeshData {
    var idx: [Int] = [], pos: [V3] = [], nrm: [V3] = [], uv: [SIMD2<Double>] = []
    var initNormals: [V3] = []
    var prev = V3.zero
    let n = points.count
    for j in 0..<n {
        if j == 0 {
            let dx = points[1].x - points[0].x, dy = points[1].y - points[0].y
            let normal = V3(dy, -dx, 0)
            prev = normal
            initNormals.append(simd_normalize(normal))
        } else if j == n - 1 {
            initNormals.append(prev)
        } else {
            let dx = points[j + 1].x - points[j].x, dy = points[j + 1].y - points[j].y
            let cur = V3(dy, -dx, 0)
            initNormals.append(simd_normalize(cur + prev))
            prev = cur
        }
    }
    let inv = 1.0 / Double(segments)
    for i in 0...segments {
        let phi = phiStart + Double(i) * inv * phiLength
        let s = sin(phi), c = cos(phi)
        for j in 0..<n {
            pos.append(V3(points[j].x * s, points[j].y, points[j].x * c))
            uv.append(SIMD2(Double(i) / Double(segments), Double(j) / Double(n - 1)))
            nrm.append(V3(initNormals[j].x * s, initNormals[j].y, initNormals[j].x * c))
        }
    }
    for i in 0..<segments {
        for j in 0..<(n - 1) {
            let base = j + i * n
            let a = base, b = base + n, c = base + n + 1, d = base + 1
            idx += [a, b, d, c, d, b]
        }
    }
    return MeshData(indices: idx, positions: pos, normals: nrm, uvs: uv)
}

func planeGeometry(_ width: Double, _ height: Double, _ wSeg: Int = 1, _ hSeg: Int = 1) -> MeshData {
    var idx: [Int] = [], pos: [V3] = [], nrm: [V3] = [], uv: [SIMD2<Double>] = []
    let gx1 = wSeg + 1, gy1 = hSeg + 1
    let sw = width / Double(wSeg), sh = height / Double(hSeg)
    for iy in 0..<gy1 {
        let y = Double(iy) * sh - height / 2
        for ix in 0..<gx1 {
            let x = Double(ix) * sw - width / 2
            pos.append(V3(x, -y, 0))
            nrm.append(V3(0, 0, 1))
            uv.append(SIMD2(Double(ix) / Double(wSeg), 1 - Double(iy) / Double(hSeg)))
        }
    }
    for iy in 0..<hSeg {
        for ix in 0..<wSeg {
            let a = ix + gx1 * iy, b = ix + gx1 * (iy + 1), c = (ix + 1) + gx1 * (iy + 1), d = (ix + 1) + gx1 * iy
            idx += [a, b, d, b, c, d]
        }
    }
    return MeshData(indices: idx, positions: pos, normals: nrm, uvs: uv)
}

/// 2D outline builder with the subset of three's Path API the kit uses.
struct Shape2D {
    private(set) var points: [SIMD2<Double>] = []
    private var current = SIMD2<Double>(0, 0)
    let curveSegments: Int

    init(curveSegments: Int) { self.curveSegments = curveSegments }

    private mutating func push(_ p: SIMD2<Double>) {
        if let last = points.last, last == p { return }
        points.append(p)
    }

    mutating func moveTo(_ x: Double, _ y: Double) {
        current = SIMD2(x, y)
        push(current)
    }

    mutating func lineTo(_ x: Double, _ y: Double) {
        if points.isEmpty { push(current) }
        current = SIMD2(x, y)
        push(current)
    }

    /// EllipseCurve sampling exactly like three (resolution = 2 · curveSegments).
    mutating func absarc(_ cx: Double, _ cy: Double, _ r: Double, _ a0: Double, _ a1: Double, clockwise: Bool) {
        let twoPi = Double.pi * 2
        var delta = a1 - a0
        let same = abs(delta) < Double.ulpOfOne
        while delta < 0 { delta += twoPi }
        while delta > twoPi { delta -= twoPi }
        if delta < Double.ulpOfOne { delta = same ? 0 : twoPi }
        if clockwise && !same { delta = delta == twoPi ? -twoPi : delta - twoPi }
        let res = curveSegments * 2
        for i in 0...res {
            let a = a0 + Double(i) / Double(res) * delta
            push(SIMD2(cx + r * cos(a), cy + r * sin(a)))
        }
        current = points.last!
    }

    mutating func closePath() {
        if let f = points.first, let l = points.last, f == l { points.removeLast() }
    }
}

/// ExtrudeGeometry (no bevel, one step): front and back lids plus side walls with flat normals.
func extrudeGeometry(_ shape: Shape2D, depth: Double) -> MeshData {
    var pts = shape.points
    if let f = pts.first, let l = pts.last, f == l { pts.removeLast() }
    // ShapeUtils.isClockWise: area < 0 — three reverses counter-clockwise outlines to clockwise
    var area = 0.0
    for i in 0..<pts.count {
        let p = pts[i], q = pts[(i + 1) % pts.count]
        area += p.x * q.y - q.x * p.y
    }
    if area >= 0 { pts.reverse() }
    let tris = triangulate(pts)
    var out = MeshData()
    func tri(_ a: V3, _ b: V3, _ c: V3) {
        let n = simd_normalize(simd_cross(c - b, a - b))
        out.positions += [a, b, c]
        out.normals += [n, n, n]
        out.uvs += [.zero, .zero, .zero]
        out.mist += [0, 0, 0]
    }
    for t in tris {
        let a = pts[t.0], b = pts[t.1], c = pts[t.2]
        // bottom lid (z = 0) reversed, top lid (z = depth)
        tri(V3(c.x, c.y, 0), V3(b.x, b.y, 0), V3(a.x, a.y, 0))
        tri(V3(a.x, a.y, depth), V3(b.x, b.y, depth), V3(c.x, c.y, depth))
    }
    // side walls exactly as buildSideFaces: j = i, k = i − 1, f4(a, b, c, d) → (a, b, d), (b, c, d)
    let n = pts.count
    for i in 0..<n {
        let k = i == 0 ? n - 1 : i - 1
        let pj = pts[i], pk = pts[k]
        let a = V3(pj.x, pj.y, 0), b = V3(pk.x, pk.y, 0), c = V3(pk.x, pk.y, depth), d = V3(pj.x, pj.y, depth)
        tri(a, b, d)
        tri(b, c, d)
    }
    return out
}

/// Ear clipping; like earcut, every returned triangle is counter-clockwise (y up).
private func triangulate(_ pts: [SIMD2<Double>]) -> [(Int, Int, Int)] {
    var area = 0.0
    for i in 0..<pts.count {
        let p = pts[i], q = pts[(i + 1) % pts.count]
        area += p.x * q.y - q.x * p.y
    }
    var idx = Array(pts.indices)
    if area < 0 { idx.reverse() }
    func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    func inside(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        cross(a, b, p) >= -1e-12 && cross(b, c, p) >= -1e-12 && cross(c, a, p) >= -1e-12
    }
    var out: [(Int, Int, Int)] = []
    while idx.count > 3 {
        var clipped = false
        for k in 0..<idx.count {
            let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
            let a = pts[i0], b = pts[i1], c = pts[i2]
            if cross(a, b, c) <= 1e-12 { continue }
            var ear = true
            for m in idx where m != i0 && m != i1 && m != i2 {
                if pts[m] == a || pts[m] == b || pts[m] == c { continue }
                if inside(pts[m], a, b, c) { ear = false; break }
            }
            if !ear { continue }
            out.append((i0, i1, i2))
            idx.remove(at: k)
            clipped = true
            break
        }
        if !clipped { break }
    }
    if idx.count == 3 { out.append((idx[0], idx[1], idx[2])) }
    return out
}

// ───────────────────────── kit geometry (geometry.ts) ─────────────────────────

/// Box between min and max. `fade` = length over which the bottom dissolves into mist.
func boxGeo(_ mn: V3, _ mx: V3, fade: Double = 0) -> MeshData {
    let w = mx.x - mn.x, h = mx.y - mn.y, d = mx.z - mn.z
    let cx = (mn.x + mx.x) / 2, cz = (mn.z + mx.z) / 2
    func part(_ y0: Double, _ y1: Double, _ m0: Double, _ m1: Double) -> MeshData {
        boxGeometry(w, y1 - y0, d).translated(cx, (y0 + y1) / 2, cz).withMist { abs($0 - y0) < 1e-4 ? m0 : m1 }
    }
    if fade <= 0 { return part(mn.y, mx.y, 0, 0) }
    let f = min(fade, h)
    var parts = [part(mn.y, mn.y + f, 1, 0)]
    if f < h { parts.append(part(mn.y + f, mx.y, 0, 0)) }
    return merge(parts)
}

/// Thin, slightly overhanging cap slab with world-space UVs on top (one tile per cell).
func capGeo(_ mn: V3, _ mx: V3) -> MeshData {
    let o = 0.035, t = 0.085
    var g = boxGeometry(mx.x - mn.x + 2 * o, t, mx.z - mn.z + 2 * o)
        .translated((mn.x + mx.x) / 2, mx.y - t / 2 + 0.002, (mn.z + mx.z) / 2)
    for i in g.positions.indices {
        if g.normals[i].y > 0.5 { g.uvs[i] = SIMD2(g.positions[i].x + 0.5, -(g.positions[i].z + 0.5)) } else { g.uvs[i] = SIMD2(0.5, 0.5) }
    }
    return g.withMist()
}

/// Cap slab on any face of a box: `mn…mx` is the face rectangle (flat along the axis of `up`). Same lip and
/// tile pattern as `capGeo`, so a road on a wall reads exactly like a road on a floor.
func faceCapGeo(_ mn: V3, _ mx: V3, _ up: V3) -> MeshData {
    let a = abs(up.x) > 0.5 ? 0 : abs(up.y) > 0.5 ? 1 : 2
    let o = 0.035, t = 0.085
    var lo = mn, hi = mx
    for k in 0..<3 where k != a {
        lo[k] -= o
        hi[k] += o
    }
    let f = mn[a]
    if up[a] > 0 { lo[a] = f - t + 0.002; hi[a] = f + 0.002 } else { lo[a] = f - 0.002; hi[a] = f + t - 0.002 }
    var g = boxGeometry(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z).translated((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
    let (u, v) = a == 0 ? (2, 1) : a == 1 ? (0, 2) : (0, 1)
    for i in g.positions.indices {
        if simd_dot(g.normals[i], up) > 0.5 {
            g.uvs[i] = SIMD2(g.positions[i][u] + 0.5, g.positions[i][v] + 0.5)
        } else {
            g.uvs[i] = SIMD2(0.5, 0.5)
        }
    }
    return g.withMist()
}

/// Rotation taking +Y to the (axis-aligned) direction `axis`.
func alignY(to axis: V3) -> simd_double3x3 {
    if axis.y > 0.5 { return matrix_identity_double3x3 }
    if axis.y < -0.5 { return rot3X(.pi) }
    if abs(axis.z) > 0.5 { return rot3X(axis.z > 0 ? .pi / 2 : -.pi / 2) }
    return rot3Z(axis.x > 0 ? -.pi / 2 : .pi / 2)
}

/// Toothed wheel: rim disc, teeth and a raised boss, turning about `axis`.
func gearGeo(_ x: Double, _ y: Double, _ z: Double, _ axis: V3, _ r: Double) -> MeshData {
    let th = min(0.16, 0.06 + r * 0.06)
    var parts = [cylinderGeometry(r * 0.86, r * 0.86, th, 40),
                 cylinderGeometry(r * 0.3, r * 0.3, th * 1.9, 20),
                 cylinderGeometry(r * 0.12, r * 0.12, th * 2.6, 12)]
    let n = max(8, Int((r * 13).rounded()))
    let tw = (2 * .pi * r * 0.86) / Double(n) * 0.5
    for i in 0..<n {
        let ang = Double(i) / Double(n) * .pi * 2
        parts.append(boxGeometry(r * 0.2, th * 0.9, tw).translated(r * 0.92, 0, 0).rotatedY(ang))
    }
    return merge(parts).transformed(alignY(to: axis)).translated(x, y, z).withMist()
}

/// One-cell staircase. Step tops sit half a step around the walking line.
func stairsGeo(_ x: Double, _ z: Double, _ dir: V3, _ h0: Double, _ rise: Double, _ base: Double, _ steps: Int) -> MeshData {
    var parts: [MeshData] = []
    for i in 0..<steps {
        let a = -0.5 + Double(i) / Double(steps)
        let b = -0.5 + Double(i + 1) / Double(steps)
        let top = h0 + ((Double(i) + 0.5) / Double(steps)) * rise + 0.03
        var mn: V3, mx: V3
        if dir.x != 0 {
            let s = dir.x
            let x0 = x + s * a, x1 = x + s * b
            mn = V3(min(x0, x1), base, z - 0.5)
            mx = V3(max(x0, x1), top, z + 0.5)
        } else {
            let s = dir.z
            let z0 = z + s * a, z1 = z + s * b
            mn = V3(x - 0.5, base, min(z0, z1))
            mx = V3(x + 0.5, top, max(z0, z1))
        }
        parts.append(boxGeo(mn, mx))
    }
    return merge(parts)
}

/// Wall slab with round-topped openings, spanning `span` along the given axis.
func archGeo(x: Double, z: Double, axis: ArchAxis, y0: Double, y1: Double, span S: Double, thick: Double, openW: Double, openH: Double, count: Int) -> MeshData {
    let H = y1 - y0
    let r = openW / 2
    let hs = max(0.01, openH - r)
    var s = Shape2D(curveSegments: 14)
    s.moveTo(-S / 2, 0)
    for i in 0..<count {
        let c = -S / 2 + (Double(i) + 0.5) * S / Double(count)
        s.lineTo(c - r, 0)
        s.lineTo(c - r, hs)
        s.absarc(c, hs, r, .pi, 0, clockwise: true)
        s.lineTo(c + r, 0)
    }
    s.lineTo(S / 2, 0)
    s.lineTo(S / 2, H)
    s.lineTo(-S / 2, H)
    s.closePath()
    var g = extrudeGeometry(s, depth: thick).translated(0, 0, -thick / 2)
    if axis == .z { g = g.rotatedY(-Double.pi / 2) }
    return g.translated(x, y0, z).withMist()
}

private let ONION: [SIMD2<Double>] = [
    SIMD2(0, 0), SIMD2(0.44, 0), SIMD2(0.47, 0.1), SIMD2(0.46, 0.26), SIMD2(0.36, 0.45), SIMD2(0.2, 0.62), SIMD2(0.08, 0.76), SIMD2(0.03, 0.86), SIMD2(0, 0.92),
]

func domeGeo(_ x: Double, _ y: Double, _ z: Double, _ r: Double, _ style: DomeStyle) -> MeshData {
    var g: MeshData
    let k = r / 0.45
    switch style {
    case .onion:
        g = latheGeometry(ONION.map { $0 * k }, 20)
    case .round:
        g = sphereGeometry(r, 20, 10, phiStart: 0, phiLength: .pi * 2, thetaStart: 0, thetaLength: .pi / 2)
    case .cone:
        g = cylinderGeometry(0, r * 1.25, r * 1.6, 4, 1).rotatedY(.pi / 4).translated(0, r * 0.8, 0)
    }
    g = g.translated(x, y, z)
    let top = style == .onion ? 0.92 * k : style == .round ? r : r * 1.6
    let fin = sphereGeometry(0.055 * k, 10, 6).translated(x, y + top + 0.04 * k, z)
    let spike = cylinderGeometry(0, 0.025 * k, 0.22 * k, 6).translated(x, y + top + 0.17 * k, z)
    return merge([g.withMist(), fin.withMist(), spike.withMist()])
}

func treeGeo(_ x: Double, _ y: Double, _ z: Double, _ h: Double) -> MeshData {
    let prof: [SIMD2<Double>] = [SIMD2(0, 0.1), SIMD2(0.2, 0.14), SIMD2(0.27, 0.36), SIMD2(0.24, 0.62), SIMD2(0.15, 0.86), SIMD2(0.05, 1.02), SIMD2(0, 1.08)]
    return latheGeometry(prof.map { SIMD2($0.x * h * 0.8, $0.y * h) }, 7).translated(x, y, z).withMist()
}

func trunkGeo(_ x: Double, _ y: Double, _ z: Double, _ h: Double) -> MeshData {
    boxGeo(V3(x - 0.035, y, z - 0.035), V3(x + 0.035, y + h * 0.16, z + 0.035))
}

func pillarGeo(_ x: Double, _ z: Double, _ y0: Double, _ y1: Double, _ r: Double, fade: Double = 0) -> MeshData {
    boxGeo(V3(x - r, y0, z - r), V3(x + r, y1, z + r), fade: fade)
}

func columnGeo(_ x: Double, _ z: Double, _ y0: Double, _ y1: Double, _ r: Double) -> MeshData {
    cylinderGeometry(r, r, y1 - y0, 16, 1).translated(x, (y0 + y1) / 2, z).withMist { abs($0 - y0) < 1e-4 && y0 < -1 ? 1 : 0 }
}

func urnGeo(_ x: Double, _ y: Double, _ z: Double) -> MeshData {
    let prof: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(0.1, 0), SIMD2(0.12, 0.05), SIMD2(0.2, 0.18), SIMD2(0.18, 0.3), SIMD2(0.1, 0.36), SIMD2(0.13, 0.42), SIMD2(0, 0.42)]
    return latheGeometry(prof, 14).translated(x, y, z).withMist()
}

/// Round-topped window recess facing `face`.
func windowGeo(_ x: Double, _ y: Double, _ z: Double, _ face: V3, _ w: Double, _ h: Double) -> MeshData {
    var s = Shape2D(curveSegments: 8)
    let r = w / 2
    s.moveTo(-r, -h / 2)
    s.lineTo(r, -h / 2)
    s.lineTo(r, h / 2 - r)
    s.absarc(0, h / 2 - r, r, 0, .pi, clockwise: false)
    s.closePath()
    let ang = atan2(face.x, face.z)
    return extrudeGeometry(s, depth: 0.04).rotatedY(ang).translated(x + face.x * 0.005, y, z + face.z * 0.005).withMist()
}

/// Crank: hub, four arms with pins; built around +Y.
func crankParts(_ r: Double) -> (body: MeshData, pins: MeshData) {
    var arms = [cylinderGeometry(0.17, 0.17, 0.2, 16), cylinderGeometry(0.26, 0.26, 0.09, 20)]
    var pins: [MeshData] = []
    for i in 0..<4 {
        let a = Double(i) * .pi / 2
        arms.append(boxGeometry(r, 0.07, 0.09).translated(r / 2, 0, 0).rotatedY(a))
        pins.append(cylinderGeometry(0.075, 0.075, 0.24, 12).translated(r, 0.02, 0).rotatedY(a))
        pins.append(sphereGeometry(0.08, 10, 6).translated(r, 0.15, 0).rotatedY(a))
    }
    return (merge(arms), merge(pins))
}

func knobParts() -> (body: MeshData, pins: MeshData) {
    let disc = cylinderGeometry(0.2, 0.2, 0.12, 20).rotatedZ(.pi / 2)
    let stem = cylinderGeometry(0.06, 0.06, 0.2, 10).rotatedZ(.pi / 2).translated(-0.12, 0, 0)
    let cap = cylinderGeometry(0.11, 0.11, 0.14, 16).rotatedZ(.pi / 2).translated(0.06, 0, 0)
    return (merge([disc, stem]), cap)
}

func planeXZ(_ mn: V3, _ mx: V3) -> MeshData {
    planeGeometry(mx.x - mn.x, mx.z - mn.z).rotatedX(-.pi / 2).translated((mn.x + mx.x) / 2, mn.y, (mn.z + mx.z) / 2)
}
