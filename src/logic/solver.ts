import { findPath, reachable } from './LevelLogic';
import { Puzzle } from './Puzzle';

export type Action =
  | { type: 'walk'; to: string }
  | { type: 'mech'; mech: string; to: number }
  | { type: 'cam'; dir: 1 | -1 };

interface SNode {
  key: string;
  puzzle: Puzzle;
  parent?: string;
  action?: Action;
  depth: number;
}

export interface SolveResult {
  solved: boolean;
  /** Actions from the start state to the goal (shortest in number of actions). */
  plan: Action[];
  states: number;
  /** Keys of reachable states from which the goal can no longer be reached. */
  deadEnds: string[];
  /** Reachable states (for further validation). */
  all: Map<string, Puzzle>;
}

/** Canonical character position: the first node of the same body within the same connected component. */
function canonical(p: Puzzle): string {
  const g = p.graph();
  const node = g.nodes.get(p.charNode);
  if (!node || p.atGoal()) return p.charNode;
  const comp = reachable(g, p.charNode);
  let best = p.charNode;
  for (const id of comp) if (g.nodes.get(id)!.body === node.body && id < best) best = id;
  return best;
}

export function stateKey(p: Puzzle): string {
  const m = p.logic.def.mechs.map((d) => p.state.mech[d.id]).join(',');
  return `${m}|${p.state.flags.join('+')}|${p.state.cam}|${canonical(p)}`;
}

/** Successor states via abstract actions (walks to interesting nodes, mechanism moves, world rotation). */
export function successors(p: Puzzle): { action: Action; next: Puzzle }[] {
  const out: { action: Action; next: Puzzle }[] = [];
  const g = p.graph();
  const comp = reachable(g, p.charNode);
  const goal = p.logic.def.goal;

  // walks: plates not yet pressed, the goal, one representative per body (for riding / standing aside)
  const targets = new Set<string>();
  const seenBodies = new Set<string>();
  for (const id of [...comp].sort()) {
    if (id === p.charNode) continue;
    const n = g.nodes.get(id)!;
    const plate = p.plateAt(id);
    if (plate && !p.hasFlag(`plate:${plate.id}`)) targets.add(id);
    if (id === goal) targets.add(id);
    if (!seenBodies.has(n.body)) {
      seenBodies.add(n.body);
      targets.add(id);
    }
  }
  for (const t of targets) {
    const path = findPath(g, p.charNode, t);
    if (!path) continue;
    const next = p.clone();
    next.walk(path);
    out.push({ action: { type: 'walk', to: t }, next });
  }

  for (const m of p.logic.def.mechs) {
    for (const s of m.states) {
      if (s === p.state.mech[m.id]) continue;
      if (p.canSetState(m.id, s)) continue;
      const next = p.clone();
      next.setMech(m.id, s);
      out.push({ action: { type: 'mech', mech: m.id, to: s }, next });
    }
  }

  if (p.canRotateWorld) {
    for (const dir of [1, -1] as const) {
      const next = p.clone();
      next.rotateWorld(dir);
      out.push({ action: { type: 'cam', dir }, next });
    }
  }
  return out;
}

/** Exhaustive breadth-first search over the puzzle state space. */
export function solve(
  start: Puzzle,
  opts: { maxStates?: number; checkDeadEnds?: boolean; stopWhen?: (p: Puzzle) => boolean } = {},
): SolveResult {
  const max = opts.maxStates ?? 200000;
  const nodes = new Map<string, SNode>();
  const edges = new Map<string, string[]>();
  const k0 = stateKey(start);
  nodes.set(k0, { key: k0, puzzle: start.clone(), depth: 0 });
  const queue = [k0];
  let goalKey: string | null = null;
  const goals: string[] = [];

  while (queue.length && nodes.size < max) {
    const k = queue.shift()!;
    const cur = nodes.get(k)!;
    if (cur.puzzle.atGoal() || (opts.stopWhen && k !== k0 && opts.stopWhen(cur.puzzle))) {
      goals.push(k);
      if (!goalKey) goalKey = k;
      if (!opts.checkDeadEnds) break;
      continue;
    }
    const succ = successors(cur.puzzle);
    const list: string[] = [];
    for (const { action, next } of succ) {
      const nk = stateKey(next);
      list.push(nk);
      if (!nodes.has(nk)) {
        nodes.set(nk, { key: nk, puzzle: next, parent: k, action, depth: cur.depth + 1 });
        queue.push(nk);
      }
    }
    edges.set(k, list);
  }

  const plan: Action[] = [];
  if (goalKey) {
    let c: string | undefined = goalKey;
    while (c && nodes.get(c)!.action) {
      plan.push(nodes.get(c)!.action!);
      c = nodes.get(c)!.parent;
    }
    plan.reverse();
  }

  const deadEnds: string[] = [];
  if (opts.checkDeadEnds) {
    const rev = new Map<string, string[]>();
    for (const [a, list] of edges) for (const b of list) {
      if (!rev.has(b)) rev.set(b, []);
      rev.get(b)!.push(a);
    }
    const ok = new Set<string>(goals);
    const stack = [...goals];
    while (stack.length) {
      const c = stack.pop()!;
      for (const p of rev.get(c) ?? []) if (!ok.has(p)) { ok.add(p); stack.push(p); }
    }
    for (const k of nodes.keys()) if (!ok.has(k)) deadEnds.push(k);
  }

  const all = new Map<string, Puzzle>();
  for (const [k, n] of nodes) all.set(k, n.puzzle);
  return { solved: !!goalKey, plan, states: nodes.size, deadEnds, all };
}
