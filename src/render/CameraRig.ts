// CameraController: exact isometric orthographic camera with zone framing, smooth follow and
// world rotation in 90° steps.
import { OrthographicCamera, Vector3 } from 'three';
import { damp, ease } from '../core/anim';

const ELEV = Math.atan(1 / Math.SQRT2); // 35.264° — true isometric

export class CameraRig {
  readonly camera = new OrthographicCamera(-10, 10, 10, -10, -200, 400);
  readonly target = new Vector3();
  private goalTarget = new Vector3();
  size = 8;
  private goalSize = 8;
  /** yaw of the view vector; quadrant q ↔ 45° + q·90° */
  yaw = Math.PI / 4;
  private yawFrom = this.yaw;
  private yawTo = this.yaw;
  private yawT = 1;
  private yawDur = 1.2;
  /** Temporary yaw offset while the player drags the sky. */
  dragYaw = 0;
  private dragYawSmoothed = 0;
  aspect = 1;
  followRate = 2.2;
  zoomRate = 1.6;
  /** Gentle breathing drift for life while idle. */
  drift = 1;
  private vel = new Vector3();
  private sizeVel = 0;

  static yawFor(q: number): number {
    return Math.PI / 4 + q * (Math.PI / 2);
  }

  setQuadrant(q: number, animate: boolean, duration = 1.2): void {
    const to = CameraRig.yawFor(q);
    if (!animate) {
      this.yaw = this.yawFrom = this.yawTo = to;
      this.yawT = 1;
      return;
    }
    // shortest direction from the current yaw
    let delta = to - this.yaw;
    while (delta > Math.PI) delta -= Math.PI * 2;
    while (delta < -Math.PI) delta += Math.PI * 2;
    this.yawFrom = this.yaw + this.dragYawSmoothed;
    this.dragYaw = 0;
    this.dragYawSmoothed = 0;
    this.yawTo = this.yaw + delta;
    this.yawT = 0;
    this.yawDur = duration;
  }

  get rotating(): boolean {
    return this.yawT < 1;
  }

  frame(target: Vector3 | [number, number, number], size: number, snap = false): void {
    if (Array.isArray(target)) this.goalTarget.set(...target);
    else this.goalTarget.copy(target);
    this.goalSize = size;
    if (snap) {
      this.target.copy(this.goalTarget);
      this.size = size;
      this.vel.set(0, 0, 0);
      this.sizeVel = 0;
    }
  }

  /** View direction (from target toward camera). */
  viewDir(out = new Vector3()): Vector3 {
    const y = this.yaw + this.dragYawSmoothed;
    return out.set(Math.sin(y) * Math.cos(ELEV), Math.sin(ELEV), Math.cos(y) * Math.cos(ELEV)).normalize();
  }

  update(dt: number, time: number): void {
    if (this.yawT < 1) {
      this.yawT = Math.min(1, this.yawT + dt / this.yawDur);
      this.yaw = this.yawFrom + (this.yawTo - this.yawFrom) * ease.inOutQuart(this.yawT);
    }
    this.dragYawSmoothed += (this.dragYaw - this.dragYawSmoothed) * damp(14, dt);
    // critically damped springs: moves ease in and out instead of starting abruptly
    const tFollow = 1.6 / Math.max(0.1, this.followRate);
    const tZoom = 1.6 / Math.max(0.1, this.zoomRate);
    for (const ax of ['x', 'y', 'z'] as const) {
      const r = smoothDamp(this.target[ax], this.goalTarget[ax], this.vel[ax], tFollow, dt);
      this.target[ax] = r[0];
      this.vel[ax] = r[1];
    }
    const zs = smoothDamp(this.size, this.goalSize, this.sizeVel, tZoom, dt);
    this.size = zs[0];
    this.sizeVel = zs[1];
    // the view breathes out a little while the world turns
    const breatheOut = this.yawT < 1 ? Math.sin(Math.PI * this.yawT) * 0.06 : 0;

    const dir = this.viewDir();
    const t = this.target;
    const breathe = Math.sin(time * 0.35) * 0.04 * this.drift;
    this.camera.position.set(t.x + dir.x * 120, t.y + breathe + dir.y * 120, t.z + dir.z * 120);
    this.camera.up.set(0, 1, 0);
    this.camera.lookAt(t.x, t.y + breathe, t.z);

    const base = this.size * (1 + breatheOut);
    const s = this.aspect < 1 ? base / Math.max(0.62, this.aspect) : base;
    this.camera.top = s;
    this.camera.bottom = -s;
    this.camera.left = -s * this.aspect;
    this.camera.right = s * this.aspect;
    this.camera.updateProjectionMatrix();
  }
}

/** Unity-style SmoothDamp (critically damped spring). Returns [value, velocity]. */
function smoothDamp(cur: number, target: number, vel: number, smoothTime: number, dt: number): [number, number] {
  const omega = 2 / smoothTime;
  const x = omega * dt;
  const exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
  const change = cur - target;
  const temp = (vel + omega * change) * dt;
  const v = (vel - omega * temp) * exp;
  return [target + (change + temp) * exp, v];
}
