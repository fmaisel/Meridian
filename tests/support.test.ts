import { describe, expect, it } from 'vitest';
import { Box3, Vector3 } from 'three';
import { buildLevel, CLOUD } from '../src/level/level';
import { LevelLogic } from '../src/logic/LevelLogic';
import type { V3 } from '../src/logic/types';

// "Nothing stands in the air": every solid, slab, pillar and arch must reach down into the cloud deck
// or touch something that does (transitively). Parts that ride on rails/frames are exempt.

const def = buildLevel();
const logic = new LevelLogic(def);

interface Item { body: string; box: Box3; label: string }

function items(params: Record<string, number>): Item[] {
  const mats = logic.bodyMatrices(params);
  const out: Item[] = [];
  const push = (body: string, min: V3, max: V3, label: string) => {
    const b = new Box3(new Vector3(...min), new Vector3(...max)).applyMatrix4(mats.get(body)!);
    out.push({ body, box: b, label });
  };
  for (const b of def.bodies) {
    for (const s of b.solids) push(b.id, s.min, s.max, 'solid');
    for (const v of b.visuals) {
      const n = (k: string) => v[k] as number;
      if (v.type === 'box') push(b.id, v.min as V3, v.max as V3, 'box');
      else if (v.type === 'pillar' || v.type === 'column')
        push(b.id, [n('x') - n('r'), n('y0'), n('z') - n('r')], [n('x') + n('r'), n('y1'), n('z') + n('r')], v.type);
      else if (v.type === 'arch') {
        const half = n('span') / 2;
        const t = n('thick') / 2;
        const ax = v.axis === 'x';
        push(b.id, [n('x') - (ax ? half : t), n('y0'), n('z') - (ax ? t : half)], [n('x') + (ax ? half : t), n('y1'), n('z') + (ax ? t : half)], 'arch');
      }
    }
  }
  return out;
}

function touches(a: Box3, b: Box3, eps = 0.03): boolean {
  return (
    a.min.x <= b.max.x + eps && a.max.x >= b.min.x - eps &&
    a.min.y <= b.max.y + eps && a.max.y >= b.min.y - eps &&
    a.min.z <= b.max.z + eps && a.max.z >= b.min.z - eps
  );
}

function floating(params: Record<string, number>): Item[] {
  const list = items(params);
  const rides = new Set(def.bodies.filter((b) => b.rides).map((b) => b.id));
  const grounded = list.map((i) => i.box.min.y <= CLOUD + 0.5 || rides.has(i.body));
  let changed = true;
  while (changed) {
    changed = false;
    for (let i = 0; i < list.length; i++) {
      if (grounded[i]) continue;
      for (let j = 0; j < list.length; j++)
        if (grounded[j] && touches(list[i].box, list[j].box)) { grounded[i] = true; changed = true; break; }
    }
  }
  return list.filter((_, i) => !grounded[i]);
}

describe('support', () => {
  it('nothing floats once every lift has risen', () => {
    const p: Record<string, number> = {};
    for (const m of def.mechs) p[m.id] = m.kind === 'lift' ? m.states[m.states.length - 1] : m.initial;
    const f = floating(p).map((i) => `${i.body} ${i.label} ${i.box.min.toArray().map((v) => v.toFixed(2))}`);
    expect(f).toEqual([]);
  });

  it('nothing floats in the initial state', () => {
    const p: Record<string, number> = {};
    for (const m of def.mechs) p[m.id] = m.initial;
    expect(floating(p).map((i) => `${i.body} ${i.label}`)).toEqual([]);
  });

  it('lowered lifts are hidden inside the clouds', () => {
    const p: Record<string, number> = {};
    for (const m of def.mechs) p[m.id] = m.initial;
    const mats = logic.bodyMatrices(p);
    for (const m of def.mechs.filter((m) => m.kind === 'lift' && m.initial === 0 && m.poses[0][1] < -5)) {
      for (const bid of logic.bodiesMovedBy(m.id)) {
        const b = def.bodies.find((x) => x.id === bid)!;
        for (const s of b.solids) {
          const top = new Box3(new Vector3(...s.min), new Vector3(...s.max)).applyMatrix4(mats.get(bid)!).max.y;
          expect(top, `${bid} pokes out of the clouds`).toBeLessThan(-9.5);
        }
      }
    }
  });
});

describe('motion', () => {
  it('lifts and sliders never pass through other architecture while moving', () => {
    const base: Record<string, number> = {};
    for (const m of def.mechs) base[m.id] = m.kind === 'lift' ? m.states[m.states.length - 1] : m.initial;
    const hits: string[] = [];
    for (const m of def.mechs.filter((x) => x.kind !== 'rotator')) {
      const moving = new Set(logic.bodiesMovedBy(m.id));
      const lo = Math.min(...m.states);
      const hi = Math.max(...m.states);
      for (let i = 0; i <= 40; i++) {
        const p = { ...base, [m.id]: lo + ((hi - lo) * i) / 40 };
        const solids = logic.worldSolids(logic.bodyMatrices(p));
        for (const a of solids.filter((s) => moving.has(s.body)))
          for (const b of solids.filter((s) => !moving.has(s.body))) {
            if (a.max.y < CLOUD + 6 && b.max.y < CLOUD + 6) continue; // hidden inside the clouds
            const o = (k: 'x' | 'y' | 'z') => Math.min(a.max[k], b.max[k]) - Math.max(a.min[k], b.min[k]);
            if (o('x') > 0.03 && o('y') > 0.03 && o('z') > 0.03) hits.push(`${a.body}×${b.body}`);
          }
      }
    }
    expect([...new Set(hits)]).toEqual([]);
  });
});
