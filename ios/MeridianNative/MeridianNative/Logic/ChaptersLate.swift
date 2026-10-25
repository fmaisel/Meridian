// Chapters III–V: the clockwork turnstile, the twin gears and the tumbling hall.

import Foundation
import simd

// ───────────────────────── III. The Clockwork ─────────────────────────
// A clock hand turns on a rose-coloured island. Its hub is a step switch: whoever arrives there is carried
// a quarter turn and set down facing new directions. The Eye on the west ledge lets the world turn; seen
// from the far side, the north ledge reaches the high shrine.

func buildClockwork() -> LevelDef {
    var bodies: [BodyBuilder] = []
    var mechs: [MechDef] = []
    var plates: [PlateDef] = []
    func B(_ id: String, palette: String, mech: String? = nil) -> BodyBuilder {
        let b = BodyBuilder(id, palette: palette, zone: "c3", mech: mech)
        bodies.append(b)
        return b
    }

    // the clock hand on its column, a great gear beneath it
    let hand = B("hand", palette: "rose", mech: "clock")
    hand.box(0, 0, -1, 1, 1.62, 2, mat: "accent")
    hand.tag(0, 2, 0, "plate:hub").glyph(0, 2, 0, "step")
    hand.block(V3(-0.28, CLOUD, -0.28), V3(0.28, 1.62, 0.28), "stone")
    hand.gear(0, 1.42, 0, axis: V3(0, 1, 0), r: 1.32, mat: "trim")
    mechs.append(MechDef(id: "clock", kind: .rotator(pivot: V3(0, 0, 0), axis: V3(0, 1, 0)), initial: 0, rider: true,
                         control: ControlDef(type: .none), states: [0, 1, 2, 3], name: "the clock hand", duration: 1.5))
    plates.append(PlateDef(id: "hub", tile: hand.ref(0, 2, 0), actions: [.turn("clock", by: 1)], repeatable: true))

    // four ledges, one at each hour
    let south = B("south", palette: "rose")
    south.box(0, 0, 2, 3, CLOUD, 2)
    south.box(-1, -1, 3, 3, CLOUD, 2)
    south.tag(-1, 2, 3, "start").glyph(-1, 2, 3, "start")
    south.block(V3(0.5, 1.2, 2.55), V3(1.35, 2.3, 3.45), "stone", false).tree(0.92, 2.3, 3.0, 1.15)
    south.window(0, 0.6, 3.5, .pz, 0.16, 0.6).window(0.5, -0.4, 2.5, .px, 0.16, 0.6)

    let west = B("west", palette: "rose")
    west.box(-3, -2, 0, 0, CLOUD, 2)
    west.tag(-3, 2, 0, "eye").glyph(-3, 2, 0, "eye")
    plates.append(PlateDef(id: "eye", tile: west.ref(-3, 2, 0), actions: [.flag("eye")]))
    west.pavilion(-3, 2, 0, h: 1.35, roof: "roof", style: .onion)
    west.window(-2, 0.6, 0.5, .pz, 0.16, 0.6)

    let east = B("east", palette: "rose")
    east.box(2, 3, 0, 0, CLOUD, 2)
    east.box(3, 3, 1, 1, CLOUD, 2)
    east.block(V3(2.6, 1.2, 1.55), V3(3.4, 2.4, 2.4), "stone", false).tree(3, 2.4, 2, 1.25)
    east.window(3.5, 0.5, 0, .px, 0.16, 0.6).window(3, -0.6, 1.5, .pz, 0.16, 0.6)
    minaret(east, 3.3, 2, -0.3, h: 1.5, w: 0.3, roof: "roof")

    let north = B("north", palette: "rose")
    north.box(0, 0, -2, -2, CLOUD, 2)
    north.seam(0, 2, -2, .nz)
    north.block(V3(-0.52, 2, -2.5), V3(-0.44, 2.3, -1.5), "trim", false)
    north.block(V3(0.44, 2, -2.5), V3(0.52, 2.3, -1.5), "trim", false)

    // the shrine on the clock tower, high on the far side
    let tower = B("tower", palette: "rose")
    tower.box(-3, -2, -5, -5, CLOUD, 4)
    tower.seam(-2, 4, -5, .pz)
    tower.tag(-3, 4, -5, "goal")
    tower.visual(.shrine(x: -3, y: 4, z: -5))
    tower.block(V3(-3.62, 0.6, -5.62), V3(-1.38, 0.82, -4.38), "trim", false)
    tower.gear(-2.5, 2.3, -4.48, axis: V3(0, 0, 1), r: 0.62, mat: "trim")
    tower.window(-1.5, 2.3, -5, .px, 0.18, 0.7).window(-1.5, -0.6, -5, .px, 0.18, 0.7)
    minaret(tower, -1.75, 4, -5.25, h: 1.7, w: 0.3, roof: "roof")

    let zones = [zone3("c3", V3(-0.5, 2.4, -0.8), 6.4, "rose",
                       ["The hand turns whenever you reach its centre.", "Find the Eye, then look from the far side."])]
    return LevelDef(bodies: bodies.map { $0.build() }, mechs: mechs, plates: plates, zones: zones,
                    start: south.ref(-1, 2, 3), goal: tower.ref(-3, 4, -5), rotateFlag: "eye")
}

private func zone3(_ id: String, _ target: V3, _ size: Double, _ mood: String, _ hints: [String]) -> ZoneDef {
    ZoneDef(id: id, title: nil, target: target, size: size, mood: mood, hints: hints)
}

// ───────────────────────── IV. The Twin Gears ─────────────────────────
// Two L-shaped bridges sit on meshing gears; one wheel turns both, in opposite senses. They meet only when
// their arms face each other — so you must ride one to bring the other round.

func buildTwinGears() -> LevelDef {
    var bodies: [BodyBuilder] = []
    var mechs: [MechDef] = []
    let plates: [PlateDef] = []
    func B(_ id: String, palette: String, mech: String? = nil) -> BodyBuilder {
        let b = BodyBuilder(id, palette: palette, zone: "c4", mech: mech)
        bodies.append(b)
        return b
    }

    let a = B("gearA", palette: "temple", mech: "gears")
    a.box(0, 1, 0, 0, 1.62, 2, mat: "accent").box(0, 0, 1, 1, 1.62, 2, mat: "accent")
    a.block(V3(-0.28, CLOUD, -0.28), V3(0.28, 1.62, 0.28), "stone")
    a.gear(0, 1.4, 0, axis: V3(0, 1, 0), r: 1.36, mat: "trim")
    let b = B("gearB", palette: "temple", mech: "gears")
    b.def.pivot = V3(3, 0, 0)
    b.def.mechSign = -1
    b.box(2, 3, 0, 0, 1.62, 2, mat: "accent").box(3, 3, -1, -1, 1.62, 2, mat: "accent")
    b.block(V3(2.72, CLOUD, -0.28), V3(3.28, 1.62, 0.28), "stone")
    b.gear(3, 1.4, 0, axis: V3(0, 1, 0), r: 1.36, mat: "trim")
    // the wheel stands on its own post between the two, geared to both
    let wheel = B("wheel", palette: "temple", mech: "gears")
    wheel.def.pivot = V3(1.5, 0, -1.7)
    wheel.gear(1.5, 2.95, -1.7, axis: V3(0, 1, 0), r: 0.42, mat: "trim")
    wheel.visual(.crank(x: 1.5, y: 3.3, z: -1.7, axis: V3(0, 1, 0), r: 0.6, mech: "gears"))
    let post = B("post", palette: "temple")
    post.block(V3(1.24, CLOUD, -1.96), V3(1.76, 2.8, -1.44), "stone")
    post.block(V3(1.14, 2.62, -2.06), V3(1.86, 2.8, -1.34), "trim", false)
    mechs.append(MechDef(id: "gears", kind: .rotator(pivot: V3(0, 0, 0), axis: V3(0, 1, 0)), initial: 0, rider: true,
                         control: ControlDef(type: .crank, body: "wheel", at: V3(1.5, 3.3, -1.7)), states: [0, 1, 2, 3],
                         name: "the twin gears"))

    // the gate where the wanderer arrives
    let gate = B("gate", palette: "temple")
    gate.box(-3, -2, 0, 0, CLOUD, 2)
    gate.box(-3, -3, 1, 1, CLOUD, 2)
    gate.tag(-3, 2, 1, "start").glyph(-3, 2, 1, "start")
    minaret(gate, -3.3, 2, -0.3, h: 1.9, w: 0.32, roof: "roof")
    gate.window(-2.5, 0.6, 0, .px, 0.16, 0.6).window(-3, -0.8, 1.5, .pz, 0.16, 0.6)

    // a quiet balcony to the north and a pavilion to the south of the first gear
    let balcony = B("balcony", palette: "temple")
    balcony.box(0, 0, -2, -3, CLOUD, 2)
    balcony.pavilion(0, 2, -3, h: 1.3, roof: "roof", style: .round)
    let south = B("southA", palette: "temple")
    south.box(0, 0, 2, 2, CLOUD, 2)
    south.block(V3(-0.42, 2, 2.38), V3(0.42, 2.9, 2.46), "trim", false)

    // the far side: an east landing and, to the south, the shrine
    let east = B("east", palette: "temple")
    east.box(5, 5, 0, 0, CLOUD, 2)
    minaret(east, 5.3, 2, 0.3, h: 1.6, w: 0.3, roof: "roof")
    let shrine = B("shrine", palette: "temple")
    shrine.box(3, 3, 2, 3, CLOUD, 2)
    shrine.tag(3, 2, 3, "goal")
    shrine.visual(.shrine(x: 3, y: 2, z: 3))
    minaret(shrine, 2.4, 2, 3.4, h: 2.2, w: 0.34, roof: "roof")
    minaret(shrine, 3.6, 2, 3.4, h: 2.2, w: 0.34, roof: "roof")
    shrine.window(3.5, 0.4, 2.5, .px, 0.16, 0.6).window(3, -0.8, 3.5, .pz, 0.16, 0.6)

    let zones = [zone3("c4", V3(1.2, 2.4, 0.6), 6.2, "night",
                       ["One wheel, two bridges, two directions.", "Ride the first bridge round."])]
    return LevelDef(bodies: bodies.map { $0.build() }, mechs: mechs, plates: plates, zones: zones,
                    start: gate.ref(-3, 2, 1), goal: shrine.ref(3, 2, 3), rotateFlag: "__never__")
}

// ───────────────────────── V. The Tumbling Hall ─────────────────────────
// A long block hangs on an axle between two pylons. Each of its four faces carries a road: lying flat it
// joins the low ledges, standing on edge it becomes a narrow high road between the pylons.

func buildTumblingHall() -> LevelDef {
    var bodies: [BodyBuilder] = []
    var mechs: [MechDef] = []
    func B(_ id: String, palette: String, mech: String? = nil) -> BodyBuilder {
        let b = BodyBuilder(id, palette: palette, zone: "c5", mech: mech)
        bodies.append(b)
        return b
    }
    let hw = 1.45  // half width of the block (a hair narrower than its tiles, so it clears the ledges)
    let up = V3(0, 1, 0), down = V3(0, -1, 0), nz = V3(0, 0, -1), pz = V3(0, 0, 1)
    let px = V3(1, 0, 0), nx = V3(-1, 0, 0)

    let hall = B("hall", palette: "slate", mech: "tumble")
    hall.block(V3(-0.5, 1.5, -hw), V3(2.5, 2.5, hw), "stone")
    // top face: two rows of road, the third left bare
    for x in [0.0, 1, 2] { for z in [0.0, 1] { hall.tile(x, 2.5, z) } }
    for x in [0.0, 1, 2] { hall.close(x, 2.5, 0, .nz) }
    hall.visual(.faceCap(min: V3(-0.5, 2.5, -0.5), max: V3(2.5, 2.5, hw), up: up))
    // underside: three full rows
    for x in [0.0, 1, 2] { for z in [-1.0, 0, 1] { hall.faceTile(V3(x, 1.5, z), up: down, dirs: [px, nx, pz, V3(0, 0, -1)]) } }
    hall.visual(.faceCap(min: V3(-0.5, 1.5, -hw), max: V3(2.5, 1.5, hw), up: down))
    // the north face: a narrow road open at both ends
    for x in [0.0, 1, 2] { hall.faceTile(V3(x, 2, -1.5), up: nz, dirs: [px, nx]) }
    hall.visual(.faceCap(min: V3(-0.5, 1.5, -hw), max: V3(2.5, 2.5, -hw), up: nz))
    // the south face: the road stops short of the east end
    hall.faceTile(V3(0, 2, 1.5), up: pz, dirs: [px, nx])
    hall.faceTile(V3(1, 2, 1.5), up: pz, dirs: [nx])
    hall.visual(.faceCap(min: V3(-0.5, 1.5, hw), max: V3(1.5, 2.5, hw), up: pz))
    // axle through both pylons, the wheel on its east end
    hall.block(V3(-1.45, 1.86, -0.14), V3(3.6, 2.14, 0.14), "trim", false)
    hall.visual(.crank(x: 3.68, y: 2, z: 0, axis: V3(1, 0, 0), r: 0.58, mech: "tumble"))
    for x in [-0.5, 2.5] {
        hall.block(V3(x - 0.06, 1.44, -hw - 0.06), V3(x + 0.06, 2.56, hw + 0.06), "trim", false)
    }
    mechs.append(MechDef(id: "tumble", kind: .rotator(pivot: V3(0, 2, 0), axis: V3(1, 0, 0)), initial: 0, rider: false,
                         control: ControlDef(type: .crank, body: "hall", at: V3(3.68, 2, 0)), states: [0, 1, 2, 3],
                         name: "the tumbling hall"))

    /// Low ledge (deck) along z, set back from the block so it clears it while it turns.
    func deck(_ b: BodyBuilder, _ x0: Double, _ x1: Double, _ z: Double, inner: Double) {
        let zMin = z < 0 ? z - 0.5 : inner, zMax = z < 0 ? -inner : z + 0.5
        b.def.solids.append(SolidDef(min: V3(x0 - 0.5, CLOUD, zMin), max: V3(x1 + 0.5, 2.5, zMax)))
        b.visual(.box(min: V3(x0 - 0.5, CLOUD, zMin), max: V3(x1 + 0.5, 2.5, zMax), mat: "stone", cap: true, capMat: nil))
        b.visual(.box(min: V3(x0 - 0.545, 2.14, zMin - 0.045), max: V3(x1 + 0.545, 2.23, zMax + 0.045), mat: "trim", cap: false, capMat: nil))
        var x = x0
        while x <= x1 { b.tile(x, 2.5, z); x += 1 }
    }

    let south = B("south", palette: "slate")
    deck(south, 0, 2, 2, inner: 1.55)
    south.box(2, 2, 3, 3, CLOUD, 2.5)
    south.tag(2, 2.5, 3, "start").glyph(2, 2.5, 3, "start")
    south.block(V3(-0.4, 2.5, 2.35), V3(0.35, 3.2, 2.45), "trim", false)
    south.window(1, 1.2, 2.5, .pz, 0.16, 0.6).window(2.5, 0.6, 3, .px, 0.16, 0.6)

    let north = B("north", palette: "slate")
    deck(north, -1, 2, -2, inner: 1.55)
    north.stairs(-1, -1, .pz, 2.5, 1, base: CLOUD)
    north.pavilion(2, 2.5, -2, h: 1.3, roof: "roofViolet", style: .onion)
    north.window(1, 1.2, -1.55, .pz, 0.16, 0.6)

    let west = B("west", palette: "slate")
    west.box(-1, -1, 0, 0, CLOUD, 3.5)
    minaret(west, -1.28, 3.5, 0.28, h: 1.4, w: 0.26, roof: "roofViolet")
    west.window(-1, 0.4, 0.5, .pz, 0.16, 0.6)

    let east = B("east", palette: "slate")
    east.box(3, 3, -2, 0, CLOUD, 3.5)
    east.tag(3, 3.5, -2, "goal")
    east.visual(.shrine(x: 3, y: 3.5, z: -2))
    east.window(3, 0.8, 0.5, .pz, 0.16, 0.6).window(3.5, 0.2, -1, .px, 0.16, 0.6)
    east.banner(3.55, 3.3, -0.4, .px, len: 1.3, w: 0.24, mat: "banner")

    let zones = [zone3("c5", V3(1.2, 2.8, 0.2), 6.2, "deep",
                       ["Every face of the hall is a road.", "Lie it on its back to cross; stand it on its side to climb."])]
    return LevelDef(bodies: bodies.map { $0.build() }, mechs: mechs, plates: [], zones: zones,
                    start: south.ref(2, 2.5, 3), goal: east.ref(3, 3.5, -2), rotateFlag: "__never__")
}
