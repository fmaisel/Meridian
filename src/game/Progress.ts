// ProgressManager: persists the level state (mechanisms, flags, camera, position) in localStorage.
import type { PuzzleState } from '../logic/types';
import type { Settings } from './UI';

const KEY = 'meridian.save.v1';
const SETTINGS_KEY = 'meridian.settings.v1';

export interface SaveData {
  version: 1;
  state: PuzzleState;
  charNode: string;
  seenZones: string[];
  mechParams?: Record<string, number>;
  done?: boolean;
}

function safe<T>(f: () => T, fallback: T): T {
  try {
    return f();
  } catch {
    return fallback;
  }
}

export const Progress = {
  load(): SaveData | null {
    return safe(() => {
      const raw = localStorage.getItem(KEY);
      if (!raw) return null;
      const d = JSON.parse(raw) as SaveData;
      return d.version === 1 ? d : null;
    }, null);
  },
  save(d: SaveData): void {
    safe(() => localStorage.setItem(KEY, JSON.stringify(d)), undefined);
  },
  clear(): void {
    safe(() => localStorage.removeItem(KEY), undefined);
  },
  loadSettings(): Settings {
    const def: Settings = { music: 0.6, sfx: 0.8, shadows: true, turnButtons: false };
    return safe(() => ({ ...def, ...JSON.parse(localStorage.getItem(SETTINGS_KEY) ?? '{}') }), def);
  },
  saveSettings(s: Settings): void {
    safe(() => localStorage.setItem(SETTINGS_KEY, JSON.stringify(s)), undefined);
  },
};
