// Level construction kit: authoring helpers that emit tiles, solids and visual descriptors together,
// so geometry, collision and navigation can never drift apart.
import type { BodyDef, EdgeDef, TileDef, V3, VisualDef } from '../logic/types';

export const DIR = {
  px: [1, 0, 0] as V3,
  nx: [-1, 0, 0] as V3,
  pz: [0, 0, 1] as V3,
  nz: [0, 0, -1] as V3,
};
export type DirName = keyof typeof DIR;
const ALL: DirName[] = ['px', 'nx', 'pz', 'nz'];

export interface BoxOpts {
  /** Generate walkable tiles on the top cells (default true). */
  walk?: boolean;
  /** Material key. */
  mat?: string;
  /** Draw a lighter cap slab on top (default = walk). */
  cap?: boolean;
  /** Collision solid (default true). */
  solid?: boolean;
  /** Fade into the mist below (default true for tall boxes). */
  capMat?: string;
}

export class BodyBuilder {
  readonly def: BodyDef;
  private tileMap = new Map<string, TileDef>();

  constructor(id: string, opts: { palette: string; zone: string; mech?: string; parent?: string }) {
    this.def = {
      id,
      tiles: [],
      solids: [],
      visuals: [],
      palette: opts.palette,
      zone: opts.zone,
      mech: opts.mech,
      parent: opts.parent,
      tileZones: {},
    };
  }

  private key(x: number, y: number, z: number) {
    return `${x},${y},${z}`;
  }

  /** Walkable flat tile at cell (x,z) with surface height y. */
  tile(x: number, y: number, z: number, opts: { dirs?: DirName[]; tags?: string[] } = {}): TileDef {
    const k = this.key(x, y, z);
    let t = this.tileMap.get(k);
    if (!t) {
      const dirs = opts.dirs ?? ALL;
      t = {
        id: `t${x}_${y}_${z}`.replace(/-/g, 'm').replace(/\./g, 'p'),
        pos: [x, y, z],
        edges: dirs.map((d) => ({ dir: DIR[d], h: y })),
        tags: [...(opts.tags ?? [])],
      };
      this.tileMap.set(k, t);
      this.def.tiles.push(t);
    } else if (opts.tags) {
      t.tags.push(...opts.tags);
    }
    return t;
  }

  getTile(x: number, y: number, z: number): TileDef {
    const t = this.tileMap.get(this.key(x, y, z));
    if (!t) throw new Error(`${this.def.id}: no tile at ${x},${y},${z}`);
    return t;
  }

  ref(x: number, y: number, z: number): string {
    return `${this.def.id}/${this.getTile(x, y, z).id}`;
  }

  tag(x: number, y: number, z: number, tag: string): this {
    this.getTile(x, y, z).tags.push(tag);
    return this;
  }

  zoneOf(x: number, y: number, z: number, zone: string): this {
    this.def.tileZones![this.getTile(x, y, z).id] = zone;
    return this;
  }

  /** Mark an edge of a tile as a perspective seam. */
  seam(x: number, y: number, z: number, d: DirName): this {
    const t = this.getTile(x, y, z);
    const e = t.edges.find((e) => sameDir(e.dir, DIR[d]));
    if (!e) throw new Error(`${this.def.id}: tile ${x},${y},${z} has no ${d} edge`);
    e.seam = true;
    return this;
  }

  /** Close an edge (wall, railing). */
  close(x: number, y: number, z: number, ...ds: DirName[]): this {
    const t = this.getTile(x, y, z);
    t.edges = t.edges.filter((e) => !ds.some((d) => sameDir(e.dir, DIR[d])));
    return this;
  }

  /** Axis-aligned block covering cells x0..x1, z0..z1 from y0 to y1. */
  box(x0: number, x1: number, z0: number, z1: number, y0: number, y1: number, o: BoxOpts = {}): this {
    const walk = o.walk ?? true;
    const min: V3 = [Math.min(x0, x1) - 0.5, y0, Math.min(z0, z1) - 0.5];
    const max: V3 = [Math.max(x0, x1) + 0.5, y1, Math.max(z0, z1) + 0.5];
    if (o.solid ?? true) this.def.solids.push({ min, max });
    this.def.visuals.push({ type: 'box', min, max, mat: o.mat ?? 'stone', cap: o.cap ?? walk, capMat: o.capMat });
    // a slim cornice just below the walking surface frames every platform
    if (walk && y1 - y0 >= 0.5 && o.mat !== 'accent')
      this.def.visuals.push({
        type: 'box', min: [min[0] - 0.045, y1 - 0.36, min[2] - 0.045], max: [max[0] + 0.045, y1 - 0.27, max[2] + 0.045], mat: 'trim', cap: false,
      });
    if (walk)
      for (let x = Math.min(x0, x1); x <= Math.max(x0, x1); x++)
        for (let z = Math.min(z0, z1); z <= Math.max(z0, z1); z++) this.tile(x, y1, z);
    return this;
  }

  /** Decorative / solid block in raw coordinates (no tiles). */
  block(min: V3, max: V3, mat = 'stone', solid = true): this {
    if (solid) this.def.solids.push({ min, max });
    this.def.visuals.push({ type: 'box', min, max, mat, cap: false });
    return this;
  }

  /**
   * One-cell staircase at (x,z) rising toward `d` from h0 to h0+rise. The stair connects a tile at h0
   * on the low side with a tile at h0+rise on the high side.
   */
  stairs(x: number, z: number, d: DirName, h0: number, rise = 1, o: { mat?: string; base?: number; steps?: number } = {}): this {
    const dir = DIR[d];
    const back: V3 = [-dir[0], 0, -dir[2]];
    const pos: V3 = [x, h0 + rise / 2, z];
    const edges: EdgeDef[] = [
      { dir: back, h: h0 },
      { dir, h: h0 + rise },
    ];
    const t: TileDef = { id: `s${x}_${h0}_${z}`.replace(/-/g, 'm').replace(/\./g, 'p'), pos, edges, tags: ['stair'] };
    this.def.tiles.push(t);
    const base = o.base ?? h0 - 0.5;
    this.def.solids.push({ min: [x - 0.5, base, z - 0.5], max: [x + 0.5, h0, z + 0.5] });
    this.def.visuals.push({ type: 'stairs', x, z, dir, h0, rise, base, mat: o.mat ?? 'stone', steps: o.steps ?? Math.max(3, Math.round(rise * 4)) });
    return this;
  }

  /** A straight flight of stairs over several cells, rising `rise` per cell. */
  flight(x: number, z: number, d: DirName, h0: number, cells: number, rise = 1, o: { mat?: string; base?: number } = {}): this {
    const dir = DIR[d];
    for (let i = 0; i < cells; i++)
      this.stairs(x + dir[0] * i, z + dir[2] * i, d, h0 + i * rise, rise, { mat: o.mat, base: o.base });
    return this;
  }

  visual(v: VisualDef): this {
    this.def.visuals.push(v);
    return this;
  }

  pillar(x: number, z: number, y0: number, y1: number, r = 0.12, mat = 'stone'): this {
    return this.visual({ type: 'pillar', x, z, y0, y1, r, mat });
  }

  /** Arch wall: a slab spanning along `axis` with a round-topped opening. */
  arch(o: { x: number; z: number; axis: 'x' | 'z'; y0: number; y1: number; span: number; thick?: number; openW?: number; openH?: number; mat?: string; count?: number }): this {
    return this.visual({ type: 'arch', thick: 0.5, mat: 'stone', count: 1, ...o });
  }

  dome(x: number, y: number, z: number, r = 0.45, mat = 'roof', style: 'onion' | 'round' | 'cone' = 'onion'): this {
    return this.visual({ type: 'dome', x, y, z, r, mat, style });
  }

  /** Small open pavilion on a tile: four columns and a dome. */
  pavilion(x: number, y: number, z: number, o: { h?: number; mat?: string; roof?: string; style?: 'onion' | 'round' | 'cone' } = {}): this {
    const h = o.h ?? 1.4;
    const mat = o.mat ?? 'stone';
    for (const [dx, dz] of [[-0.38, -0.38], [0.38, -0.38], [-0.38, 0.38], [0.38, 0.38]])
      this.pillar(x + dx, z + dz, y, y + h, 0.06, mat);
    this.visual({ type: 'box', min: [x - 0.5, y + h, z - 0.5], max: [x + 0.5, y + h + 0.18, z + 0.5], mat, cap: false });
    this.dome(x, y + h + 0.18, z, 0.42, o.roof ?? 'roof', o.style ?? 'onion');
    return this;
  }

  tree(x: number, y: number, z: number, h = 1.3, mat = 'foliage'): this {
    return this.visual({ type: 'tree', x, y, z, h, mat });
  }

  window(x: number, y: number, z: number, face: DirName, w = 0.18, h = 0.5): this {
    return this.visual({ type: 'window', x, y, z, face: DIR[face], w, h });
  }

  /** Cloth banner hanging from an anchor point, facing `face`. */
  banner(x: number, y: number, z: number, face: DirName, o: { len?: number; w?: number; mat?: string } = {}): this {
    return this.visual({ type: 'banner', x, y, z, face: DIR[face], len: o.len ?? 1.2, w: o.w ?? 0.34, mat: o.mat ?? 'roofCoral' });
  }

  glyph(x: number, y: number, z: number, kind: string): this {
    return this.visual({ type: 'glyph', x, y, z, kind });
  }

  build(): BodyDef {
    return this.def;
  }
}

function sameDir(a: V3, b: V3) {
  return Math.abs(a[0] - b[0]) < 1e-6 && Math.abs(a[2] - b[2]) < 1e-6;
}
