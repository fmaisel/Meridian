// AnimationSystem: easing curves and time-based tweens. No allocation per frame besides active tweens.

export type Ease = (t: number) => number;

export const ease = {
  linear: (t: number) => t,
  inOutSine: (t: number) => 0.5 - 0.5 * Math.cos(Math.PI * t),
  outSine: (t: number) => Math.sin((t * Math.PI) / 2),
  inOutCubic: (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
  outCubic: (t: number) => 1 - Math.pow(1 - t, 3),
  inCubic: (t: number) => t * t * t,
  outQuart: (t: number) => 1 - Math.pow(1 - t, 4),
  inOutQuart: (t: number) => (t < 0.5 ? 8 * t ** 4 : 1 - Math.pow(-2 * t + 2, 4) / 2),
  /** Gentle overshoot, used for snapping architecture into place. */
  outBack: (t: number, s = 1.25) => 1 + (s + 1) * Math.pow(t - 1, 3) + s * Math.pow(t - 1, 2),
  outExpo: (t: number) => (t >= 1 ? 1 : 1 - Math.pow(2, -10 * t)),
};

export interface TweenOpts {
  duration: number;
  delay?: number;
  ease?: Ease;
  tag?: string;
  onUpdate?: (k: number, t: number) => void;
  onDone?: () => void;
}

interface Tween extends TweenOpts {
  elapsed: number;
  done: boolean;
}

export class Animator {
  private list: Tween[] = [];

  add(o: TweenOpts): () => void {
    const t: Tween = { ...o, elapsed: 0, done: false };
    this.list.push(t);
    return () => {
      t.done = true;
    };
  }

  /** Resolve after the tween completes. */
  play(o: TweenOpts): Promise<void> {
    return new Promise((res) => {
      const done = o.onDone;
      this.add({ ...o, onDone: () => { done?.(); res(); } });
    });
  }

  wait(seconds: number): Promise<void> {
    return this.play({ duration: seconds });
  }

  cancel(tag: string): void {
    for (const t of this.list) if (t.tag === tag) t.done = true;
  }

  has(tag: string): boolean {
    return this.list.some((t) => t.tag === tag && !t.done);
  }

  update(dt: number): void {
    if (!this.list.length) return;
    const active = this.list;
    this.list = [];
    for (const t of active) {
      if (t.done) continue;
      t.elapsed += dt;
      const local = t.elapsed - (t.delay ?? 0);
      if (local < 0) { this.list.push(t); continue; }
      const k = Math.min(1, local / Math.max(1e-6, t.duration));
      t.onUpdate?.((t.ease ?? ease.inOutCubic)(k), k);
      if (k >= 1) {
        t.done = true;
        t.onDone?.();
      } else this.list.push(t);
    }
  }
}

/** Frame-rate independent exponential smoothing factor. */
export function damp(rate: number, dt: number): number {
  return 1 - Math.exp(-rate * dt);
}

export const clamp = (v: number, a: number, b: number) => Math.max(a, Math.min(b, v));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
