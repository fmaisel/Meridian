// Sky, distant silhouettes, drifting mist, light motes and the light rig.
import {
  AdditiveBlending, BufferAttribute, BufferGeometry, Color, DirectionalLight, Group, HemisphereLight, Mesh,
  OrthographicCamera, PlaneGeometry, Points, PointsMaterial, Scene, ShaderMaterial, Vector3, type WebGLRenderer,
  NormalBlending, MeshBasicMaterial, DoubleSide,
} from 'three';
import { glyphTexture } from './glyphs';
import { atmosphere } from './materials';
import { blendMood, cloneMood, MOODS, type Mood } from './palette';

export class Environment {
  readonly bgScene = new Scene();
  readonly bgCamera = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
  readonly group = new Group();
  readonly sun: DirectionalLight;
  readonly hemi: HemisphereLight;
  readonly mood: Mood = cloneMood(MOODS.dawn);
  private target: Mood = cloneMood(MOODS.dawn);
  private skyMat: ShaderMaterial;
  private motes: Points;
  private mist: Mesh[] = [];
  private brighten = 0;
  /** Camera yaw, for sky parallax. */
  yaw = 0;

  constructor(private scene: Scene) {
    this.skyMat = new ShaderMaterial({
      uniforms: {
        uTop: { value: new Color() },
        uBottom: { value: new Color() },
        uGlow: { value: new Color() },
        uTime: atmosphere.uTime,
        uAspect: { value: 1 },
        uBright: { value: 0 },
        uShift: { value: 0 },
        uLift: { value: 0 },
      },
      depthWrite: false,
      depthTest: false,
      vertexShader: `varying vec2 vUv; void main(){ vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }`,
      fragmentShader: `
        uniform vec3 uTop; uniform vec3 uBottom; uniform vec3 uGlow; uniform float uTime; uniform float uAspect; uniform float uBright;
        uniform float uShift; uniform float uLift;
        varying vec2 vUv;
        float hash(vec2 p){ return fract(sin(dot(p, vec2(12.9898,78.233))) * 43758.5453); }
        float h1(float n){ return fract(sin(n*91.3458)*47453.5453); }
        // distant skyline of towers and domes, as a height at horizontal position x
        float skyline(float x, float seed){
          float cx = x * 7.0 + seed * 31.0;
          float cell = floor(cx);
          float f = fract(cx);
          float present = step(0.32, h1(cell + seed));
          float w = 0.25 + 0.5 * h1(cell * 1.31 + seed);
          float inside = step(abs(f - 0.5), w * 0.5);
          float h = (0.03 + 0.11 * h1(cell * 2.17 + seed)) * present * inside;
          float dr = w * 0.5;
          float dome = step(0.55, h1(cell * 3.7 + seed)) * present * sqrt(max(0.0, dr*dr - (f-0.5)*(f-0.5))) / 7.0 * 1.6;
          float spire = step(0.8, h1(cell * 5.3 + seed)) * present * max(0.0, 0.03 - abs(f-0.5)*0.4) * 2.0;
          return h + (h > 0.0 ? dome + spire : 0.0);
        }
        void main(){
          float t = smoothstep(0.0, 1.0, vUv.y);
          vec3 c = mix(uBottom, uTop, t*t*(3.0-2.0*t));
          vec2 p = vec2((vUv.x-0.5)*uAspect, vUv.y-0.42);
          float g = exp(-dot(p,p)*2.4);
          c = mix(c, uGlow, g*(0.55 + uBright*0.45));
          // two layers of far silhouettes sinking away as we ascend
          for (int i = 0; i < 2; i++) {
            float fi = float(i);
            float par = 0.35 + fi * 0.3;
            float x = (vUv.x - 0.5) * uAspect * (0.9 - fi*0.25) + uShift * par;
            float base = 0.1 - uLift * par + fi * 0.06;
            float hgt = skyline(x, 3.0 + fi * 7.0);
            float m = smoothstep(0.0015, 0.0, (vUv.y - base) - hgt) * step(0.0, hgt);
            float below = smoothstep(base + 0.02, base - 0.12, vUv.y);
            vec3 sc = mix(uTop, uBottom, 0.55 + fi * 0.2);
            c = mix(c, sc, max(m, below * step(0.0, 1.0)) * (0.22 - fi * 0.08));
          }
          c += (hash(vUv*vec2(1920.0,1080.0) + fract(uTime)) - 0.5) / 255.0 * 1.5;
          gl_FragColor = vec4(c, 1.0);
          #include <colorspace_fragment>
        }`,
    });
    const quad = new Mesh(new PlaneGeometry(2, 2), this.skyMat);
    quad.frustumCulled = false;
    this.bgScene.add(quad);

    this.hemi = new HemisphereLight('#fff8ee', '#d9e6d8', 1.55);
    this.sun = new DirectionalLight('#fff1dc', 2.15);
    this.sun.castShadow = true;
    this.sun.shadow.mapSize.set(2048, 2048);
    const sc = this.sun.shadow.camera;
    sc.left = -22; sc.right = 22; sc.top = 22; sc.bottom = -22; sc.near = 1; sc.far = 120;
    this.sun.shadow.bias = -0.0006;
    this.sun.shadow.normalBias = 0.02;
    this.sun.shadow.radius = 4;
    this.scene.add(this.hemi, this.sun, this.sun.target);

    this.buildMist();
    this.motes = this.buildMotes();
    this.buildBirds();
    this.scene.add(this.group);
    this.apply();
  }

  private buildMist() {
    const mat = new ShaderMaterial({
      uniforms: { uColor: atmosphere.uFogColor, uTime: atmosphere.uTime, uOpacity: { value: 0.5 } },
      transparent: true,
      depthWrite: false,
      vertexShader: `varying vec2 vUv; varying vec3 vW; void main(){ vUv = uv; vec4 w = modelMatrix*vec4(position,1.0); vW=w.xyz; gl_Position = projectionMatrix*viewMatrix*w; }`,
      fragmentShader: `
        uniform vec3 uColor; uniform float uTime; uniform float uOpacity; varying vec2 vUv; varying vec3 vW;
        float n(vec2 p){ vec2 i=floor(p); vec2 f=fract(p); f=f*f*(3.0-2.0*f);
          float a=fract(sin(dot(i,vec2(127.1,311.7)))*43758.5453); float b=fract(sin(dot(i+vec2(1,0),vec2(127.1,311.7)))*43758.5453);
          float c=fract(sin(dot(i+vec2(0,1),vec2(127.1,311.7)))*43758.5453); float d=fract(sin(dot(i+vec2(1,1),vec2(127.1,311.7)))*43758.5453);
          return mix(mix(a,b,f.x),mix(c,d,f.x),f.y); }
        void main(){
          vec2 p = vW.xz*0.08 + vec2(uTime*0.012, uTime*0.008);
          float v = n(p)*0.6 + n(p*2.3 + 4.0)*0.3 + n(p*5.1 - uTime*0.02)*0.1;
          float edge = smoothstep(0.5, 0.2, length(vUv-0.5));
          float a = smoothstep(0.35, 0.8, v) * edge * uOpacity;
          gl_FragColor = vec4(uColor, a);
          #include <colorspace_fragment>
        }`,
    });
    for (const [y, s] of [[-5, 90], [-7.5, 110], [-10, 130]] as const) {
      const g = new PlaneGeometry(s, s);
      g.rotateX(-Math.PI / 2);
      const m = new Mesh(g, mat);
      m.position.y = y;
      m.renderOrder = 1;
      this.mist.push(m);
      this.group.add(m);
    }
  }

  private buildMotes(): Points {
    const n = 220;
    const pos = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
      pos[i * 3] = (Math.random() - 0.5) * 50;
      pos[i * 3 + 1] = Math.random() * 40 - 8;
      pos[i * 3 + 2] = (Math.random() - 0.5) * 50;
    }
    const g = new BufferGeometry();
    g.setAttribute('position', new BufferAttribute(pos, 3));
    const m = new PointsMaterial({
      size: 0.16, map: glyphTexture('soft'), transparent: true, depthWrite: false, opacity: 0.7,
      color: '#ffffff', blending: AdditiveBlending, sizeAttenuation: true,
    });
    m.blending = NormalBlending;
    const p = new Points(g, m);
    p.frustumCulled = false;
    this.group.add(p);
    return p;
  }

  private birds: { g: Group; l: Mesh; r: Mesh; phase: number; radius: number; height: number; speed: number }[] = [];

  /** A small flock of pale birds circling the monument — slow, quiet life in the sky. */
  private buildBirds() {
    const wing = new BufferGeometry();
    wing.setAttribute('position', new BufferAttribute(new Float32Array([0, 0, -0.05, 0, 0, 0.05, 0.22, 0.0, 0.0]), 3));
    wing.computeVertexNormals();
    const mat = new MeshBasicMaterial({ color: '#fffaf2', side: DoubleSide, transparent: true, opacity: 0.85, depthWrite: false });
    for (let i = 0; i < 7; i++) {
      const g = new Group();
      const l = new Mesh(wing, mat);
      const r = new Mesh(wing, mat);
      r.scale.x = -1;
      g.add(l, r);
      g.scale.setScalar(0.9 + (i % 3) * 0.2);
      this.group.add(g);
      this.birds.push({ g, l, r, phase: i * 0.9, radius: 9 + (i % 4) * 1.6, height: 3 + (i % 3) * 1.4, speed: 0.11 + (i % 2) * 0.03 });
    }
  }

  setMood(name: string): void {
    const m = MOODS[name];
    if (m) this.target = cloneMood(m);
  }

  /** Extra radiance for the finale. */
  setBrighten(v: number): void {
    this.brighten = v;
  }

  update(dt: number, focus: Vector3, time: number, aspect: number): void {
    blendMood(this.mood, this.target, 1 - Math.exp(-1.2 * dt), this.mood);
    this.apply();
    this.skyMat.uniforms.uAspect.value = aspect;
    this.skyMat.uniforms.uShift.value = this.yaw * 0.6 + (focus.x - focus.z) * 0.012;
    this.skyMat.uniforms.uLift.value = focus.y * 0.018;
    this.skyMat.uniforms.uBright.value = this.brighten;
    // keep the shadow frustum centred on what we look at
    this.sun.target.position.copy(focus);
    this.sun.position.copy(focus).add(SUN_DIR);
    for (const m of this.mist) { m.position.x = focus.x; m.position.z = focus.z; }
    const pos = this.motes.geometry.getAttribute('position') as BufferAttribute;
    const arr = pos.array as Float32Array;
    for (let i = 0; i < arr.length; i += 3) {
      arr[i + 1] += dt * (0.18 + (i % 7) * 0.02);
      arr[i] += Math.sin(time * 0.3 + i) * dt * 0.05;
      if (arr[i + 1] > focus.y + 22) arr[i + 1] = focus.y - 16;
      if (arr[i + 1] < focus.y - 16) arr[i + 1] = focus.y + 20;
    }
    pos.needsUpdate = true;
    this.motes.position.set(focus.x, 0, focus.z);
    for (const b of this.birds) {
      const a = time * b.speed + b.phase;
      const x = focus.x + Math.cos(a) * b.radius;
      const z = focus.z + Math.sin(a) * b.radius;
      b.g.position.set(x, focus.y + b.height + Math.sin(time * 0.6 + b.phase) * 0.4, z);
      b.g.rotation.y = -a;
      const flap = Math.sin(time * 7 + b.phase * 3) * 0.55 * (0.5 + 0.5 * Math.max(0, Math.sin(time * 0.5 + b.phase)));
      b.l.rotation.z = flap;
      b.r.rotation.z = -flap;
    }
  }

  private apply() {
    const m = this.mood;
    const u = this.skyMat.uniforms;
    (u.uTop.value as Color).copy(m.skyTop);
    (u.uBottom.value as Color).copy(m.skyBottom);
    (u.uGlow.value as Color).copy(m.glow);
    atmosphere.uFogColor.value.copy(m.fog);
    this.sun.color.copy(m.sun);
    this.hemi.color.copy(m.hemiSky);
    this.hemi.groundColor.copy(m.hemiGround);
  }

  renderBackground(r: WebGLRenderer): void {
    r.render(this.bgScene, this.bgCamera);
  }
}

export const SUN_DIR = new Vector3(0.3, 1, 0.68).normalize().multiplyScalar(60);
