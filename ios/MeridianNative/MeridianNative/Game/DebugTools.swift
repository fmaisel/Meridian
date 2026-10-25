// DebugTools: visualises nav nodes, links (seams in magenta), solids and the puzzle state
// (port of src/game/Debug.ts). Toggled with a three-finger tap.

import Foundation

final class DebugTools {
    private(set) var enabled = false
    private let logic: LevelLogic
    private let r: Renderer

    init(logic: LevelLogic, renderer: Renderer) {
        self.logic = logic
        r = renderer
    }

    func toggle(_ on: Bool? = nil) {
        enabled = on ?? !enabled
        r.debugEnabled = enabled
    }

    func rebuild(_ graph: NavGraph, _ params: [String: Double]) {
        r.debugPoints = []
        r.debugLines = []
        r.debugSeams = []
        r.debugBoxes = []
        if !enabled { return }
        func lv(_ p: V3, _ c: F3) -> LineVertex { LineVertex(p: (Float(p.x), Float(p.y), Float(p.z)), c: (c.x, c.y, c.z)) }
        for n in graph.nodeList {
            let c = n.tags.contains { $0.hasPrefix("plate") } ? color("#00a08a") : n.tags.contains("goal") ? color("#e0a020") : color("#3050ff")
            r.debugPoints.append(lv(n.pos + V3(0, 0.05, 0), c))
        }
        let walk = color("#2040ff"), seam = color("#ff00c8")
        for n in graph.nodeList {
            let a = n.pos
            for l in graph.links(n.id) {
                if l.to < n.id && !l.seam { continue }
                let b = graph.node(l.to)!.pos
                let up = V3(0, 0.06, 0)
                if l.seam {
                    r.debugSeams += [lv(a + up, seam), lv(l.a + up, seam), lv(l.a + up, seam), lv(l.b + up, seam), lv(l.b + up, seam), lv(b + up, seam)]
                } else {
                    r.debugLines += [lv(a + up, walk), lv(b + up, walk)]
                }
            }
        }
        let box = color("#ff6040")
        for s in logic.worldSolids(logic.bodyMatrices(params)) {
            let mn = s.min, mx = s.max
            let c = (0..<8).map { i in V3(i & 1 != 0 ? mx.x : mn.x, i & 2 != 0 ? mx.y : mn.y, i & 4 != 0 ? mx.z : mn.z) }
            for (a, b) in [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)] {
                r.debugBoxes += [lv(c[a], box), lv(c[b], box)]
            }
        }
    }

    func describe(_ p: Puzzle, fps: Double, extra: String) -> String {
        let mechs = logic.def.mechs.map { "\($0.id):\(p.state.mech[$0.id]!)" }.joined(separator: "  ")
        return [
            "fps \(Int(fps.rounded()))   cam q\(p.state.cam)",
            "at \(p.charNode)",
            "mechs \(mechs)",
            "flags \(p.state.flags.isEmpty ? "—" : p.state.flags.joined(separator: ", "))",
            extra,
            "",
            "three-finger tap: toggle debug",
        ].joined(separator: "\n")
    }
}
