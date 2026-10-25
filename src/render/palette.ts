// Controlled palette: a few dominant colour families. Architecture palettes are fixed per area;
// moods (sky, mist, light) blend as the camera ascends.
import { Color } from 'three';

export type MatKey =
  | 'stone' | 'accent' | 'trim' | 'cap' | 'roof' | 'roofCoral' | 'roofViolet' | 'foliage' | 'gate'
  | 'window' | 'handle' | 'handlePin' | 'gold';

export const PALETTES: Record<string, Partial<Record<MatKey | 'lily' | 'flower', string>>> = {
  lily: { stone: '#86c39c', lily: '#86c39c', flower: '#f4a9bb' },
  sand: {
    stone: '#e9cf9f', accent: '#dcb17c', trim: '#f3e2c0', cap: '#f8edd5', roof: '#6d9ea6', roofCoral: '#e27c63',
    foliage: '#ec8a33', gate: '#c7785a', window: '#9a6f55',
  },
  coral: {
    stone: '#ea7f69', accent: '#f2b48f', trim: '#f6d7c2', cap: '#f8c3a8', roof: '#6d9ea6', roofCoral: '#c9584a',
    foliage: '#e07a3c', gate: '#f3e3cf', window: '#a2473f',
  },
  ivory: {
    stone: '#f1e7d7', accent: '#e8a491', trim: '#e79d8b', cap: '#fbf5ea', roof: '#e78c9e', roofCoral: '#e78c9e',
    foliage: '#ef9a52', gate: '#d9897a', window: '#b98d7c',
  },
  dusk: {
    stone: '#f5dbe3', accent: '#a690dd', trim: '#fdf2f5', cap: '#fdeff4', roof: '#9b84d6', roofCoral: '#e8879c',
    roofViolet: '#8f78cf', foliage: '#f0a1b8', gate: '#8f78cf', window: '#9a7fb8',
  },
};

const COMMON: Partial<Record<MatKey, string>> = {
  handle: '#fbf3e4', handlePin: '#e9735c', gold: '#f2c46b', roofViolet: '#8f78cf',
};

export function paletteColor(palette: string, key: string): string {
  const p = PALETTES[palette] ?? PALETTES.sand;
  return (p as Record<string, string>)[key] ?? (COMMON as Record<string, string>)[key] ?? p.stone!;
}

export interface Mood {
  skyTop: Color;
  skyBottom: Color;
  fog: Color;
  sun: Color;
  hemiSky: Color;
  hemiGround: Color;
  glow: Color;
}

const mk = (o: Record<keyof Mood, string>): Mood =>
  Object.fromEntries(Object.entries(o).map(([k, v]) => [k, new Color(v)])) as unknown as Mood;

export const MOODS: Record<string, Mood> = {
  dawn: mk({ skyTop: '#bfe4da', skyBottom: '#f7eedb', fog: '#eef0de', sun: '#fff1dc', hemiSky: '#fff8ee', hemiGround: '#d9e6d8', glow: '#fff6dc' }),
  noon: mk({ skyTop: '#9fd2c4', skyBottom: '#eef2e3', fog: '#dfeee4', sun: '#fff1e2', hemiSky: '#fff6ee', hemiGround: '#d3e6da', glow: '#fdf6e6' }),
  dusk: mk({ skyTop: '#9a88d2', skyBottom: '#f5dbe3', fog: '#ecd5e3', sun: '#fff0e6', hemiSky: '#fff1f6', hemiGround: '#dccbe8', glow: '#ffe6ee' }),
  radiant: mk({ skyTop: '#f6d39a', skyBottom: '#fff4e2', fog: '#fff0dc', sun: '#fff6e8', hemiSky: '#fffaf0', hemiGround: '#f7e1c6', glow: '#fff3d6' }),
};

export function blendMood(a: Mood, b: Mood, t: number, out: Mood): Mood {
  for (const k of Object.keys(a) as (keyof Mood)[]) out[k].copy(a[k]).lerp(b[k], t);
  return out;
}

export function cloneMood(m: Mood): Mood {
  return Object.fromEntries(Object.entries(m).map(([k, v]) => [k, (v as Color).clone()])) as unknown as Mood;
}
