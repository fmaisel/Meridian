// The closing sequence: the light is set in the summit lamp, a beam rises, slender spires grow out
// of the mist around the monument, and the camera withdraws to a composed view of the whole.
import {
  AdditiveBlending, Color, CylinderGeometry, Mesh, MeshBasicMaterial, ShaderMaterial, Sprite, SpriteMaterial, Vector3,
  Group,
} from 'three';
import { ease } from '../core/anim';
import { boxGeo, domeGeo, merge } from '../render/geometry';
import { glyphTexture } from '../render/glyphs';
import type { Game } from './Game';

const SPIRES: { x: number; z: number; top: number; w: number; pal: string; roof: string }[] = [
  { x: 11, z: -7, top: 9, w: 1.1, pal: 'ivory', roof: 'roof' },
  { x: -9, z: 11, top: 6, w: 1.3, pal: 'sand', roof: 'roof' },
  { x: 13, z: 4, top: 3, w: 1.6, pal: 'coral', roof: 'roofCoral' },
  { x: -17, z: -3, top: 12, w: 1.0, pal: 'dusk', roof: 'roofViolet' },
  { x: 6, z: -14, top: 15, w: 0.9, pal: 'dusk', roof: 'roofViolet' },
  { x: -4, z: 15, top: 1, w: 1.8, pal: 'ivory', roof: 'roof' },
  { x: 17, z: -1, top: 7, w: 0.8, pal: 'sand', roof: 'roof' },
];

export async function runFinale(game: Game): Promise<void> {
  const { anim, audio, env, rig, effects, charView, view, mats, scene } = game;
  audio.finale();
  env.setMood('radiant');
  const goal = game.nodeWorld(game.logic.def.goal);

  // the lamp catches the light
  const lamp = view.lamp;
  const lampPos = lamp ? lamp.getWorldPosition(new Vector3()) : goal.clone().add(new Vector3(0, 1.3, 0));
  const glow = new Sprite(new SpriteMaterial({ map: glyphTexture('soft'), color: '#ffe3a0', transparent: true, depthWrite: false, blending: AdditiveBlending, opacity: 0 }));
  glow.position.copy(lampPos);
  glow.renderOrder = 8;
  scene.add(glow);
  game.finaleObjects.push(glow);
  effects.shimmer(goal.clone().add(new Vector3(0, 0.5, 0)), '#fff1c4', 3);
  await anim.play({
    duration: 2.4, ease: ease.inOutSine,
    onUpdate: (k) => {
      charView.glowBoost = k * 1.2;
      env.setBrighten(k * 0.6);
      if (lamp) (lamp.material as MeshBasicMaterial).color.set(new Color('#d8c7a6').lerp(new Color('#fff6d8'), k));
      glow.material.opacity = k;
      glow.scale.setScalar(0.5 + k * 2.6);
    },
  });

  // a beam of light rises into the sky
  const beamMat = new ShaderMaterial({
    uniforms: { uK: { value: 0 }, uColor: { value: new Color('#fff1c8') } },
    transparent: true, depthWrite: false, blending: AdditiveBlending,
    vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix*modelViewMatrix*vec4(position,1.0); }`,
    fragmentShader: `uniform float uK; uniform vec3 uColor; varying vec2 vUv;
      void main(){ float a = (1.0 - vUv.y) * smoothstep(0.0, 0.05, vUv.y) * uK; a *= 0.55 + 0.45*sin(vUv.x*6.2831*3.0); gl_FragColor = vec4(uColor, a*0.6); }`,
  });
  const beam = new Mesh(new CylinderGeometry(0.16, 0.06, 40, 16, 1, true), beamMat);
  beam.position.copy(lampPos).add(new Vector3(0, 20, 0));
  beam.renderOrder = 8;
  scene.add(beam);
  game.finaleObjects.push(beam);
  anim.add({ duration: 3, ease: ease.outCubic, onUpdate: (k) => { beamMat.uniforms.uK.value = k; } });

  // every window in the monument and the city below catches the light
  const windows = view.windowMaterials();
  const base = windows.map((m) => m.color.clone());
  const warm = new Color('#ffd98a');
  anim.add({
    duration: 4, delay: 0.5, ease: ease.inOutSine,
    onUpdate: (k) => windows.forEach((m, i) => { m.color.copy(base[i]).lerp(warm, k); m.userData.glow.value = k * 0.55; m.userData.glowColor.value.set('#ffe7a8'); }),
  });

  // spires grow from the mist
  const spires = new Group();
  scene.add(spires);
  game.finaleObjects.push(spires);
  SPIRES.forEach((s, i) => {
    const h = s.w / 2;
    const m = new Mesh(
      merge([boxGeo([s.x - h, -40, s.z - h], [s.x + h, s.top, s.z + h], 6), boxGeo([s.x - h - 0.12, s.top - 0.4, s.z - h - 0.12], [s.x + h + 0.12, s.top - 0.15, s.z + h + 0.12])]),
      mats.get(s.pal, 'stone'),
    );
    const dome = new Mesh(domeGeo(s.x, s.top, s.z, h * 0.9, 'onion'), mats.get(s.pal, s.roof));
    const g = new Group();
    g.add(m, dome);
    g.position.y = -26;
    spires.add(g);
    anim.add({ duration: 5.5, delay: 0.4 + i * 0.45, ease: ease.inOutCubic, onUpdate: (k) => { g.position.y = -26 * (1 - k); } });
  });
  audio.rumble(4);

  // withdraw to the whole monument from the front
  rig.followRate = 0.55;
  rig.zoomRate = 0.4;
  rig.setQuadrant(0, true, 5);
  rig.frame([-2, 8.5, 1], 19.5);
  await anim.wait(7.5);
  rig.followRate = 2.2;
  rig.zoomRate = 1.6;
}
