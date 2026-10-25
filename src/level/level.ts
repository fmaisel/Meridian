// MERIDIAN — the single level.
// Coordinates: integer cells, Y up. A tile at (x,y,z) is a walkable surface at height y.
// Default view looks from (+1,+1,+1): +x runs down-right on screen, +z down-left, +y up.
// Every structure either reaches down into the cloud deck (y < CLOUD) or rests on / hangs from one that does.
import { BodyBuilder } from './kit';
import type { LevelDef, MechDef, PlateDef, ZoneDef } from '../logic/types';

/** Supports end here, deep inside the cloud deck. */
export const CLOUD = -18;

export function buildLevel(): LevelDef {
  const bodies: BodyBuilder[] = [];
  const mechs: MechDef[] = [];
  const plates: PlateDef[] = [];
  const B = (id: string, o: ConstructorParameters<typeof BodyBuilder>[1]) => {
    const b = new BodyBuilder(id, o);
    bodies.push(b);
    return b;
  };
  /** Square support column from the clouds up to `top`, centred on (x,z). */
  const support = (b: BodyBuilder, x: number, z: number, top: number, w = 0.7, mat = 'stone') => {
    b.block([x - w / 2, CLOUD, z - w / 2], [x + w / 2, top, z + w / 2], mat);
    // capital and a slim band give every column a finished, carved look
    const c = w / 2 + 0.1;
    b.block([x - c, top - 0.24, z - c], [x + c, top, z + c], 'trim', false);
    if (top > -1) b.block([x - w / 2 - 0.05, top - 1.1, z - w / 2 - 0.05], [x + w / 2 + 0.05, top - 0.98, z + w / 2 + 0.05], 'trim', false);
  };

  // ───────────────────────── The Central Tower (landmark) ─────────────────────────
  const tower = B('tower', { palette: 'ivory', zone: 'z6' });
  tower.box(-1, 1, -1, 1, CLOUD, 15.2, { walk: false, mat: 'stone' });
  tower.block([-1.62, 3.6, -1.62], [1.62, 3.9, 1.62], 'trim', false);
  tower.block([-1.62, 9.6, -1.62], [1.62, 9.9, 1.62], 'trim', false);
  for (const y of [-2, 1, 5.2, 7.6, 11.6, 13.6]) {
    tower.window(0, y, 1.5, 'pz', 0.2, 0.9);
    tower.window(1.5, y, 0, 'px', 0.2, 0.9);
    tower.window(0, y, -1.5, 'nz', 0.2, 0.9);
    tower.window(-1.5, y, 0, 'nx', 0.2, 0.9);
  }
  // corner pilasters and a frieze of small arched windows under the crown
  for (const [cx, cz] of [[-1.5, -1.5], [1.5, -1.5], [-1.5, 1.5], [1.5, 1.5]])
    tower.block([cx - 0.1, CLOUD, cz - 0.1], [cx + 0.1, 15.2, cz + 0.1], 'trim', false);
  for (const o of [-0.85, 0, 0.85]) {
    tower.window(o, 14.55, 1.5, 'pz', 0.13, 0.42).window(1.5, 14.55, o, 'px', 0.13, 0.42);
    tower.window(o, 14.55, -1.5, 'nz', 0.13, 0.42).window(-1.5, 14.55, o, 'nx', 0.13, 0.42);
  }
  tower.block([-1.64, 14.1, -1.64], [1.64, 14.2, 1.64], 'trim', false);
  // long banners hang from the cornice on the two faces seen first
  tower.banner(0.7, 9.55, 1.62, 'pz', { len: 3.4, w: 0.42 }).banner(1.62, 9.55, -0.7, 'px', { len: 3.4, w: 0.42 });

  // ───────────────────────── I. The Courtyard (y = 0) ─────────────────────────
  // Learn to walk. A plate in the corner raises the stair out of the clouds.
  const s1 = B('s1', { palette: 'sand', zone: 'z1' });
  s1.box(3, 7, 7, 7, CLOUD, 0).box(3, 7, 3, 3, CLOUD, 0).box(3, 3, 4, 6, CLOUD, 0).box(7, 7, 4, 6, CLOUD, 0);
  s1.block([3.5, CLOUD, 3.5], [6.5, -0.55, 6.5], 'stone');
  s1.visual({ type: 'water', min: [3.5, -0.32, 3.5], max: [6.5, -0.32, 6.5] });
  for (const [lx, lz, lr, fl] of [[4.2, 4.5, 0.22, 1], [5.6, 4.1, 0.17, 0], [5.9, 5.7, 0.24, 1], [4.6, 5.9, 0.15, 0]] as [number, number, number, number][])
    s1.visual({ type: 'lily', x: lx, y: -0.31, z: lz, r: lr, flower: fl });
  // the pool spills over the near edge and falls into the clouds
  s1.block([4.6, -0.7, 7.5], [5.4, -0.25, 8.4], 'stone', false);
  s1.visual({ type: 'water', min: [4.68, -0.36, 7.5], max: [5.32, -0.36, 8.4] });
  s1.visual({ type: 'fall', x: 5, z: 8.42, y0: CLOUD + 6, y1: -0.36, w: 0.62, face: [0, 0, 1] });
  s1.tag(7, 0, 7, 'start').glyph(7, 0, 7, 'start');
  s1.tag(3, 0, 7, 'plate:p1').glyph(3, 0, 7, 'plate');
  s1.pavilion(3, 0, 3, { h: 1.5, roof: 'roof', style: 'onion' });
  // cypress planters clinging to the outer wall
  s1.block([7.5, -1.2, 4.6], [8.4, 0.25, 5.4], 'stone', false).tree(7.95, 0.25, 5, 1.5);
  s1.block([7.5, -1.2, 5.6], [8.4, 0.1, 6.4], 'stone', false).tree(7.95, 0.1, 6, 1.1);
  s1.block([5.6, -1.2, 7.5], [6.4, 0.2, 8.4], 'stone', false).tree(6, 0.2, 7.95, 1.3);

  const st1 = B('st1', { palette: 'sand', zone: 'z1', mech: 'lift1' });
  st1.stairs(2, 4, 'nx', 0, 1, { base: CLOUD }).stairs(1, 4, 'nx', 1, 1, { base: CLOUD });
  mechs.push({ id: 'lift1', kind: 'lift', poses: [[0, -13, 0], [0, 0, 0]], initial: 0, rider: false, states: [0, 1], control: { type: 'none' } });
  plates.push({ id: 'p1', tile: s1.ref(3, 0, 7), actions: [{ mech: 'lift1', to: 1 }] });

  // ───────────────────────── II. The First Deception (y = 2) ─────────────────────────
  // A walkway ends in the void. The Eye at its end lets you turn the world; from view 3 the
  // high coral isle (B) closes the gap.
  const s2 = B('s2', { palette: 'sand', zone: 'z2' });
  s2.box(-2, 0, 3, 5, 1, 2);
  support(s2, -1, 4, 1, 1.4);
  s2.box(-5, -3, 4, 4, 1.45, 2);
  support(s2, -5, 4, 1.45, 0.4, 'trim');
  s2.tag(-5, 2, 4, 'eye').seam(-5, 2, 4, 'nx').glyph(-5, 2, 4, 'eye');
  plates.push({ id: 'eye', tile: s2.ref(-5, 2, 4), actions: [{ flag: 'eye' }] });
  s2.pavilion(-2, 2, 5, { h: 1.3, roof: 'roof', style: 'round' });
  s2.block([0.5, 1.2, 4.6], [1.3, 2.25, 5.4], 'stone', false).tree(0.9, 2.25, 5, 1.0);

  // ───────────────────────── III. The Turning Bridge (y = 4) ─────────────────────────
  const s3 = B('s3', { palette: 'coral', zone: 'z3' });
  s3.box(-10, -8, 5, 7, 3, 4);
  support(s3, -9, 6, 3, 0.8);
  s3.seam(-8, 4, 6, 'px');
  s3.pavilion(-10, 4, 7, { h: 1.5, roof: 'roofCoral', style: 'onion' });
  // west balcony with P2
  s3.box(-12, -11, 2, 4, 3.2, 4);
  support(s3, -12, 3, 3.2, 0.6);
  s3.tag(-12, 4, 3, 'plate:p2').glyph(-12, 4, 3, 'plate');
  // north platform; its stair (T3) rises toward the lattice
  s3.box(-9, -8, -1, 1, 3, 4);
  support(s3, -8.5, 0, 3, 0.8);
  s3.block([-7.5, 3, 0.6], [-6.9, 4.2, 1.4], 'stone', false).tree(-7.2, 4.2, 1, 1.15);

  // R1 — the turning bridge on its own column; the wanderer may ride it.
  const r1 = B('r1', { palette: 'coral', zone: 'z3', mech: 'r1' });
  r1.box(-9, -9, 2, 4, 3.55, 4, { mat: 'accent' });
  r1.block([-9.24, CLOUD, 2.76], [-8.76, 3.55, 3.24], 'stone');
  r1.visual({ type: 'crank', x: -9, y: 2.75, z: 3, axis: [0, 1, 0], r: 1.0, mech: 'r1' });
  mechs.push({
    id: 'r1', kind: 'rotator', pivot: [-9, 0, 3], axis: [0, 1, 0], states: [0, 1, 2, 3], initial: 1, rider: true,
    control: { type: 'crank', body: 'r1', at: [-9, 2.75, 3] }, name: 'the turning bridge',
  });

  const st3 = B('st3', { palette: 'coral', zone: 'z3', mech: 'lift3' });
  st3.flight(-9, -2, 'nz', 4, 3, 1, { base: CLOUD });
  mechs.push({ id: 'lift3', kind: 'lift', poses: [[0, -17, 0], [0, 0, 0]], initial: 0, rider: false, states: [0, 1], control: { type: 'none' } });
  plates.push({ id: 'p2', tile: s3.ref(-12, 4, 3), actions: [{ mech: 'lift3', to: 1 }] });

  // ───────────────────────── IV. The Lattice (y = 7 … 13) ─────────────────────────
  // Directly above the turning bridge. A lift with three stops; the middle walkway runs beneath the
  // upper one to plate P3, which lifts the gate on the upper walkway.
  const s4 = B('s4', { palette: 'coral', zone: 'z4' });
  s4.box(-9, -8, -5, -5, 6.4, 7);
  support(s4, -8, -5, 6.4, 0.7);
  s4.box(-10, -10, -4, -3, 9.5, 10).box(-12, -11, -3, -3, 9.5, 10);
  s4.tag(-12, 10, -3, 'plate:p3').glyph(-12, 10, -3, 'plate');
  support(s4, -12, -3, 9.5, 0.7);
  s4.box(-10, -10, -4, -2, 12.45, 13);
  support(s4, -10, -2, 12.45, 0.55);
  s4.pavilion(-11, 10, -3, { h: 1.25, roof: 'roofCoral', style: 'cone' });

  const el = B('el4', { palette: 'coral', zone: 'z4', mech: 'el4' });
  el.def.rides = true;
  el.box(-10, -10, -5, -5, 6.6, 7, { mat: 'accent' });
  el.visual({ type: 'knob', x: -10, y: 6.45, z: -5, mech: 'el4' });
  const rail = B('el4rail', { palette: 'coral', zone: 'z4' });
  for (const [px, pz] of [[-10.62, -5.62], [-9.38, -5.62], [-10.62, -4.38]] as [number, number][])
    rail.pillar(px, pz, CLOUD, 15, 0.07, 'trim');
  rail.block([-10.7, 15, -5.7], [-9.3, 15.25, -4.3], 'trim', false).dome(-10, 15.25, -5, 0.4, 'roofCoral', 'round');
  rail.banner(-9.38, 14.95, -5.62, 'px', { len: 1.0, w: 0.26, mat: 'trim' });
  mechs.push({
    id: 'el4', kind: 'slider', axis: [0, 1, 0], step: 3, states: [0, 1, 2], initial: 0, rider: true,
    control: { type: 'knob', body: 'el4', at: [-10, 6.45, -5] }, name: 'the lift',
  });

  const g4 = B('g4', { palette: 'coral', zone: 'z4', mech: 'gate4' });
  g4.def.rides = true;
  g4.block([-10.45, 13, -3.18], [-9.55, 14.25, -2.82], 'gate');
  mechs.push({ id: 'gate4', kind: 'lift', poses: [[0, 0, 0], [0, 1.45, 0]], initial: 0, rider: false, states: [0, 1], control: { type: 'none' }, duration: 1.6 });
  plates.push({ id: 'p3', tile: s4.ref(-12, 10, -3), actions: [{ mech: 'gate4', to: 1 }] });
  s4.arch({ x: -10, z: -3, axis: 'x', y0: 13, y1: 15.8, span: 1.2, openW: 0.92, openH: 1.45, thick: 0.3, mat: 'stone' });

  // ───────────────────────── V. The Bridge of Two Views (y = 13) ─────────────────────────
  // Right at the lattice exit: an L-shaped turntable (R5) leads either to the balcony with P4 or to
  // the gap. P4 slides the missing segment in along its rail. The segment's far end then reaches two
  // different landings at the crown: one only from view 0, the other only from view 1.
  const s5 = B('s5', { palette: 'dusk', zone: 'z5' });
  s5.box(-13, -12, 0, 0, 12.4, 13);
  support(s5, -12.5, 0, 12.4, 0.6);
  s5.tag(-13, 13, 0, 'plate:p4').glyph(-13, 13, 0, 'plate');
  s5.pavilion(-12, 13, 0, { h: 1.25, roof: 'roofViolet', style: 'onion' });
  // rail carrying the segment
  s5.block([-7.22, 12.15, -0.5], [-6.78, 12.55, 3.5], 'trim');
  support(s5, -7, -0.2, 12.15, 0.4, 'trim');
  support(s5, -7, 3.2, 12.15, 0.4, 'trim');

  const r5 = B('r5', { palette: 'dusk', zone: 'z5', mech: 'r5' });
  r5.box(-10, -10, -1, 0, 12.55, 13, { mat: 'accent' }).box(-9, -9, 0, 0, 12.55, 13, { mat: 'accent' });
  r5.block([-10.24, CLOUD, -0.24], [-9.76, 12.55, 0.24], 'stone');
  r5.visual({ type: 'crank', x: -10, y: 11.8, z: 0, axis: [0, 1, 0], r: 1.0, mech: 'r5' });
  mechs.push({
    id: 'r5', kind: 'rotator', pivot: [-10, 0, 0], axis: [0, 1, 0], states: [0, 1, 2, 3], initial: 3, rider: true,
    control: { type: 'crank', body: 'r5', at: [-10, 11.8, 0] }, name: 'the turntable',
  });

  const sg = B('sg5', { palette: 'dusk', zone: 'z6', mech: 'slide5' });
  sg.def.rides = true;
  sg.box(-8, -6, 0, 0, 12.55, 13, { mat: 'stone' });
  sg.seam(-6, 13, 0, 'px');
  sg.zoneOf(-8, 13, 0, 'z5');
  mechs.push({ id: 'slide5', kind: 'lift', poses: [[0, 0, 3], [0, 0, 0]], initial: 0, rider: false, states: [0, 1], control: { type: 'none' }, duration: 2.4 });
  plates.push({ id: 'p4', tile: s5.ref(-13, 13, 0), actions: [{ mech: 'slide5', to: 1 }] });

  // ───────────────────────── VI. The Crown (y = 17) ─────────────────────────
  const s6 = B('s6', { palette: 'ivory', zone: 'z6' });
  // north landing (view-1 seam) with P6, standing on its own column
  s6.box(-1, 1, -4, -4, 16.5, 17);
  s6.seam(-1, 17, -4, 'nx');
  support(s6, 0, -4, 16.5, 0.7);
  s6.tag(1, 17, -4, 'plate:p6').glyph(1, 17, -4, 'plate');
  // south landing (view-0 seam) with P5, held by a bracket from the tower; the arm cannot reach it
  s6.box(-1, -1, 4, 5, 16.5, 17).box(0, 0, 5, 5, 16.5, 17);
  s6.seam(-1, 17, 4, 'nx');
  s6.block([-1.3, 15.6, 1.5], [-0.7, 16.1, 4.5], 'trim');
  s6.block([-1.3, 16.1, 3.6], [-0.7, 16.5, 4.4], 'trim');
  s6.tag(0, 17, 5, 'plate:p5').glyph(0, 17, 5, 'plate');
  s6.block([0.5, 16.2, 4.6], [1.3, 17.25, 5.4], 'stone', false).tree(0.9, 17.25, 5, 1.0);
  plates.push({ id: 'p5', tile: s6.ref(0, 17, 5), actions: [{ flag: 'crown' }] });

  // R6 — the crown: a ring around the central spire with one arm (west in state 0).
  const cr = B('crown', { palette: 'dusk', zone: 'z6', mech: 'r6' });
  cr.box(-1, 1, -1, -1, 15.5, 17).box(-1, 1, 1, 1, 15.5, 17).box(-1, -1, 0, 0, 15.5, 17).box(1, 1, 0, 0, 15.5, 17);
  cr.block([-0.5, 15.5, -0.5], [0.5, 17.15, 0.5], 'accent');
  cr.box(-3, -2, 0, 0, 16.55, 17, { mat: 'accent' });
  cr.seam(-3, 17, 0, 'nx');
  cr.visual({ type: 'column', x: 0, z: 0, y0: 17.15, y1: 18.6, r: 0.13, mat: 'trim' });
  cr.visual({ type: 'crank', x: 0, y: 18.25, z: 0, axis: [0, 1, 0], r: 0.72, mech: 'r6' });
  cr.dome(0, 18.6, 0, 0.3, 'roofViolet', 'onion');
  cr.block([-1.6, 15.2, -1.6], [1.6, 15.5, 1.6], 'trim', false);
  mechs.push({
    id: 'r6', kind: 'rotator', pivot: [0, 0, 0], axis: [0, 1, 0], states: [0, 1, 2, 3], initial: 2, rider: true,
    control: { type: 'crank', body: 'crown', at: [0, 18.25, 0], requires: 'crown' }, name: 'the crown',
  });

  // ───────────────────────── VII–VIII. The Summit ─────────────────────────
  // Rises out of the clouds when P6 is pressed; reached through the final seam (view 2) from the crown arm.
  const sm = B('summit', { palette: 'dusk', zone: 'z7', mech: 'lift7' });
  sm.box(-8, -6, -3, -2, 18.4, 19);
  sm.seam(-6, 19, -2, 'px');
  sm.block([-7.75, CLOUD, -2.75], [-7.25, 18.4, -2.25], 'stone');
  sm.tag(-8, 19, -2, 'goal');
  sm.visual({ type: 'shrine', x: -8, y: 19, z: -2 });
  // slender turrets at the far corners frame the shrine
  for (const tz of [-3.27, -1.73]) {
    sm.block([-8.5, 19, tz - 0.2], [-8.1, 21, tz + 0.2], 'stone');
    sm.dome(-8.3, 21, tz, 0.24, 'roofViolet', 'onion');
  }
  sm.banner(-8.1, 20.8, -1.73, 'pz', { len: 0.9, w: 0.24, mat: 'gold' });
  sm.block([-8.5, 18.4, -3.55], [-5.5, 19.28, -3.45], 'trim', false);
  sm.tree(-6.15, 19, -3.2, 0.9);
  mechs.push({ id: 'lift7', kind: 'lift', poses: [[0, -32, 0], [0, 0, 0]], initial: 0, rider: false, states: [0, 1], control: { type: 'none' }, duration: 4.5 });
  plates.push({ id: 'p6', tile: s6.ref(1, 17, -4), actions: [{ mech: 'lift7', to: 1 }], title: 'VII · The Final Turning' });

  // ───────────────────────── The lower city ─────────────────────────
  // Rooftops, domes and little bridges of an older city rise just out of the cloud deck around the
  // monument. Their tops stay below y = -2.6, so (in isometric projection) they can never hide a tile.
  buildLowerCity(bodies, B);

  const zones: ZoneDef[] = [
    { id: 'z1', title: 'I · The Courtyard', target: [4, 1, 4.5], size: 6.5, mood: 'dawn', hints: ['Some stones remember being stepped on.', 'Try the glowing square in the corner.'] },
    { id: 'z2', title: 'II · The First Deception', target: [-4, 2.5, 4.5], size: 6.5, mood: 'dawn', hints: ['The path ends where the eye looks.', 'Drag the sky to turn the world.'] },
    { id: 'z3', title: 'III · The Turning Bridge', target: [-9.5, 4.5, 2.5], size: 6.5, mood: 'noon', hints: ['A bridge may carry you while it turns.', 'Stand on the bridge, then turn the wheel.'] },
    { id: 'z4', title: 'IV · The Lattice', target: [-10.2, 10.2, -3.6], size: 6.5, mood: 'noon', hints: ['Beneath the high road lies a lower one.', 'Ride the lift halfway.'] },
    { id: 'z5', title: 'V · The Bridge of Two Views', target: [-10, 13, -0.8], size: 6.5, mood: 'dusk', hints: ['The turntable leads to the balcony first.', 'Let the wheel turn the arms toward what you need.'] },
    { id: 'z6', title: 'VI · The Crown', target: [-3.2, 15.6, 0], size: 8.2, mood: 'dusk', hints: ['One road, two endings — it depends on how you look.', 'The crown turns only once the south ledge is found.'] },
    { id: 'z7', target: [-4.5, 17.5, -1.2], size: 8.2, mood: 'dusk', hints: ['Point the arm toward the summit, then turn the world.'] },
  ];

  return {
    bodies: bodies.map((b) => b.build()),
    mechs,
    plates,
    zones,
    start: s1.ref(7, 0, 7),
    goal: sm.ref(-8, 19, -2),
    rotateFlag: 'eye',
  };
}

/** Decorative city beneath the clouds (no tiles, no solids). */
function buildLowerCity(bodies: BodyBuilder[], B: (id: string, o: ConstructorParameters<typeof BodyBuilder>[1]) => BodyBuilder) {
  // footprints of everything that reaches down through the cloud deck, plus a margin
  const keepOut: [number, number, number, number][] = [[4.4, 5.6, 8.2, 12]]; // the waterfall
  for (const b of bodies)
    for (const sol of b.def.solids)
      if (sol.min[1] < -2.5) keepOut.push([sol.min[0] - 0.9, sol.max[0] + 0.9, sol.min[2] - 0.9, sol.max[2] + 0.9]);
  // the lowered stair and summit columns come up later in these places
  keepOut.push([-10.4, -7.6, -5.4, -0.6], [0.4, 2.6, 3.4, 4.6], [-9.4, -5.4, -4.4, -0.6]);
  const free = (x0: number, x1: number, z0: number, z1: number) =>
    !keepOut.some(([a, b, c, d]) => x0 < b && x1 > a && z0 < d && z1 > c);

  let seed = 11;
  const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const city = [
    B('city_sand', { palette: 'sand', zone: 'z1' }),
    B('city_coral', { palette: 'coral', zone: 'z3' }),
    B('city_ivory', { palette: 'ivory', zone: 'z6' }),
  ];
  const roofs = ['roof', 'roofCoral', 'roof'];
  const placed: [number, number, number, number, number][] = [];
  for (let gx = -22; gx <= 18; gx += 2.6)
    for (let gz = -20; gz <= 20; gz += 2.6) {
      const jx = gx + (rnd() - 0.5) * 0.9;
      const jz = gz + (rnd() - 0.5) * 0.9;
      const r = Math.hypot(jx + 2, jz);
      if (r < 6.5 || r > 21 || rnd() < 0.42) continue;
      const w = 0.8 + rnd() * 0.9;
      const d = 0.8 + rnd() * 0.9;
      const x0 = jx - w / 2, x1 = jx + w / 2, z0 = jz - d / 2, z1 = jz + d / 2;
      if (!free(x0, x1, z0, z1)) continue;
      // nearer the monument the city stands a little taller
      const top = -4.0 - rnd() * 1.8 - Math.max(0, r - 7) * 0.15;
      const mist = Math.min(0.9, 0.42 + Math.max(0, (r - 7) / 14));
      const k = Math.floor(rnd() * 3);
      const b = city[k];
      b.visual({ type: 'box', min: [x0, CLOUD, z0], max: [x1, top, z1], mat: 'stone', cap: false, mist });
      b.visual({ type: 'box', min: [x0 - 0.06, top - 0.32, z0 - 0.06], max: [x1 + 0.06, top - 0.22, z1 + 0.06], mat: 'trim', cap: false, mist });
      const style = rnd();
      if (style < 0.28) {
        b.visual({ type: 'dome', x: jx, y: top, z: jz, r: Math.min(w, d) * 0.42, mat: roofs[k], style: rnd() < 0.6 ? 'onion' : 'round', mist });
      } else if (style < 0.45) {
        b.visual({ type: 'dome', x: jx, y: top, z: jz, r: Math.min(w, d) * 0.45, mat: roofs[k], style: 'cone', mist });
      } else if (style < 0.62) {
        // a little lookout on the roof
        const t = Math.min(w, d) * 0.22;
        b.visual({ type: 'box', min: [jx - t, top, jz - t], max: [jx + t, top + 0.6, jz + t], mat: 'stone', cap: false, mist });
        b.visual({ type: 'dome', x: jx, y: top + 0.6, z: jz, r: t * 1.1, mat: roofs[k], style: 'onion', mist });
      } else if (style < 0.75) {
        // stepped roof
        b.visual({ type: 'box', min: [x0 + w * 0.2, top, z0 + d * 0.2], max: [x1 - w * 0.2, top + 0.35, z1 - d * 0.2], mat: 'stone', cap: false, mist });
      }
      for (let wi = 0; wi < 2; wi++)
        b.visual({ type: 'window', x: jx + (wi - 0.5) * w * 0.4, y: top - 0.9, z: z1, face: [0, 0, 1], w: 0.12, h: 0.38, mist });
      // occasionally a bridge to an earlier neighbour
      const nb = placed.find(([px, pz, , , pt]) => Math.abs(px - jx) < 3.2 && Math.abs(pz - jz) < 0.6 && Math.abs(pt - top) < 0.8);
      if (nb && rnd() < 0.5) {
        const y = Math.min(top, nb[4]) - 0.55;
        const xa = Math.min(nb[0], jx), xb = Math.max(nb[0], jx);
        b.visual({ type: 'box', min: [xa, y - 0.2, jz - 0.22], max: [xb, y, jz + 0.22], mat: 'trim', cap: false, mist });
      }
      placed.push([jx, jz, w, d, top]);
    }
}
