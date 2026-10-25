import { describe, expect, it } from 'vitest';
import { buildLevel } from '../src/level/level';
import { LevelLogic, findPath } from '../src/logic/LevelLogic';
import { Puzzle } from '../src/logic/Puzzle';
import { solve, type Action } from '../src/logic/solver';

const def = buildLevel();
const logic = new LevelLogic(def);

const fmt = (a: Action) =>
  a.type === 'walk' ? `walk → ${a.to}` : a.type === 'mech' ? `${a.mech} → ${a.to}` : `world ${a.dir > 0 ? '⟲' : '⟳'}`;

describe('level integrity', () => {
  it('has unique body and tile ids', () => {
    const ids = new Set<string>();
    for (const b of def.bodies) {
      expect(ids.has(b.id)).toBe(false);
      ids.add(b.id);
      const tiles = new Set<string>();
      for (const t of b.tiles) {
        expect(tiles.has(t.id), `${b.id}/${t.id}`).toBe(false);
        tiles.add(t.id);
      }
    }
  });

  it('start, goal and plates refer to existing, walkable tiles', () => {
    const g = logic.graph(logic.initialState());
    expect(g.nodes.has(def.start)).toBe(true);
    const all = new Set(def.bodies.flatMap((b) => b.tiles.map((t) => `${b.id}/${t.id}`)));
    expect(all.has(def.goal)).toBe(true);
    for (const p of def.plates) expect(all.has(p.tile), p.tile).toBe(true);
  });

  it('every seam edge has a partner in at least one view and state reachable in play', () => {
    const res = solve(new Puzzle(logic), { checkDeadEnds: true });
    const used = new Set<string>();
    for (const p of res.all.values()) {
      const g = p.graph();
      for (const [id, links] of g.links) for (const l of links) if (l.seam) used.add(id);
    }
    const seamTiles = def.bodies.flatMap((b) => b.tiles.filter((t) => t.edges.some((e) => e.seam)).map((t) => `${b.id}/${t.id}`));
    for (const t of seamTiles) expect(used.has(t), `seam tile ${t} never links`).toBe(true);
  });
});

describe('solver', () => {
  const res = solve(new Puzzle(logic), { checkDeadEnds: true });

  it('the level is solvable', () => {
    if (res.solved) console.log(`Solution (${res.plan.length} actions, ${res.states} states):\n  ` + res.plan.map(fmt).join('\n  '));
    expect(res.solved).toBe(true);
  });

  it('no reachable state is a dead end', () => {
    if (res.deadEnds.length) console.log('Dead ends:', res.deadEnds.slice(0, 10));
    expect(res.deadEnds.length).toBe(0);
  });

  it('no moving solids interpenetrate in any reachable state', () => {
    const seen = new Set<string>();
    for (const p of res.all.values()) {
      const k = JSON.stringify(p.state.mech);
      if (seen.has(k)) continue;
      seen.add(k);
      // pairs that only meet deep inside the cloud deck are invisible and unreachable
      const ov = logic.overlaps(p.state.mech).filter(([a, b]) => a.max.y > -12 || b.max.y > -12);
      expect(ov.map(([a, b]) => `${a.body}×${b.body} @ ${k}`)).toEqual([]);
    }
  });

  it('every mechanism and the world rotation are necessary', () => {
    // Ablation: freezing any mechanism (or the camera) must make the level unsolvable.
    for (const m of def.mechs) {
      const frozen = {
        ...def,
        mechs: def.mechs.map((x) => (x.id === m.id ? { ...x, states: [x.initial] } : x)),
        plates: def.plates.map((p) => ({ ...p, actions: p.actions.filter((a) => !('mech' in a) || a.mech !== m.id) })),
      };
      const l2 = new LevelLogic(frozen);
      const r = solve(new Puzzle(l2));
      expect(r.solved, `level solvable without moving ${m.id}`).toBe(false);
    }
    const noCam = { ...def, rotateFlag: '__never__' };
    expect(solve(new Puzzle(new LevelLogic(noCam))).solved, 'solvable without world rotation').toBe(false);
  });

  it('pathfinding never crosses a seam in the default view at the start', () => {
    const p = new Puzzle(logic);
    const g = p.graph();
    for (const links of g.links.values()) for (const l of links) expect(l.seam).toBe(false);
    expect(findPath(g, def.start, def.start)).toEqual([def.start]);
  });
});
