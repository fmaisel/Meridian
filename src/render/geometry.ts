// Procedural geometry for the architectural kit. Every geometry carries an `aMist` attribute
// (0 = clear, 1 = dissolved into the sky) so supports can fade into the void.
import {
  BoxGeometry, BufferAttribute, BufferGeometry, CylinderGeometry, ExtrudeGeometry, LatheGeometry, Shape,
  SphereGeometry, Vector2, Float32BufferAttribute, PlaneGeometry,
} from 'three';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import type { V3 } from '../logic/types';

export function setMist(g: BufferGeometry, f: (y: number) => number = () => 0): BufferGeometry {
  const pos = g.getAttribute('position');
  const arr = new Float32Array(pos.count);
  for (let i = 0; i < pos.count; i++) arr[i] = f(pos.getY(i));
  g.setAttribute('aMist', new BufferAttribute(arr, 1));
  return g;
}

function clean(g: BufferGeometry): BufferGeometry {
  // keep only the attributes all kit geometries share so they can be merged
  const n = g.index ? g.toNonIndexed() : g;
  for (const k of Object.keys(n.attributes)) if (!['position', 'normal', 'uv', 'aMist'].includes(k)) n.deleteAttribute(k);
  if (!n.getAttribute('uv')) n.setAttribute('uv', new Float32BufferAttribute(new Float32Array(n.getAttribute('position').count * 2), 2));
  if (!n.getAttribute('aMist')) setMist(n);
  return n;
}

export function merge(list: BufferGeometry[]): BufferGeometry {
  const g = mergeGeometries(list.map(clean), false);
  if (!g) throw new Error('merge failed');
  return g;
}

/** Box between min and max. `fade` = length over which the bottom dissolves into mist. */
export function boxGeo(min: V3, max: V3, fade = 0): BufferGeometry {
  const w = max[0] - min[0];
  const h = max[1] - min[1];
  const d = max[2] - min[2];
  const cx = (min[0] + max[0]) / 2;
  const cz = (min[2] + max[2]) / 2;
  const part = (y0: number, y1: number, m0: number, m1: number) => {
    const g = new BoxGeometry(w, y1 - y0, d);
    g.translate(cx, (y0 + y1) / 2, cz);
    return setMist(g, (y) => (Math.abs(y - y0) < 1e-4 ? m0 : m1));
  };
  if (fade <= 0) return part(min[1], max[1], 0, 0);
  const f = Math.min(fade, h);
  const parts = [part(min[1], min[1] + f, 1, 0)];
  if (f < h) parts.push(part(min[1] + f, max[1], 0, 0));
  return merge(parts);
}

/** Thin, slightly overhanging cap slab with world-space UVs on top (one tile per cell). */
export function capGeo(min: V3, max: V3): BufferGeometry {
  const o = 0.035;
  const t = 0.085;
  const g = new BoxGeometry(max[0] - min[0] + 2 * o, t, max[2] - min[2] + 2 * o);
  g.translate((min[0] + max[0]) / 2, max[1] - t / 2 + 0.002, (min[2] + max[2]) / 2);
  const pos = g.getAttribute('position');
  const nrm = g.getAttribute('normal');
  const uv = g.getAttribute('uv');
  for (let i = 0; i < pos.count; i++) {
    if (nrm.getY(i) > 0.5) uv.setXY(i, pos.getX(i) + 0.5, -(pos.getZ(i) + 0.5));
    else uv.setXY(i, 0.5, 0.5);
  }
  return setMist(g);
}

/** One-cell staircase. Step tops sit half a step around the walking line. */
export function stairsGeo(x: number, z: number, dir: V3, h0: number, rise: number, base: number, steps: number): BufferGeometry {
  const parts: BufferGeometry[] = [];
  for (let i = 0; i < steps; i++) {
    const a = -0.5 + i / steps;
    const b = -0.5 + (i + 1) / steps;
    const top = h0 + ((i + 0.5) / steps) * rise + 0.03;
    // along-dir extent [a, b] (relative to cell centre), across [-0.5, 0.5]
    let min: V3, max: V3;
    if (dir[0] !== 0) {
      const s = dir[0];
      const x0 = x + s * a;
      const x1 = x + s * b;
      min = [Math.min(x0, x1), base, z - 0.5];
      max = [Math.max(x0, x1), top, z + 0.5];
    } else {
      const s = dir[2];
      const z0 = z + s * a;
      const z1 = z + s * b;
      min = [x - 0.5, base, Math.min(z0, z1)];
      max = [x + 0.5, top, Math.max(z0, z1)];
    }
    parts.push(boxGeo(min, max));
  }
  return merge(parts);
}

/** Wall slab with round-topped openings, spanning `span` along the given axis. */
export function archGeo(o: { x: number; z: number; axis: 'x' | 'z'; y0: number; y1: number; span: number; thick: number; openW: number; openH: number; count: number }): BufferGeometry {
  const H = o.y1 - o.y0;
  const S = o.span;
  const r = o.openW / 2;
  const hs = Math.max(0.01, o.openH - r);
  const s = new Shape();
  s.moveTo(-S / 2, 0);
  for (let i = 0; i < o.count; i++) {
    const c = -S / 2 + ((i + 0.5) * S) / o.count;
    s.lineTo(c - r, 0);
    s.lineTo(c - r, hs);
    s.absarc(c, hs, r, Math.PI, 0, true);
    s.lineTo(c + r, 0);
  }
  s.lineTo(S / 2, 0);
  s.lineTo(S / 2, H);
  s.lineTo(-S / 2, H);
  s.closePath();
  const g = new ExtrudeGeometry(s, { depth: o.thick, bevelEnabled: false, curveSegments: 14 });
  g.translate(0, 0, -o.thick / 2);
  if (o.axis === 'z') g.rotateY(-Math.PI / 2);
  g.translate(o.x, o.y0, o.z);
  return setMist(g);
}

const ONION: [number, number][] = [
  [0, 0], [0.44, 0], [0.47, 0.1], [0.46, 0.26], [0.36, 0.45], [0.2, 0.62], [0.08, 0.76], [0.03, 0.86], [0, 0.92],
];

export function domeGeo(x: number, y: number, z: number, r: number, style: 'onion' | 'round' | 'cone'): BufferGeometry {
  let g: BufferGeometry;
  const k = r / 0.45;
  if (style === 'onion') {
    g = new LatheGeometry(ONION.map(([a, b]) => new Vector2(a * k, b * k)), 20);
  } else if (style === 'round') {
    g = new SphereGeometry(r, 20, 10, 0, Math.PI * 2, 0, Math.PI / 2);
  } else {
    g = new CylinderGeometry(0, r * 1.25, r * 1.6, 4, 1);
    g.rotateY(Math.PI / 4);
    g.translate(0, r * 0.8, 0);
  }
  g.translate(x, y, z);
  const top = style === 'onion' ? 0.92 * k : style === 'round' ? r : r * 1.6;
  const fin = new SphereGeometry(0.055 * k, 10, 6);
  fin.translate(x, y + top + 0.04 * k, z);
  const spike = new CylinderGeometry(0, 0.025 * k, 0.22 * k, 6);
  spike.translate(x, y + top + 0.17 * k, z);
  return merge([setMist(g), setMist(fin), setMist(spike)]);
}

export function treeGeo(x: number, y: number, z: number, h: number): BufferGeometry {
  const prof: [number, number][] = [[0, 0.1], [0.2, 0.14], [0.27, 0.36], [0.24, 0.62], [0.15, 0.86], [0.05, 1.02], [0, 1.08]];
  const g = new LatheGeometry(prof.map(([a, b]) => new Vector2(a * h * 0.8, b * h)), 7);
  g.translate(x, y, z);
  return setMist(g);
}

export function trunkGeo(x: number, y: number, z: number, h: number): BufferGeometry {
  return boxGeo([x - 0.035, y, z - 0.035], [x + 0.035, y + h * 0.16, z + 0.035]);
}

export function pillarGeo(x: number, z: number, y0: number, y1: number, r: number, fade = 0): BufferGeometry {
  return boxGeo([x - r, y0, z - r], [x + r, y1, z + r], fade);
}

export function columnGeo(x: number, z: number, y0: number, y1: number, r: number): BufferGeometry {
  const g = new CylinderGeometry(r, r, y1 - y0, 16, 1);
  g.translate(x, (y0 + y1) / 2, z);
  return setMist(g, (y) => (Math.abs(y - y0) < 1e-4 && y0 < -1 ? 1 : 0));
}

export function urnGeo(x: number, y: number, z: number): BufferGeometry {
  const prof: [number, number][] = [[0, 0], [0.1, 0], [0.12, 0.05], [0.2, 0.18], [0.18, 0.3], [0.1, 0.36], [0.13, 0.42], [0, 0.42]];
  const g = new LatheGeometry(prof.map(([a, b]) => new Vector2(a, b)), 14);
  g.translate(x, y, z);
  return setMist(g);
}

/** Round-topped window recess facing `face`. */
export function windowGeo(x: number, y: number, z: number, face: V3, w: number, h: number): BufferGeometry {
  const s = new Shape();
  const r = w / 2;
  s.moveTo(-r, -h / 2);
  s.lineTo(r, -h / 2);
  s.lineTo(r, h / 2 - r);
  s.absarc(0, h / 2 - r, r, 0, Math.PI, false);
  s.closePath();
  const g = new ExtrudeGeometry(s, { depth: 0.04, bevelEnabled: false, curveSegments: 8 });
  const ang = Math.atan2(face[0], face[2]);
  g.rotateY(ang);
  g.translate(x + face[0] * 0.005, y, z + face[2] * 0.005);
  return setMist(g);
}

/** Crank: hub, four arms with pins; built around +Y then oriented later. */
export function crankParts(r: number): { body: BufferGeometry; pins: BufferGeometry } {
  const hub = new CylinderGeometry(0.17, 0.17, 0.2, 16);
  const ring = new CylinderGeometry(0.26, 0.26, 0.09, 20);
  const arms: BufferGeometry[] = [setMist(hub), setMist(ring)];
  const pins: BufferGeometry[] = [];
  for (let i = 0; i < 4; i++) {
    const a = (i * Math.PI) / 2;
    const arm = new BoxGeometry(r, 0.07, 0.09);
    arm.translate(r / 2, 0, 0);
    arm.rotateY(a);
    arms.push(setMist(arm));
    const pin = new CylinderGeometry(0.075, 0.075, 0.24, 12);
    pin.translate(r, 0.02, 0);
    pin.rotateY(a);
    pins.push(setMist(pin));
    const cap = new SphereGeometry(0.08, 10, 6);
    cap.translate(r, 0.15, 0);
    cap.rotateY(a);
    pins.push(setMist(cap));
  }
  return { body: merge(arms), pins: merge(pins) };
}

export function knobParts(): { body: BufferGeometry; pins: BufferGeometry } {
  const disc = new CylinderGeometry(0.2, 0.2, 0.12, 20);
  disc.rotateZ(Math.PI / 2);
  const stem = new CylinderGeometry(0.06, 0.06, 0.2, 10);
  stem.rotateZ(Math.PI / 2);
  stem.translate(-0.12, 0, 0);
  const cap = new CylinderGeometry(0.11, 0.11, 0.14, 16);
  cap.rotateZ(Math.PI / 2);
  cap.translate(0.06, 0, 0);
  return { body: merge([setMist(disc), setMist(stem)]), pins: merge([setMist(cap)]) };
}

export function planeXZ(min: V3, max: V3): BufferGeometry {
  const g = new PlaneGeometry(max[0] - min[0], max[2] - min[2]);
  g.rotateX(-Math.PI / 2);
  g.translate((min[0] + max[0]) / 2, min[1], (min[2] + max[2]) / 2);
  return g;
}
