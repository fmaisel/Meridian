// CharacterController: follows a node path over the nav graph with eased speed, crosses perspective
// seams by jumping along the view axis (invisible on screen) and reports node arrivals
// (port of src/game/CharacterController.ts).

import Foundation
import simd

private struct Waypoint {
    var p: V3
    var node: String?
    var jump: V3?
    var seam = false
}

private let MAX_SPEED = 2.35
private let ACCEL = 9.0

final class CharacterController {
    var pos = V3.zero
    var node: String
    private(set) var walking = false
    private var wps: [Waypoint] = []
    private var speed = 0.0
    private var stopAtNext = false
    private var retarget: String?
    private var overlay = false
    private var stepCount = 0
    let view: CharacterView

    /// Called on arrival at each node; return false to halt.
    var onArrive: (String, Bool) -> Bool = { _, _ in true }
    /// Recompute a path from the current node (used when the player taps while walking).
    var repath: (String, String) -> [String]? = { _, _ in nil }
    /// Current walkable graph (to validate the next link).
    var graph: () -> NavGraph = { fatalError("graph not set") }
    var onStep: (Int) -> Void = { _ in }

    init(view: CharacterView, start: String) {
        self.view = view
        node = start
    }

    func follow(_ path: [String], _ g: NavGraph) {
        wps = build(path, g)
        walking = !wps.isEmpty
        stopAtNext = false
        retarget = nil
    }

    /// Re-route at the next node.
    func redirect(_ target: String) { retarget = target }

    func requestStop() {
        if walking { stopAtNext = true }
    }

    private func build(_ path: [String], _ g: NavGraph) -> [Waypoint] {
        var out: [Waypoint] = []
        var i = 0
        while i + 1 < path.count {
            guard let link = g.links(path[i]).first(where: { $0.to == path[i + 1] }), let next = g.node(path[i + 1]) else { break }
            out.append(Waypoint(p: link.a, node: nil, jump: link.seam ? link.b : nil, seam: link.seam))
            out.append(Waypoint(p: next.pos, node: next.id))
            i += 1
        }
        return out
    }

    private func remaining() -> Double {
        var d = 0.0
        var prev = pos
        for w in wps {
            d += simd_distance(prev, w.p)
            if w.node != nil && stopAtNext { return d }
            prev = w.jump ?? w.p
        }
        return d
    }

    private func halt() {
        wps = []
        walking = false
        speed = 0
        setOverlay(false)
    }

    private func setOverlay(_ on: Bool) {
        if on != overlay {
            overlay = on
            view.setOverlay(on)
        }
    }

    func update(_ dt: Double) {
        if !walking { return }
        let rem = remaining()
        let brake = (2 * ACCEL * 0.55 * max(0, rem)).squareRoot()
        speed = min(MAX_SPEED, speed + ACCEL * dt, max(0.6, brake))
        var budget = speed * dt
        while budget > 0 && !wps.isEmpty {
            let w = wps[0]
            let to = w.p
            let d = simd_distance(pos, to)
            if w.seam { setOverlay(true) }
            if d > 1e-5 { view.face(to.x - pos.x, to.z - pos.z) }
            if d <= budget {
                pos = to
                budget -= d
                wps.removeFirst()
                if let j = w.jump { pos = j }
                if let n = w.node {
                    node = n
                    onStep(stepCount)
                    stepCount += 1
                    if !arrive(n) { return }
                }
            } else {
                pos += simd_normalize(to - pos) * budget
                budget = 0
            }
        }
        if wps.isEmpty { halt() }
    }

    private func arrive(_ node: String) -> Bool {
        let final = wps.isEmpty
        if !final { setOverlay(wps[0].seam) } else { setOverlay(false) }
        let ok = onArrive(node, final)
        if !ok || stopAtNext {
            halt()
            return false
        }
        if let t = retarget {
            retarget = nil
            guard let path = repath(node, t) else { halt(); return false }
            wps = build(path, graph())
            if wps.isEmpty { halt(); return false }
            return true
        }
        if !final {
            // validate the next link still exists (architecture may have moved)
            let nextNode = wps.first(where: { $0.node != nil })?.node
            let ok2 = nextNode.map { nn in graph().links(node).contains { $0.to == nn } } ?? false
            if !ok2 { halt(); return false }
        }
        return true
    }
}
