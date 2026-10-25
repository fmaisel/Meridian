// Interaction feedback: tile rings, seam shimmer, handle pulses and dust bursts.
import {
  AdditiveBlending, BufferAttribute, BufferGeometry, Color, Group, Mesh, MeshBasicMaterial, PlaneGeometry, Points,
  PointsMaterial, Sprite, SpriteMaterial, Vector3,
} from 'three';
import { Animator, ease } from '../core/anim';
import { glyphTexture } from './glyphs';
import type { HandleView } from './LevelView';

export class Effects {
  readonly group = new Group();
  private ringGeo: PlaneGeometry;

  constructor(private anim: Animator) {
    this.ringGeo = new PlaneGeometry(1, 1);
    this.ringGeo.rotateX(-Math.PI / 2);
  }

  /** Square ring on a tile: confirms a click (ok) or politely refuses (not ok). */
  ring(pos: Vector3, ok: boolean): void {
    const mat = new MeshBasicMaterial({
      map: glyphTexture('ring'), color: ok ? '#ffffff' : '#9a8a90', transparent: true, depthWrite: false, depthTest: false,
    });
    const m = new Mesh(this.ringGeo, mat);
    m.position.copy(pos).add(new Vector3(0, 0.02, 0));
    m.renderOrder = 6;
    this.group.add(m);
    this.anim.add({
      duration: ok ? 0.6 : 0.45,
      ease: ease.outCubic,
      onUpdate: (k) => {
        const s = ok ? 0.75 + k * 0.35 : 1 - k * 0.45;
        m.scale.set(s, 1, s);
        mat.opacity = (1 - k) * (ok ? 0.95 : 0.7);
      },
      onDone: () => { this.group.remove(m); mat.dispose(); },
    });
  }

  /** Repeated ring pulse to point at a tile (hints). */
  beckon(pos: Vector3, times = 3): void {
    for (let i = 0; i < times; i++) {
      this.anim.add({ duration: 0.01, delay: i * 0.9, onDone: () => this.ring(pos, true) });
    }
  }

  /** Soft light blooming at a point (connections, seams). */
  shimmer(pos: Vector3, color = '#fff6dc', scale = 1.6): void {
    const mat = new SpriteMaterial({ map: glyphTexture('soft'), color: new Color(color), transparent: true, depthWrite: false, depthTest: false, blending: AdditiveBlending });
    const s = new Sprite(mat);
    s.position.copy(pos);
    s.renderOrder = 7;
    this.group.add(s);
    this.anim.add({
      duration: 1.6,
      ease: ease.linear,
      onUpdate: (_k, t) => {
        const a = Math.sin(Math.PI * Math.min(1, t * 1.4));
        s.scale.setScalar(scale * (0.4 + t));
        mat.opacity = a * 0.9;
      },
      onDone: () => { this.group.remove(s); mat.dispose(); },
    });
  }

  /** Glow pulse on a handle (hover, hint, refusal). */
  pulseHandle(h: HandleView, times = 3): void {
    this.anim.add({
      duration: 0.9 * times,
      ease: ease.linear,
      onUpdate: (_k, t) => {
        const v = Math.max(0, Math.sin(t * times * Math.PI)) * 0.55;
        for (const m of h.materials) m.userData.glow.value = Math.max(m.userData.glow.value, v);
      },
      onDone: () => { for (const m of h.materials) m.userData.glow.value = 0; },
    });
  }

  /** Small refusal wiggle on a handle. */
  wiggle(h: HandleView): void {
    const base = h.group.rotation.clone();
    this.anim.add({
      duration: 0.45,
      ease: ease.linear,
      onUpdate: (_k, t) => {
        const a = Math.sin(t * Math.PI * 6) * (1 - t) * 0.12;
        h.group.rotation.set(base.x, base.y + a, base.z + (h.kind === 'knob' ? a : 0));
      },
      onDone: () => h.group.rotation.copy(base),
    });
  }

  /** A small light that travels from a plate to the part it moves — cause and effect made visible. */
  trail(from: Vector3, to: Vector3, duration = 1.3, color = '#bff3e8'): void {
    const lift = Math.max(from.y, to.y) + 1.2 + from.distanceTo(to) * 0.12;
    const at = (t: number, out: Vector3) => {
      const a = from.clone().lerp(to, t);
      a.y = (1 - t) * (1 - t) * from.y + 2 * (1 - t) * t * lift + t * t * to.y;
      return out.copy(a);
    };
    for (let i = 0; i < 4; i++) {
      const mat = new SpriteMaterial({ map: glyphTexture('soft'), color: new Color(color), transparent: true, depthWrite: false, depthTest: false, blending: AdditiveBlending });
      const s = new Sprite(mat);
      s.renderOrder = 7;
      const size = i === 0 ? 0.7 : 0.45 - i * 0.08;
      s.scale.setScalar(size);
      this.group.add(s);
      at(0, s.position);
      this.anim.add({
        duration, delay: i * 0.06, ease: ease.inOutSine,
        onUpdate: (k) => {
          at(k, s.position);
          mat.opacity = Math.min(1, k * 6) * (i === 0 ? 1 : 0.6) * (k > 0.92 ? (1 - k) / 0.08 : 1);
        },
        onDone: () => { this.group.remove(s); mat.dispose(); },
      });
    }
    this.anim.add({ duration: 0.01, delay: duration, onDone: () => this.shimmer(to, color, 1.6) });
  }

  dust(pos: Vector3, spread = 1.2, color = '#fff8ec'): void {
    const n = 36;
    const p = new Float32Array(n * 3);
    const v: Vector3[] = [];
    for (let i = 0; i < n; i++) {
      p[i * 3] = pos.x + (Math.random() - 0.5) * spread;
      p[i * 3 + 1] = pos.y + Math.random() * 0.2;
      p[i * 3 + 2] = pos.z + (Math.random() - 0.5) * spread;
      v.push(new Vector3((Math.random() - 0.5) * 0.6, 0.3 + Math.random() * 0.7, (Math.random() - 0.5) * 0.6));
    }
    const g = new BufferGeometry();
    g.setAttribute('position', new BufferAttribute(p, 3));
    const mat = new PointsMaterial({ size: 0.12, map: glyphTexture('soft'), color, transparent: true, depthWrite: false, opacity: 0.9 });
    const pts = new Points(g, mat);
    this.group.add(pts);
    let last = 0;
    this.anim.add({
      duration: 1.8,
      ease: ease.linear,
      onUpdate: (_k, t) => {
        const dt = (t - last) * 1.8;
        last = t;
        for (let i = 0; i < n; i++) {
          p[i * 3] += v[i].x * dt;
          p[i * 3 + 1] += v[i].y * dt;
          p[i * 3 + 2] += v[i].z * dt;
        }
        g.getAttribute('position').needsUpdate = true;
        mat.opacity = 0.9 * (1 - t);
      },
      onDone: () => { this.group.remove(pts); g.dispose(); mat.dispose(); },
    });
  }
}
