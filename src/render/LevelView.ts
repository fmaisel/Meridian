// ArchitectureSystem (visual side): turns body definitions into merged meshes, one group per body,
// and poses the groups from continuous mechanism parameters every frame.
import {
  CylinderGeometry, GreaterDepth, Group, Mesh, MeshBasicMaterial, PlaneGeometry, Quaternion, SphereGeometry, Vector3, type BufferGeometry, type Material,
  type MeshLambertMaterial, type Object3D,
} from 'three';
import type { LevelLogic } from '../logic/LevelLogic';
import type { BodyDef, V3, VisualDef } from '../logic/types';
import {
  setMist, archGeo, boxGeo, capGeo, columnGeo, crankParts, domeGeo, knobParts, merge, pillarGeo, planeXZ, stairsGeo,
  treeGeo, trunkGeo, urnGeo, windowGeo,
} from './geometry';
import { bannerMaterial, fallMaterial, glyphMaterial, GLYPH_COLORS, waterMaterial } from './glyphs';
import { paletteColor } from './palette';
import type { MaterialLibrary } from './materials';

export interface HandleView {
  mech: string;
  body: string;
  group: Group;
  materials: MeshLambertMaterial[];
  pick: Object3D[];
  /** Handle anchor in body-local coordinates. */
  local: Vector3;
  axis: Vector3;
  kind: 'crank' | 'knob';
}

export interface GlyphView {
  mesh: Mesh;
  mat: MeshBasicMaterial;
  kind: string;
}

export class LevelView {
  readonly root = new Group();
  readonly groups = new Map<string, Group>();
  readonly handles: HandleView[] = [];
  readonly glyphs = new Map<string, GlyphView>();
  /** Meshes that can be clicked to walk (raycast targets). */
  readonly pickables: Object3D[] = [];
  /** The summit lamp, lit in the finale. */
  lamp: Mesh | null = null;

  /** All window materials (they glow warmly at the end). */
  windowMaterials(): MeshLambertMaterial[] {
    const out: MeshLambertMaterial[] = [];
    for (const list of this.bodyMats.values()) for (const m of list) if (m.userData.isWindow) out.push(m as MeshLambertMaterial);
    return out;
  }

  constructor(private logic: LevelLogic, private mats: MaterialLibrary) {
    this.root.name = 'level';
    for (const b of logic.order) this.buildBody(b);
  }

  private buildBody(b: BodyDef) {
    const group = new Group();
    group.name = b.id;
    group.matrixAutoUpdate = false;
    group.userData.body = b.id;
    const buckets = new Map<string, { mat: Material; geos: BufferGeometry[] }>();
    const add = (key: string, mat: Material, g: BufferGeometry) => {
      let e = buckets.get(key);
      if (!e) buckets.set(key, (e = { mat, geos: [] }));
      e.geos.push(g);
    };
    const M = (key: string) => this.track(b.id, this.mats.forBody(b.id, b.palette, key));

    // stairs that rise from the clouds come up step by step
    const md = b.mech ? this.logic.mechs.get(b.mech) : undefined;
    const stairs = b.visuals.filter((v) => v.type === 'stairs');
    const stagger = md?.kind === 'lift' && stairs.length >= 2;
    const baseAdd = add;
    for (const v of b.visuals) {
      const mist = (v.mist as number | undefined) ?? 0;
      const add = mist > 0
        ? (key: string, mat: Material, g: BufferGeometry) => { liftMist(g, mist); baseAdd(key, mat, g); }
        : baseAdd;
      if (stagger && v.type === 'stairs') {
        const sub = new Map<string, { mat: Material; geos: BufferGeometry[] }>();
        const subAdd = (key: string, mat: Material, g: BufferGeometry) => {
          let e = sub.get(key);
          if (!e) sub.set(key, (e = { mat, geos: [] }));
          e.geos.push(g);
        };
        this.visual(b, v, subAdd, M, group);
        const child = new Group();
        child.matrixAutoUpdate = false;
        for (const [, { mat, geos }] of sub) {
          const mesh = new Mesh(merge(geos), mat);
          mesh.castShadow = mesh.receiveShadow = true;
          mesh.userData.body = b.id;
          child.add(mesh);
          this.pickables.push(mesh);
        }
        group.add(child);
        let list = this.staggered.get(b.id);
        if (!list) this.staggered.set(b.id, (list = []));
        list.push(child);
      } else this.visual(b, v, add, M, group);
    }

    for (const [, { mat, geos }] of buckets) {
      const mesh = new Mesh(merge(geos), mat);
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      mesh.userData.body = b.id;
      group.add(mesh);
      this.pickables.push(mesh);
    }
    this.root.add(group);
    this.groups.set(b.id, group);
  }

  private visual(
    b: BodyDef, v: VisualDef,
    add: (key: string, mat: Material, g: BufferGeometry) => void,
    M: (key: string) => MeshLambertMaterial,
    group: Group,
  ) {
    const n = (k: string) => v[k] as number;
    const s = (k: string) => v[k] as string;
    const vec = (k: string) => v[k] as V3;
    switch (v.type) {
      case 'box': {
        const mat = s('mat');
        add(mat, M(mat), boxGeo(vec('min'), vec('max'), (v.fade as number) ?? autoFade(vec('min'), vec('max'))));
        if (v.cap) add('cap', this.track(b.id, this.mats.forBody(b.id, b.palette, (v.capMat as string) ?? 'cap', true)), capGeo(vec('min'), vec('max')));
        break;
      }
      case 'stairs': {
        const dir = vec('dir');
        const h0 = n('h0');
        add('stairs', M('cap'), stairsGeo(n('x'), n('z'), dir, h0, n('rise'), h0 - 0.12, n('steps')));
        const base = n('base');
        if (base < h0 - 0.12) {
          const x = n('x'), z = n('z');
          add(s('mat'), M(s('mat')), boxGeo([x - 0.5, base, z - 0.5], [x + 0.5, h0 - 0.12, z + 0.5]));
        }
        break;
      }
      case 'pillar':
        add(s('mat'), M(s('mat')), pillarGeo(n('x'), n('z'), n('y0'), n('y1'), n('r'), (v.fade as number) ?? 0));
        break;
      case 'column':
        add(s('mat'), M(s('mat')), columnGeo(n('x'), n('z'), n('y0'), n('y1'), n('r')));
        break;
      case 'arch':
        add(s('mat'), M(s('mat')), archGeo(v as never));
        break;
      case 'dome':
        add(s('mat'), M(s('mat')), domeGeo(n('x'), n('y'), n('z'), n('r'), v.style as 'onion'));
        break;
      case 'tree':
        add(s('mat'), M(s('mat')), treeGeo(n('x'), n('y'), n('z'), n('h')));
        add('trunk', M('window'), trunkGeo(n('x'), n('y'), n('z'), n('h')));
        break;
      case 'window':
        const wm = M('window');
        wm.userData.isWindow = true;
        wm.userData.baseColor ??= wm.color.clone();
        add('window', wm, windowGeo(n('x'), n('y'), n('z'), vec('face'), n('w'), n('h')));
        break;
      case 'banner': {
        const face = vec('face');
        const w = n('w'), len = n('len');
        const g = new PlaneGeometry(w, len, 3, 12);
        g.translate(0, -len / 2, 0);
        const mesh = new Mesh(g, bannerMaterial(paletteColor(b.palette, s('mat')), n('x') * 1.7 + n('z')));
        mesh.position.set(n('x') + face[0] * 0.03, n('y'), n('z') + face[2] * 0.03);
        mesh.rotation.y = Math.atan2(face[0], face[2]);
        mesh.castShadow = true;
        group.add(mesh);
        // the rod it hangs from
        const rodLen = w + 0.12;
        const rod = boxGeo([-rodLen / 2, n('y') - 0.03, -0.025], [rodLen / 2, n('y') + 0.03, 0.025]);
        rod.translate(-0, 0, 0);
        const rm = new Mesh(rod, M('trim'));
        rm.position.set(0, 0, 0);
        const holder = new Group();
        holder.position.set(n('x') + face[0] * 0.05, 0, n('z') + face[2] * 0.05);
        holder.rotation.y = Math.atan2(face[0], face[2]);
        holder.add(rm);
        group.add(holder);
        break;
      }
      case 'lily': {
        const pad = new CylinderGeometry(n('r'), n('r'), 0.02, 14, 1, false, 0.3, Math.PI * 2 - 0.6);
        pad.translate(n('x'), n('y'), n('z'));
        add('lily', this.track(b.id, this.mats.forBody(b.id, 'lily', 'lily')), setMist(pad));
        if (v.flower) {
          const fl = new CylinderGeometry(0, 0.07, 0.09, 6);
          fl.translate(n('x') + 0.03, n('y') + 0.05, n('z') - 0.02);
          add('flower', this.track(b.id, this.mats.forBody(b.id, 'lily', 'flower')), setMist(fl));
        }
        break;
      }
      case 'urn':
        add('trim', M('trim'), urnGeo(n('x'), n('y'), n('z')));
        break;
      case 'shrine': {
        const x = n('x'), y = n('y'), z = n('z');
        for (const [dx, dz] of [[-0.42, -0.42], [0.42, -0.42], [-0.42, 0.42], [0.42, 0.42]])
          add('trim', M('trim'), pillarGeo(x + dx, z + dz, y, y + 1.9, 0.065));
        add('trim', M('trim'), boxGeo([x - 0.55, y + 1.9, z - 0.55], [x + 0.55, y + 2.12, z + 0.55]));
        add('roofViolet', M('roofViolet'), domeGeo(x, y + 2.12, z, 0.5, 'onion'));
        add('trim', M('trim'), pillarGeo(x, z, y + 1.42, y + 1.9, 0.012));
        const lamp = new Mesh(new SphereGeometry(0.12, 16, 10), new MeshBasicMaterial({ color: '#d8c7a6' }));
        lamp.position.set(x, y + 1.32, z);
        group.add(lamp);
        this.lamp = lamp;
        break;
      }
      case 'water': {
        const mesh = new Mesh(planeXZ(vec('min'), vec('max')), waterMaterial());
        mesh.receiveShadow = false;
        group.add(mesh);
        break;
      }
      case 'fall': {
        const y0 = n('y0'), y1 = n('y1');
        const g = new PlaneGeometry(n('w'), y1 - y0, 1, 8);
        const face = vec('face');
        g.rotateY(Math.atan2(face[0], face[2]));
        g.translate(n('x'), (y0 + y1) / 2, n('z'));
        group.add(new Mesh(g, fallMaterial()));
        break;
      }
      case 'glyph': {
        const kind = s('kind');
        const mat = glyphMaterial(kind);
        mat.userData.baseOpacity = mat.opacity;
        this.track(b.id, mat);
        const g = new PlaneGeometry(0.86, 0.86);
        g.rotateX(-Math.PI / 2);
        const mesh = new Mesh(g, mat);
        mesh.position.set(n('x'), n('y') + 0.006, n('z'));
        mesh.renderOrder = 2;
        group.add(mesh);
        this.glyphs.set(`${b.id}@${n('x')},${n('y')},${n('z')}`, { mesh, mat, kind });
        break;
      }
      case 'crank':
      case 'knob': {
        const parts = v.type === 'crank' ? crankParts(n('r')) : knobParts();
        const hg = new Group();
        const mBody = this.mats.unique(b.palette, 'handle');
        const mPin = this.mats.unique(b.palette, 'handlePin');
        const m1 = new Mesh(parts.body, mBody);
        const m2 = new Mesh(parts.pins, mPin);
        for (const m of [m1, m2]) { m.castShadow = true; m.userData.handle = s('mech'); }
        // faint silhouette that stays visible through any architecture in front of the handle
        const ghostBody = new MeshBasicMaterial({ color: '#fff8ee', transparent: true, opacity: 0.42, depthFunc: GreaterDepth, depthWrite: false });
        const ghostPin = new MeshBasicMaterial({ color: '#f08a72', transparent: true, opacity: 0.55, depthFunc: GreaterDepth, depthWrite: false });
        for (const [m, gmat] of [[m1, ghostBody], [m2, ghostPin]] as const) {
          const gm = new Mesh(m.geometry, gmat);
          gm.renderOrder = 9;
          m.add(gm);
        }
        hg.add(m1, m2);
        const axis = new Vector3(...((v.axis as V3) ?? [0, 1, 0])).normalize();
        if (v.type === 'crank') {
          hg.quaternion.copy(new Quaternion().setFromUnitVectors(new Vector3(0, 1, 0), axis));
          hg.rotateY(Math.PI / 4);
        }
        if (v.type === 'knob') {
          // pendant knob: rod hanging below the platform with a disc
          const rod = new Mesh(pillarGeo(0, 0, -0.75, 0, 0.04), mBody);
          rod.userData.handle = s('mech');
          hg.add(rod);
          m1.position.y = -0.8;
          m2.position.y = -0.8;
          m1.rotation.z = Math.PI / 2;
          m2.rotation.z = Math.PI / 2;
        }
        hg.position.set(n('x'), n('y'), n('z'));
        group.add(hg);
        // invisible, generous pick volume
        const pick = new Mesh(new PlaneGeometry(1, 1), mBody);
        pick.visible = false;
        this.handles.push({
          mech: s('mech'), body: b.id, group: hg, materials: [mBody, mPin], pick: [m1, m2, ...hg.children],
          local: new Vector3(n('x'), n('y') + (v.type === 'knob' ? -0.8 : 0), n('z')), axis, kind: v.type,
        });
        pick.geometry.dispose();
        break;
      }
      default:
        console.warn('unknown visual', v.type);
    }
  }

  private bodyMats = new Map<string, Material[]>();
  private fades = new Map<string, number>();

  private track<T extends Material>(body: string, m: T): T {
    let list = this.bodyMats.get(body);
    if (!list) this.bodyMats.set(body, (list = []));
    if (!list.includes(m)) list.push(m);
    return m;
  }

  /** Cutaway amount for a body (0 = solid, 1 = window fully open around the current foci). */
  setFade(body: string, cut: number): void {
    const prev = this.fades.get(body) ?? 0;
    if (Math.abs(prev - cut) < 1e-4) return;
    this.fades.set(body, cut);
    const open = cut > 0.001;
    for (const m of this.bodyMats.get(body) ?? []) {
      const base = (m.userData.baseOpacity as number | undefined) ?? 1;
      if (m.userData.cut) {
        m.userData.cut.value = cut;
        m.transparent = open;
      } else {
        m.opacity = base;
      }
    }
  }

  fadeOf(body: string): number {
    return this.fades.get(body) ?? 0;
  }

  /** Apply continuous mechanism parameters. */
  pose(params: Record<string, number>): void {
    const mats = this.logic.bodyMatrices(params);
    for (const [id, g] of this.groups) {
      g.matrix.copy(mats.get(id)!);
      g.matrixWorldNeedsUpdate = true;
    }
    for (const [id, children] of this.staggered) {
      const b = this.logic.bodies.get(id)!;
      const md = this.logic.mechs.get(b.mech!)!;
      const p = params[md.id];
      const lo = Math.min(...md.states);
      const hi = Math.max(...md.states);
      const t = (p - lo) / Math.max(1e-6, hi - lo);
      const body = new Vector3().setFromMatrixPosition(this.logic.mechMatrix(md, p));
      const n = children.length;
      const gap = 0.45;
      children.forEach((c, i) => {
        // first step leads, the others follow; all agree at both ends of the motion
        const ti = Math.min(1, Math.max(0, t * (1 + gap * (n - 1)) - gap * i));
        const pi = lo + (hi - lo) * (ti * ti * (3 - 2 * ti));
        const own = new Vector3().setFromMatrixPosition(this.logic.mechMatrix(md, pi));
        c.matrix.makeTranslation(own.x - body.x, own.y - body.y, own.z - body.z);
        c.matrixWorldNeedsUpdate = true;
      });
    }
  }

  private staggered = new Map<string, Group[]>();

  setPressed(bodyId: string, pos: V3, pressed: boolean): void {
    const gv = this.glyphs.get(`${bodyId}@${pos[0]},${pos[1]},${pos[2]}`);
    if (!gv) return;
    gv.mat.color.set(pressed ? GLYPH_COLORS.pressed : GLYPH_COLORS[gv.kind] ?? '#ffffff');
  }

  glyphAt(bodyId: string, pos: V3): GlyphView | undefined {
    return this.glyphs.get(`${bodyId}@${pos[0]},${pos[1]},${pos[2]}`);
  }
}

function liftMist(g: BufferGeometry, m: number) {
  const a = g.getAttribute('aMist');
  if (!a) return;
  for (let i = 0; i < a.count; i++) a.setX(i, Math.max(a.getX(i), m));
  a.needsUpdate = true;
}

/** Tall boxes that reach far below their top dissolve into the mist over their lowest stretch. */
function autoFade(_min: V3, _max: V3): number {
  // everything reaches into the cloud deck; the height mist does the fading
  return 0;
}
