// Pure data types describing the level. No rendering dependencies.
// Port of src/logic/types.ts. Logic math runs in Double so results match the JavaScript original exactly.

import simd

typealias V3 = SIMD3<Double>

/// An open edge of a walkable tile: horizontal direction and the surface height at that edge.
struct EdgeDef {
    var dir: V3
    var h: Double
    /// Edge may connect through a perspective seam (projection-based link).
    var seam: Bool = false
}

/// Tiles are reference types because the level kit tags, closes and seams them after creation.
final class TileDef {
    let id: String
    /// Standing point in body-local coordinates.
    let pos: V3
    var edges: [EdgeDef]
    /// 'plate:<id>' | 'goal' | 'eye' | 'start' | 'stair'
    var tags: [String]
    /// Surface normal in body-local space for tiles on the side or underside of a body (nil = +Y, the body's top).
    /// A faced tile is walkable whenever its normal points to the sky, so a turning block can offer a wall as a road.
    var up: V3?

    init(id: String, pos: V3, edges: [EdgeDef], tags: [String], up: V3? = nil) {
        self.id = id
        self.pos = pos
        self.edges = edges
        self.tags = tags
        self.up = up
    }
}

struct SolidDef {
    var min: V3
    var max: V3
}

enum DomeStyle: String { case onion, round, cone }
enum ArchAxis: String { case x, z }

/// Visual descriptors are opaque to the logic layer and consumed by the renderer.
enum VisualKind {
    case box(min: V3, max: V3, mat: String, cap: Bool, capMat: String?)
    case stairs(x: Double, z: Double, dir: V3, h0: Double, rise: Double, base: Double, mat: String, steps: Int)
    case pillar(x: Double, z: Double, y0: Double, y1: Double, r: Double, mat: String)
    case column(x: Double, z: Double, y0: Double, y1: Double, r: Double, mat: String)
    case arch(x: Double, z: Double, axis: ArchAxis, y0: Double, y1: Double, span: Double, thick: Double, openW: Double, openH: Double, mat: String, count: Int)
    case dome(x: Double, y: Double, z: Double, r: Double, mat: String, style: DomeStyle)
    case tree(x: Double, y: Double, z: Double, h: Double, mat: String)
    case window(x: Double, y: Double, z: Double, face: V3, w: Double, h: Double)
    case banner(x: Double, y: Double, z: Double, face: V3, len: Double, w: Double, mat: String)
    case water(min: V3, max: V3)
    case lily(x: Double, y: Double, z: Double, r: Double, flower: Bool)
    case fall(x: Double, z: Double, y0: Double, y1: Double, w: Double, face: V3)
    case glyph(x: Double, y: Double, z: Double, kind: String)
    case crank(x: Double, y: Double, z: Double, axis: V3, r: Double, mech: String)
    case knob(x: Double, y: Double, z: Double, mech: String)
    case shrine(x: Double, y: Double, z: Double)
    /// Walkable cap on a side face of a box (faced tiles); `up` is the face normal.
    case faceCap(min: V3, max: V3, up: V3)
    /// Decorative toothed wheel turning about `axis` (clockwork, pulleys).
    case gear(x: Double, y: Double, z: Double, axis: V3, r: Double, mat: String)
}

struct VisualDef {
    var kind: VisualKind
    /// 0 = clear, 1 = fully dissolved into the sky (used by the lower city).
    var mist: Double = 0
}

final class BodyDef {
    let id: String
    /// Parent body; this body's pose is relative to it.
    var parent: String?
    /// Mechanism driving this body's pose.
    var mech: String?
    var tiles: [TileDef] = []
    var solids: [SolidDef] = []
    var visuals: [VisualDef] = []
    /// Moving part that rides on rails/frames instead of standing on the clouds (support check).
    var rides = false
    /// Palette key used by the renderer.
    var palette: String
    /// Camera zone that tiles of this body belong to (may be overridden per tile).
    var zone: String
    var tileZones: [String: String] = [:]
    /// Coupled mechanisms: several bodies may share one mechanism. Each turns about its own pivot (rotators)
    /// and in its own sense — a sign of -1 makes geared bridges counter-rotate and counterweights descend.
    var pivot: V3?
    var mechSign: Double = 1

    init(id: String, palette: String, zone: String, mech: String? = nil, parent: String? = nil) {
        self.id = id
        self.palette = palette
        self.zone = zone
        self.mech = mech
        self.parent = parent
    }
}

enum ControlType: String { case crank, knob, none }

struct ControlDef {
    var type: ControlType
    /// Body that carries the handle visual (usually the mechanism body itself or a static base).
    var body: String? = nil
    /// Handle position in the carrier body's local space.
    var at: V3? = nil
    /// Flag required before the handle can be used.
    var requires: String? = nil
}

enum MechKind {
    case rotator(pivot: V3, axis: V3)
    case slider(axis: V3, step: Double)
    /// Plate- or script-driven body that moves between authored poses (translation only).
    case lift(poses: [V3])
}

struct MechDef {
    var id: String
    var kind: MechKind
    var initial: Int
    /// Character may stay on the body while it moves.
    var rider: Bool
    var control: ControlDef
    /// Allowed discrete states.
    var states: [Int]
    /// Short hint shown when the player is stuck near this mechanism.
    var name: String? = nil
    /// Seconds for plate-driven motion.
    var duration: Double? = nil

    var isRotator: Bool { if case .rotator = kind { return true } else { return false } }
    var isSlider: Bool { if case .slider = kind { return true } else { return false } }
    var isLift: Bool { if case .lift = kind { return true } else { return false } }
}

enum PlateAction {
    case mech(String, to: Int)
    case flag(String)
    /// Advance a mechanism by `by` notches through its states (wrapping) — used by step switches.
    case turn(String, by: Int)
}

struct PlateDef {
    var id: String
    /// Tile reference 'bodyId/tileId'.
    var tile: String
    var actions: [PlateAction]
    /// Chapter card shown when the plate is pressed.
    var title: String? = nil
    /// Step switch: acts every time the wanderer steps onto it (instead of once).
    var repeatable = false
}

struct ZoneDef {
    var id: String
    var title: String?
    /// Camera look-at target.
    var target: V3
    /// Orthographic half-height in world units.
    var size: Double
    /// Atmosphere key for sky/fog.
    var mood: String
    /// Hint lines shown progressively when the player is idle in this zone.
    var hints: [String]
}

struct LevelDef {
    var bodies: [BodyDef]
    var mechs: [MechDef]
    var plates: [PlateDef]
    var zones: [ZoneDef]
    var start: String
    var goal: String
    /// Flag that unlocks world rotation.
    var rotateFlag: String
    var initialFlags: [String] = []
}

struct PuzzleState: Codable, Equatable {
    var mech: [String: Int]
    /// Always kept sorted.
    var flags: [String]
    var cam: Int
}
