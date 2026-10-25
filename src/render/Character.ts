// The wanderer: a small robed figure carrying a lantern-light. Purely visual; movement is driven
// by the CharacterController in game/.
import {
  GreaterDepth, CylinderGeometry, Group, LatheGeometry, Mesh, MeshBasicMaterial, PlaneGeometry, SphereGeometry, Sprite,
  SpriteMaterial, Vector2, type Material,
} from 'three';
import { glyphTexture } from './glyphs';
import { lit } from './materials';

export class CharacterView {
  readonly root = new Group();
  readonly body = new Group();
  readonly shadow: Mesh;
  private robe: Mesh;
  private head: Mesh;
  private hood: Mesh;
  private orb: Mesh;
  private halo: Sprite;
  private phase = 0;
  private yaw = 0;
  private targetYaw = 0;
  private walkBlend = 0;
  private overlayMats: Material[] = [];
  private ghostMat: MeshBasicMaterial;
  glowBoost = 0;

  constructor() {
    const robeMat = lit('#fbf7ef');
    const sash = lit('#e9735c');
    const skin = lit('#fbf7ef');
    const robeProfile: [number, number][] = [
      [0, 0], [0.17, 0], [0.165, 0.04], [0.13, 0.2], [0.095, 0.36], [0.07, 0.42], [0, 0.43],
    ];
    this.robe = new Mesh(new LatheGeometry(robeProfile.map(([a, b]) => new Vector2(a, b)), 18), robeMat);
    this.head = new Mesh(new SphereGeometry(0.085, 18, 12), skin);
    this.head.position.y = 0.49;
    // tall pointed hood leaning back
    this.hood = new Mesh(new CylinderGeometry(0.0, 0.088, 0.3, 14, 1, true), robeMat);
    this.hood.position.set(0, 0.6, -0.04);
    this.hood.rotation.x = -0.32;
    const belt = new Mesh(new CylinderGeometry(0.105, 0.112, 0.035, 18), sash);
    belt.position.y = 0.3;
    // lantern orb on a short staff
    const staff = new Mesh(new CylinderGeometry(0.009, 0.009, 0.42, 6), lit('#b9876a'));
    staff.position.set(0.14, 0.27, 0.03);
    this.orb = new Mesh(new SphereGeometry(0.04, 12, 8), new MeshBasicMaterial({ color: '#fff3c9' }));
    this.orb.position.set(0.14, 0.5, 0.03);
    this.halo = new Sprite(new SpriteMaterial({ map: glyphTexture('soft'), color: '#ffe7a8', transparent: true, opacity: 0.85, depthWrite: false }));
    this.halo.scale.set(0.32, 0.32, 1);
    this.halo.position.copy(this.orb.position);

    for (const m of [this.robe, this.head, this.hood, belt, staff]) {
      m.castShadow = true;
      m.receiveShadow = false;
    }
    this.body.add(this.robe, this.head, this.hood, belt, staff, this.orb, this.halo);
    this.body.scale.setScalar(1.18);
    this.root.add(this.body);

    const sh = new PlaneGeometry(0.5, 0.5);
    sh.rotateX(-Math.PI / 2);
    this.shadow = new Mesh(sh, new MeshBasicMaterial({ map: glyphTexture('shadow'), transparent: true, depthWrite: false, opacity: 0.5 }));
    this.shadow.position.y = 0.012;
    this.shadow.renderOrder = 3;
    this.root.add(this.shadow);

    this.root.traverse((o) => {
      const m = (o as Mesh).material as Material | undefined;
      if (m && !this.overlayMats.includes(m)) this.overlayMats.push(m);
    });

    // faint silhouette visible through architecture in front of the wanderer
    this.ghostMat = new MeshBasicMaterial({ color: '#fffaf2', transparent: true, opacity: 0.38, depthFunc: GreaterDepth, depthWrite: false });
    for (const m of [this.robe, this.head, this.hood]) {
      const gm = new Mesh(m.geometry, this.ghostMat);
      gm.renderOrder = 9;
      m.add(gm);
    }
  }

  face(dx: number, dz: number): void {
    if (Math.abs(dx) + Math.abs(dz) < 1e-4) return;
    this.targetYaw = Math.atan2(dx, dz);
  }

  /** Render on top of geometry (used while crossing perspective seams). */
  setOverlay(on: boolean): void {
    for (const m of this.overlayMats) {
      m.depthTest = !on;
    }
    this.ghostMat.visible = !on;
    this.root.traverse((o) => { o.renderOrder = on ? 10 : o === this.shadow ? 3 : 0; });
  }

  update(dt: number, walking: boolean, speed: number, time: number): void {
    this.walkBlend += ((walking ? 1 : 0) - this.walkBlend) * (1 - Math.exp(-10 * dt));
    let d = this.targetYaw - this.yaw;
    while (d > Math.PI) d -= Math.PI * 2;
    while (d < -Math.PI) d += Math.PI * 2;
    this.yaw += d * (1 - Math.exp(-14 * dt));
    this.body.rotation.y = this.yaw;

    this.phase += dt * speed * 7.2;
    const w = this.walkBlend;
    const bob = Math.abs(Math.sin(this.phase)) * 0.035 * w;
    const breathe = Math.sin(time * 1.8) * 0.006 * (1 - w);
    this.body.position.y = bob + breathe;
    this.body.rotation.z = Math.sin(this.phase) * 0.06 * w;
    this.body.rotation.x = 0.1 * w;
    this.robe.scale.set(1 + Math.sin(this.phase * 2) * 0.03 * w, 1 - bob * 0.6, 1 + Math.cos(this.phase * 2) * 0.03 * w);
    this.head.position.y = 0.49 + Math.sin(this.phase * 2) * 0.005 * w;
    this.orb.position.y = 0.5 + Math.sin(time * 2.4) * 0.012 + bob * 0.4;
    this.halo.position.copy(this.orb.position);
    const hs = 0.32 + Math.sin(time * 2.1) * 0.03 + this.glowBoost * 0.6;
    this.halo.scale.set(hs, hs, 1);
    this.shadow.scale.setScalar(1 - bob * 2.5);
  }
}
