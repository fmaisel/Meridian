// InteractionSystem: decodes pointer/keyboard input into intents — walk to a tile, drag a handle,
// drag the sky to turn the world — and manages hover feedback.
import { Raycaster, Vector2, type Camera, type Object3D } from 'three';

export interface InteractionHost {
  camera(): Camera;
  enabled(): boolean;
  handleMeshes(): Object3D[];
  levelMeshes(): Object3D[];
  hoverHandle(mech: string | null): void;
  /** Return true to begin dragging (handle accepted). */
  handleDown(mech: string, x: number, y: number): boolean;
  handleMove(x: number, y: number): void;
  handleUp(): void;
  click(x: number, y: number, ray: Raycaster): void;
  skyDrag(dx: number): void;
  skyRelease(dx: number, vx: number): void;
  key(code: string): void;
}

export class Interaction {
  private ray = new Raycaster();
  private ndc = new Vector2();
  private mode: 'none' | 'handle' | 'sky' | 'press' = 'none';
  private downX = 0;
  private downY = 0;
  private lastX = 0;
  private lastT = 0;
  private vx = 0;
  private pointerId = -1;

  constructor(private el: HTMLCanvasElement, private host: InteractionHost) {
    el.addEventListener('pointerdown', this.onDown);
    el.addEventListener('pointermove', this.onMove);
    window.addEventListener('pointerup', this.onUp);
    window.addEventListener('pointercancel', this.onUp);
    window.addEventListener('keydown', (e) => this.host.key(e.code));
    el.addEventListener('contextmenu', (e) => e.preventDefault());
  }

  private setRay(x: number, y: number) {
    const r = this.el.getBoundingClientRect();
    this.ndc.set(((x - r.left) / r.width) * 2 - 1, -((y - r.top) / r.height) * 2 + 1);
    this.ray.setFromCamera(this.ndc, this.host.camera());
  }

  private pickHandle(x: number, y: number): string | null {
    this.setRay(x, y);
    const hits = this.ray.intersectObjects(this.host.handleMeshes(), false);
    if (hits.length) return hits[0].object.userData.handle as string;
    // forgiving: if the nearest level hit is far behind a handle, accept handles within a few pixels
    return null;
  }

  private onDown = (e: PointerEvent) => {
    if (!this.host.enabled() || this.pointerId !== -1) return;
    this.pointerId = e.pointerId;
    try {
      this.el.setPointerCapture(e.pointerId);
    } catch {
      /* synthetic or already-released pointers cannot be captured */
    }
    this.downX = this.lastX = e.clientX;
    this.downY = e.clientY;
    this.lastT = performance.now();
    this.vx = 0;
    const mech = this.pickHandle(e.clientX, e.clientY);
    if (mech && this.host.handleDown(mech, e.clientX, e.clientY)) {
      this.mode = 'handle';
      this.el.classList.add('grabbing');
      return;
    }
    this.mode = 'press';
  };

  private onMove = (e: PointerEvent) => {
    if (this.pointerId === -1) {
      if (!this.host.enabled()) return;
      const mech = this.pickHandle(e.clientX, e.clientY);
      this.host.hoverHandle(mech);
      this.el.classList.toggle('grab', !!mech);
      return;
    }
    if (e.pointerId !== this.pointerId) return;
    const now = performance.now();
    const dt = Math.max(1, now - this.lastT);
    this.vx = 0.7 * this.vx + 0.3 * ((e.clientX - this.lastX) / dt);
    this.lastX = e.clientX;
    this.lastT = now;
    if (this.mode === 'handle') {
      this.host.handleMove(e.clientX, e.clientY);
    } else if (this.mode === 'press') {
      const dx = e.clientX - this.downX;
      const dy = e.clientY - this.downY;
      if (Math.hypot(dx, dy) > 10 && Math.abs(dx) > Math.abs(dy) * 0.8) this.mode = 'sky';
    }
    if (this.mode === 'sky') this.host.skyDrag(e.clientX - this.downX);
  };

  private onUp = (e: PointerEvent) => {
    if (e.pointerId !== this.pointerId) return;
    this.pointerId = -1;
    this.el.classList.remove('grabbing');
    if (this.mode === 'handle') this.host.handleUp();
    else if (this.mode === 'sky') this.host.skyRelease(e.clientX - this.downX, this.vx);
    else if (this.mode === 'press' && this.host.enabled()) {
      if (Math.hypot(e.clientX - this.downX, e.clientY - this.downY) < 10) {
        this.setRay(e.clientX, e.clientY);
        this.host.click(e.clientX, e.clientY, this.ray);
      }
    }
    this.mode = 'none';
  };
}
