// Canvas-drawn glyph textures and the small shader materials (water, waterfall) used by the kit.
import { CanvasTexture, Color, DoubleSide, MeshBasicMaterial, ShaderMaterial, SRGBColorSpace } from 'three';
import { atmosphere } from './materials';

type Painter = (g: CanvasRenderingContext2D, s: number) => void;

const painters: Record<string, Painter> = {
  plate: (g, s) => {
    g.strokeStyle = '#ffffff';
    g.lineWidth = s * 0.045;
    g.strokeRect(s * 0.16, s * 0.16, s * 0.68, s * 0.68);
    g.beginPath();
    g.arc(s / 2, s / 2, s * 0.2, 0, Math.PI * 2);
    g.stroke();
    g.fillStyle = '#ffffff';
    g.beginPath();
    g.arc(s / 2, s / 2, s * 0.08, 0, Math.PI * 2);
    g.fill();
  },
  eye: (g, s) => {
    g.strokeStyle = '#ffffff';
    g.lineWidth = s * 0.04;
    g.beginPath();
    g.moveTo(s * 0.14, s / 2);
    g.quadraticCurveTo(s / 2, s * 0.12, s * 0.86, s / 2);
    g.quadraticCurveTo(s / 2, s * 0.88, s * 0.14, s / 2);
    g.stroke();
    g.beginPath();
    g.arc(s / 2, s / 2, s * 0.13, 0, Math.PI * 2);
    g.stroke();
    g.fillStyle = '#ffffff';
    g.beginPath();
    g.arc(s / 2, s / 2, s * 0.055, 0, Math.PI * 2);
    g.fill();
  },
  start: (g, s) => {
    g.strokeStyle = '#ffffff';
    g.lineWidth = s * 0.035;
    g.beginPath();
    g.arc(s / 2, s / 2, s * 0.26, 0, Math.PI * 2);
    g.stroke();
  },
  goal: (g, s) => {
    g.strokeStyle = '#ffffff';
    g.fillStyle = '#ffffff';
    g.lineWidth = s * 0.035;
    g.beginPath();
    g.arc(s / 2, s / 2, s * 0.14, 0, Math.PI * 2);
    g.fill();
    for (let i = 0; i < 8; i++) {
      const a = (i / 8) * Math.PI * 2;
      g.beginPath();
      g.moveTo(s / 2 + Math.cos(a) * s * 0.22, s / 2 + Math.sin(a) * s * 0.22);
      g.lineTo(s / 2 + Math.cos(a) * s * (i % 2 ? 0.3 : 0.37), s / 2 + Math.sin(a) * s * (i % 2 ? 0.3 : 0.37));
      g.stroke();
    }
  },
  ring: (g, s) => {
    g.strokeStyle = '#ffffff';
    g.lineWidth = s * 0.05;
    g.strokeRect(s * 0.12, s * 0.12, s * 0.76, s * 0.76);
  },
  soft: (g, s) => {
    const grd = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
    grd.addColorStop(0, 'rgba(255,255,255,1)');
    grd.addColorStop(0.4, 'rgba(255,255,255,0.45)');
    grd.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = grd;
    g.fillRect(0, 0, s, s);
  },
  shadow: (g, s) => {
    const grd = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
    grd.addColorStop(0, 'rgba(40,20,30,0.55)');
    grd.addColorStop(0.55, 'rgba(40,20,30,0.25)');
    grd.addColorStop(1, 'rgba(40,20,30,0)');
    g.fillStyle = grd;
    g.fillRect(0, 0, s, s);
  },
};

const texCache = new Map<string, CanvasTexture>();

export function glyphTexture(kind: string): CanvasTexture {
  let t = texCache.get(kind);
  if (!t) {
    const s = 256;
    const c = document.createElement('canvas');
    c.width = c.height = s;
    const g = c.getContext('2d')!;
    g.lineCap = 'round';
    g.lineJoin = 'round';
    (painters[kind] ?? painters.ring)(g, s);
    t = new CanvasTexture(c);
    t.colorSpace = SRGBColorSpace;
    t.anisotropy = 4;
    texCache.set(kind, t);
  }
  return t;
}

export const GLYPH_COLORS: Record<string, string> = {
  plate: '#2fa89a',
  eye: '#2fa89a',
  start: '#ffffff',
  goal: '#f2b44f',
  pressed: '#f4c46a',
};

export function glyphMaterial(kind: string): MeshBasicMaterial {
  return new MeshBasicMaterial({
    map: glyphTexture(kind),
    color: new Color(GLYPH_COLORS[kind] ?? '#ffffff'),
    transparent: true,
    opacity: kind === 'start' ? 0.55 : 0.9,
    depthWrite: false,
    polygonOffset: true,
    polygonOffsetFactor: -4,
    polygonOffsetUnits: -4,
  });
}

export function waterMaterial(): ShaderMaterial {
  return new ShaderMaterial({
    uniforms: {
      uTime: atmosphere.uTime,
      uDeep: { value: new Color('#3faea4') },
      uShallow: { value: new Color('#86dccd') },
    },
    vertexShader: `varying vec3 vW; void main(){ vec4 w = modelMatrix * vec4(position,1.0); vW = w.xyz; gl_Position = projectionMatrix * viewMatrix * w; }`,
    fragmentShader: `
      uniform float uTime; uniform vec3 uDeep; uniform vec3 uShallow; varying vec3 vW;
      void main(){
        float r = sin(vW.x*3.1 + uTime*0.9) * sin(vW.z*2.7 - uTime*0.7);
        float band = sin((vW.x - vW.z)*5.0 + uTime*1.3 + r*1.8);
        float lines = smoothstep(0.93, 1.0, band);
        vec3 c = mix(uDeep, uShallow, 0.55 + 0.25*r);
        c += vec3(lines) * 0.18;
        gl_FragColor = vec4(c, 1.0);
        #include <colorspace_fragment>
      }`,
  });
}

export function fallMaterial(): ShaderMaterial {
  return new ShaderMaterial({
    uniforms: {
      uTime: atmosphere.uTime,
      uColor: { value: new Color('#e9fbf6') },
      uTint: { value: new Color('#7fd3c6') },
      uFogColor: atmosphere.uFogColor,
      uFogLow: atmosphere.uFogLow,
      uFogHigh: atmosphere.uFogHigh,
    },
    transparent: true,
    depthWrite: false,
    side: DoubleSide,
    vertexShader: `varying vec2 vUv; varying vec3 vW; void main(){ vUv = uv; vec4 w = modelMatrix * vec4(position,1.0); vW = w.xyz; gl_Position = projectionMatrix * viewMatrix * w; }`,
    fragmentShader: `
      uniform float uTime; uniform vec3 uColor; uniform vec3 uTint; uniform vec3 uFogColor; uniform float uFogLow; uniform float uFogHigh;
      varying vec2 vUv; varying vec3 vW;
      float h(float n){ return fract(sin(n)*43758.5453); }
      void main(){
        float col = floor(vUv.x * 9.0);
        float speed = 1.6 + h(col)*0.8;
        float s = fract(vW.y*0.9 + uTime*speed + h(col*7.0));
        float streak = smoothstep(0.0, 0.25, s) * smoothstep(1.0, 0.55, s);
        float edge = smoothstep(0.0, 0.12, vUv.x) * smoothstep(1.0, 0.88, vUv.x);
        vec3 c = mix(uTint, uColor, streak);
        float a = (0.55 + 0.4*streak) * edge;
        float mist = 1.0 - smoothstep(uFogLow, uFogHigh, vW.y);
        c = mix(c, uFogColor, mist);
        a *= 1.0 - mist*0.85;
        gl_FragColor = vec4(c, a);
        #include <colorspace_fragment>
      }`,
  });
}

/** Cloth banner: sways in the wind from its rod, swallow-tailed, with a pale border and a gold disc. */
export function bannerMaterial(color: string, phase: number): ShaderMaterial {
  return new ShaderMaterial({
    uniforms: {
      uTime: atmosphere.uTime,
      uColor: { value: new Color(color) },
      uTrim: { value: new Color('#fbf1e2') },
      uGold: { value: new Color('#f2c46b') },
      uPhase: { value: phase },
      uFogColor: atmosphere.uFogColor,
      uFogLow: atmosphere.uFogLow,
      uFogHigh: atmosphere.uFogHigh,
    },
    side: DoubleSide,
    vertexShader: `
      uniform float uTime; uniform float uPhase; varying vec2 vUv; varying vec3 vW; varying float vShade;
      void main(){
        vUv = uv;
        vec3 p = position;
        float free = 1.0 - uv.y;
        float wave = sin(uv.y * 5.0 - uTime * 1.6 + uPhase) * 0.07 * free + sin(uv.x * 3.0 + uTime * 2.2 + uPhase) * 0.015 * free;
        p.z += wave;
        vShade = 0.86 + 0.14 * cos(uv.y * 5.0 - uTime * 1.6 + uPhase);
        vec4 w = modelMatrix * vec4(p, 1.0);
        vW = w.xyz;
        gl_Position = projectionMatrix * viewMatrix * w;
      }`,
    fragmentShader: `
      uniform vec3 uColor; uniform vec3 uTrim; uniform vec3 uGold; uniform vec3 uFogColor; uniform float uFogLow; uniform float uFogHigh;
      varying vec2 vUv; varying vec3 vW; varying float vShade;
      void main(){
        float notch = 0.14 * (1.0 - abs(vUv.x - 0.5) * 2.0);
        if (vUv.y < notch) discard;
        vec3 c = uColor;
        float border = step(vUv.x, 0.09) + step(0.91, vUv.x) + step(0.93, vUv.y);
        c = mix(c, uTrim, clamp(border, 0.0, 1.0) * 0.85);
        vec2 q = vec2((vUv.x - 0.5) * 1.0, (vUv.y - 0.62) * 0.35);
        c = mix(c, uGold, smoothstep(0.13, 0.11, length(q)));
        c *= vShade;
        float mist = 1.0 - smoothstep(uFogLow, uFogHigh, vW.y);
        c = mix(c, uFogColor, mist);
        gl_FragColor = vec4(c, 1.0);
        #include <colorspace_fragment>
      }`,
  });
}
