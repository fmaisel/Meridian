// Deterministic puzzle rules on top of LevelLogic. Port of src/logic/Puzzle.ts.

import Foundation

enum OperateBlock: String {
    case noControl = "no-control"
    case locked
    case occupied
    case invalidState = "invalid-state"
    case strands
}

struct PlateEffect {
    var plate: PlateDef
    /// `by` is set for step-switch turns (notches advanced, so the view can keep turning the same way).
    var mechChanges: [(mech: String, from: Int, to: Int, by: Int?)]
    var flags: [String]
}

/// Holds the authoritative state: mechanism states, flags, camera quadrant and the node the character stands on.
final class Puzzle {
    let logic: LevelLogic
    var state: PuzzleState { didSet { graphMemo = nil } }
    var charNode: String
    private var graphMemo: NavGraph?

    init(_ logic: LevelLogic, state: PuzzleState? = nil, charNode: String? = nil) {
        self.logic = logic
        self.state = state.map(cloneState) ?? logic.initialState()
        self.charNode = charNode ?? logic.def.start
    }

    func clone() -> Puzzle {
        Puzzle(logic, state: state, charNode: charNode)
    }

    func graph() -> NavGraph {
        if let g = graphMemo { return g }
        let g = logic.graph(state)
        graphMemo = g
        return g
    }

    func hasFlag(_ f: String) -> Bool {
        state.flags.contains(f)
    }

    func addFlag(_ f: String) {
        if !hasFlag(f) {
            state.flags.append(f)
            state.flags.sort()
        }
    }

    var canRotateWorld: Bool {
        hasFlag(logic.def.rotateFlag)
    }

    func path(to: String) -> [String]? {
        findPath(graph(), charNode, to)
    }

    func plateAt(_ node: String) -> PlateDef? {
        logic.plateByNode[node]
    }

    /// Character arrives at a node. Applies one-shot plate effects (state changes happen immediately).
    @discardableResult
    func visit(_ node: String) -> PlateEffect? {
        charNode = node
        guard let plate = logic.plateByNode[node] else { return nil }
        if !plate.repeatable {
            let pf = "plate:\(plate.id)"
            if hasFlag(pf) { return nil }
            addFlag(pf)
        }
        var eff = PlateEffect(plate: plate, mechChanges: [], flags: [])
        for a in plate.actions { applyAction(a, &eff) }
        return eff
    }

    private func applyAction(_ a: PlateAction, _ eff: inout PlateEffect) {
        switch a {
        case let .flag(f):
            addFlag(f)
            eff.flags.append(f)
        case let .mech(mech, to):
            let from = state.mech[mech] ?? -1
            state.mech[mech] = to
            eff.mechChanges.append((mech: mech, from: from, to: to, by: nil))
        case let .turn(mech, by):
            let states = logic.mechs[mech]!.states
            let from = state.mech[mech] ?? states[0]
            let i = states.firstIndex(of: from) ?? 0
            let to = states[((i + by) % states.count + states.count) % states.count]
            state.mech[mech] = to
            eff.mechChanges.append((mech: mech, from: from, to: to, by: by))
        }
    }

    /// Visiting every node along a path (used by the solver; the game visits incrementally).
    /// The wanderer halts on a step switch while the mechanism it drives turns, exactly as in the game.
    @discardableResult
    func walk(_ path: [String]) -> [PlateEffect] {
        var out: [PlateEffect] = []
        for n in path.dropFirst() {
            if let e = visit(n) {
                out.append(e)
                if e.plate.repeatable { break }
            }
        }
        return out
    }

    func mechCarriesCharacter(_ m: MechDef) -> Bool {
        guard let node = graph().node(charNode) else { return false }
        return logic.bodiesMovedBy(m.id).contains(node.body)
    }

    func canOperate(_ mechId: String) -> OperateBlock? {
        let m = logic.mechs[mechId]!
        if m.control.type == .none { return .noControl }
        if let r = m.control.requires, !hasFlag(r) { return .locked }
        if !m.rider && mechCarriesCharacter(m) { return .occupied }
        return nil
    }

    /// Can the mechanism be set to `to` from the current state (without stranding the character off-graph)?
    func canSetState(_ mechId: String, _ to: Int) -> OperateBlock? {
        if let block = canOperate(mechId) { return block }
        let m = logic.mechs[mechId]!
        if !m.states.contains(to) { return .invalidState }
        var probe = cloneState(state)
        probe.mech[mechId] = to
        if !logic.graph(probe).has(charNode) { return .strands }
        return nil
    }

    func setMech(_ mechId: String, _ to: Int) {
        state.mech[mechId] = to
    }

    func rotateWorld(_ dir: Int) {
        state.cam = (((state.cam + dir) % 4) + 4) % 4
    }

    func atGoal() -> Bool {
        charNode == logic.def.goal
    }
}

func cloneState(_ s: PuzzleState) -> PuzzleState {
    PuzzleState(mech: s.mech, flags: s.flags, cam: s.cam)
}
