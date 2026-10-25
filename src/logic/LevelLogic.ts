import { Matrix4, Quaternion, Vector3 } from 'three';
import type { BodyDef, LevelDef, MechDef, PuzzleState, SolidDef, TileDef, V3 } from './types';

/** Isometric view vectors (camera offset direction), one per world-rotation quadrant. q+1 = +90° about Y. */
export const VIEWS: V3[] = [
  [1, 1, 1],
  [1, 1, -1],
  [-1, 1, -1],
  [-1, 1, 1],
];

const UP = new Vector3(0, 1, 0);
const EPS = 1e-3;

export interface NavEdge {
  p: Vector3;
  d: Vector3;
  seam: boolean;
}

export interface NavNode {
  id: string;
  body: string;
  tile: TileDef;
  pos: Vector3;
  edges: NavEdge[];
  zone: string;
  tags: string[];
}

export interface NavLink {
  to: string;
  seam: boolean;
  /** Edge point on the source side. */
  a: Vector3;
  /** Edge point on the destination side (differs from `a` only for seams, by k·view). */
  b: Vector3;
  cost: number;
}

export interface NavGraph {
  nodes: Map<string, NavNode>;
  links: Map<string, NavLink[]>;
  view: V3;
}

export interface WorldBox {
  body: string;
  min: Vector3;
  max: Vector3;
}

const r6 = (n: number) => Math.round(n * 1e6) / 1e6;
const snapV = (v: Vector3) => v.set(r6(v.x), r6(v.y), r6(v.z));
const key4 = (v: Vector3) => `${Math.round(v.x * 4)},${Math.round(v.y * 4)},${Math.round(v.z * 4)}`;

/**
 * Pure level logic: body transforms as a function of mechanism parameters, solids in world space and
 * the navigation graph (physical links + perspective seams) for a given puzzle state.
 */
export class LevelLogic {
  readonly def: LevelDef;
  readonly bodies = new Map<string, BodyDef>();
  readonly mechs = new Map<string, MechDef>();
  readonly order: BodyDef[] = [];
  private graphCache = new Map<string, NavGraph>();

  constructor(def: LevelDef) {
    this.def = def;
    for (const b of def.bodies) this.bodies.set(b.id, b);
    for (const m of def.mechs) this.mechs.set(m.id, m);
    // Topological order so parents are resolved before children.
    const seen = new Set<string>();
    const visit = (b: BodyDef) => {
      if (seen.has(b.id)) return;
      if (b.parent) {
        const p = this.bodies.get(b.parent);
        if (!p) throw new Error(`Body ${b.id}: unknown parent ${b.parent}`);
        visit(p);
      }
      seen.add(b.id);
      this.order.push(b);
    };
    def.bodies.forEach(visit);
    for (const b of def.bodies) {
      if (b.mech && !this.mechs.has(b.mech)) throw new Error(`Body ${b.id}: unknown mech ${b.mech}`);
    }
  }

  initialState(): PuzzleState {
    const mech: Record<string, number> = {};
    for (const m of this.def.mechs) mech[m.id] = m.initial;
    return { mech, flags: [...(this.def.initialFlags ?? [])].sort(), cam: 0 };
  }

  /** Local pose of a mechanism for a continuous parameter (state index, may be fractional while animating). */
  mechMatrix(m: MechDef, param: number, out = new Matrix4()): Matrix4 {
    if (m.kind === 'rotator') {
      const p = new Vector3(...m.pivot);
      const q = new Quaternion().setFromAxisAngle(new Vector3(...m.axis).normalize(), (param * Math.PI) / 2);
      out.makeTranslation(p.x, p.y, p.z);
      out.multiply(new Matrix4().makeRotationFromQuaternion(q));
      out.multiply(new Matrix4().makeTranslation(-p.x, -p.y, -p.z));
      return out;
    }
    if (m.kind === 'slider') {
      const a = new Vector3(...m.axis).multiplyScalar(param * m.step);
      return out.makeTranslation(a.x, a.y, a.z);
    }
    const n = m.poses.length - 1;
    const c = Math.max(0, Math.min(n, param));
    const i = Math.min(n - 1, Math.floor(c));
    const t = n === 0 ? 0 : c - i;
    const a = new Vector3(...m.poses[i]);
    const b = new Vector3(...m.poses[Math.min(n, i + 1)]);
    a.lerp(b, t);
    return out.makeTranslation(a.x, a.y, a.z);
  }

  /** World matrices for all bodies given mechanism parameters. */
  bodyMatrices(params: Record<string, number>): Map<string, Matrix4> {
    const out = new Map<string, Matrix4>();
    for (const b of this.order) {
      const m = new Matrix4();
      if (b.parent) m.copy(out.get(b.parent)!);
      if (b.mech) {
        const md = this.mechs.get(b.mech)!;
        m.multiply(this.mechMatrix(md, params[b.mech] ?? md.initial));
      }
      out.set(b.id, m);
    }
    return out;
  }

  /** Is `bodyId` the given body or one of its descendants? */
  isWithin(bodyId: string, ancestor: string): boolean {
    let cur: string | undefined = bodyId;
    while (cur) {
      if (cur === ancestor) return true;
      cur = this.bodies.get(cur)?.parent;
    }
    return false;
  }

  /** Bodies moved by a mechanism (the driven bodies and all their descendants). */
  bodiesMovedBy(mechId: string): string[] {
    const roots = this.def.bodies.filter((b) => b.mech === mechId).map((b) => b.id);
    return this.def.bodies.filter((b) => roots.some((r) => this.isWithin(b.id, r))).map((b) => b.id);
  }

  worldSolids(mats: Map<string, Matrix4>): WorldBox[] {
    const out: WorldBox[] = [];
    const corner = new Vector3();
    for (const b of this.order) {
      const m = mats.get(b.id)!;
      for (const s of b.solids) out.push(transformBox(s, m, b.id, corner));
    }
    return out;
  }

  graphKey(state: PuzzleState): string {
    const parts = this.def.mechs.map((m) => state.mech[m.id]);
    return parts.join(',') + '|' + state.cam;
  }

  graph(state: PuzzleState): NavGraph {
    const key = this.graphKey(state);
    let g = this.graphCache.get(key);
    if (!g) {
      g = this.buildGraph(state.mech, state.cam);
      if (this.graphCache.size > 4000) this.graphCache.clear();
      this.graphCache.set(key, g);
    }
    return g;
  }

  buildGraph(params: Record<string, number>, cam: number, exclude?: Set<string>): NavGraph {
    const mats = this.bodyMatrices(params);
    const solids = this.worldSolids(mats);
    const view = VIEWS[((cam % 4) + 4) % 4];
    const nodes = new Map<string, NavNode>();
    const n = new Vector3();
    const probe = new Vector3();

    for (const b of this.order) {
      if (exclude?.has(b.id)) continue;
      const m = mats.get(b.id)!;
      const rot = new Matrix4().extractRotation(m);
      n.copy(UP).applyMatrix4(rot);
      if (n.y < 1 - EPS) continue; // surfaces of this body do not face up in this pose
      for (const t of b.tiles) {
        const pos = snapV(new Vector3(...t.pos).applyMatrix4(m));
        probe.set(pos.x, pos.y + 0.45, pos.z);
        if (solids.some((s) => inside(probe, s))) continue;
        const edges: NavEdge[] = t.edges.map((e) => {
          const local = new Vector3(t.pos[0] + e.dir[0] * 0.5, e.h, t.pos[2] + e.dir[2] * 0.5);
          return {
            p: snapV(local.applyMatrix4(m)),
            d: snapV(new Vector3(...e.dir).applyMatrix4(rot)),
            seam: !!e.seam,
          };
        });
        const id = `${b.id}/${t.id}`;
        nodes.set(id, {
          id,
          body: b.id,
          tile: t,
          pos,
          edges,
          zone: b.tileZones?.[t.id] ?? b.zone,
          tags: t.tags,
        });
      }
    }

    const links = new Map<string, NavLink[]>();
    for (const id of nodes.keys()) links.set(id, []);
    const byPoint = new Map<string, { node: NavNode; e: NavEdge }[]>();
    const byProj = new Map<string, { node: NavNode; e: NavEdge }[]>();
    const proj = (p: Vector3) =>
      `${Math.round((p.x - view[0] * p.y) * 4)},${Math.round((p.z - view[2] * p.y) * 4)}`;

    for (const node of nodes.values()) {
      for (const e of node.edges) {
        const k = key4(e.p);
        if (!byPoint.has(k)) byPoint.set(k, []);
        byPoint.get(k)!.push({ node, e });
        if (e.seam) {
          const pk = proj(e.p);
          if (!byProj.has(pk)) byProj.set(pk, []);
          byProj.get(pk)!.push({ node, e });
        }
      }
    }

    const addLink = (a: NavNode, ea: NavEdge, b: NavNode, eb: NavEdge, seam: boolean) => {
      if (a.id === b.id) return;
      const list = links.get(a.id)!;
      if (list.some((l) => l.to === b.id)) return;
      const cost = a.pos.distanceTo(ea.p) + b.pos.distanceTo(eb.p) + (seam ? 0.25 : 0);
      list.push({ to: b.id, seam, a: ea.p.clone(), b: eb.p.clone(), cost });
    };
    const opposite = (d1: Vector3, d2: Vector3) => Math.abs(d1.x + d2.x) < EPS && Math.abs(d1.z + d2.z) < EPS;

    for (const group of byPoint.values()) {
      for (const x of group)
        for (const y of group) if (x.node !== y.node && opposite(x.e.d, y.e.d)) addLink(x.node, x.e, y.node, y.e, false);
    }
    for (const group of byProj.values()) {
      for (const x of group)
        for (const y of group) {
          if (x.node === y.node || !opposite(x.e.d, y.e.d)) continue;
          if (key4(x.e.p) === key4(y.e.p)) continue; // physical, already handled
          addLink(x.node, x.e, y.node, y.e, true);
        }
    }
    return { nodes, links, view };
  }

  /** Pairs of solids from different, non-related bodies that interpenetrate (for validation). */
  overlaps(params: Record<string, number>, onlyMoving = true): [WorldBox, WorldBox][] {
    const mats = this.bodyMatrices(params);
    const solids = this.worldSolids(mats);
    const moving = new Set<string>();
    for (const m of this.def.mechs) this.bodiesMovedBy(m.id).forEach((b) => moving.add(b));
    const out: [WorldBox, WorldBox][] = [];
    for (let i = 0; i < solids.length; i++)
      for (let j = i + 1; j < solids.length; j++) {
        const a = solids[i];
        const b = solids[j];
        if (a.body === b.body) continue;
        if (onlyMoving && !moving.has(a.body) && !moving.has(b.body)) continue;
        if (this.isWithin(a.body, b.body) || this.isWithin(b.body, a.body)) continue;
        if (boxesOverlap(a, b, 0.02)) out.push([a, b]);
      }
    return out;
  }
}

function transformBox(s: SolidDef, m: Matrix4, body: string, c: Vector3): WorldBox {
  const min = new Vector3(Infinity, Infinity, Infinity);
  const max = new Vector3(-Infinity, -Infinity, -Infinity);
  for (let i = 0; i < 8; i++) {
    c.set(i & 1 ? s.max[0] : s.min[0], i & 2 ? s.max[1] : s.min[1], i & 4 ? s.max[2] : s.min[2]).applyMatrix4(m);
    min.min(c);
    max.max(c);
  }
  return { body, min: snapV(min), max: snapV(max) };
}

function inside(p: Vector3, s: WorldBox): boolean {
  return (
    p.x > s.min.x + EPS && p.x < s.max.x - EPS &&
    p.y > s.min.y + EPS && p.y < s.max.y - EPS &&
    p.z > s.min.z + EPS && p.z < s.max.z - EPS
  );
}

function boxesOverlap(a: WorldBox, b: WorldBox, eps: number): boolean {
  return (
    a.min.x < b.max.x - eps && a.max.x > b.min.x + eps &&
    a.min.y < b.max.y - eps && a.max.y > b.min.y + eps &&
    a.min.z < b.max.z - eps && a.max.z > b.min.z + eps
  );
}

/** Dijkstra over the nav graph. Returns node ids from start to goal (inclusive) or null. */
export function findPath(g: NavGraph, from: string, to: string): string[] | null {
  if (!g.nodes.has(from) || !g.nodes.has(to)) return null;
  if (from === to) return [from];
  const dist = new Map<string, number>([[from, 0]]);
  const prev = new Map<string, string>();
  const open = new Set<string>([from]);
  while (open.size) {
    let cur = '';
    let best = Infinity;
    for (const id of open) {
      const d = dist.get(id)!;
      if (d < best) { best = d; cur = id; }
    }
    open.delete(cur);
    if (cur === to) break;
    for (const l of g.links.get(cur) ?? []) {
      const nd = best + l.cost;
      if (nd < (dist.get(l.to) ?? Infinity)) {
        dist.set(l.to, nd);
        prev.set(l.to, cur);
        open.add(l.to);
      }
    }
  }
  if (!prev.has(to)) return null;
  const path = [to];
  let c = to;
  while (c !== from) { c = prev.get(c)!; path.push(c); }
  return path.reverse();
}

/** All node ids reachable from `from`. */
export function reachable(g: NavGraph, from: string): Set<string> {
  const seen = new Set<string>();
  if (!g.nodes.has(from)) return seen;
  const stack = [from];
  seen.add(from);
  while (stack.length) {
    const c = stack.pop()!;
    for (const l of g.links.get(c) ?? []) if (!seen.has(l.to)) { seen.add(l.to); stack.push(l.to); }
  }
  return seen;
}
