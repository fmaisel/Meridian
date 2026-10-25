import { LevelLogic, findPath, type NavGraph } from './LevelLogic';
import type { MechDef, PlateAction, PlateDef, PuzzleState } from './types';

export type OperateBlock = 'no-control' | 'locked' | 'occupied' | 'invalid-state' | 'strands';

export interface PlateEffect {
  plate: PlateDef;
  mechChanges: { mech: string; from: number; to: number }[];
  flags: string[];
}

/**
 * Deterministic puzzle rules on top of LevelLogic. Holds the authoritative state:
 * mechanism states, flags, camera quadrant and the node the character stands on.
 */
export class Puzzle {
  readonly logic: LevelLogic;
  state: PuzzleState;
  charNode: string;
  private plateByNode = new Map<string, PlateDef>();

  constructor(logic: LevelLogic, state?: PuzzleState, charNode?: string) {
    this.logic = logic;
    this.state = state ? cloneState(state) : logic.initialState();
    this.charNode = charNode ?? logic.def.start;
    for (const p of logic.def.plates) this.plateByNode.set(p.tile, p);
  }

  clone(): Puzzle {
    return new Puzzle(this.logic, this.state, this.charNode);
  }

  graph(): NavGraph {
    return this.logic.graph(this.state);
  }

  hasFlag(f: string): boolean {
    return this.state.flags.includes(f);
  }

  addFlag(f: string): void {
    if (!this.hasFlag(f)) {
      this.state.flags.push(f);
      this.state.flags.sort();
    }
  }

  get canRotateWorld(): boolean {
    return this.hasFlag(this.logic.def.rotateFlag);
  }

  path(to: string): string[] | null {
    return findPath(this.graph(), this.charNode, to);
  }

  plateAt(node: string): PlateDef | undefined {
    return this.plateByNode.get(node);
  }

  /** Character arrives at a node. Applies one-shot plate effects (state changes happen immediately). */
  visit(node: string): PlateEffect | null {
    this.charNode = node;
    const plate = this.plateByNode.get(node);
    if (!plate) return null;
    const pf = `plate:${plate.id}`;
    if (this.hasFlag(pf)) return null;
    this.addFlag(pf);
    const eff: PlateEffect = { plate, mechChanges: [], flags: [] };
    for (const a of plate.actions) this.applyAction(a, eff);
    return eff;
  }

  private applyAction(a: PlateAction, eff: PlateEffect) {
    if ('flag' in a) {
      this.addFlag(a.flag);
      eff.flags.push(a.flag);
    } else {
      const from = this.state.mech[a.mech];
      this.state.mech[a.mech] = a.to;
      eff.mechChanges.push({ mech: a.mech, from, to: a.to });
    }
  }

  /** Visiting every node along a path (used by the solver; the game visits incrementally). */
  walk(path: string[]): PlateEffect[] {
    const out: PlateEffect[] = [];
    for (const n of path.slice(1)) {
      const e = this.visit(n);
      if (e) out.push(e);
    }
    return out;
  }

  mechCarriesCharacter(m: MechDef): boolean {
    const node = this.graph().nodes.get(this.charNode);
    if (!node) return false;
    return this.logic.bodiesMovedBy(m.id).includes(node.body);
  }

  canOperate(mechId: string): OperateBlock | null {
    const m = this.logic.mechs.get(mechId)!;
    if (m.control.type === 'none') return 'no-control';
    if (m.control.requires && !this.hasFlag(m.control.requires)) return 'locked';
    if (!m.rider && this.mechCarriesCharacter(m)) return 'occupied';
    return null;
  }

  /** Can the mechanism be set to `to` from the current state (without stranding the character off-graph)? */
  canSetState(mechId: string, to: number): OperateBlock | null {
    const block = this.canOperate(mechId);
    if (block) return block;
    const m = this.logic.mechs.get(mechId)!;
    if (!m.states.includes(to)) return 'invalid-state';
    const probe = cloneState(this.state);
    probe.mech[mechId] = to;
    if (!this.logic.graph(probe).nodes.has(this.charNode)) return 'strands';
    return null;
  }

  setMech(mechId: string, to: number): void {
    this.state.mech[mechId] = to;
  }

  rotateWorld(dir: 1 | -1): void {
    this.state.cam = (((this.state.cam + dir) % 4) + 4) % 4;
  }

  atGoal(): boolean {
    return this.charNode === this.logic.def.goal;
  }
}

export function cloneState(s: PuzzleState): PuzzleState {
  return { mech: { ...s.mech }, flags: [...s.flags], cam: s.cam };
}
