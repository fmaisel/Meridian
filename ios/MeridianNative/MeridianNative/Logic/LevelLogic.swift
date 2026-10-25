// Pure level logic: body transforms as a function of mechanism parameters, solids in world space and
// the navigation graph (physical links + perspective seams) for a given puzzle state.
// Port of src/logic/LevelLogic.ts. All iteration orders mirror the JavaScript Map/Set insertion order.

import Foundation
import simd

/// Isometric view vectors (camera offset direction), one per world-rotation quadrant. q+1 = +90° about Y.
let VIEWS: [V3] = [
    V3(1, 1, 1),
    V3(1, 1, -1),
    V3(-1, 1, -1),
    V3(-1, 1, 1),
]

private let UP = V3(0, 1, 0)
private let EPS = 1e-3

struct NavEdge {
    var p: V3
    var d: V3
    var seam: Bool
}

final class NavNode {
    let id: String
    let body: String
    let tile: TileDef
    let pos: V3
    let edges: [NavEdge]
    let zone: String
    let tags: [String]
    /// Position of this node in `NavGraph.nodeList` (insertion order).
    let index: Int

    init(id: String, body: String, tile: TileDef, pos: V3, edges: [NavEdge], zone: String, tags: [String], index: Int) {
        self.id = id
        self.body = body
        self.tile = tile
        self.pos = pos
        self.edges = edges
        self.zone = zone
        self.tags = tags
        self.index = index
    }
}

struct NavLink {
    var to: String
    var seam: Bool
    /// Edge point on the source side.
    var a: V3
    /// Edge point on the destination side (differs from `a` only for seams, by k·view).
    var b: V3
    var cost: Double
}

/// Navigation graph. Nodes keep the insertion order of the JavaScript `Map`.
final class NavGraph: @unchecked Sendable {
    /// Nodes in insertion order (== iteration order of `nodes` in the TypeScript original).
    let nodeList: [NavNode]
    /// Outgoing links per node, parallel to `nodeList`.
    let linkList: [[NavLink]]
    let view: V3
    let index: [String: Int]
    /// Index-based adjacency (parallel to `linkList`): target index and cost.
    let adj: [[(to: Int, cost: Double)]]

    init(nodeList: [NavNode], linkList: [[NavLink]], view: V3) {
        self.nodeList = nodeList
        self.linkList = linkList
        self.view = view
        var idx: [String: Int] = [:]
        idx.reserveCapacity(nodeList.count)
        for n in nodeList { idx[n.id] = n.index }
        index = idx
        adj = linkList.map { ls in ls.map { (to: idx[$0.to]!, cost: $0.cost) } }
    }

    var count: Int { nodeList.count }
    func node(_ id: String) -> NavNode? { index[id].map { nodeList[$0] } }
    func links(_ id: String) -> [NavLink] { index[id].map { linkList[$0] } ?? [] }
    func has(_ id: String) -> Bool { index[id] != nil }

    // Per-start-node memo of derived reachability data (the graph is immutable, so these are pure).
    private let memoLock = NSLock()
    private var canonMemo: [Int: String] = [:]
    private var compMemo: [Int: [Int]] = [:]
    private lazy var idOrder: [Int] = nodeList.indices.sorted { nodeList[$0].id < nodeList[$1].id }

    /// Lowest id (string order) of a node of the same body within the component reachable from `i`.
    func canonicalId(from i: Int) -> String {
        memoLock.lock()
        if let c = canonMemo[i] { memoLock.unlock(); return c }
        memoLock.unlock()
        let mask = reachableMask(self, i)
        let body = nodeList[i].body
        var best = nodeList[i].id
        for (j, ok) in mask.enumerated() where ok {
            let n = nodeList[j]
            if n.body == body && n.id < best { best = n.id }
        }
        memoLock.lock()
        canonMemo[i] = best
        memoLock.unlock()
        return best
    }

    /// Indices reachable from `i`, sorted by node id (== `[...reachable(g, id)].sort()`).
    func sortedComponent(from i: Int) -> [Int] {
        memoLock.lock()
        if let c = compMemo[i] { memoLock.unlock(); return c }
        let order = idOrder
        memoLock.unlock()
        let mask = reachableMask(self, i)
        let comp = order.filter { mask[$0] }
        memoLock.lock()
        compMemo[i] = comp
        memoLock.unlock()
        return comp
    }
}

struct WorldBox {
    var body: String
    var min: V3
    var max: V3
}

final class LevelLogic: @unchecked Sendable {
    let def: LevelDef
    let bodies: [String: BodyDef]
    let mechs: [String: MechDef]
    let order: [BodyDef]
    /// Plates keyed by their tile reference (later plates on the same tile win, like Map.set).
    let plateByNode: [String: PlateDef]
    private let movedBy: [String: [String]]
    private let mechIndex: [String: Int]
    private let mechIds: [String]
    /// "bodyId/tileId" per body, parallel to `tiles`.
    private let tileRefs: [String: [String]]
    private var graphCache: [[Int]: NavGraph] = [:]
    private let cacheLock = NSLock()

    init(_ def: LevelDef) {
        self.def = def
        var bodies: [String: BodyDef] = [:]
        for b in def.bodies { bodies[b.id] = b }
        var mechs: [String: MechDef] = [:]
        var mechIndex: [String: Int] = [:]
        for (i, m) in def.mechs.enumerated() { mechs[m.id] = m; mechIndex[m.id] = i }
        self.bodies = bodies
        self.mechs = mechs
        self.mechIndex = mechIndex
        self.mechIds = def.mechs.map { $0.id }
        var refs: [String: [String]] = [:]
        for b in def.bodies { refs[b.id] = b.tiles.map { "\(b.id)/\($0.id)" } }
        self.tileRefs = refs
        // Topological order so parents are resolved before children.
        var seen = Set<String>()
        var order: [BodyDef] = []
        func visit(_ b: BodyDef) {
            if seen.contains(b.id) { return }
            if let pid = b.parent {
                guard let p = bodies[pid] else { fatalError("Body \(b.id): unknown parent \(pid)") }
                visit(p)
            }
            seen.insert(b.id)
            order.append(b)
        }
        def.bodies.forEach(visit)
        self.order = order
        for b in def.bodies {
            if let m = b.mech, mechs[m] == nil { fatalError("Body \(b.id): unknown mech \(m)") }
        }
        var plates: [String: PlateDef] = [:]
        for p in def.plates { plates[p.tile] = p }
        plateByNode = plates
        // Bodies moved by each mechanism (driven bodies and all their descendants), in def.bodies order.
        func within(_ bodyId: String, _ ancestor: String) -> Bool {
            var cur: String? = bodyId
            while let c = cur {
                if c == ancestor { return true }
                cur = bodies[c]?.parent
            }
            return false
        }
        var moved: [String: [String]] = [:]
        for m in def.mechs {
            let roots = def.bodies.filter { $0.mech == m.id }.map { $0.id }
            moved[m.id] = def.bodies.filter { b in roots.contains { within(b.id, $0) } }.map { $0.id }
        }
        movedBy = moved
    }

    func initialState() -> PuzzleState {
        var mech: [String: Int] = [:]
        for m in def.mechs { mech[m.id] = m.initial }
        return PuzzleState(mech: mech, flags: def.initialFlags.sorted(), cam: 0)
    }

    /// Local pose of a mechanism for a continuous parameter (state index, may be fractional while animating).
    /// `body` applies a coupled body's own pivot and sense of motion.
    func mechMatrix(_ m: MechDef, _ param: Double, body: BodyDef? = nil) -> simd_double4x4 {
        let sign = body?.mechSign ?? 1
        switch m.kind {
        case let .rotator(pivot, axis):
            let p = body?.pivot ?? pivot
            let ax = JSMat.normalize(axis)
            var out = JSMat.makeTranslation(p.x, p.y, p.z)
            out = JSMat.multiply(out, JSMat.makeRotationAxisAngle(ax, (sign * param * Double.pi) / 2))
            out = JSMat.multiply(out, JSMat.makeTranslation(-p.x, -p.y, -p.z))
            return out
        case let .slider(axis, step):
            let s = sign * param * step
            return JSMat.makeTranslation(axis.x * s, axis.y * s, axis.z * s)
        case let .lift(poses):
            let n = poses.count - 1
            let nd = Double(n)
            let c = jsMax(0, jsMin(nd, param))
            let i = Int(jsMin(nd - 1, c.rounded(.down)))
            let t = n == 0 ? 0 : c - Double(i)
            var a = poses[i]
            let b = poses[min(n, i + 1)]
            a.x += (b.x - a.x) * t
            a.y += (b.y - a.y) * t
            a.z += (b.z - a.z) * t
            return JSMat.makeTranslation(a.x, a.y, a.z)
        }
    }

    /// World matrices for all bodies given mechanism parameters.
    func bodyMatrices(_ params: [String: Double]) -> [String: simd_double4x4] {
        var out: [String: simd_double4x4] = [:]
        out.reserveCapacity(order.count)
        for b in order {
            var m = JSMat.identity
            if let p = b.parent { m = out[p]! }
            if let mid = b.mech {
                let md = mechs[mid]!
                m = JSMat.multiply(m, mechMatrix(md, params[mid] ?? Double(md.initial), body: b))
            }
            out[b.id] = m
        }
        return out
    }

    /// Integer convenience (puzzle states).
    func bodyMatrices(_ params: [String: Int]) -> [String: simd_double4x4] {
        bodyMatrices(params.mapValues { Double($0) })
    }

    /// Is `bodyId` the given body or one of its descendants?
    func isWithin(_ bodyId: String, _ ancestor: String) -> Bool {
        var cur: String? = bodyId
        while let c = cur {
            if c == ancestor { return true }
            cur = bodies[c]?.parent
        }
        return false
    }

    /// Bodies moved by a mechanism (the driven bodies and all their descendants). Precomputed.
    func bodiesMovedBy(_ mechId: String) -> [String] {
        movedBy[mechId] ?? []
    }

    func worldSolids(_ mats: [String: simd_double4x4]) -> [WorldBox] {
        var out: [WorldBox] = []
        for b in order {
            let m = mats[b.id]!
            for s in b.solids { out.append(transformBox(s, m, b.id)) }
        }
        return out
    }

    func graphKey(_ state: PuzzleState) -> String {
        var s = ""
        for (i, id) in mechIds.enumerated() {
            if i > 0 { s += "," }
            if let v = state.mech[id] { s += String(v) }  // undefined joins as ''
        }
        return s + "|" + String(state.cam)
    }

    /// Same identity as `graphKey` (injective mapping), but cheaper to hash.
    private func cacheKey(_ state: PuzzleState) -> [Int] {
        var k = [Int]()
        k.reserveCapacity(mechIds.count + 1)
        for id in mechIds { k.append(state.mech[id] ?? Int.min) }
        k.append(state.cam)
        return k
    }

    /// Cached graph for a puzzle state. Thread-safe.
    func graph(_ state: PuzzleState) -> NavGraph {
        let key = cacheKey(state)
        cacheLock.lock()
        if let g = graphCache[key] {
            cacheLock.unlock()
            return g
        }
        cacheLock.unlock()
        let g = buildGraph(state.mech, cam: state.cam)
        cacheLock.lock()
        if let existing = graphCache[key] {
            cacheLock.unlock()
            return existing
        }
        if graphCache.count > 4000 { graphCache.removeAll() }
        graphCache[key] = g
        cacheLock.unlock()
        return g
    }

    func buildGraph(_ params: [String: Int], cam: Int, exclude: Set<String>? = nil) -> NavGraph {
        buildGraph(params.mapValues { Double($0) }, cam: cam, exclude: exclude)
    }

    func buildGraph(_ params: [String: Double], cam: Int, exclude: Set<String>? = nil) -> NavGraph {
        let mats = bodyMatrices(params)
        let solids = worldSolids(mats)
        let view = VIEWS[((cam % 4) + 4) % 4]
        var nodes: [NavNode] = []
        var nodeIds = Set<String>()

        for b in order {
            if exclude?.contains(b.id) == true { continue }
            let m = mats[b.id]!
            let rot = JSMat.extractRotation(m)
            let n = JSMat.apply(UP, rot)
            // top surfaces of this body face up in this pose (faced tiles decide on their own)
            let topUp = n.y >= 1 - EPS
            if !topUp && !b.tiles.contains(where: { $0.up != nil }) { continue }
            for (ti, t) in b.tiles.enumerated() {
                if let up = t.up {
                    if JSMat.apply(up, rot).y < 1 - EPS { continue }
                } else if !topUp { continue }
                let pos = snapV(JSMat.apply(t.pos, m))
                let probe = V3(pos.x, pos.y + 0.45, pos.z)
                if solids.contains(where: { inside(probe, $0) }) { continue }
                let edges = t.edges.map { e -> NavEdge in
                    // faced tiles are flat: their edges lie in the face plane, half a cell out
                    let local = t.up == nil
                        ? V3(t.pos.x + e.dir.x * 0.5, e.h, t.pos.z + e.dir.z * 0.5)
                        : t.pos + e.dir * 0.5
                    return NavEdge(p: snapV(JSMat.apply(local, m)), d: snapV(JSMat.apply(e.dir, rot)), seam: e.seam)
                }
                let id = tileRefs[b.id]![ti]
                let node = NavNode(id: id, body: b.id, tile: t, pos: pos, edges: edges,
                                   zone: b.tileZones[t.id] ?? b.zone, tags: t.tags, index: 0)
                if nodeIds.contains(id) {
                    // Map.set on an existing key replaces the value but keeps its position.
                    let i = nodes.firstIndex { $0.id == id }!
                    nodes[i] = NavNode(id: id, body: node.body, tile: t, pos: pos, edges: edges, zone: node.zone, tags: t.tags, index: i)
                } else {
                    nodeIds.insert(id)
                    nodes.append(NavNode(id: id, body: node.body, tile: t, pos: pos, edges: edges, zone: node.zone, tags: t.tags, index: nodes.count))
                }
            }
        }

        var links = [[NavLink]](repeating: [], count: nodes.count)
        // insertion-ordered multimaps (key → group)
        // Keys are the rounded integers behind the TS strings `${…},${…},${…}` (an injective mapping: -0 and 0
        // print identically and map to the same Int).
        var byPointIdx: [GridKey: Int] = [:]
        var byPoint: [[(node: Int, e: Int)]] = []
        var byProjIdx: [GridKey: Int] = [:]
        var byProj: [[(node: Int, e: Int)]] = []
        func proj(_ p: V3) -> GridKey {
            GridKey(Int(jsRound((p.x - view.x * p.y) * 4)), Int(jsRound((p.z - view.z * p.y) * 4)), 0)
        }

        for node in nodes {
            for (ei, e) in node.edges.enumerated() {
                let k = gridKey4(e.p)
                if let gi = byPointIdx[k] { byPoint[gi].append((node.index, ei)) } else {
                    byPointIdx[k] = byPoint.count
                    byPoint.append([(node.index, ei)])
                }
                if e.seam {
                    let pk = proj(e.p)
                    if let gi = byProjIdx[pk] { byProj[gi].append((node.index, ei)) } else {
                        byProjIdx[pk] = byProj.count
                        byProj.append([(node.index, ei)])
                    }
                }
            }
        }

        func addLink(_ ai: Int, _ ea: NavEdge, _ bi: Int, _ eb: NavEdge, _ seam: Bool) {
            let a = nodes[ai], b = nodes[bi]
            if a.id == b.id { return }
            if links[ai].contains(where: { $0.to == b.id }) { return }
            let cost = JSMat.distance(a.pos, ea.p) + JSMat.distance(b.pos, eb.p) + (seam ? 0.25 : 0)
            links[ai].append(NavLink(to: b.id, seam: seam, a: ea.p, b: eb.p, cost: cost))
        }
        func opposite(_ d1: V3, _ d2: V3) -> Bool { abs(d1.x + d2.x) < EPS && abs(d1.z + d2.z) < EPS }

        for group in byPoint {
            for x in group {
                for y in group {
                    let xe = nodes[x.node].edges[x.e], ye = nodes[y.node].edges[y.e]
                    if x.node != y.node && opposite(xe.d, ye.d) { addLink(x.node, xe, y.node, ye, false) }
                }
            }
        }
        for group in byProj {
            for x in group {
                for y in group {
                    let xe = nodes[x.node].edges[x.e], ye = nodes[y.node].edges[y.e]
                    if x.node == y.node || !opposite(xe.d, ye.d) { continue }
                    if gridKey4(xe.p) == gridKey4(ye.p) { continue }  // physical, already handled
                    addLink(x.node, xe, y.node, ye, true)
                }
            }
        }
        return NavGraph(nodeList: nodes, linkList: links, view: view)
    }

    /// Pairs of solids from different, non-related bodies that interpenetrate (for validation).
    func overlaps(_ params: [String: Double], onlyMoving: Bool = true) -> [(WorldBox, WorldBox)] {
        let mats = bodyMatrices(params)
        let solids = worldSolids(mats)
        var moving = Set<String>()
        for m in def.mechs { for b in bodiesMovedBy(m.id) { moving.insert(b) } }
        var out: [(WorldBox, WorldBox)] = []
        for i in 0..<solids.count {
            for j in (i + 1)..<max(i + 1, solids.count) {
                let a = solids[i], b = solids[j]
                if a.body == b.body { continue }
                if onlyMoving && !moving.contains(a.body) && !moving.contains(b.body) { continue }
                if isWithin(a.body, b.body) || isWithin(b.body, a.body) { continue }
                if boxesOverlap(a, b, 0.02) { out.append((a, b)) }
            }
        }
        return out
    }

    func overlaps(_ params: [String: Int], onlyMoving: Bool = true) -> [(WorldBox, WorldBox)] {
        overlaps(params.mapValues { Double($0) }, onlyMoving: onlyMoving)
    }
}

struct GridKey: Hashable {
    var a: Int, b: Int, c: Int
    init(_ a: Int, _ b: Int, _ c: Int) { self.a = a; self.b = b; self.c = c }
}

/// Integer form of `key4` (same equivalence classes as the string).
@inline(__always)
func gridKey4(_ v: V3) -> GridKey {
    GridKey(Int(jsRound(v.x * 4)), Int(jsRound(v.y * 4)), Int(jsRound(v.z * 4)))
}

private func transformBox(_ s: SolidDef, _ m: simd_double4x4, _ body: String) -> WorldBox {
    var mn = V3(.infinity, .infinity, .infinity)
    var mx = V3(-.infinity, -.infinity, -.infinity)
    for i in 0..<8 {
        let c = JSMat.apply(V3(i & 1 != 0 ? s.max.x : s.min.x, i & 2 != 0 ? s.max.y : s.min.y, i & 4 != 0 ? s.max.z : s.min.z), m)
        mn = V3(jsMin(mn.x, c.x), jsMin(mn.y, c.y), jsMin(mn.z, c.z))
        mx = V3(jsMax(mx.x, c.x), jsMax(mx.y, c.y), jsMax(mx.z, c.z))
    }
    return WorldBox(body: body, min: snapV(mn), max: snapV(mx))
}

@inline(__always)
private func inside(_ p: V3, _ s: WorldBox) -> Bool {
    p.x > s.min.x + EPS && p.x < s.max.x - EPS &&
        p.y > s.min.y + EPS && p.y < s.max.y - EPS &&
        p.z > s.min.z + EPS && p.z < s.max.z - EPS
}

private func boxesOverlap(_ a: WorldBox, _ b: WorldBox, _ eps: Double) -> Bool {
    a.min.x < b.max.x - eps && a.max.x > b.min.x + eps &&
        a.min.y < b.max.y - eps && a.max.y > b.min.y + eps &&
        a.min.z < b.max.z - eps && a.max.z > b.min.z + eps
}

// MARK: - Path finding

/// Dijkstra over node indices; identical to the TS version (open set scanned in insertion order, first minimum wins).
func findPathIndices(_ g: NavGraph, _ s: Int, _ t: Int) -> [Int]? {
    if s == t { return [s] }
    let n = g.nodeList.count
    var dist = [Double](repeating: .infinity, count: n)
    var prev = [Int](repeating: -1, count: n)
    var inOpen = [Bool](repeating: false, count: n)
    var open: [Int] = [s]
    dist[s] = 0
    inOpen[s] = true
    while !open.isEmpty {
        var bestK = -1
        var best = Double.infinity
        for k in 0..<open.count {
            let d = dist[open[k]]
            if d < best { best = d; bestK = k }
        }
        // (JS falls back to cur = '' when nothing is < Infinity; cannot happen with finite costs.)
        if bestK < 0 { break }
        let cur = open.remove(at: bestK)
        inOpen[cur] = false
        if cur == t { break }
        for l in g.adj[cur] {
            let nd = best + l.cost
            if nd < dist[l.to] {
                dist[l.to] = nd
                prev[l.to] = cur
                if !inOpen[l.to] { inOpen[l.to] = true; open.append(l.to) }
            }
        }
    }
    if prev[t] < 0 { return nil }
    var path = [t]
    var c = t
    while c != s { c = prev[c]; path.append(c) }
    return path.reversed()
}

/// Dijkstra over the nav graph. Returns node ids from start to goal (inclusive) or nil.
func findPath(_ g: NavGraph, _ from: String, _ to: String) -> [String]? {
    guard let s = g.index[from], let t = g.index[to] else { return nil }
    if from == to { return [from] }
    return findPathIndices(g, s, t).map { $0.map { g.nodeList[$0].id } }
}

/// Reachable node indices from `s` (as a membership mask).
func reachableMask(_ g: NavGraph, _ s: Int) -> [Bool] {
    var seen = [Bool](repeating: false, count: g.nodeList.count)
    var stack = [s]
    seen[s] = true
    while let c = stack.popLast() {
        for l in g.adj[c] where !seen[l.to] {
            seen[l.to] = true
            stack.append(l.to)
        }
    }
    return seen
}

/// All node ids reachable from `from`.
func reachable(_ g: NavGraph, _ from: String) -> Set<String> {
    guard let s = g.index[from] else { return [] }
    let mask = reachableMask(g, s)
    var out = Set<String>()
    for (i, ok) in mask.enumerated() where ok { out.insert(g.nodeList[i].id) }
    return out
}
