// Command-line verification harness for the Swift logic port (not part of the app).
// Build:  cd ios/MeridianNative/Tools/LogicCheck && ./run.sh
//   LogicCheck dump  → prints the same text dump as dump.ts (diff them)
//   LogicCheck test  → ports of tests/solver.test.ts + tests/support.test.ts, plus timings

import Foundation
import simd

let num = jsNumberString
func v3(_ v: V3) -> String { "\(num(v.x)),\(num(v.y)),\(num(v.z))" }
func fmtA(_ a: Action) -> String {
    switch a {
    case let .walk(to): return "walk:\(to)"
    case let .mech(m, to): return "mech:\(m):\(to)"
    case let .cam(dir): return "cam:\(dir)"
    }
}
func elements(_ m: simd_double4x4) -> [Double] {
    (0..<16).map { m[$0 / 4][$0 % 4] }
}

var outLines: [String] = []
func w(_ s: String) { outLines.append(s) }

func visualFields(_ v: VisualDef) -> (String, [(String, String)]) {
    var f: [(String, String)] = []
    let type: String
    switch v.kind {
    case let .box(mn, mx, mat, cap, capMat):
        type = "box"; f = [("min", v3(mn)), ("max", v3(mx)), ("mat", mat), ("cap", "\(cap)")]
        if let capMat { f.append(("capMat", capMat)) }
    case let .stairs(x, z, dir, h0, rise, base, mat, steps):
        type = "stairs"; f = [("x", num(x)), ("z", num(z)), ("dir", v3(dir)), ("h0", num(h0)), ("rise", num(rise)), ("base", num(base)), ("mat", mat), ("steps", "\(steps)")]
    case let .pillar(x, z, y0, y1, r, mat):
        type = "pillar"; f = [("x", num(x)), ("z", num(z)), ("y0", num(y0)), ("y1", num(y1)), ("r", num(r)), ("mat", mat)]
    case let .column(x, z, y0, y1, r, mat):
        type = "column"; f = [("x", num(x)), ("z", num(z)), ("y0", num(y0)), ("y1", num(y1)), ("r", num(r)), ("mat", mat)]
    case let .arch(x, z, axis, y0, y1, span, thick, openW, openH, mat, count):
        type = "arch"; f = [("x", num(x)), ("z", num(z)), ("axis", axis.rawValue), ("y0", num(y0)), ("y1", num(y1)), ("span", num(span)),
                            ("thick", num(thick)), ("openW", num(openW)), ("openH", num(openH)), ("mat", mat), ("count", "\(count)")]
    case let .dome(x, y, z, r, mat, style):
        type = "dome"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("r", num(r)), ("mat", mat), ("style", style.rawValue)]
    case let .tree(x, y, z, h, mat):
        type = "tree"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("h", num(h)), ("mat", mat)]
    case let .window(x, y, z, face, ww, h):
        type = "window"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("face", v3(face)), ("w", num(ww)), ("h", num(h))]
    case let .banner(x, y, z, face, len, ww, mat):
        type = "banner"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("face", v3(face)), ("len", num(len)), ("w", num(ww)), ("mat", mat)]
    case let .water(mn, mx):
        type = "water"; f = [("min", v3(mn)), ("max", v3(mx))]
    case let .lily(x, y, z, r, flower):
        type = "lily"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("r", num(r)), ("flower", flower ? "1" : "0")]
    case let .fall(x, z, y0, y1, ww, face):
        type = "fall"; f = [("x", num(x)), ("z", num(z)), ("y0", num(y0)), ("y1", num(y1)), ("w", num(ww)), ("face", v3(face))]
    case let .glyph(x, y, z, kind):
        type = "glyph"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("kind", kind)]
    case let .crank(x, y, z, axis, r, mech):
        type = "crank"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("axis", v3(axis)), ("r", num(r)), ("mech", mech)]
    case let .knob(x, y, z, mech):
        type = "knob"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("mech", mech)]
    case let .shrine(x, y, z):
        type = "shrine"; f = [("x", num(x)), ("y", num(y)), ("z", num(z))]
    case let .faceCap(mn, mx, up):
        type = "faceCap"; f = [("min", v3(mn)), ("max", v3(mx)), ("up", v3(up))]
    case let .gear(x, y, z, axis, r, mat):
        type = "gear"; f = [("x", num(x)), ("y", num(y)), ("z", num(z)), ("axis", v3(axis)), ("r", num(r)), ("mat", mat)]
    }
    if v.mist != 0 { f.append(("mist", num(v.mist))) }
    return (type, f.sorted { $0.0 < $1.0 })
}

func dumpGraph(_ label: String, _ g: NavGraph) {
    w("graph \(label) view=\(v3(g.view)) nodes=\(g.nodeList.count)")
    for n in g.nodeList {
        let edges = n.edges.map { "\(v3($0.p)):\(v3($0.d)):\($0.seam)" }.joined(separator: ";")
        w(" node \(n.id) body=\(n.body) zone=\(n.zone) tags=\(n.tags.joined(separator: "+")) pos=\(v3(n.pos)) edges=\(edges)")
        for l in g.links(n.id) {
            w("  link \(l.to) seam=\(l.seam) a=\(v3(l.a)) b=\(v3(l.b)) cost=\(num(l.cost))")
        }
    }
}

/// Thread CPU time in ms (stable on a loaded machine).
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }

func runDump() {
    let def = buildLevel()
    let logic = LevelLogic(def)
    w("level start=\(def.start) goal=\(def.goal) rotateFlag=\(def.rotateFlag) initialFlags=\(def.initialFlags.joined(separator: "+"))")
    for b in def.bodies {
        w("body \(b.id) parent=\(b.parent ?? "-") mech=\(b.mech ?? "-") palette=\(b.palette) zone=\(b.zone) rides=\(b.rides)")
        for k in b.tileZones.keys.sorted() { w(" tileZone \(k)=\(b.tileZones[k]!)") }
        w(" tiles \(b.tiles.count)")
        for t in b.tiles {
            let edges = t.edges.map { "\(v3($0.dir)):\(num($0.h)):\($0.seam)" }.joined(separator: ";")
            w(" tile \(t.id) pos=\(v3(t.pos)) edges=\(edges) tags=\(t.tags.joined(separator: "+"))")
        }
        w(" solids \(b.solids.count)")
        for s in b.solids { w(" solid \(v3(s.min)) \(v3(s.max))") }
        w(" visuals \(b.visuals.count)")
        for v in b.visuals {
            let (type, f) = visualFields(v)
            w(" visual \(type) \(f.map { "\($0.0)=\($0.1)" }.joined(separator: " "))")
        }
    }
    for m in def.mechs {
        let kind: String
        switch m.kind {
        case let .rotator(pivot, axis): kind = "rotator pivot=\(v3(pivot)) axis=\(v3(axis))"
        case let .slider(axis, step): kind = "slider axis=\(v3(axis)) step=\(num(step))"
        case let .lift(poses): kind = "lift poses=\(poses.map(v3).joined(separator: ";"))"
        }
        let c = m.control
        w("mech \(m.id) \(kind) initial=\(m.initial) rider=\(m.rider) states=\(m.states.map(String.init).joined(separator: ",")) control=\(c.type.rawValue)/\(c.body ?? "-")/\(c.at.map(v3) ?? "-")/\(c.requires ?? "-") name=\(m.name ?? "-") duration=\(m.duration.map(num) ?? "-")")
    }
    for p in def.plates {
        let acts = p.actions.map { a -> String in
            switch a {
            case let .flag(f): return "flag:\(f)"
            case let .mech(m, to): return "mech:\(m):\(to)"
            case let .turn(m, by): return "turn:\(m):\(by)"
            }
        }.joined(separator: ";")
        w("plate \(p.id) tile=\(p.tile) actions=\(acts) title=\(p.title ?? "-")")
    }
    for z in def.zones {
        w("zone \(z.id) title=\(z.title ?? "-") target=\(v3(z.target)) size=\(num(z.size)) mood=\(z.mood) hints=\(z.hints.joined(separator: "|"))")
    }

    for m in def.mechs {
        let lo = Double(m.states.min()!), hi = Double(m.states.max()!)
        for i in 0...8 {
            let p = lo - 0.5 + ((hi - lo + 1) * Double(i)) / 8
            w("mechMatrix \(m.id) \(num(p)) \(elements(logic.mechMatrix(m, p)).map(num).joined(separator: ","))")
        }
    }
    let mats = logic.bodyMatrices(logic.initialState().mech)
    for b in logic.order { w("bodyMatrix \(b.id) \(elements(mats[b.id]!).map(num).joined(separator: ","))") }
    for m in def.mechs { w("movedBy \(m.id) \(logic.bodiesMovedBy(m.id).joined(separator: ","))") }
    for s in logic.worldSolids(mats) { w("worldSolid \(s.body) \(v3(s.min)) \(v3(s.max))") }

    let p0 = Puzzle(logic)
    dumpGraph(logic.graphKey(p0.state), p0.graph())

    let t0 = now()
    let res = solve(Puzzle(logic), checkDeadEnds: true)
    let t1 = now()
    FileHandle.standardError.write("Swift full solve: \(Int(t1 - t0)) ms\n".data(using: .utf8)!)
    w("solve solved=\(res.solved) states=\(res.states) deadEnds=\(res.deadEnds.count) planLength=\(res.plan.count)")
    for a in res.plan { w(" plan \(fmtA(a))") }
    for k in res.deadEnds { w(" deadEnd \(k)") }
    for (i, e) in res.all.enumerated() { w(" state \(i) \(e.key)") }

    let p = Puzzle(logic)
    var step = 0
    while step <= res.plan.count {
        dumpGraph("step\(step) \(logic.graphKey(p.state)) char=\(p.charNode) flags=\(p.state.flags.joined(separator: "+"))", p.graph())
        let n = p.state.flags.count
        let h = solve(p.clone(), maxStates: 20000, stopWhen: { $0.state.flags.count > n })
        w("hint \(step) solved=\(h.solved) states=\(h.states) first=\(h.solved && !h.plan.isEmpty ? fmtA(h.plan[0]) : "-") plan=\(h.plan.map(fmtA).joined(separator: " "))")
        if step == res.plan.count { break }
        switch res.plan[step] {
        case let .walk(to):
            let path = findPath(p.graph(), p.charNode, to) ?? [p.charNode]
            w("path \(path.joined(separator: " "))")
            for e in p.walk(path) {
                w("effect \(e.plate.id) \(e.mechChanges.map { "\($0.mech):\($0.from)->\($0.to)" }.joined(separator: ",")) flags=\(e.flags.joined(separator: ","))")
            }
        case let .mech(mech, to):
            for m in def.mechs { w("canOperate \(m.id) \(p.canOperate(m.id)?.rawValue ?? "ok")") }
            w("canSetState \(mech) \(to) \(p.canSetState(mech, to)?.rawValue ?? "ok")")
            p.setMech(mech, to)
        case let .cam(dir):
            p.rotateWorld(dir)
        }
        step += 1
    }
    w("atGoal \(p.atGoal())")

    var params = logic.initialState().mech.mapValues { Double($0) }
    params["r1"] = 1.5
    params["el4"] = 0.5
    dumpGraph("fractional", logic.buildGraph(params, cam: 3, exclude: ["s2"]))

    print(outLines.joined(separator: "\n"))
}

// MARK: - Tests

var failures = 0
var passes = 0
func check(_ cond: Bool, _ msg: @autoclosure () -> String) {
    if cond { passes += 1 } else { failures += 1; print("FAIL: \(msg())") }
}

struct Box3 { var min: V3; var max: V3 }
func box3Apply(_ mn: V3, _ mx: V3, _ m: simd_double4x4) -> Box3 {
    var lo = V3(.infinity, .infinity, .infinity), hi = V3(-.infinity, -.infinity, -.infinity)
    for i in 0..<8 {
        let c = JSMat.apply(V3(i & 1 != 0 ? mx.x : mn.x, i & 2 != 0 ? mx.y : mn.y, i & 4 != 0 ? mx.z : mn.z), m)
        lo = V3(jsMin(lo.x, c.x), jsMin(lo.y, c.y), jsMin(lo.z, c.z))
        hi = V3(jsMax(hi.x, c.x), jsMax(hi.y, c.y), jsMax(hi.z, c.z))
    }
    return Box3(min: lo, max: hi)
}

func runTests() {
    for c in CHAPTERS {
        print("── chapter \(c.numeral) · \(c.title)")
        runTests(c.build(), timings: c.grand)
    }
    print("\(passes) checks passed, \(failures) failed")
    if failures > 0 { exit(1) }
}

/// Prints each chapter's shortest solution (design aid).
func runPlans() {
    for c in CHAPTERS where !c.grand {
        let def = c.build()
        let logic = LevelLogic(def)
        let res = solve(Puzzle(logic), checkDeadEnds: true)
        print("\(c.numeral) \(c.title): solved=\(res.solved) states=\(res.states) deadEnds=\(res.deadEnds.count) plan=\(res.plan.count)")
        let p = Puzzle(logic)
        for a in res.plan {
            switch a {
            case let .walk(to):
                let path = findPath(p.graph(), p.charNode, to) ?? [p.charNode]
                p.walk(path)
                print("  walk \(to)  → at \(p.charNode)")
            case let .mech(m, to): p.setMech(m, to); print("  \(m) → \(to)")
            case let .cam(d): p.rotateWorld(d); print("  cam \(d) → q\(p.state.cam)")
            }
        }
        for k in res.deadEnds.prefix(5) { print("  deadEnd \(k)") }
    }
}

func runTests(_ def: LevelDef, timings: Bool) {
    let logic = LevelLogic(def)

    // ── level integrity
    do {
        var ids = Set<String>()
        for b in def.bodies {
            check(!ids.contains(b.id), "duplicate body \(b.id)")
            ids.insert(b.id)
            var tiles = Set<String>()
            for t in b.tiles {
                check(!tiles.contains(t.id), "duplicate tile \(b.id)/\(t.id)")
                tiles.insert(t.id)
            }
        }
    }
    do {
        let g = logic.graph(logic.initialState())
        check(g.has(def.start), "start not in initial graph")
        let all = Set(def.bodies.flatMap { b in b.tiles.map { "\(b.id)/\($0.id)" } })
        check(all.contains(def.goal), "goal tile missing")
        for p in def.plates { check(all.contains(p.tile), "plate tile missing \(p.tile)") }
    }

    let t0 = now()
    let res = solve(Puzzle(logic), checkDeadEnds: true)
    let t1 = now()
    print("Swift full solve (checkDeadEnds): \(String(format: "%.0f", t1 - t0)) ms, \(res.states) states, plan \(res.plan.count) actions")

    do {
        var used = Set<String>()
        for e in res.all {
            let g = e.puzzle.graph()
            for n in g.nodeList { for l in g.links(n.id) where l.seam { used.insert(n.id) } }
        }
        let seamTiles = def.bodies.flatMap { b in b.tiles.filter { $0.edges.contains { $0.seam } }.map { "\(b.id)/\($0.id)" } }
        for t in seamTiles { check(used.contains(t), "seam tile \(t) never links") }
    }

    // ── solver
    check(res.solved, "the level is solvable")
    check(res.deadEnds.isEmpty, "dead ends: \(res.deadEnds.prefix(10))")
    do {
        var seen = Set<String>()
        for e in res.all {
            let k = def.mechs.map { "\($0.id):\(e.puzzle.state.mech[$0.id]!)" }.joined(separator: ",")
            if seen.contains(k) { continue }
            seen.insert(k)
            let ov = logic.overlaps(e.puzzle.state.mech).filter { $0.0.max.y > -12 || $0.1.max.y > -12 }
            check(ov.isEmpty, "overlaps \(ov.map { "\($0.0.body)×\($0.1.body)" }) @ \(k)")
        }
    }
    do {
        // Ablation: freezing any mechanism (or the camera) must make the level unsolvable.
        for m in def.mechs {
            var frozen = def
            frozen.mechs = def.mechs.map { x in
                var y = x
                if x.id == m.id { y.states = [x.initial] }
                return y
            }
            frozen.plates = def.plates.map { p in
                var q = p
                q.actions = p.actions.filter { a in
                    if case let .mech(id, _) = a { return id != m.id }
                    return true
                }
                return q
            }
            let r = solve(Puzzle(LevelLogic(frozen)))
            check(!r.solved, "level solvable without moving \(m.id)")
        }
        if def.rotateFlag != "__never__" {
            var noCam = def
            noCam.rotateFlag = "__never__"
            check(!solve(Puzzle(LevelLogic(noCam))).solved, "solvable without world rotation")
        }
    }
    do {
        let p = Puzzle(logic)
        let g = p.graph()
        for n in g.nodeList { for l in g.links(n.id) { check(!l.seam, "seam link at start \(n.id)→\(l.to)") } }
        check(findPath(g, def.start, def.start) == [def.start], "findPath start→start")
    }

    // ── support
    struct Item { var body: String; var box: Box3; var label: String }
    func items(_ params: [String: Double]) -> [Item] {
        let mats = logic.bodyMatrices(params)
        var out: [Item] = []
        func push(_ body: String, _ mn: V3, _ mx: V3, _ label: String) {
            out.append(Item(body: body, box: box3Apply(mn, mx, mats[body]!), label: label))
        }
        for b in def.bodies {
            for s in b.solids { push(b.id, s.min, s.max, "solid") }
            for v in b.visuals {
                switch v.kind {
                case let .box(mn, mx, _, _, _): push(b.id, mn, mx, "box")
                case let .pillar(x, z, y0, y1, r, _): push(b.id, V3(x - r, y0, z - r), V3(x + r, y1, z + r), "pillar")
                case let .column(x, z, y0, y1, r, _): push(b.id, V3(x - r, y0, z - r), V3(x + r, y1, z + r), "column")
                case let .arch(x, z, axis, y0, y1, span, thick, _, _, _, _):
                    let half = span / 2, t = thick / 2, ax = axis == .x
                    push(b.id, V3(x - (ax ? half : t), y0, z - (ax ? t : half)), V3(x + (ax ? half : t), y1, z + (ax ? t : half)), "arch")
                default: break
                }
            }
        }
        return out
    }
    func touches(_ a: Box3, _ b: Box3, _ eps: Double = 0.03) -> Bool {
        a.min.x <= b.max.x + eps && a.max.x >= b.min.x - eps &&
            a.min.y <= b.max.y + eps && a.max.y >= b.min.y - eps &&
            a.min.z <= b.max.z + eps && a.max.z >= b.min.z - eps
    }
    func floating(_ params: [String: Double]) -> [Item] {
        let list = items(params)
        let rides = Set(def.bodies.filter { $0.rides }.map { $0.id })
        var grounded = list.map { $0.box.min.y <= CLOUD + 0.5 || rides.contains($0.body) }
        var changed = true
        while changed {
            changed = false
            for i in 0..<list.count where !grounded[i] {
                for j in 0..<list.count where grounded[j] && touches(list[i].box, list[j].box) {
                    grounded[i] = true; changed = true; break
                }
            }
        }
        return list.enumerated().filter { !grounded[$0.offset] }.map { $0.element }
    }
    func lastState(_ m: MechDef) -> Double { m.isLift ? Double(m.states.last!) : Double(m.initial) }
    do {
        var p: [String: Double] = [:]
        for m in def.mechs { p[m.id] = lastState(m) }
        let f = floating(p).map { "\($0.body) \($0.label) \(v3($0.box.min))" }
        check(f.isEmpty, "floating once lifts risen: \(f)")
    }
    do {
        var p: [String: Double] = [:]
        for m in def.mechs { p[m.id] = Double(m.initial) }
        let f = floating(p).map { "\($0.body) \($0.label)" }
        check(f.isEmpty, "floating in initial state: \(f)")
    }
    do {
        var p: [String: Double] = [:]
        for m in def.mechs { p[m.id] = Double(m.initial) }
        let mats = logic.bodyMatrices(p)
        for m in def.mechs {
            guard case let .lift(poses) = m.kind, m.initial == 0, poses[0].y < -5 else { continue }
            for bid in logic.bodiesMovedBy(m.id) {
                let b = def.bodies.first { $0.id == bid }!
                for s in b.solids {
                    let top = box3Apply(s.min, s.max, mats[bid]!).max.y
                    check(top < -9.5, "\(bid) pokes out of the clouds")
                }
            }
        }
    }
    // ── motion
    do {
        var base: [String: Double] = [:]
        for m in def.mechs { base[m.id] = lastState(m) }
        var hits: [String] = []
        for m in def.mechs where !m.isRotator {
            let moving = Set(logic.bodiesMovedBy(m.id))
            let lo = Double(m.states.min()!), hi = Double(m.states.max()!)
            for i in 0...40 {
                var p = base
                p[m.id] = lo + ((hi - lo) * Double(i)) / 40
                let solids = logic.worldSolids(logic.bodyMatrices(p))
                for a in solids where moving.contains(a.body) {
                    for b in solids where !moving.contains(b.body) {
                        if a.max.y < CLOUD + 6 && b.max.y < CLOUD + 6 { continue }
                        func o(_ k: Int) -> Double { min(a.max[k], b.max[k]) - max(a.min[k], b.min[k]) }
                        if o(0) > 0.03 && o(1) > 0.03 && o(2) > 0.03 { hits.append("\(a.body)×\(b.body)") }
                    }
                }
            }
        }
        check(hits.isEmpty, "motion collisions: \(Set(hits))")
    }

    // ── thread-safety smoke test: hint solver on background threads while the main thread queries graphs
    do {
        let group = DispatchGroup()
        var results = [Bool](repeating: false, count: 4)
        let lock = NSLock()
        for i in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                let r = solve(Puzzle(logic), maxStates: 20000, stopWhen: { $0.state.flags.count > 1 })
                lock.lock(); results[i] = r.solved; lock.unlock()
                group.leave()
            }
        }
        for e in res.all.prefix(3000) { _ = e.puzzle.graph().count }
        group.wait()
        check(results.allSatisfy { $0 }, "concurrent hint solves")
    }

    // ── timings
    if timings {
        let st = logic.initialState()
        let n = 200
        let a = now()
        for _ in 0..<n { _ = logic.buildGraph(st.mech, cam: st.cam) }
        let b = now()
        print("Swift single graph build (uncached): \(String(format: "%.3f", (b - a) / Double(n))) ms")
        let p = Puzzle(logic)
        let c = now()
        let h = solve(p.clone(), maxStates: 20000, stopWhen: { $0.state.flags.count > 0 })
        let d = now()
        print("Swift hint query from start (warm cache): \(String(format: "%.1f", d - c)) ms, \(h.states) states")
        // worst hint query along the solution (fresh logic = cold graph cache, like a new game)
        let hl = LevelLogic(def)
        let hp = Puzzle(hl)
        var worst = 0.0, worstStep = 0, total = 0.0
        for (i, a) in res.plan.enumerated() {
            let n = hp.state.flags.count
            let s0 = now()
            _ = solve(hp.clone(), maxStates: 20000, stopWhen: { $0.state.flags.count > n })
            let dt = now() - s0
            total += dt
            if dt > worst { worst = dt; worstStep = i }
            switch a {
            case let .walk(to): hp.walk(findPath(hp.graph(), hp.charNode, to) ?? [hp.charNode])
            case let .mech(m, to): hp.setMech(m, to)
            case let .cam(dir): hp.rotateWorld(dir)
            }
        }
        print("Swift hint queries along the solution: worst \(String(format: "%.1f", worst)) ms (step \(worstStep)), total \(String(format: "%.0f", total)) ms")
        let freshLogic = LevelLogic(def)
        let e = now()
        _ = solve(Puzzle(freshLogic), maxStates: 20000, stopWhen: { $0.state.flags.count > 0 })
        let f = now()
        print("Swift hint query from start (cold cache): \(String(format: "%.1f", f - e)) ms")
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "test"
if mode == "dump" { runDump() } else if mode == "plans" { runPlans() } else { runTests() }
