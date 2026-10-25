// Exhaustive breadth-first puzzle solver. Port of src/logic/solver.ts with identical exploration order.

import Foundation

enum Action: Equatable, Hashable {
    case walk(to: String)
    case mech(String, to: Int)
    case cam(dir: Int)
}

struct SolveResult {
    var solved: Bool
    /// Actions from the start state to the goal (shortest in number of actions).
    var plan: [Action]
    var states: Int
    /// Keys of reachable states from which the goal can no longer be reached (discovery order).
    var deadEnds: [String]
    /// Reachable states in discovery order (== iteration order of the TS `all` Map).
    var all: [(key: String, puzzle: Puzzle)]
}

/// Canonical character position: the first node of the same body within the same connected component.
private func canonical(_ p: Puzzle) -> String {
    let g = p.graph()
    guard let node = g.node(p.charNode), !p.atGoal() else { return p.charNode }
    return g.canonicalId(from: node.index)
}

func stateKey(_ p: Puzzle) -> String {
    var m = ""
    for (i, d) in p.logic.def.mechs.enumerated() {
        if i > 0 { m += "," }
        if let v = p.state.mech[d.id] { m += String(v) }
    }
    return m + "|" + p.state.flags.joined(separator: "+") + "|" + String(p.state.cam) + "|" + canonical(p)
}

/// Successor states via abstract actions (walks to interesting nodes, mechanism moves, world rotation).
func successors(_ p: Puzzle) -> [(action: Action, next: Puzzle)] {
    var out: [(action: Action, next: Puzzle)] = []
    let g = p.graph()
    let goal = p.logic.def.goal

    if let start = g.index[p.charNode] {
        let compIds = g.sortedComponent(from: start).map { g.nodeList[$0].id }

        // walks: plates not yet pressed, the goal, one representative per body (for riding / standing aside)
        var targets: [String] = []
        var targetSet = Set<String>()
        func addTarget(_ id: String) { if targetSet.insert(id).inserted { targets.append(id) } }
        var seenBodies = Set<String>()
        for id in compIds {
            if id == p.charNode { continue }
            let n = g.node(id)!
            if let plate = p.plateAt(id), plate.repeatable || !p.hasFlag("plate:\(plate.id)") { addTarget(id) }
            if id == goal { addTarget(id) }
            if seenBodies.insert(n.body).inserted { addTarget(id) }
        }
        for t in targets {
            guard let path = findPathIndices(g, start, g.index[t]!) else { continue }
            let next = p.clone()
            next.walk(path.map { g.nodeList[$0].id })
            out.append((action: .walk(to: t), next: next))
        }
    }

    for m in p.logic.def.mechs {
        for s in m.states {
            if s == p.state.mech[m.id] { continue }
            if p.canSetState(m.id, s) != nil { continue }
            let next = p.clone()
            next.setMech(m.id, s)
            out.append((action: .mech(m.id, to: s), next: next))
        }
    }

    if p.canRotateWorld {
        for dir in [1, -1] {
            let next = p.clone()
            next.rotateWorld(dir)
            out.append((action: .cam(dir: dir), next: next))
        }
    }
    return out
}

/// Exhaustive breadth-first search over the puzzle state space.
func solve(_ start: Puzzle, maxStates: Int = 200000, checkDeadEnds: Bool = false,
           stopWhen: ((Puzzle) -> Bool)? = nil) -> SolveResult {
    let max = maxStates
    var index: [String: Int] = [:]
    var keys: [String] = []
    var puzzles: [Puzzle] = []
    var parents: [Int] = []
    var actions: [Action?] = []
    var edges: [[Int]?] = []

    let k0 = stateKey(start)
    index[k0] = 0
    keys.append(k0)
    puzzles.append(start.clone())
    parents.append(-1)
    actions.append(nil)
    edges.append(nil)
    var queue = [0]
    var head = 0
    var goalIdx = -1
    var goals: [Int] = []

    while head < queue.count && keys.count < max {
        let ki = queue[head]
        head += 1
        let cur = puzzles[ki]
        if cur.atGoal() || (stopWhen != nil && ki != 0 && stopWhen!(cur)) {
            goals.append(ki)
            if goalIdx < 0 { goalIdx = ki }
            if !checkDeadEnds { break }
            continue
        }
        let succ = successors(cur)
        var list: [Int] = []
        list.reserveCapacity(succ.count)
        for (action, next) in succ {
            let nk = stateKey(next)
            if let ni = index[nk] {
                list.append(ni)
            } else {
                let ni = keys.count
                index[nk] = ni
                keys.append(nk)
                puzzles.append(next)
                parents.append(ki)
                actions.append(action)
                edges.append(nil)
                queue.append(ni)
                list.append(ni)
            }
        }
        edges[ki] = list
    }

    var plan: [Action] = []
    if goalIdx >= 0 {
        var c = goalIdx
        while c >= 0, let a = actions[c] {
            plan.append(a)
            c = parents[c]
        }
        plan.reverse()
    }

    var deadEnds: [String] = []
    if checkDeadEnds {
        var rev = [[Int]](repeating: [], count: keys.count)
        for (a, list) in edges.enumerated() {
            guard let list else { continue }
            for b in list { rev[b].append(a) }
        }
        var ok = [Bool](repeating: false, count: keys.count)
        for gi in goals { ok[gi] = true }
        var stack = goals
        while let c = stack.popLast() {
            for p in rev[c] where !ok[p] {
                ok[p] = true
                stack.append(p)
            }
        }
        for i in 0..<keys.count where !ok[i] { deadEnds.append(keys[i]) }
    }

    var all: [(key: String, puzzle: Puzzle)] = []
    all.reserveCapacity(keys.count)
    for i in 0..<keys.count { all.append((key: keys[i], puzzle: puzzles[i])) }
    return SolveResult(solved: goalIdx >= 0, plan: plan, states: keys.count, deadEnds: deadEnds, all: all)
}
