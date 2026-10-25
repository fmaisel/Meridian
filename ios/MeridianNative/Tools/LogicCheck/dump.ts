// Reference dump of the TypeScript logic. Run from the repo root:
//   npx vite-node ios/MeridianNative/Tools/LogicCheck/dump.ts > /tmp/ts.txt
// The Swift harness (main.swift) prints the identical format.
import { buildLevel } from '../../../../src/level/level';
import { LevelLogic, findPath, type NavGraph } from '../../../../src/logic/LevelLogic';
import { Puzzle } from '../../../../src/logic/Puzzle';
import { solve, type Action } from '../../../../src/logic/solver';
import type { V3 } from '../../../../src/logic/types';

const out: string[] = [];
const w = (s: string) => out.push(s);
const num = (n: number) => String(n);
const v3 = (v: ArrayLike<number>) => `${num(v[0])},${num(v[1])},${num(v[2])}`;
const val = (x: unknown): string => {
  if (Array.isArray(x)) return x.map((e) => val(e)).join(',');
  if (typeof x === 'number') return num(x);
  return String(x);
};
const fmtA = (a: Action) => (a.type === 'walk' ? `walk:${a.to}` : a.type === 'mech' ? `mech:${a.mech}:${a.to}` : `cam:${a.dir}`);

const def = buildLevel();
const logic = new LevelLogic(def);

w(`level start=${def.start} goal=${def.goal} rotateFlag=${def.rotateFlag} initialFlags=${(def.initialFlags ?? []).join('+')}`);
for (const b of def.bodies) {
  w(`body ${b.id} parent=${b.parent ?? '-'} mech=${b.mech ?? '-'} palette=${b.palette} zone=${b.zone} rides=${!!b.rides}`);
  for (const k of Object.keys(b.tileZones ?? {}).sort()) w(` tileZone ${k}=${b.tileZones![k]}`);
  w(` tiles ${b.tiles.length}`);
  for (const t of b.tiles)
    w(` tile ${t.id} pos=${v3(t.pos)} edges=${t.edges.map((e) => `${v3(e.dir)}:${num(e.h)}:${!!e.seam}`).join(';')} tags=${t.tags.join('+')}`);
  w(` solids ${b.solids.length}`);
  for (const s of b.solids) w(` solid ${v3(s.min)} ${v3(s.max)}`);
  w(` visuals ${b.visuals.length}`);
  for (const v of b.visuals) {
    const keys = Object.keys(v).filter((k) => k !== 'type' && v[k] !== undefined).sort();
    w(` visual ${v.type} ${keys.map((k) => `${k}=${val(v[k])}`).join(' ')}`);
  }
}
for (const m of def.mechs) {
  const kind =
    m.kind === 'rotator' ? `rotator pivot=${v3(m.pivot)} axis=${v3(m.axis)}` : m.kind === 'slider' ? `slider axis=${v3(m.axis)} step=${num(m.step)}` : `lift poses=${m.poses.map(v3).join(';')}`;
  const c = m.control;
  w(`mech ${m.id} ${kind} initial=${m.initial} rider=${m.rider} states=${m.states.join(',')} control=${c.type}/${c.body ?? '-'}/${c.at ? v3(c.at) : '-'}/${c.requires ?? '-'} name=${m.name ?? '-'} duration=${m.duration === undefined ? '-' : num(m.duration)}`);
}
for (const p of def.plates)
  w(`plate ${p.id} tile=${p.tile} actions=${p.actions.map((a) => ('flag' in a ? `flag:${a.flag}` : `mech:${a.mech}:${a.to}`)).join(';')} title=${p.title ?? '-'}`);
for (const z of def.zones)
  w(`zone ${z.id} title=${z.title ?? '-'} target=${v3(z.target)} size=${num(z.size)} mood=${z.mood} hints=${(z.hints ?? []).join('|')}`);

// mechanism matrices (incl. fractional animation params)
for (const m of def.mechs) {
  const lo = Math.min(...m.states), hi = Math.max(...m.states);
  for (let i = 0; i <= 8; i++) {
    const p = lo - 0.5 + ((hi - lo + 1) * i) / 8;
    w(`mechMatrix ${m.id} ${num(p)} ${Array.from(logic.mechMatrix(m, p).elements).map(num).join(',')}`);
  }
}
const mats = logic.bodyMatrices(logic.initialState().mech);
for (const b of logic.order) w(`bodyMatrix ${b.id} ${Array.from(mats.get(b.id)!.elements).map(num).join(',')}`);
for (const m of def.mechs) w(`movedBy ${m.id} ${logic.bodiesMovedBy(m.id).join(',')}`);
for (const s of logic.worldSolids(mats)) w(`worldSolid ${s.body} ${v3(s.min.toArray())} ${v3(s.max.toArray())}`);

const dumpGraph = (label: string, g: NavGraph) => {
  w(`graph ${label} view=${v3(g.view)} nodes=${g.nodes.size}`);
  for (const n of g.nodes.values()) {
    w(` node ${n.id} body=${n.body} zone=${n.zone} tags=${n.tags.join('+')} pos=${v3(n.pos.toArray())} edges=${n.edges.map((e) => `${v3(e.p.toArray())}:${v3(e.d.toArray())}:${e.seam}`).join(';')}`);
    for (const l of g.links.get(n.id)!) w(`  link ${l.to} seam=${l.seam} a=${v3(l.a.toArray())} b=${v3(l.b.toArray())} cost=${num(l.cost)}`);
  }
};

const p0 = new Puzzle(logic);
dumpGraph(logic.graphKey(p0.state), p0.graph());

const t0 = performance.now();
const res = solve(new Puzzle(logic), { checkDeadEnds: true });
const t1 = performance.now();
console.error(`TS full solve: ${(t1 - t0).toFixed(0)} ms`);
w(`solve solved=${res.solved} states=${res.states} deadEnds=${res.deadEnds.length} planLength=${res.plan.length}`);
for (const a of res.plan) w(` plan ${fmtA(a)}`);
for (const k of res.deadEnds) w(` deadEnd ${k}`);
let i = 0;
for (const k of res.all.keys()) w(` state ${i++} ${k}`);

// walk the solution; dump graph + hint query at every prefix
const p = new Puzzle(logic);
for (let step = 0; step <= res.plan.length; step++) {
  dumpGraph(`step${step} ${logic.graphKey(p.state)} char=${p.charNode} flags=${p.state.flags.join('+')}`, p.graph());
  const n = p.state.flags.length;
  const h = solve(p.clone(), { maxStates: 20000, stopWhen: (q) => q.state.flags.length > n });
  w(`hint ${step} solved=${h.solved} states=${h.states} first=${h.solved && h.plan[0] ? fmtA(h.plan[0]) : '-'} plan=${h.plan.map(fmtA).join(' ')}`);
  if (step === res.plan.length) break;
  const a = res.plan[step];
  if (a.type === 'walk') {
    const path = findPath(p.graph(), p.charNode, a.to) ?? [p.charNode];
    w(`path ${path.join(' ')}`);
    const effs = p.walk(path);
    for (const e of effs) w(`effect ${e.plate.id} ${e.mechChanges.map((c) => `${c.mech}:${c.from}->${c.to}`).join(',')} flags=${e.flags.join(',')}`);
  } else if (a.type === 'mech') {
    for (const id of def.mechs.map((m) => m.id)) w(`canOperate ${id} ${p.canOperate(id) ?? 'ok'}`);
    w(`canSetState ${a.mech} ${a.to} ${p.canSetState(a.mech, a.to) ?? 'ok'}`);
    p.setMech(a.mech, a.to);
  } else p.rotateWorld(a.dir);
}
w(`atGoal ${p.atGoal()}`);

// a graph build with exclusions and fractional params
const gx = logic.buildGraph({ ...logic.initialState().mech, r1: 1.5, el4: 0.5 }, 3, new Set(['s2']));
dumpGraph('fractional', gx);

process.stdout.write(out.join('\n') + '\n');
