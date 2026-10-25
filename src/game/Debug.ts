// DebugTools: visualises nav nodes, links (seams in magenta), solids and the puzzle state.
import {
  Box3, Box3Helper, BufferGeometry, Color, Group, LineBasicMaterial, LineSegments, Points, PointsMaterial,
  Float32BufferAttribute,
} from 'three';
import type { LevelLogic, NavGraph } from '../logic/LevelLogic';
import type { Puzzle } from '../logic/Puzzle';

export class DebugTools {
  readonly group = new Group();
  enabled = false;

  constructor(private logic: LevelLogic) {
    this.group.visible = false;
    this.group.renderOrder = 20;
  }

  toggle(on = !this.enabled): void {
    this.enabled = on;
    this.group.visible = on;
  }

  rebuild(graph: NavGraph, params: Record<string, number>): void {
    for (const c of [...this.group.children]) {
      this.group.remove(c);
      (c as LineSegments).geometry?.dispose();
    }
    if (!this.enabled) return;
    const pts: number[] = [];
    const cols: number[] = [];
    for (const n of graph.nodes.values()) {
      pts.push(n.pos.x, n.pos.y + 0.05, n.pos.z);
      const c = n.tags.some((t) => t.startsWith('plate')) ? new Color('#00a08a') : n.tags.includes('goal') ? new Color('#e0a020') : new Color('#3050ff');
      cols.push(c.r, c.g, c.b);
    }
    const pg = new BufferGeometry();
    pg.setAttribute('position', new Float32BufferAttribute(pts, 3));
    pg.setAttribute('color', new Float32BufferAttribute(cols, 3));
    const pm = new PointsMaterial({ size: 7, sizeAttenuation: false, vertexColors: true, depthTest: false });
    this.group.add(new Points(pg, pm));

    const walk: number[] = [];
    const seam: number[] = [];
    for (const [id, links] of graph.links) {
      const a = graph.nodes.get(id)!.pos;
      for (const l of links) {
        if (l.to < id && !l.seam) continue;
        const b = graph.nodes.get(l.to)!.pos;
        const arr = l.seam ? seam : walk;
        if (l.seam) arr.push(a.x, a.y + 0.06, a.z, l.a.x, l.a.y + 0.06, l.a.z, l.b.x, l.b.y + 0.06, l.b.z, b.x, b.y + 0.06, b.z);
        else arr.push(a.x, a.y + 0.06, a.z, b.x, b.y + 0.06, b.z);
      }
    }
    const lw = new BufferGeometry();
    lw.setAttribute('position', new Float32BufferAttribute(walk, 3));
    this.group.add(new LineSegments(lw, new LineBasicMaterial({ color: '#2040ff', depthTest: false, transparent: true, opacity: 0.8 })));
    const ls = new BufferGeometry();
    ls.setAttribute('position', new Float32BufferAttribute(seam, 3));
    this.group.add(new LineSegments(ls, new LineBasicMaterial({ color: '#ff00c8', depthTest: false })));

    const mats = this.logic.bodyMatrices(params);
    for (const s of this.logic.worldSolids(mats)) {
      const h = new Box3Helper(new Box3(s.min.clone(), s.max.clone()), new Color('#ff6040'));
      (h.material as LineBasicMaterial).transparent = true;
      (h.material as LineBasicMaterial).opacity = 0.35;
      this.group.add(h);
    }
  }

  describe(p: Puzzle, fps: number, extra: string): string {
    const lines = [
      `fps ${fps.toFixed(0)}   cam q${p.state.cam}`,
      `at ${p.charNode}`,
      `mechs ${Object.entries(p.state.mech).map(([k, v]) => `${k}:${v}`).join('  ')}`,
      `flags ${p.state.flags.join(', ') || '—'}`,
      extra,
      '',
      '` toggle debug · N next solver step',
    ];
    return lines.join('\n');
  }
}
