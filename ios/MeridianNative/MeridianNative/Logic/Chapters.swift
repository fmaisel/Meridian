// The book of chapters: five small dioramas, each built around one new piece of architecture, and the
// great monument Meridian as the closing chapter. Every chapter is an ordinary LevelDef built with the kit
// and verified by the same solver (Tools/LogicCheck): solvable, no dead ends, every mechanism necessary.

import Foundation
import simd

struct ChapterDef {
    let id: String
    let numeral: String
    let title: String
    /// "In which …" lines of the chapter card.
    let lines: [String]
    let build: () -> LevelDef
    /// Composed view of the whole diorama (intro card and ending).
    let overview: (target: V3, size: Double)
    /// Emblem colours in the chapter gallery: outer petals, petal tips, centre disc.
    let emblem: (petals: String, tips: String, centre: String)
    /// Meridian ends with the full finale and the closing screen; the small chapters with a quieter one.
    var grand = false
}

let CHAPTERS: [ChapterDef] = [
    ChapterDef(id: "drawbridge", numeral: "I", title: "The Drawbridge",
               lines: ["the wanderer", "lowers a road", "out of the sky"],
               build: buildDrawbridge, overview: (V3(-0.5, 2, 1.5), 5.6),
               emblem: ("#2f6f78", "#9fd8cf", "#101a1c")),
    ChapterDef(id: "counterweight", numeral: "II", title: "The Counterweight",
               lines: ["what rises", "must let", "something fall"],
               build: buildCounterweight, overview: (V3(1.5, 2.6, 0), 6.2),
               emblem: ("#7c7a3c", "#e4d58e", "#2a2614")),
    ChapterDef(id: "clockwork", numeral: "III", title: "The Clockwork",
               lines: ["every step", "turns the", "garden wheel"],
               build: buildClockwork, overview: (V3(0, 2.2, 0), 6.0),
               emblem: ("#b0536a", "#f4b9c3", "#2c1018")),
    ChapterDef(id: "gears", numeral: "IV", title: "The Twin Gears",
               lines: ["two bridges", "turn as one", "but never alike"],
               build: buildTwinGears, overview: (V3(1.5, 2.4, 0), 6.0),
               emblem: ("#c9b26a", "#fff1c4", "#191712")),
    ChapterDef(id: "tumbling", numeral: "V", title: "The Tumbling Hall",
               lines: ["a floor", "becomes a wall", "becomes a road"],
               build: buildTumblingHall, overview: (V3(1, 2.6, 0), 6.0),
               emblem: ("#3d55c9", "#a9bdf5", "#0d1430")),
    ChapterDef(id: "meridian", numeral: "VI", title: "Meridian",
               lines: ["the light", "climbs the", "quiet monument"],
               build: buildLevel, overview: (V3(-3, 7.5, 1), 16.5),
               emblem: ("#e9735c", "#f6d7c2", "#2a1612"), grand: true),
]

func chapterDef(_ id: String) -> ChapterDef? { CHAPTERS.first { $0.id == id } }

// ───────────────────────── shared pieces ─────────────────────────

/// Square column from the clouds up to `top`, with a capital and a carved band.
func column(_ b: BodyBuilder, _ x: Double, _ z: Double, _ top: Double, _ w: Double = 0.7, _ mat: String = "stone") {
    b.block(V3(x - w / 2, CLOUD, z - w / 2), V3(x + w / 2, top, z + w / 2), mat)
    let c = w / 2 + 0.1
    b.block(V3(x - c, top - 0.24, z - c), V3(x + c, top, z + c), "trim", false)
    b.block(V3(x - w / 2 - 0.05, top - 1.1, z - w / 2 - 0.05), V3(x + w / 2 + 0.05, top - 0.98, z + w / 2 + 0.05), "trim", false)
}

/// Slender minaret with an onion dome, standing on (x, y, z).
func minaret(_ b: BodyBuilder, _ x: Double, _ y: Double, _ z: Double, h: Double = 2.2, w: Double = 0.36, roof: String = "roof") {
    b.block(V3(x - w / 2, y, z - w / 2), V3(x + w / 2, y + h, z + w / 2), "stone", false)
    b.block(V3(x - w / 2 - 0.06, y + h, z - w / 2 - 0.06), V3(x + w / 2 + 0.06, y + h + 0.12, z + w / 2 + 0.06), "trim", false)
    b.dome(x, y + h + 0.12, z, w * 0.62, roof, .onion)
}

private func zone(_ id: String, _ target: V3, _ size: Double, _ mood: String, _ hints: [String]) -> ZoneDef {
    ZoneDef(id: id, title: nil, target: target, size: size, mood: mood, hints: hints)
}

// ───────────────────────── I. The Drawbridge ─────────────────────────
// A courtyard below, a gate tower above and, across the gap, the shrine. The plate raises the stair;
// the wheel on the hinge lowers the bridge that stands like a wall against the sky.

func buildDrawbridge() -> LevelDef {
    var bodies: [BodyBuilder] = []
    var mechs: [MechDef] = []
    var plates: [PlateDef] = []
    func B(_ id: String, palette: String, mech: String? = nil) -> BodyBuilder {
        let b = BodyBuilder(id, palette: palette, zone: "c1", mech: mech)
        bodies.append(b)
        return b
    }

    // the courtyard
    let yard = B("yard", palette: "sand")
    yard.box(2, 4, 4, 4, CLOUD, 0)
    yard.box(4, 4, 5, 5, CLOUD, 0)
    yard.tag(4, 0, 5, "start").glyph(4, 0, 5, "start")
    yard.tag(2, 0, 4, "plate:p1").glyph(2, 0, 4, "plate")
    yard.block(V3(4.5, -1.1, 4.6), V3(5.3, 0.3, 5.4), "stone", false).tree(4.9, 0.3, 5, 1.2)
    yard.block(V3(1.6, -0.9, 4.5), V3(2.0, 0.9, 4.9), "trim", false).dome(1.8, 0.9, 4.7, 0.2, "roof", .onion)
    yard.window(4, -1.2, 5.5, .pz, 0.18, 0.6).window(2, -1.4, 4.5, .pz, 0.18, 0.6).window(4.5, -1.2, 4, .px, 0.18, 0.6)

    let stair = B("stair", palette: "sand", mech: "lift1")
    stair.flight(2, 3, .nz, 0, 2, 1, base: CLOUD)
    mechs.append(MechDef(id: "lift1", kind: .lift(poses: [V3(0, -14, 0), V3(0, 0, 0)]), initial: 0, rider: false,
                         control: ControlDef(type: .none), states: [0, 1], duration: 2.6))
    plates.append(PlateDef(id: "p1", tile: yard.ref(2, 0, 4), actions: [.mech("lift1", to: 1)]))

    // the gate tower, with two minarets
    let tower = B("gate", palette: "ivory")
    tower.box(1, 2, 0, 0, CLOUD, 2)
    tower.box(2, 2, 1, 1, CLOUD, 2)
    tower.block(V3(1.45, 1.55, -0.62), V3(2.62, 1.66, 0.62), "trim", false)
    minaret(tower, 2.25, 2, -0.25, h: 2.4, w: 0.34, roof: "roof")
    tower.arch(x: 2.5, z: 0.5, axis: .z, y0: -2.6, y1: 1.6, span: 1.0, thick: 0.08, openW: 0.5, openH: 1.6, mat: "trim")
    tower.window(1.5, 0.4, 0.5, .pz, 0.16, 0.6).window(2.5, 0.6, 1, .px, 0.16, 0.6).window(2.5, -1.6, 0, .px, 0.16, 0.6)
    tower.banner(2.55, 1.5, 1.2, .px, len: 1.6, w: 0.3, mat: "roofCoral")

    // the bridge: raised (state 1) it stands as a wall above the hinge; lowered (state 0) it spans the gap
    let bridge = B("bridge", palette: "ivory", mech: "draw")
    bridge.box(-2, 0, 0, 0, 1.62, 2, mat: "stone")
    bridge.block(V3(-2.5, 2, -0.52), V3(0.5, 2.22, -0.44), "trim", false)
    bridge.block(V3(-2.5, 2, 0.44), V3(0.5, 2.22, 0.52), "trim", false)
    bridge.visual(.crank(x: 0.5, y: 2, z: 0.82, axis: V3(0, 0, -1), r: 0.62, mech: "draw"))
    mechs.append(MechDef(id: "draw", kind: .rotator(pivot: V3(0.5, 2, 0), axis: V3(0, 0, -1)), initial: 1, rider: false,
                         control: ControlDef(type: .crank, body: "bridge", at: V3(0.5, 2, 0.82)), states: [0, 1],
                         name: "the drawbridge"))

    // the shrine island
    let isle = B("isle", palette: "ivory")
    isle.box(-4, -3, 0, 0, CLOUD, 2)
    isle.box(-4, -3, -1, -1, CLOUD, 2)
    isle.tag(-4, 2, -1, "goal")
    isle.visual(.shrine(x: -4, y: 2, z: -1))
    minaret(isle, -3.25, 2, -0.75, h: 1.6, w: 0.3, roof: "roof")
    isle.block(V3(-3.5, 1.1, 0.5), V3(-2.6, 2.2, 1.3), "stone", false).tree(-3.05, 2.2, 0.9, 1.0)
    isle.window(-3, 0.6, 0.5, .pz, 0.16, 0.6).window(-4, -0.9, 0.5, .pz, 0.16, 0.6)

    let zones = [zone("c1", V3(-0.5, 2, 1.5), 5.6, "dawn",
                      ["Some stones remember being stepped on.", "The wheel on the hinge lowers the wall."])]
    return LevelDef(bodies: bodies.map { $0.build() }, mechs: mechs, plates: plates, zones: zones,
                    start: yard.ref(4, 0, 5), goal: isle.ref(-4, 2, -1), rotateFlag: "__never__")
}

// ───────────────────────── II. The Counterweight ─────────────────────────
// Two platforms hang from one rope over a pulley. Raising the near one lowers the far one. The balcony plate
// raises a footbridge halfway up — where both platforms meet when the rope is level.

func buildCounterweight() -> LevelDef {
    var bodies: [BodyBuilder] = []
    var mechs: [MechDef] = []
    var plates: [PlateDef] = []
    func B(_ id: String, palette: String, mech: String? = nil) -> BodyBuilder {
        let b = BodyBuilder(id, palette: palette, zone: "c2", mech: mech)
        bodies.append(b)
        return b
    }

    // the garden terrace
    let garden = B("garden", palette: "olive")
    garden.box(-2, -1, 0, 0, CLOUD, 0)
    garden.box(-2, -2, 1, 2, CLOUD, 0)
    garden.tag(-2, 0, 2, "start").glyph(-2, 0, 2, "start")
    for (x, z, h) in [(-1.2, 1.0, 0.9), (-1.2, 1.75, 1.2), (-2.75, 0.4, 1.0), (-2.8, 1.3, 1.3)] {
        garden.block(V3(x - 0.3, -0.6, z - 0.3), V3(x + 0.3, 0.15, z + 0.3), "stone", false).tree(x, 0.15, z, h)
    }
    garden.pavilion(-2, 0, 0, h: 1.4, roof: "roof", style: .onion)
    garden.banner(-1.62, 1.55, 0.38, .pz, len: 1.0, w: 0.22, mat: "banner")

    // the counterweight pair: one knob, one rope
    let near = B("near", palette: "olive", mech: "cw")
    near.def.rides = true
    near.box(0, 0, 0, 0, -0.45, 0, mat: "accent")
    near.block(V3(-0.32, CLOUD, -0.32), V3(0.32, -0.45, 0.32), "stone")
    near.visual(.knob(x: 0, y: -0.5, z: 0.5, mech: "cw"))
    let far = B("far", palette: "olive", mech: "cw")
    far.def.rides = true
    far.def.mechSign = -1
    far.box(3, 3, 0, 0, 3.55, 4, mat: "accent")
    far.block(V3(2.68, CLOUD + 4, -0.32), V3(3.32, 3.55, 0.32), "stone")
    mechs.append(MechDef(id: "cw", kind: .slider(axis: V3(0, 1, 0), step: 2), initial: 0, rider: true,
                         control: ControlDef(type: .knob, body: "near", at: V3(0, -0.5, 0.5)), states: [0, 1, 2],
                         name: "the counterweight"))

    // pulley gantry on a central mast behind the pair; cables run through both platforms into the clouds
    let mast = B("mast", palette: "olive")
    mast.block(V3(1.2, CLOUD, -1.55), V3(1.8, 6.9, -0.95), "stone")
    mast.block(V3(1.1, 6.9, -1.65), V3(1.9, 7.05, -0.85), "trim", false)
    mast.block(V3(1.35, 6.35, -1.0), V3(1.65, 6.6, 0), "trim")
    mast.block(V3(-0.3, 6.35, -0.15), V3(3.3, 6.6, 0.15), "trim")
    mast.dome(1.5, 7.05, -1.25, 0.34, "roof", .onion)
    mast.gear(0, 6.75, 0, axis: V3(0, 0, 1), r: 0.36, mat: "accent")
    mast.gear(3, 6.75, 0, axis: V3(0, 0, 1), r: 0.36, mat: "accent")
    for (x, z) in [(-0.42, 0.42), (0.42, -0.42), (2.58, 0.42), (3.42, -0.42)] {
        mast.pillar(x, z, CLOUD, 6.4, 0.025, "trim")
    }
    mast.window(1.5, 3.5, -0.95, .pz, 0.16, 0.7).window(1.8, 1.0, -1.25, .px, 0.16, 0.7)

    // the balcony with the plate, reached from the near platform at the top of the rope
    let balcony = B("balcony", palette: "olive")
    balcony.box(0, 0, -1, -2, CLOUD, 4)
    balcony.tag(0, 4, -2, "plate:p2").glyph(0, 4, -2, "plate")
    balcony.block(V3(-0.5, 4, -2.52), V3(0.5, 4.5, -2.44), "trim", false)
    balcony.window(0.5, 2.2, -1.5, .px, 0.16, 0.6).window(0, 1.0, -0.5, .pz, 0.16, 0.6)

    // the footbridge, raised by the plate to the middle of the rope's travel
    let foot = B("foot", palette: "olive", mech: "lift2")
    foot.box(1, 2, 0, 0, 1.6, 2)
    foot.block(V3(1.25, CLOUD, -0.2), V3(1.75, 1.6, 0.2), "stone")
    foot.arch(x: 1.5, z: 0, axis: .x, y0: 0.2, y1: 1.6, span: 2.0, thick: 0.4, openW: 1.3, openH: 1.1, mat: "stone")
    mechs.append(MechDef(id: "lift2", kind: .lift(poses: [V3(0, -14, 0), V3(0, 0, 0)]), initial: 0, rider: false,
                         control: ControlDef(type: .none), states: [0, 1], duration: 3))
    plates.append(PlateDef(id: "p2", tile: balcony.ref(0, 4, -2), actions: [.mech("lift2", to: 1)]))

    // the high terrace with the shrine
    let terrace = B("terrace", palette: "olive")
    terrace.box(4, 5, 0, 0, CLOUD, 4)
    terrace.box(5, 5, -1, -1, CLOUD, 4)
    terrace.tag(5, 4, -1, "goal")
    terrace.visual(.shrine(x: 5, y: 4, z: -1))
    terrace.block(V3(4.5, 3.2, 0.5), V3(5.4, 4.3, 1.4), "stone", false).tree(4.95, 4.3, 0.95, 1.1)
    terrace.banner(5.55, 3.9, -0.1, .px, len: 1.4, w: 0.26, mat: "banner")
    terrace.window(4.5, 2.2, 0.5, .pz, 0.16, 0.7).window(5.5, 1.8, 0, .px, 0.16, 0.7)

    let zones = [zone("c2", V3(1.5, 2.6, 0), 6.2, "garden",
                      ["What rises must let something fall.", "Meet in the middle."])]
    return LevelDef(bodies: bodies.map { $0.build() }, mechs: mechs, plates: plates, zones: zones,
                    start: garden.ref(-2, 0, 2), goal: terrace.ref(5, 4, -1), rotateFlag: "__never__")
}
