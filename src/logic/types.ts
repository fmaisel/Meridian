// Pure data types describing the level. No rendering dependencies.

export type V3 = [number, number, number];

/** An open edge of a walkable tile: horizontal direction and the surface height at that edge. */
export interface EdgeDef {
  dir: V3;
  h: number;
  /** Edge may connect through a perspective seam (projection-based link). */
  seam?: boolean;
}

export interface TileDef {
  id: string;
  /** Standing point in body-local coordinates. */
  pos: V3;
  edges: EdgeDef[];
  /** 'plate:<id>' | 'goal' | 'eye' | 'start' | 'stair' */
  tags: string[];
}

export interface SolidDef {
  min: V3;
  max: V3;
}

/** Visual descriptors are opaque to the logic layer and consumed by the renderer. */
export interface VisualDef {
  type: string;
  [k: string]: unknown;
}

export interface BodyDef {
  id: string;
  /** Parent body; this body's pose is relative to it. */
  parent?: string;
  /** Mechanism driving this body's pose. */
  mech?: string;
  tiles: TileDef[];
  solids: SolidDef[];
  visuals: VisualDef[];
  /** Moving part that rides on rails/frames instead of standing on the clouds (support check). */
  rides?: boolean;
  /** Palette key used by the renderer. */
  palette: string;
  /** Camera zone that tiles of this body belong to (may be overridden per tile). */
  zone: string;
  tileZones?: Record<string, string>;
}

export interface ControlDef {
  type: 'crank' | 'knob' | 'none';
  /** Body that carries the handle visual (usually the mechanism body itself or a static base). */
  body?: string;
  /** Handle position in the carrier body's local space. */
  at?: V3;
  /** Flag required before the handle can be used. */
  requires?: string;
}

interface MechBase {
  id: string;
  initial: number;
  /** Character may stay on the body while it moves. */
  rider: boolean;
  control: ControlDef;
  /** Allowed discrete states. */
  states: number[];
  /** Short hint shown when the player is stuck near this mechanism. */
  name?: string;
  /** Seconds for plate-driven motion. */
  duration?: number;
}

export interface RotatorDef extends MechBase {
  kind: 'rotator';
  pivot: V3;
  axis: V3;
}

export interface SliderDef extends MechBase {
  kind: 'slider';
  axis: V3;
  step: number;
}

/** Plate- or script-driven body that moves between authored poses (translation only). */
export interface LiftDef extends MechBase {
  kind: 'lift';
  poses: V3[];
}

export type MechDef = RotatorDef | SliderDef | LiftDef;

export type PlateAction = { mech: string; to: number } | { flag: string };

export interface PlateDef {
  id: string;
  /** Tile reference 'bodyId/tileId'. */
  tile: string;
  actions: PlateAction[];
  /** Chapter card shown when the plate is pressed. */
  title?: string;
}

export interface ZoneDef {
  id: string;
  title?: string;
  /** Camera look-at target. */
  target: V3;
  /** Orthographic half-height in world units. */
  size: number;
  /** Atmosphere key for sky/fog. */
  mood: string;
  /** Hint lines shown progressively when the player is idle in this zone. */
  hints?: string[];
}

export interface LevelDef {
  bodies: BodyDef[];
  mechs: MechDef[];
  plates: PlateDef[];
  zones: ZoneDef[];
  start: string;
  goal: string;
  /** Flag that unlocks world rotation. */
  rotateFlag: string;
  initialFlags?: string[];
}

export interface PuzzleState {
  mech: Record<string, number>;
  flags: string[];
  cam: number;
}
