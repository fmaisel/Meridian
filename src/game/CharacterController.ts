// CharacterController: follows a node path over the nav graph with eased speed, crosses perspective
// seams by jumping along the view axis (invisible on screen) and reports node arrivals.
import { Vector3 } from 'three';
import type { NavGraph } from '../logic/LevelLogic';
import type { CharacterView } from '../render/Character';

interface Waypoint {
  p: Vector3;
  node?: string;
  jump?: Vector3;
  seam?: boolean;
}

const MAX_SPEED = 2.35;
const ACCEL = 9;

export class CharacterController {
  readonly pos = new Vector3();
  node: string;
  walking = false;
  private wps: Waypoint[] = [];
  private speed = 0;
  private stopAtNext = false;
  private retarget: string | null = null;
  private overlay = false;
  private stepCount = 0;

  /** Called on arrival at each node; return false to halt. */
  onArrive: (node: string, final: boolean) => boolean = () => true;
  /** Recompute a path from the current node (used when the player clicks while walking). */
  repath: (from: string, to: string) => string[] | null = () => null;
  /** Current walkable graph (to validate the next link). */
  graph: () => NavGraph = () => { throw new Error('graph not set'); };
  onStep: (i: number) => void = () => {};

  constructor(readonly view: CharacterView, start: string) {
    this.node = start;
  }

  follow(path: string[], g: NavGraph): void {
    this.wps = this.build(path, g);
    this.walking = this.wps.length > 0;
    this.stopAtNext = false;
    this.retarget = null;
  }

  /** Re-route at the next node. */
  redirect(target: string): void {
    this.retarget = target;
  }

  requestStop(): void {
    if (this.walking) this.stopAtNext = true;
  }

  private build(path: string[], g: NavGraph): Waypoint[] {
    const out: Waypoint[] = [];
    for (let i = 0; i + 1 < path.length; i++) {
      const link = g.links.get(path[i])?.find((l) => l.to === path[i + 1]);
      const next = g.nodes.get(path[i + 1]);
      if (!link || !next) break;
      out.push({ p: link.a.clone(), jump: link.seam ? link.b.clone() : undefined, seam: link.seam });
      out.push({ p: next.pos.clone(), node: next.id });
    }
    return out;
  }

  private remaining(): number {
    let d = 0;
    let prev = this.pos;
    for (const w of this.wps) {
      d += prev.distanceTo(w.p);
      if (w.node && this.stopAtNext) return d;
      prev = w.jump ?? w.p;
    }
    return d;
  }

  private halt() {
    this.wps = [];
    this.walking = false;
    this.speed = 0;
    this.setOverlay(false);
  }

  private setOverlay(on: boolean) {
    if (on !== this.overlay) {
      this.overlay = on;
      this.view.setOverlay(on);
    }
  }

  update(dt: number): void {
    if (!this.walking) return;
    const rem = this.remaining();
    const brake = Math.sqrt(2 * ACCEL * 0.55 * Math.max(0, rem));
    this.speed = Math.min(MAX_SPEED, this.speed + ACCEL * dt, Math.max(0.6, brake));
    let budget = this.speed * dt;
    while (budget > 0 && this.wps.length) {
      const w = this.wps[0];
      const to = w.p;
      const d = this.pos.distanceTo(to);
      if (w.seam) this.setOverlay(true);
      if (d > 1e-5) {
        const dx = to.x - this.pos.x;
        const dz = to.z - this.pos.z;
        this.view.face(dx, dz);
      }
      if (d <= budget) {
        this.pos.copy(to);
        budget -= d;
        this.wps.shift();
        if (w.jump) this.pos.copy(w.jump);
        if (w.node) {
          this.node = w.node;
          this.onStep(this.stepCount++);
          if (!this.arrive(w.node)) return;
        }
      } else {
        this.pos.addScaledVector(to.clone().sub(this.pos).normalize(), budget);
        budget = 0;
      }
    }
    if (!this.wps.length) this.halt();
  }

  private arrive(node: string): boolean {
    const final = this.wps.length === 0;
    if (!final) this.setOverlay(this.wps[0].seam ?? false);
    else this.setOverlay(false);
    const ok = this.onArrive(node, final);
    if (!ok || this.stopAtNext) {
      this.halt();
      return false;
    }
    if (this.retarget) {
      const t = this.retarget;
      this.retarget = null;
      const path = this.repath(node, t);
      if (!path) { this.halt(); return false; }
      this.wps = this.build(path, this.graph());
      if (!this.wps.length) { this.halt(); return false; }
      return true;
    }
    if (!final) {
      // validate the next link still exists (architecture may have moved)
      const nextNode = this.wps.find((w) => w.node)?.node;
      const ok2 = nextNode && this.graph().links.get(node)?.some((l) => l.to === nextNode);
      if (!ok2) { this.halt(); return false; }
    }
    return true;
  }
}
