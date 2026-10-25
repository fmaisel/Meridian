// Game: orchestrates rendering, puzzle state, navigation, character, input, UI, audio and progress
// (port of src/game/Game.ts). Runs on the main thread, driven by the display link of the Metal view;
// the hint solver runs on a background queue.

import Foundation
import QuartzCore
import simd

enum Mode { case title, select, intro, play, ending }

private let BLOCK_WHISPER: [OperateBlock: String] = [
    .locked: "It will not move yet.",
    .occupied: "Not while you stand upon it.",
    .strands: "That would leave you nowhere to stand.",
]

private struct Drag {
    var mech: MechDef
    var handle: HandleView
    var startParam: Double
    var startX: Double
    var startY: Double
    var started: Bool
    var lastX: Double
    var lastY: Double
    var angle0: Double
    var lastDetent: Int
    var lastParam: Double
    var lastT: Double
}

private struct CutWindow {
    var p: V3
    var r: Double
    var w: Double
    var target: Double
}

final class Game {
    let renderer: Renderer
    let scene = Node("scene")
    private(set) var chapter: ChapterDef
    private(set) var logic: LevelLogic
    var puzzle: Puzzle
    private(set) var view: LevelView
    let env: Environment
    let rig = CameraRig()
    let charView: CharacterView
    var char: CharacterController
    let anim = Animator()
    let effects: Effects
    let audio = AudioManager()
    let haptics = Haptics()
    let ui: UIState
    private(set) var debug: DebugTools
    let mats: MaterialLibrary

    var params: [String: Double] = [:]
    private var busy = Set<String>()
    private var drag: Drag?
    private var rotating: Int?
    private var pendingRotate: Int?
    private var prevGraph: NavGraph?
    private var liveKey = ""
    private var liveCache: NavGraph?
    private var zone: ZoneDef?
    private var seen = Set<String>()
    private(set) var mode: Mode = .title
    private var time = 0.0
    private var idle = 0.0
    private var hintStage = 0
    private var hovered: String?
    private var nodeLocal: [String: (body: String, local: V3)] = [:]
    private(set) var fpsAvg = 60.0
    private var turnTaught = false
    private var inputLock = false
    private var hintBusy = false
    /// Where each mechanism is heading (step switches keep turning the same way) and how to stop its tween.
    private var mechGoal: [String: Double] = [:]
    private var mechTween: [String: () -> Void] = [:]

    /// View size in points and the camera matrices of the last frame (for picking and projection).
    private(set) var viewSize = CGSize(width: 390, height: 844)
    private var camViewProj = M4.identity
    private var camWorld = M4.identity

    /// Objects added by the finale (removed when a new journey starts).
    var finaleObjects: [Node] = []

    init(renderer: Renderer) {
        self.renderer = renderer
        mats = MaterialLibrary(tile: renderer.textures.tile)
        // the app opens on the gallery; behind it waits the first (small) diorama, quick to build
        chapter = CHAPTERS[0]
        logic = LevelLogic(chapter.build())
        puzzle = Puzzle(logic)
        view = LevelView(logic: logic, mats: mats, renderer: renderer)
        scene.add(view.root)
        env = Environment(renderer: renderer)
        scene.add(env.group)
        charView = CharacterView(renderer: renderer)
        scene.add(charView.root)
        effects = Effects(anim: anim, renderer: renderer)
        scene.add(effects.group)
        debug = DebugTools(logic: logic, renderer: renderer)

        char = CharacterController(view: charView, start: logic.def.start)
        let settings = Progress.loadSettings()
        ui = UIState(settings: settings)
        wireCharacter()
        ui.handlers = UIHandlers(
            begin: { [unowned self] in showSelect(focus: nil) },
            continueGame: { [unowned self] in showSelect(focus: nil) },
            pause: { [unowned self] on in setPause(on) },
            hint: { [unowned self] in showHint(explicit: true) },
            restart: { [unowned self] in restart() },
            toTitle: { [unowned self] in toTitle() },
            again: { [unowned self] in restart() },
            turn: { [unowned self] d in rotateWorld(d) },
            settingsChanged: { [unowned self] s in applySettings(s) },
            nextStep: { [unowned self] in autoStep() },
            openChapter: { [unowned self] id in openChapter(id) },
            startChapter: { [unowned self] in startChapter() },
            leave: { [unowned self] in leaveChapter() },
            complete: { [unowned self] in showSelect(focus: nextChapterId()) })
        applySettings(settings)

        indexNodes()
        resetWorld()
        rig.frame(chapter.overview.target, chapter.overview.size, snap: true)
        ui.titleShown = false
        showSelect(focus: nil)
        ui.fadeIn()
    }

    private func indexNodes() {
        nodeLocal = [:]
        for b in logic.def.bodies {
            for t in b.tiles { nodeLocal["\(b.id)/\(t.id)"] = (b.id, t.pos) }
        }
    }

    /// Swap the diorama for another chapter's.
    private func load(_ c: ChapterDef) {
        if c.id == chapter.id { return }
        clearFinale()
        anim.cancel("mech")
        chapter = c
        scene.remove(view.root)
        logic = LevelLogic(c.build())
        puzzle = Puzzle(logic)
        view = LevelView(logic: logic, mats: mats, renderer: renderer)
        scene.add(view.root)
        let wasDebug = debug.enabled
        debug.toggle(false)
        debug = DebugTools(logic: logic, renderer: renderer)
        if wasDebug { debug.toggle(true) }
        indexNodes()
        solidsKey = ""
        windows = [:]
        windowKeys = []
        zone = nil
    }

    /// The chapter card data shown in the gallery.
    private func chapterCards() -> [ChapterCard] {
        let done = Progress.completed()
        return CHAPTERS.enumerated().map { i, c in
            ChapterCard(id: c.id, numeral: c.numeral, title: c.title, lines: c.lines, unlocked: Progress.unlocked(i),
                        completed: done.contains(c.id), inProgress: Progress.load(c.id) != nil,
                        petals: c.emblem.petals, tips: c.emblem.tips, centre: c.emblem.centre)
        }
    }

    private func nextChapterId() -> String {
        guard let i = CHAPTERS.firstIndex(where: { $0.id == chapter.id }) else { return chapter.id }
        return i + 1 < CHAPTERS.count ? CHAPTERS[i + 1].id : chapter.id
    }

    // ───────────────────────── state ─────────────────────────

    private func clearFinale() {
        for o in finaleObjects { scene.remove(o) }
        finaleObjects = []
        for m in view.windowMaterials() {
            if let c = m.baseColor { m.color = c }
            m.glow = 0
        }
        view.lamp?.material?.color = color("#d8c7a6")
        env.setBrighten(0)
        charView.glowBoost = 0
    }

    private func resetWorld(_ save: SaveData? = nil) {
        clearFinale()
        anim.cancel("mech")
        mechGoal = [:]
        mechTween = [:]
        busy.removeAll()
        drag = nil
        rotating = nil
        pendingRotate = nil
        if let save, Set(save.state.mech.keys) == Set(logic.def.mechs.map { $0.id }) {
            puzzle = Puzzle(logic, state: save.state, charNode: save.charNode)
        } else {
            puzzle = Puzzle(logic)
        }
        if !puzzle.graph().has(puzzle.charNode) { puzzle = Puzzle(logic) }
        params = [:]
        for m in logic.def.mechs { params[m.id] = Double(puzzle.state.mech[m.id]!) }
        view.pose(params)
        char = CharacterController(view: charView, start: puzzle.charNode)
        wireCharacter()
        seen = Set(save?.seenZones ?? [])
        zone = nil
        rig.setQuadrant(puzzle.state.cam, animate: false)
        for p in logic.def.plates { setPlateGlyph(p.id, puzzle.hasFlag("plate:\(p.id)")) }
        prevGraph = puzzle.graph()
        liveCache = nil
        idle = 0
        hintStage = 0
        turnTaught = puzzle.canRotateWorld
        debug.rebuild(prevGraph!, params)
        updateLocks()
        char.pos = nodeWorld(char.node)
        charView.setOverlay(false)
    }

    /// Handles that still wait for a flag look dormant (grey pins).
    private func updateLocks(announce: Bool = false) {
        for m in logic.def.mechs {
            guard let req = m.control.requires, let h = handleOf(m.id) else { continue }
            let locked = !puzzle.hasFlag(req)
            h.materials[1].color = color(locked ? "#bdb2b8" : "#e9735c")
            h.materials[0].color = color(locked ? "#e6dfe2" : "#fbf3e4")
            if !locked && announce {
                effects.pulseHandle(h, times: 4)
                effects.shimmer(handleWorld(h), color: "#ffe9c0", scale: 2.2)
            }
        }
    }

    private func wireCharacter() {
        let c = char
        c.graph = { [unowned self] in liveGraph() }
        c.repath = { [unowned self] from, to in findPath(liveGraph(), from, to) }
        c.onStep = { [unowned self] i in audio.step(i) }
        c.onArrive = { [unowned self] node, _ in arrive(node) }
    }

    private func save() {
        if mode != .play { return }
        Progress.save(chapter.id, SaveData(state: puzzle.state, charNode: char.node, seenZones: Array(seen).sorted()))
    }

    private func setPlateGlyph(_ plateId: String, _ pressed: Bool) {
        guard let p = logic.def.plates.first(where: { $0.id == plateId }), let loc = nodeLocal[p.tile] else { return }
        view.setPressed(loc.body, loc.local, pressed)
    }

    func nodeWorld(_ id: String) -> V3 {
        guard let loc = nodeLocal[id], let m = view.matrices[loc.body] else { return .zero }
        let p = m * SIMD4<Double>(loc.local, 1)
        return V3(p.x, p.y, p.z) / p.w
    }

    private func movingBodies() -> Set<String> {
        var s = Set<String>()
        for m in busy { for b in logic.bodiesMovedBy(m) { s.insert(b) } }
        if let d = drag { for b in logic.bodiesMovedBy(d.mech.id) { s.insert(b) } }
        return s
    }

    /// Graph usable right now: settled graph, minus bodies that are in motion.
    func liveGraph() -> NavGraph {
        let moving = movingBodies()
        if moving.isEmpty { return puzzle.graph() }
        let key = moving.sorted().joined(separator: ",") + "|" + logic.graphKey(puzzle.state)
        if key != liveKey || liveCache == nil {
            liveKey = key
            liveCache = logic.buildGraph(puzzle.state.mech, cam: puzzle.state.cam, exclude: moving)
        }
        return liveCache!
    }

    private func progressed() {
        idle = 0
        hintStage = 0
    }

    // ───────────────────────── flow ─────────────────────────

    /// The gallery of chapters (over a starry sky); `focus` scrolls to a chapter.
    private func showSelect(focus: String?) {
        audio.start()
        audio.setVolumes(music: ui.settings.music, sfx: ui.settings.sfx)
        if mode == .play { save() }
        ui.setPause(false)
        ui.showEnding(false)
        ui.hideComplete()
        ui.hideIntro()
        ui.turnTutorial(false)
        ui.turnButtons(false)
        mode = .select
        ui.groundFade = false
        ui.hud(false)
        let cards = chapterCards()
        let fallback = cards.firstIndex { $0.unlocked && !$0.completed } ?? cards.lastIndex { $0.unlocked } ?? 0
        ui.showSelect(cards, focus: focus.flatMap { id in cards.firstIndex { $0.id == id } } ?? fallback)
        if ui.titleShown { ui.hideTitle(hud: false) }
    }

    /// From the gallery into a chapter: fade, build its diorama, and show its card while the camera circles.
    private func openChapter(_ id: String) {
        guard let c = chapterDef(id), let i = CHAPTERS.firstIndex(where: { $0.id == id }), Progress.unlocked(i) else { return }
        ui.leaveSelect()
        ui.fadeOut(0.9) { [unowned self] in
            load(c)
            resetWorld(Progress.load(c.id))
            mode = .intro
            rig.followRate = 2.2
            rig.zoomRate = 1.6
            rig.yaw = CameraRig.yawFor(puzzle.state.cam) - 0.5
            let fit = overviewFit(yaw: rig.yaw)
            rig.frame(fit.target + sideShift(fit.size), fit.size, snap: true)
            showGround(logic.def.zones.first?.mood ?? "dawn")
            env.setMood(logic.def.zones.first?.mood ?? "dawn")
            audio.setMood(AUDIO_MOOD[logic.def.zones.first?.mood ?? "dawn"] ?? "dawn")
            ui.hideSelect()
            ui.showIntro(numeral: c.numeral, title: c.title, lines: c.lines, resume: Progress.load(c.id) != nil)
            ui.fadeIn()
        }
    }

    /// The ring on the chapter card: walk in.
    private func startChapter() {
        ui.hideIntro()
        audio.chapter()
        begin()
    }

    private func leaveChapter() {
        ui.setPause(false)
        save()
        ui.fadeOut(0.9) { [unowned self] in
            showSelect(focus: chapter.id)
            ui.fadeIn()
        }
    }

    private func begin() {
        audio.start()
        audio.setVolumes(music: ui.settings.music, sfx: ui.settings.sfx)
        haptics.prepare()
        mode = .play
        ui.groundFade = false
        ui.hud(true)
        ui.playingLabel = "Chapter \(chapter.numeral) · \(chapter.title)"
        rig.setQuadrant(puzzle.state.cam, animate: true, duration: 2.6)
        rig.drift = 1
        let node = puzzle.graph().node(char.node)
        inputLock = true
        anim.add(duration: 1.4, onDone: { [unowned self] in inputLock = false })
        if let node { setZone(node.zone, force: true) }
        ui.turnButtons(ui.settings.turnButtons && puzzle.canRotateWorld)
    }

    private func restart() {
        ui.setPause(false)
        ui.showEnding(false)
        ui.hideComplete()
        ui.fadeOut { [unowned self] in
            Progress.clear(chapter.id)
            env.setBrighten(0)
            mode = .title
            resetWorld()
            begin()
            ui.fadeIn()
        }
    }

    private func toTitle() {
        ui.setPause(false)
        save()
        mode = .title
        ui.hideSelect()
        ui.showTitle(hasSave: true)
    }

    func setPause(_ on: Bool) {
        if mode != .play { return }
        ui.setPause(on)
        audio.setVolumes(music: ui.settings.music * (on ? 0.5 : 1), sfx: ui.settings.sfx)
    }

    /// App went to the background: pause, save, silence.
    func suspend() {
        save()
        if mode == .play && !ui.paused { setPause(true) }
        audio.suspend(true)
    }

    func resume() {
        audio.suspend(false)
    }

    private func applySettings(_ s: Settings) {
        Progress.saveSettings(s)
        audio.setVolumes(music: s.music, sfx: s.sfx)
        renderer.shadowsEnabled = s.shadows
        haptics.enabled = s.haptics
        ui.turnButtons(s.turnButtons && puzzle.canRotateWorld && mode == .play)
    }

    private func setZone(_ id: String, force: Bool = false) {
        guard let z = logic.def.zones.first(where: { $0.id == id }) else { return }
        if zone?.id == z.id && !force { return }
        let changed = zone?.id != z.id
        zone = z
        env.setMood(z.mood)
        audio.setMood(AUDIO_MOOD[z.mood] ?? z.mood)
        if changed {
            progressed()
            // draw the eye to the handles that belong to this place
            for h in view.handles {
                let m = logic.mechs[h.mech]!
                if logic.bodies[h.body]!.zone != z.id { continue }
                if let req = m.control.requires, !puzzle.hasFlag(req) { continue }
                anim.add(duration: 0.01, delay: 1.6, onDone: { [unowned self] in effects.pulseHandle(h, times: 2) })
            }
        }
        if let title = z.title, !seen.contains(z.id) {
            seen.insert(z.id)
            anim.add(duration: 0.01, delay: force ? 1.8 : 0.6, onDone: { [unowned self] in ui.chapter(title); audio.chapter() })
        }
    }

    // ───────────────────────── character ─────────────────────────

    private func arrive(_ node: String) -> Bool {
        let eff = puzzle.visit(node)
        if let n = liveGraph().node(node) { setZone(n.zone) }
        if let eff { applyPlate(eff) }
        if puzzle.atGoal() {
            finish()
            return false
        }
        save()
        // a step switch holds the wanderer while the mechanism turns (the solver models the same)
        return !(eff?.plate.repeatable ?? false)
    }

    private func applyPlate(_ eff: PlateEffect) {
        progressed()
        if eff.plate.repeatable {
            flashPlateGlyph(eff.plate.id)
        } else {
            setPlateGlyph(eff.plate.id, true)
        }
        let pos = nodeWorld(eff.plate.tile) + V3(0, 0.15, 0)
        if let t = eff.plate.title {
            anim.add(duration: 0.01, delay: 2.2, onDone: { [unowned self] in ui.chapter(t); audio.chapter() })
        }
        if eff.flags.contains(logic.def.rotateFlag) {
            awaken(pos)
            return
        }
        audio.plate()
        haptics.plate()
        effects.shimmer(pos, color: "#bff3e8", scale: 1.2)
        let travel = { (to: V3) in min(2.2, 0.9 + simd_distance(pos, to) * 0.06) }
        if !eff.flags.isEmpty {
            // a light runs from the plate to the wheel it frees
            let lockedMech = logic.def.mechs.first { m in m.control.requires.map { eff.flags.contains($0) } ?? false }
            let h = lockedMech.flatMap { handleOf($0.id) }
            let to = h.map { handleWorld($0) } ?? pos + V3(0, 3, 0)
            let d = travel(to)
            effects.trail(pos, to, duration: d)
            anim.add(duration: 0.01, delay: d, onDone: { [unowned self] in updateLocks(announce: true); audio.connect(true); haptics.connect() })
            ui.whisper("Somewhere above, something wakes.", 4.5)
        }
        // final poses (the puzzle state already holds the new mechanism states)
        var finalParams: [String: Double] = [:]
        for (k, v) in puzzle.state.mech { finalParams[k] = Double(v) }
        let finalMats = logic.bodyMatrices(finalParams)
        var extra = 0.0
        for ch in eff.mechChanges {
            let bodies = logic.bodiesMovedBy(ch.mech)
            let def = logic.bodies[bodies[0]]!
            let local = def.tiles.first?.pos ?? (def.solids[0].min + def.solids[0].max) * 0.5
            let fm = finalMats[def.id]! * SIMD4<Double>(local, 1)
            let to = V3(fm.x, fm.y, fm.z)
            let d = travel(to) + extra
            effects.trail(pos, to, duration: d - extra)
            let m = logic.mechs[ch.mech]!
            let dur = m.duration ?? 2.2
            // a step switch advances from wherever the mechanism is heading, always the same way round
            let target = ch.by.map { jsRound(mechGoal[ch.mech] ?? params[ch.mech]!) + Double($0) } ?? Double(ch.to)
            animateMech(ch.mech, target, dur, ease.inOutCubic, delay: d)
            anim.add(duration: 0.01, delay: d, onDone: { [unowned self] in audio.rumble(dur) })
            anim.add(duration: 0.01, delay: d + dur * 0.85, onDone: { [unowned self] in effects.dust(to, spread: 1.4) })
            extra += 0.25
        }
    }

    private func awaken(_ pos: V3) {
        audio.awaken()
        haptics.plate()
        effects.shimmer(pos + V3(0, 0.3, 0), color: "#bff3e8", scale: 3)
        charView.glowBoost = 1
        anim.add(duration: 2.4, ease: ease.outCubic, onUpdate: { [unowned self] k, _ in charView.glowBoost = 1 - k })
        // the world sways, hinting that it can turn
        anim.add(duration: 3.2, delay: 0.6, ease: ease.linear, onUpdate: { [unowned self] _, t in
            rig.dragYaw = sin(t * Double.pi * 2) * 0.16 * (1 - t)
        }, onDone: { [unowned self] in rig.dragYaw = 0 })
        anim.add(duration: 0.01, delay: 2.2, onDone: { [unowned self] in if !turnTaught { ui.turnTutorial(true) } })
        ui.turnButtons(ui.settings.turnButtons)
    }

    // ───────────────────────── mechanisms ─────────────────────────

    private func animateMech(_ id: String, _ to: Double, _ dur: Double, _ fn: @escaping Ease = ease.outBack, delay: Double = 0, done: (() -> Void)? = nil) {
        busy.insert(id)
        liveCache = nil
        mechTween[id]?()  // a newer command supersedes a motion still under way
        mechGoal[id] = to
        var from = params[id]!
        var started = false
        var last = from
        mechTween[id] = anim.add(duration: dur, delay: delay, ease: fn, tag: "mech", onUpdate: { [unowned self] k, _ in
            if !started { started = true; from = params[id]!; last = from }
            let v = from + (to - from) * k
            params[id] = v
            if jsRound(last) != jsRound(v) { audio.detent(Int(jsRound(v))) }
            last = v
        }, onDone: { [unowned self] in
            params[id] = to
            busy.remove(id)
            mechTween[id] = nil
            mechGoal[id] = nil
            liveCache = nil
            done?()
            settled()
        })
    }

    /// Step switches light up briefly instead of staying pressed.
    private func flashPlateGlyph(_ plateId: String) {
        guard let p = logic.def.plates.first(where: { $0.id == plateId }), let loc = nodeLocal[p.tile],
              let gv = view.glyphAt(loc.body, loc.local) else { return }
        let from = color(GLYPH_COLORS["pressed"]!), to = color(GLYPH_COLORS[gv.kind] ?? "#ffffff")
        anim.add(duration: 1.6, ease: ease.inOutSine, onUpdate: { k, _ in gv.mat.color = mix(from, to, Float(k)) })
    }

    private func settled() {
        if !busy.isEmpty || drag != nil { return }
        let g = puzzle.graph()
        let prev = prevGraph
        prevGraph = g
        debug.rebuild(g, params)
        guard let prev else { return }
        let reach = reachable(g, char.node)
        var seamShown = 0
        var walkShown = 0
        for n in g.nodeList {
            let id = n.id
            for l in g.links(id) {
                if l.to < id { continue }
                let had = prev.links(id).contains { $0.to == l.to && $0.seam == l.seam }
                if had { continue }
                if !reach.contains(id) && !reach.contains(l.to) { continue }
                if l.seam && seamShown < 2 {
                    effects.shimmer(l.a + V3(0, 0.15, 0), color: "#fff1c4", scale: 1.8)
                    effects.shimmer(l.b + V3(0, 0.15, 0), color: "#fff1c4", scale: 1.8)
                    seamShown += 1
                } else if !l.seam && walkShown < 2 {
                    effects.shimmer(l.a + V3(0, 0.12, 0), color: "#ffffff", scale: 1.1)
                    walkShown += 1
                }
            }
        }
        if seamShown > 0 { audio.connect(true); haptics.connect() } else if walkShown > 0 { audio.connect(false) }
        save()
    }

    private func handleOf(_ mech: String) -> HandleView? { view.handles.first { $0.mech == mech } }

    private func hover(_ mech: String?) {
        if mech == hovered { return }
        if let h = hovered.flatMap({ handleOf($0) }) { for m in h.materials { m.glow = 0 } }
        hovered = mech
        if let h = mech.flatMap({ handleOf($0) }) { for m in h.materials { m.glow = 0.22 } }
    }

    private func handleWorld(_ h: HandleView) -> V3 {
        guard let m = view.matrices[h.body] else { return h.local }
        let p = m * SIMD4<Double>(h.local, 1)
        return V3(p.x, p.y, p.z)
    }

    /// World point → view coordinates in points (origin top-left).
    func screenOf(_ p: V3) -> CGPoint {
        let v = camViewProj * F4(p.f, 1)
        let x = (Double(v.x / v.w) + 1) / 2 * viewSize.width
        let y = (1 - Double(v.y / v.w)) / 2 * viewSize.height
        return CGPoint(x: x, y: y)
    }

    private func now() -> Double { CACurrentMediaTime() * 1000 }

    private func handleDown(_ mechId: String, _ x: Double, _ y: Double) -> Bool {
        let m = logic.mechs[mechId]!
        guard let h = handleOf(mechId) else { return false }
        if busy.contains(mechId) || rotating != nil { return true }
        if let block = puzzle.canOperate(mechId) {
            effects.wiggle(h)
            audio.nope()
            haptics.nope()
            if let w = BLOCK_WHISPER[block] { ui.whisper(w, 3.5) }
            return true
        }
        if char.walking { char.requestStop() }
        let center = screenOf(handleWorld(h))
        drag = Drag(mech: m, handle: h, startParam: params[mechId]!, startX: x, startY: y, started: false, lastX: x, lastY: y,
                    angle0: atan2(-(y - center.y), x - center.x), lastDetent: Int(jsRound(params[mechId]!)),
                    lastParam: params[mechId]!, lastT: now())
        liveCache = nil
        audio.tap()
        haptics.tap()
        hover(mechId)
        return true
    }

    private func handleMove(_ x: Double, _ y: Double) {
        guard var d = drag else { return }
        d.lastX = x
        d.lastY = y
        if char.walking { drag = d; return } // wait for the wanderer to stop
        if !d.started {
            // (re)anchor the gesture once movement is allowed
            d.started = true
            d.startX = x
            d.startY = y
            let c = screenOf(handleWorld(d.handle))
            d.angle0 = atan2(-(y - c.y), x - c.x)
            d.startParam = params[d.mech.id]!
        }
        let m = d.mech
        var raw: Double
        switch m.kind {
        case let .rotator(_, axis):
            let c = screenOf(handleWorld(d.handle))
            let a = atan2(-(y - c.y), x - c.x)
            var delta = a - d.angle0
            while delta > Double.pi { delta -= Double.pi * 2 }
            while delta < -Double.pi { delta += Double.pi * 2 }
            d.angle0 = a
            let sign: Double = simd_dot(simd_normalize(axis), rig.viewDir()) >= 0 ? 1 : -1
            raw = params[m.id]! + (sign * delta) / (Double.pi / 2)
        default:
            let p0 = handleWorld(d.handle)
            var step = 1.0
            var dirAxis = V3(0, 1, 0)
            if case let .slider(axis, s) = m.kind { step = s; dirAxis = axis }
            let p1 = p0 + dirAxis * step
            let s0 = screenOf(p0), s1 = screenOf(p1)
            let sx = Double(s1.x - s0.x), sy = Double(s1.y - s0.y)
            let len2 = max(1, sx * sx + sy * sy)
            raw = d.startParam + ((x - d.startX) * sx + (y - d.startY) * sy) / len2
        }
        let full = m.isRotator && m.states.count == 4
        if !full {
            let lo = Double(m.states.min()!), hi = Double(m.states.max()!)
            if raw < lo { raw = lo - rubber(lo - raw) }
            if raw > hi { raw = hi + rubber(raw - hi) }
        }
        params[m.id] = raw
        let det = Int(jsRound(raw))
        if det != d.lastDetent {
            d.lastDetent = det
            audio.detent(det)
            haptics.detent()
        }
        let t = now()
        let vel = abs(raw - d.lastParam) / max(0.001, (t - d.lastT) / 1000)
        d.lastParam = raw
        d.lastT = t
        audio.grindLevel(clamp(vel / 2.5, 0, 1))
        drag = d
    }

    private func handleUp() {
        guard let d = drag else { return }
        hover(nil)
        audio.grindLevel(0)
        let m = d.mech
        let cur = params[m.id]!
        let full = m.isRotator && m.states.count == 4
        let mod = { (v: Int) -> Int in full ? ((v % 4) + 4) % 4 : v }
        let startState = puzzle.state.mech[m.id]!
        // candidates ordered by distance from the current parameter
        let r = Int(jsRound(cur))
        var cands = [0, 1, -1, 2, -2].map { r + $0 }
        cands = stableSorted(cands) { abs(Double($0) - cur) < abs(Double($1) - cur) }
        var target = d.startParam
        var targetState = startState
        for c in cands {
            let st = mod(c)
            if !m.states.contains(st) { continue }
            if st != startState && puzzle.canSetState(m.id, st) != nil { continue }
            if abs(Double(c) - cur) > 0.75 && st != startState { continue }
            target = Double(c)
            targetState = st
            break
        }
        if targetState == startState && abs(target - d.startParam) > 0.01 && !full { target = d.startParam }
        drag = nil
        let dur = 0.35 + min(0.5, abs(target - cur) * 0.35)
        busy.insert(m.id)
        let from = cur
        anim.add(duration: dur, ease: ease.outBack, tag: "mech", onUpdate: { [unowned self] k, _ in
            params[m.id] = from + (target - from) * k
        }, onDone: { [unowned self] in
            params[m.id] = target
            busy.remove(m.id)
            liveCache = nil
            if targetState != startState {
                puzzle.setMech(m.id, targetState)
                progressed()
            }
            audio.snap()
            haptics.snap()
            settled()
        })
    }

    // ───────────────────────── world rotation ─────────────────────────

    func rotateWorld(_ dir: Int) {
        if mode != .play || rotating != nil { return }
        if !puzzle.canRotateWorld {
            anim.add(duration: 0.6, ease: ease.linear, onUpdate: { [unowned self] _, t in
                rig.dragYaw = sin(t * Double.pi) * 0.035 * Double(-dir)
            }, onDone: { [unowned self] in rig.dragYaw = 0 })
            return
        }
        if !busy.isEmpty || drag != nil { return }
        if char.walking {
            char.requestStop()
            pendingRotate = dir
            return
        }
        rotating = dir
        rig.setQuadrant(puzzle.state.cam + dir, animate: true, duration: 1.5)
        audio.worldTurn()
        haptics.turnStart()
        if !turnTaught {
            turnTaught = true
            ui.turnTutorial(false)
        }
    }

    private func skyDrag(_ dx: Double) {
        if rotating != nil { return }
        if !puzzle.canRotateWorld {
            rig.dragYaw = -sign(dx) * min(abs(dx) * 0.0004, 0.03)
            return
        }
        if !busy.isEmpty || char.walking { return }
        rig.dragYaw = -clamp(dx * 0.0032, -0.95, 0.95)
    }

    private func skyRelease(_ dx: Double, _ vx: Double) {
        if puzzle.canRotateWorld && busy.isEmpty && (abs(dx) > 70 || (abs(vx) > 0.55 && abs(dx) > 24)) {
            rotateWorld(dx > 0 ? -1 : 1)
        } else {
            rig.dragYaw = 0
        }
    }

    // ───────────────────────── input (called by the Metal view) ─────────────────────────

    var inputEnabled: Bool { mode == .play && !ui.paused && !inputLock }

    /// The gallery covers the world completely; the GPU may rest.
    var renderIdle: Bool { mode == .select && ui.selectShown && !ui.selectLeaving && !ui.titleShown }

    /// Ray through a view point (points), in world space.
    private func ray(_ x: Double, _ y: Double) -> (o: F3, d: F3) {
        let nx = x / viewSize.width * 2 - 1
        let ny = -(y / viewSize.height) * 2 + 1
        let vx = Float(nx * (rig.right - rig.left) / 2 + (rig.right + rig.left) / 2)
        let vy = Float(ny * (rig.top - rig.bottom) / 2 + (rig.top + rig.bottom) / 2)
        let o = camWorld.transformPoint(F3(vx, vy, 0))
        let d = -simd_normalize(F3(camWorld.columns.2.x, camWorld.columns.2.y, camWorld.columns.2.z))
        return (o, d)
    }

    /// Which handle is under the finger: exact hit first (`precise`), then a touch-sized zone around each handle.
    func pickHandle(_ x: Double, _ y: Double) -> (mech: String, precise: Bool)? {
        let r = ray(x, y)
        if let hit = raycast(r.o, r.d, view.handles.flatMap { $0.pick }).first, let m = hit.node.handle { return (m, true) }
        return nearHandle(x, y).map { ($0, false) }
    }

    private func nearHandle(_ x: Double, _ y: Double) -> String? {
        // a finger covers the whole wheel: hub, arms and pins, plus a fingertip's width around them
        var best: String?
        var bestD = Double.infinity
        for h in view.handles {
            let s = screenOf(handleWorld(h))
            let d = hypot(Double(s.x) - x, Double(s.y) - y)
            let reach = max(34, h.reach * pxPerUnit + 22)
            if d < reach && d < bestD { bestD = d; best = h.mech }
        }
        return best
    }

    func pointerHandleDown(_ mech: String, _ x: Double, _ y: Double) -> Bool { handleDown(mech, x, y) }
    func pointerHandleMove(_ x: Double, _ y: Double) { handleMove(x, y) }
    func pointerHandleUp() { handleUp() }
    func pointerSkyDrag(_ dx: Double) { skyDrag(dx) }
    func pointerSkyRelease(_ dx: Double, _ vx: Double) { skyRelease(dx, vx) }

    private var pxPerUnit: Double { viewSize.height / max(1e-6, rig.top - rig.bottom) }

    private func pickNode(_ x: Double, _ y: Double) -> String? {
        let g = liveGraph()
        let throughWindow = inWindow(x, y)
        let r = ray(x, y)
        let hits = raycast(r.o, r.d, view.pickables).filter { !(throughWindow && view.fadeOf($0.node.body ?? "") > 0.4) }
        if let hit = hits.first, hit.normal.y > 0.6 {
            var best: String?
            var bestD = Double.infinity
            for node in g.nodeList {
                if abs(node.pos.x - Double(hit.point.x)) > 0.53 || abs(node.pos.z - Double(hit.point.z)) > 0.53 { continue }
                let dy = node.pos.y - Double(hit.point.y)
                if dy > 0.3 || dy < -0.85 { continue }
                if abs(dy) < bestD { bestD = abs(dy); best = node.id }
            }
            if let best { return best }
        }
        // fallback: nearest node in screen space (finger-sized), preferring the one closest to the camera
        let vd = rig.viewDir()
        var best: String?
        var bestScore = -Double.infinity
        let ppu = pxPerUnit
        let thresh = max(24, ppu * 0.5)
        for node in g.nodeList {
            let s = screenOf(node.pos)
            let d = hypot(Double(s.x) - x, Double(s.y) - y)
            if d > thresh { continue }
            let score = simd_dot(node.pos, vd) - d / ppu
            if score > bestScore { bestScore = score; best = node.id }
        }
        return best
    }

    func tap(_ x: Double, _ y: Double) {
        if rotating != nil || drag != nil { return }
        guard let node = pickNode(x, y) else { return }
        let g = liveGraph()
        let pos = g.node(node)!.pos
        if char.walking {
            let path = findPath(g, char.node, node)
            effects.ring(pos, ok: path != nil)
            if path != nil { char.redirect(node); audio.tap(); haptics.tap() } else { audio.nope(); haptics.nope() }
            return
        }
        guard let path = findPath(g, char.node, node) else {
            effects.ring(pos, ok: false)
            audio.nope()
            haptics.nope()
            return
        }
        effects.ring(pos, ok: true)
        audio.tap()
        haptics.tap()
        if path.count > 1 { char.follow(path, g) }
    }

    func toggleDebug() {
        debug.toggle()
        debug.rebuild(puzzle.graph(), params)
        if !debug.enabled { ui.debugText = nil }
    }

    // ───────────────────────── hints & solver ─────────────────────────

    /// First step toward the next milestone (a new flag, i.e. a plate or the eye) or the goal — solved off the main thread.
    private func nextAction(_ done: @escaping (Action?) -> Void) {
        let start = puzzle.clone()
        let n = start.state.flags.count
        DispatchQueue.global(qos: .userInitiated).async {
            let res = solve(start, maxStates: 20000, stopWhen: { $0.state.flags.count > n })
            let a = res.solved ? res.plan.first : nil
            DispatchQueue.main.async { done(a) }
        }
    }

    private func showHint(explicit: Bool) {
        if let z = zone, !z.hints.isEmpty { ui.whisper(z.hints[min(hintStage, z.hints.count - 1)], 7) }
        if !explicit && hintStage == 0 { hintStage = 1; return }
        hintStage = min(hintStage + 1, 3)
        if hintBusy { return }
        hintBusy = true
        nextAction { [weak self] a in
            guard let self else { return }
            hintBusy = false
            guard let a, mode == .play else { return }
            switch a {
            case let .mech(mech, _):
                if let h = handleOf(mech) { effects.pulseHandle(h, times: 4) }
            case .cam:
                ui.turnTutorial(true)
                anim.add(duration: 0.01, delay: 6, onDone: { [unowned self] in self.ui.turnTutorial(false) })
            case let .walk(to):
                effects.beckon(nodeWorld(to), times: 3)
            }
        }
    }

    /// Debug/autoplay: perform the solver's next action.
    func autoStep() {
        if char.walking || !busy.isEmpty || rotating != nil || hintBusy { return }
        hintBusy = true
        nextAction { [weak self] a in
            guard let self else { return }
            hintBusy = false
            guard let a else { return }
            switch a {
            case let .walk(to):
                let g = liveGraph()
                if let path = findPath(g, char.node, to), path.count > 1 { char.follow(path, g) }
            case let .mech(mech, to):
                let m = logic.mechs[mech]!
                let cur = params[mech]!
                var target = Double(to)
                if m.isRotator && m.states.count == 4 {
                    // shortest rotation in parameter space
                    let base = Int(jsRound(cur))
                    var best = base
                    for k in -3...3 where (((base + k) % 4) + 4) % 4 == to && abs(k) < abs(best - base) + (best == base ? 99 : 0) { best = base + k }
                    target = Double(best)
                }
                animateMech(mech, target, 0.9, ease.inOutCubic, done: { [unowned self] in self.puzzle.setMech(mech, to); self.progressed() })
            case let .cam(dir):
                rotateWorld(dir)
            }
        }
    }

    // ───────────────────────── finale ─────────────────────────

    private func finish() {
        mode = .ending
        ui.hud(false)
        ui.turnTutorial(false)
        ui.turnButtons(false)
        Progress.clear(chapter.id)
        Progress.markCompleted(chapter.id)
        showGround(zone?.mood ?? "dawn")
        if chapter.grand {
            ui.groundColor = MOODS["radiant"]!.fog
            runFinale(self) { [weak self] in self?.ui.showEnding(true) }
        } else {
            let c = chapter
            runChapterFinale(self) { [weak self] in self?.ui.showComplete(numeral: c.numeral, title: c.title) }
        }
    }

    // ───────────────────────── loop ─────────────────────────

    func resize(_ size: CGSize) {
        viewSize = size
        rig.aspect = Double(size.width / max(1, size.height))
    }

    // cutaway state
    private var solidsKey = ""
    private var solidsCache: [WorldBox] = []
    private var windows: [String: CutWindow] = [:]
    private var windowKeys: [String] = []
    private var windowList: [(p: V3, r: Double)] = []

    /// Architecture standing between the camera and what matters right now — the wanderer, the handles
    /// of the current section and its unpressed plates — becomes see-through, in every view.
    private func updateCutaway(_ dt: Double) {
        let key = logic.def.mechs.map { String(format: "%.3f", params[$0.id]!) }.joined(separator: ",")
        if key != solidsKey {
            solidsKey = key
            solidsCache = logic.worldSolids(logic.bodyMatrices(params))
        }
        var hide = Set<String>()
        var active: [(key: String, p: V3, r: Double)] = []
        if mode == .play {
            let dir = rig.viewDir()
            let charBody = nodeLocal[char.node]?.body
            let charP = char.pos + V3(0, 0.38, 0)
            var foci: [(key: String, p: V3, probes: [V3], own: String?, r: Double)] = [
                ("char", charP, [char.pos + V3(0, 0.12, 0), char.pos + V3(0, 0.7, 0)], charBody, 1.45),
            ]
            let zoneOf = { (body: String, tile: String?) -> String in
                let b = self.logic.bodies[body]!
                return tile.flatMap { b.tileZones[$0] } ?? b.zone
            }
            for h in view.handles {
                let inZone = zone.map { zoneOf(h.body, nil) == $0.id } ?? false
                let carrying = charBody.map { logic.isWithin($0, h.body) } ?? false
                if inZone || carrying || drag?.handle === h {
                    let p = handleWorld(h)
                    foci.append(("h:\(h.mech)", p, [p], h.body, 1.25))
                }
            }
            for pl in logic.def.plates {
                if puzzle.hasFlag("plate:\(pl.id)") { continue }
                let loc = nodeLocal[pl.tile]!
                let tileId = pl.tile.split(separator: "/").dropFirst().joined(separator: "/")
                if let z = zone, zoneOf(loc.body, tileId) != z.id { continue }
                let p = nodeWorld(pl.tile) + V3(0, 0.1, 0)
                foci.append(("p:\(pl.id)", p, [p], loc.body, 1.0))
            }
            for f in foci {
                var hit = false
                for sol in solidsCache {
                    if sol.body == f.own { continue }
                    if f.probes.contains(where: { rayHitsBox($0, dir, sol.min, sol.max) }) { hide.insert(sol.body); hit = true }
                }
                if hit { active.append((f.key, f.p, f.r)) }
            }
        }
        // windows open and close softly; their centres follow what they reveal
        let kw = damp(5, dt)
        for a in active {
            if var cur = windows[a.key] {
                cur.p = a.p; cur.r = a.r; cur.target = 1
                windows[a.key] = cur
            } else {
                windows[a.key] = CutWindow(p: a.p, r: a.r, w: 0, target: 1)
                windowKeys.append(a.key)
            }
        }
        let activeKeys = Set(active.map { $0.key })
        for k in windowKeys {
            var w = windows[k]!
            if !activeKeys.contains(k) { w.target = 0 }
            w.w += (w.target - w.w) * kw
            windows[k] = w
        }
        windowKeys.removeAll { k in
            let w = windows[k]!
            if w.target == 0 && w.w < 0.01 { windows[k] = nil; return true }
            return false
        }
        let dpr = Double(renderer.pixelRatio)
        let ppu = pxPerUnit
        let list = Array(stableSorted(windowKeys.map { windows[$0]! }) { $0.w > $1.w }.prefix(6))
        for (i, w) in list.enumerated() {
            let sp = screenOf(w.p)
            let r = w.r * ppu * (0.35 + 0.65 * w.w)
            renderer.frame.setFocus(i, F4(Float(Double(sp.x) * dpr), Float((viewSize.height - Double(sp.y)) * dpr), Float(r * dpr), 0))
        }
        renderer.frame.rimColor = F4(color("#fff4dc"), Float(list.count))
        windowList = list.map { ($0.p, $0.r * ppu) }
        let k = damp(4.2, dt)
        for id in view.groupOrder {
            let cur = Double(view.fadeOf(id))
            let target = hide.contains(id) ? 1.0 : 0.0
            let next = cur + (target - cur) * k
            view.setFade(id, Float(abs(next - target) < 0.004 ? target : next))
        }
    }

    /// Is a view point inside an open cutaway window?
    private func inWindow(_ x: Double, _ y: Double) -> Bool {
        windowList.contains { w in
            let s = screenOf(w.p)
            return hypot(Double(s.x) - x, Double(s.y) - y) < w.r * 0.85
        }
    }

    /// Slow orbit around the monument; in landscape the monument sits right of the title.
    private func titleCamera(_ dt: Double) {
        rig.yaw += dt * 0.035
        let fit = overviewFit(yaw: rig.yaw)
        var c = fit.target
        let wide = rig.aspect > 1.15
        c += sideShift(fit.size)
        rig.frame(c, fit.size)
        if ui.wide != wide { ui.wide = wide }
    }

    /// Behind a chapter card the diorama turns slowly, lifted a little so the card's words sit over the sky.
    private func introCamera(_ dt: Double) {
        rig.yaw += dt * 0.05
        let fit = overviewFit(yaw: rig.yaw)
        rig.frame(fit.target + sideShift(fit.size), fit.size)
    }

    /// Soft ground of mist over the lower screen while the diorama is shown whole (cards, endings), so
    /// columns melt away instead of being cut by the screen edge.
    private func showGround(_ mood: String) {
        ui.groundColor = (MOODS[mood] ?? MOODS["dawn"]!).fog
        ui.groundFade = true
    }

    private var fitSizeCache: (key: String, size: Double)?

    /// Framing of the whole diorama for a camera yaw: the walkable architecture (with everything standing on
    /// it, lifts risen) fits the screen in portrait and landscape, with extra room below where the columns
    /// sink into the mist. The zoom is the widest over a full turn, so an orbiting camera keeps a steady size.
    /// In landscape the cards keep to the left half; this moves the diorama into the right half.
    func sideShift(_ size: Double) -> V3 {
        guard rig.aspect > 1.15 else { return .zero }
        let right = V3(cos(rig.yaw), 0, -sin(rig.yaw))
        return right * (-size * rig.aspect * 0.5)
    }

    func overviewFit(yaw: Double) -> (target: V3, size: Double) {
        var p = params
        for m in logic.def.mechs where m.isLift { p[m.id] = Double(m.states.max()!) }
        let mats = logic.bodyMatrices(p)
        var pts: [V3] = []
        for b in logic.def.bodies {
            guard let m = mats[b.id] else { continue }
            for t in b.tiles {
                let w = m * SIMD4<Double>(t.pos, 1)
                let q = V3(w.x, w.y, w.z)
                let rise = t.tags.contains("goal") ? 2.9 : 1.6
                // the whole cell and what stands on it (domes, pavilions, the shrine), with a little air
                for (dx, dz) in [(-0.75, -0.75), (0.75, -0.75), (-0.75, 0.75), (0.75, 0.75)] {
                    pts.append(q + V3(dx, -0.4, dz))
                    pts.append(q + V3(dx, rise, dz))
                }
            }
        }
        let elev = atan(1 / 2.0.squareRoot())
        // A tall monument (Meridian) in landscape keeps the portrait's closeness: same scale as the phone held
        // upright, the top kept in view and the lower floors left to the mist.
        let close = chapter.grand && rig.aspect > 1.15
        func frame(_ yaw: Double, _ fixedHalf: Double? = nil) -> (target: V3, half: Double) {
            let dir = V3(sin(yaw) * cos(elev), sin(elev), cos(yaw) * cos(elev))
            let right = V3(cos(yaw), 0, -sin(yaw))
            let up = simd_normalize(V3(0, 1, 0) - dir * dir.y)
            var u0 = Double.infinity, u1 = -Double.infinity, v0 = Double.infinity, v1 = -Double.infinity
            var y0 = Double.infinity, y1 = -Double.infinity
            for q in pts {
                let u = simd_dot(q, right), v = simd_dot(q, up)
                u0 = min(u0, u); u1 = max(u1, u); v0 = min(v0, v); v1 = max(v1, v)
                y0 = min(y0, q.y); y1 = max(y1, q.y)
            }
            v0 -= (v1 - v0) * 0.28  // the mist band beneath
            v1 += (v1 - v0) * 0.04
            let half: Double
            if close {
                let portrait = 1 / rig.aspect
                half = fixedHalf ?? max((v1 - v0) / 2, (u1 - u0) / 2 / portrait) * 1.12 * portrait
            } else {
                let share = rig.aspect > 1.15 ? 0.48 : 1.0
                half = fixedHalf ?? max((v1 - v0) / 2, (u1 - u0) / 2 / max(0.1, rig.aspect * share)) * 1.12
            }
            let uc = (u0 + u1) / 2
            let vc = close ? v1 - half * 0.94 : (v0 + v1) / 2
            let k = ((y0 + y1) / 2 - up.y * vc) / dir.y
            return (right * uc + up * vc + dir * k, half)
        }
        let key = "\(chapter.id)|\(String(format: "%.3f", rig.aspect))"
        let half: Double
        if let c = fitSizeCache, c.key == key {
            half = c.size
        } else {
            half = (0..<16).map { frame(Double($0) / 16 * 2 * .pi).half }.max() ?? 8
            fitSizeCache = (key, half)
        }
        // CameraRig widens portrait views by 1 / max(0.62, aspect); undo that so `half` is what shows
        let size = rig.aspect < 1 ? half * max(0.62, rig.aspect) : half
        return (frame(yaw, half).target, size)
    }

    func frame(_ rawDt: Double) {
        let dt = min(0.05, rawDt)
        time += dt
        renderer.frame.fog = F4(-12.5, -2.5, Float(time), renderer.frame.fog.w)
        fpsAvg += (1 / max(rawDt, 1e-4) - fpsAvg) * 0.05

        let paused = ui.paused
        if !paused {
            anim.update(dt)
            char.update(dt)
            if mode == .play { updatePlay(dt) }
        }
        if mode == .title { titleCamera(dt) }
        if mode == .intro { introCamera(dt) }
        updateAutoplay(dt)

        view.pose(params)
        updateCutaway(dt)
        if !char.walking { char.pos = nodeWorld(char.node) }
        charView.root.position = char.pos.f
        charView.update(dt, walking: char.walking, speed: 1, time: time)

        rig.update(dt, time)
        env.yaw = rig.yaw + rig.dragYaw
        renderer.frame.focus = F4(rig.target.f, 0)
        renderer.frame.viewDir = F4(rig.viewDir().f, 0)
        env.update(dt, focus: rig.target, time: time, aspect: rig.aspect)

        camWorld = rig.worldMatrix
        let viewM = camWorld.inverse
        let proj = rig.projMatrix
        camViewProj = proj * viewM
        renderer.frame.view = viewM
        renderer.frame.proj = proj
        renderer.frame.viewProj = camViewProj
        renderer.pixelsPerUnit = Float(pxPerUnit) * renderer.pixelRatio

        if debug.enabled {
            let a = drag.map { "drag \($0.mech.id) \(String(format: "%.2f", params[$0.mech.id]!))" } ?? ""
            ui.debugText = debug.describe(puzzle, fps: fpsAvg, extra: "\(a) busy:\(busy.sorted().joined(separator: ","))")
        }
    }

    /// Developer aid (launch argument `-autoplay`): plays the solver's solution through the real systems.
    private let autoplay = ProcessInfo.processInfo.arguments.contains("-autoplay")
    private var autoTimer = 0.0
    private var launchHandled = false

    /// Debug (launch argument `-jump N`): jump to the state after the first `n` actions of the solver's solution.
    func debugJump(_ n: Int) {
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-chapter"), i + 1 < ProcessInfo.processInfo.arguments.count,
           let c = chapterDef(ProcessInfo.processInfo.arguments[i + 1]) { load(c) }
        let p = Puzzle(logic)
        let plan = solve(p.clone()).plan
        for a in plan.prefix(n) {
            switch a {
            case let .walk(to): p.walk(findPath(p.graph(), p.charNode, to) ?? [p.charNode])
            case let .mech(m, to): p.setMech(m, to)
            case let .cam(dir): p.rotateWorld(dir)
            }
        }
        resetWorld(SaveData(state: p.state, charNode: p.charNode, seenZones: logic.def.zones.map { $0.id }))
        if mode != .play { mode = .play; ui.hideTitle(hud: true); ui.hideSelect(); ui.hideIntro() }
        audio.start()
        ui.turnButtons(ui.settings.turnButtons && puzzle.canRotateWorld)
        if let node = puzzle.graph().node(char.node) { setZone(node.zone, force: true) }
    }

    private func updateAutoplay(_ dt: Double) {
        let args = ProcessInfo.processInfo.arguments
        let atStart = mode == .title || mode == .select
        if let i = args.firstIndex(of: "-jump"), atStart, time > 1.5,
           i + 1 < args.count, let n = Int(args[i + 1]) {
            debugJump(n)
        }
        // developer aids: `-chapter <id>` opens a chapter, `-select` the gallery, `-intro` stops at the card
        if atStart && time > 1.2 && !launchHandled {
            launchHandled = true
            if let i = args.firstIndex(of: "-chapter"), i + 1 < args.count, args.firstIndex(of: "-jump") == nil {
                let id = args[i + 1]
                ui.hideTitle(hud: false)
                if args.contains("-intro") { openChapter(id) } else if let c = chapterDef(id) {
                    ui.hideSelect()
                    load(c)
                    resetWorld(Progress.load(c.id))
                    begin()
                }
            } else if args.contains("-select") {
                showSelect(focus: nil)
            }
        }
        guard autoplay else { return }
        autoTimer += dt
        if atStart && autoTimer > 2 && !ui.titleFading {
            autoTimer = 0
            ui.hideSelect()
            resetWorld()
            begin()
        }
        if mode == .play && autoTimer > 0.6 && !inputLock { autoTimer = 0; autoStep() }
    }

    private func updatePlay(_ dt: Double) {
        // camera framing: zone composition, gently leaning toward the wanderer
        if let z = zone {
            rig.frame(z.target + (char.pos - z.target) * 0.16, z.size)
        }
        if let r = rotating, !rig.rotating {
            puzzle.rotateWorld(r)
            rotating = nil
            liveCache = nil
            haptics.turnEnd()
            progressed()
            settled()
        }
        if let d = pendingRotate, !char.walking {
            pendingRotate = nil
            rotateWorld(d)
        }
        // drag waits for the wanderer to stop
        if let d = drag, !d.started, !char.walking { handleMove(d.lastX, d.lastY) }

        // gentle hints when idle for a long time
        if !char.walking && drag == nil && busy.isEmpty {
            idle += dt
            if (hintStage == 0 && idle > 55) || (hintStage == 1 && idle > 110) {
                showHint(explicit: false)
                if hintStage < 2 { idle = hintStage == 1 ? 56 : 0 }
            }
        }
    }

    // ───────────────────────── picking ─────────────────────────

    struct Hit {
        let node: Node
        let distance: Float
        let point: F3
        let normal: F3
    }

    /// Mesh raycast with three's rules: bounding sphere test, front faces only, hits sorted by distance.
    private func raycast(_ o: F3, _ d: F3, _ nodes: [Node]) -> [Hit] {
        var hits: [Hit] = []
        var seenIds = Set<Int>()
        for n in nodes {
            guard seenIds.insert(n.id).inserted, let mesh = n.mesh, let tri = mesh.cpu else { continue }
            let w = n.worldMatrix
            let inv = w.inverse
            let lo = inv.transformPoint(o)
            let ld = simd_normalize(inv.upperLeft3x3 * d)
            // bounding sphere
            let oc = lo - mesh.center
            let b = simd_dot(oc, ld)
            let c = simd_dot(oc, oc) - mesh.radius * mesh.radius
            if c > 0 && b > 0 { continue }
            if b * b - c < 0 { continue }
            var best: (t: Float, p: F3, n: F3)?
            var i = 0
            while i + 2 < tri.count {
                let a = tri[i], bb = tri[i + 1], cc = tri[i + 2]
                i += 3
                let e1 = bb - a, e2 = cc - a
                let normal = simd_cross(e1, e2)
                let ddn = simd_dot(ld, normal)
                if ddn >= 0 { continue } // back face (FrontSide materials) or parallel
                let diff = lo - a
                let dq = -ddn
                let db1 = -simd_dot(ld, simd_cross(diff, e2))
                if db1 < 0 { continue }
                let db2 = -simd_dot(ld, simd_cross(e1, diff))
                if db2 < 0 || db1 + db2 > dq { continue }
                let qdn = simd_dot(diff, normal)
                if qdn < 0 { continue }
                let t = qdn / dq
                if best == nil || t < best!.t {
                    best = (t, lo + ld * t, simd_normalize(simd_cross(cc - bb, a - bb)))
                }
            }
            if let bh = best {
                let wp = w.transformPoint(bh.p)
                hits.append(Hit(node: n, distance: simd_distance(o, wp), point: wp, normal: w.transformDirection(bh.n)))
            }
        }
        return stableSorted(hits) { $0.distance < $1.distance }
    }
}

/// Does the ray p + t·d (t > 0) pass through the box (and not merely start inside it)?
private func rayHitsBox(_ p: V3, _ d: V3, _ mn: V3, _ mx: V3) -> Bool {
    var t0 = 0.05
    var t1 = 400.0
    for ax in 0..<3 {
        let o = p[ax], v = d[ax]
        if abs(v) < 1e-9 {
            if o <= mn[ax] || o >= mx[ax] { return false }
            continue
        }
        var a = (mn[ax] - o) / v
        var b = (mx[ax] - o) / v
        if a > b { swap(&a, &b) }
        t0 = max(t0, a)
        t1 = min(t1, b)
        if t0 > t1 { return false }
    }
    let inside = p.x > mn.x && p.x < mx.x && p.y > mn.y && p.y < mx.y && p.z > mn.z && p.z < mx.z
    return !inside
}

private func rubber(_ x: Double) -> Double { 0.25 * (1 - exp(-x * 3)) }

private func sign(_ v: Double) -> Double { v > 0 ? 1 : v < 0 ? -1 : 0 }

/// JavaScript's Array.prototype.sort is stable; Swift's sort is not guaranteed to be.
func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
    a.enumerated().sorted { x, y in
        if less(x.element, y.element) { return true }
        if less(y.element, x.element) { return false }
        return x.offset < y.offset
    }.map { $0.element }
}
