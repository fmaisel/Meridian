import {
  Vector3, CanvasTexture, Color, DoubleSide, MeshBasicMaterial, MeshLambertMaterial, RepeatWrapping, SRGBColorSpace,
  type Material, type Texture,
} from 'three';
import { paletteColor } from './palette';

/** Uniforms shared by every architectural material (atmosphere). */
export const atmosphere = {
  uFogColor: { value: new Color('#eef0de') },
  uFogLow: { value: -12.5 },
  uFogHigh: { value: -2.5 },
  uTime: { value: 0 },
  /** Cutaway windows: screen position (device px, origin bottom-left) and radius per focus. */
  uFoci: { value: Array.from({ length: 6 }, () => new Vector3()) },
  uFociN: { value: 0 },
  uRimColor: { value: new Color('#fff4dc') },
  /** Aerial perspective: what lies far behind the focus (along the view) dissolves into the sky. */
  uFocus: { value: new Vector3() },
  uViewDir: { value: new Vector3(1, 1, 1).normalize() },
};

export interface LitOpts {
  map?: Texture;
  flat?: boolean;
  transparent?: boolean;
  opacity?: number;
  side?: typeof DoubleSide;
  emissive?: string;
}

/**
 * Lambert material with height mist: every fragment below the monument dissolves into the sky colour,
 * plus an optional per-vertex mist attribute (`aMist`, 0 = clear, 1 = fully dissolved) used to fade
 * supports into the void. `uGlow` lifts the colour for interaction feedback.
 */
export function lit(color: string | Color, o: LitOpts = {}): MeshLambertMaterial {
  const m = new MeshLambertMaterial({
    color,
    map: o.map ?? null,
    flatShading: o.flat ?? false,
    transparent: o.transparent ?? false,
    opacity: o.opacity ?? 1,
  });
  if (o.side !== undefined) m.side = o.side;
  if (o.emissive) m.emissive = new Color(o.emissive);
  const glow = { value: 0 };
  const glowColor = { value: new Color('#fff7e8') };
  const cut = { value: 0 };
  m.userData.glow = glow;
  m.userData.glowColor = glowColor;
  m.userData.cut = cut;
  m.onBeforeCompile = (shader) => {
    shader.uniforms.uFogColor = atmosphere.uFogColor;
    shader.uniforms.uFogLow = atmosphere.uFogLow;
    shader.uniforms.uFogHigh = atmosphere.uFogHigh;
    shader.uniforms.uGlow = glow;
    shader.uniforms.uGlowColor = glowColor;
    shader.uniforms.uCut = cut;
    shader.uniforms.uFoci = atmosphere.uFoci;
    shader.uniforms.uFociN = atmosphere.uFociN;
    shader.uniforms.uRimColor = atmosphere.uRimColor;
    shader.uniforms.uFocus = atmosphere.uFocus;
    shader.uniforms.uViewDir = atmosphere.uViewDir;
    shader.vertexShader = shader.vertexShader
      .replace('#include <common>', '#include <common>\nattribute float aMist;\nvarying float vMist;\nvarying vec3 vWPos;')
      .replace(
        '#include <project_vertex>',
        '#include <project_vertex>\nvMist = aMist;\nvWPos = (modelMatrix * vec4(transformed, 1.0)).xyz;',
      );
    shader.fragmentShader = shader.fragmentShader
      .replace(
        '#include <common>',
        '#include <common>\nuniform vec3 uFogColor;\nuniform float uFogLow;\nuniform float uFogHigh;\nuniform float uGlow;\nuniform vec3 uGlowColor;\nuniform float uCut;\nuniform vec3 uFoci[6];\nuniform int uFociN;\nuniform vec3 uRimColor;\nuniform vec3 uFocus;\nuniform vec3 uViewDir;\nvarying float vMist;\nvarying vec3 vWPos;',
      )
      .replace(
        '#include <dithering_fragment>',
        `gl_FragColor.rgb = mix(gl_FragColor.rgb, uGlowColor, uGlow);
         // gentle tonal grading: the monument warms and brightens as it rises
         gl_FragColor.rgb *= mix(0.955, 1.03, smoothstep(-4.0, 22.0, vWPos.y));
         float behind = dot(uFocus - vWPos, uViewDir);
         float aerial = smoothstep(5.0, 30.0, behind) * (0.42 + 0.58 * vMist);
         float mist = max(max(vMist * 0.6, aerial), 1.0 - smoothstep(uFogLow, uFogHigh, vWPos.y));
         gl_FragColor.rgb = mix(gl_FragColor.rgb, uFogColor, mist * mist * (3.0 - 2.0 * mist));
         // cutaway: a soft round window opens where this body hides what matters
         if (uCut > 0.001) {
           float m = 1.0;
           float grain = fract(sin(dot(floor(gl_FragCoord.xy * 0.5), vec2(12.9898, 78.233))) * 43758.5453) - 0.5;
           for (int i = 0; i < 6; i++) {
             if (i >= uFociN) break;
             vec3 f = uFoci[i];
             float r = f.z * (0.55 + 0.45 * uCut);
             float d = distance(gl_FragCoord.xy, f.xy) + grain * r * 0.05;
             m = min(m, smoothstep(r * 0.5, r, d));
           }
           float rim = smoothstep(0.0, 0.5, m) * smoothstep(1.0, 0.5, m);
           gl_FragColor.rgb = mix(gl_FragColor.rgb, uRimColor, rim * 0.35 * uCut);
           float a = mix(1.0, m, uCut);
           if (a < 0.03) discard;
           gl_FragColor.a *= a;
         }
         #include <dithering_fragment>`,
      );
  };
  m.customProgramCacheKey = () => 'lit-mist-v3';
  return m;
}

/** Subtle tile pattern for walkable caps (one cell per texture repeat). */
function makeTileTexture(): CanvasTexture {
  const s = 128;
  const c = document.createElement('canvas');
  c.width = c.height = s;
  const g = c.getContext('2d')!;
  g.fillStyle = '#ffffff';
  g.fillRect(0, 0, s, s);
  // soft inset border
  g.strokeStyle = 'rgba(120, 90, 70, 0.10)';
  g.lineWidth = 3;
  g.strokeRect(1.5, 1.5, s - 3, s - 3);
  g.strokeStyle = 'rgba(255,255,255,0.6)';
  g.lineWidth = 2;
  g.strokeRect(6, 6, s - 12, s - 12);
  // faint centre square
  g.fillStyle = 'rgba(120, 90, 70, 0.035)';
  g.fillRect(22, 22, s - 44, s - 44);
  const t = new CanvasTexture(c);
  t.wrapS = t.wrapT = RepeatWrapping;
  t.colorSpace = SRGBColorSpace;
  t.anisotropy = 4;
  return t;
}

export class MaterialLibrary {
  private cache = new Map<string, Material>();
  private tileTex: CanvasTexture | null = null;

  get(palette: string, key: string): MeshLambertMaterial {
    const k = `${palette}:${key}`;
    let m = this.cache.get(k) as MeshLambertMaterial | undefined;
    if (!m) {
      const flat = key === 'foliage';
      m = lit(paletteColor(palette, key), { flat });
      this.cache.set(k, m);
    }
    return m;
  }

  cap(palette: string, key = 'cap'): MeshLambertMaterial {
    const k = `${palette}:cap:${key}`;
    let m = this.cache.get(k) as MeshLambertMaterial | undefined;
    if (!m) {
      this.tileTex ??= makeTileTexture();
      m = lit(paletteColor(palette, key), { map: this.tileTex });
      this.cache.set(k, m);
    }
    return m;
  }

  /** Material owned by one body (so the body can fade on its own when it hides the action). */
  forBody(body: string, palette: string, key: string, cap = false): MeshLambertMaterial {
    const k = `body:${body}:${palette}:${key}:${cap}`;
    let m = this.cache.get(k) as MeshLambertMaterial | undefined;
    if (!m) {
      if (cap) {
        this.tileTex ??= makeTileTexture();
        m = lit(paletteColor(palette, key), { map: this.tileTex });
      } else m = lit(paletteColor(palette, key), { flat: key === 'foliage' });
      this.cache.set(k, m);
    }
    return m;
  }

  /** A unique material instance (for handles that glow individually). */
  unique(palette: string, key: string): MeshLambertMaterial {
    return lit(paletteColor(palette, key));
  }

  basic(key: string, make: () => MeshBasicMaterial): MeshBasicMaterial {
    let m = this.cache.get(`basic:${key}`) as MeshBasicMaterial | undefined;
    if (!m) {
      m = make();
      this.cache.set(`basic:${key}`, m);
    }
    return m;
  }
}
