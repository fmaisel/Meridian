// UIManager: title screen, pause, settings, chapter cards, whispers and the ending. DOM only.

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

export interface UIHandlers {
  begin(): void;
  continueGame(): void;
  pause(on: boolean): void;
  hint(): void;
  restart(): void;
  toTitle(): void;
  again(): void;
  turn(dir: 1 | -1): void;
  settingsChanged(s: Settings): void;
}

export interface Settings {
  music: number;
  sfx: number;
  shadows: boolean;
  turnButtons: boolean;
}

export class UIManager {
  private hintTimer = 0;
  private chapterTimer = 0;
  private settingsReturn: 'title' | 'pause' = 'title';
  private confirmAction: (() => void) | null = null;
  settings: Settings;

  constructor(h: UIHandlers, initial: Settings) {
    this.settings = { ...initial };
    $('btn-begin').onclick = () => h.begin();
    $('btn-continue').onclick = () => h.continueGame();
    $('btn-pause').onclick = () => h.pause(true);
    $('btn-resume').onclick = () => h.pause(false);
    $('btn-hint').onclick = () => { h.pause(false); h.hint(); };
    $('btn-restart').onclick = () => this.confirm('Start the journey again?', () => h.restart());
    $('btn-totitle').onclick = () => h.toTitle();
    $('btn-again').onclick = () => h.again();
    $('btn-turn-left').onclick = () => h.turn(-1);
    $('btn-turn-right').onclick = () => h.turn(1);
    $('btn-settings').onclick = () => this.openSettings('pause');
    $('btn-settings-title').onclick = () => this.openSettings('title');
    $('btn-settings-back').onclick = () => this.closeSettings();
    $('btn-confirm-yes').onclick = () => { this.show('confirm', false); const a = this.confirmAction; this.confirmAction = null; a?.(); };
    $('btn-confirm-no').onclick = () => { this.show('confirm', false); this.show('pause', true); };

    const music = $<HTMLInputElement>('vol-music');
    const sfx = $<HTMLInputElement>('vol-sfx');
    const shadows = $<HTMLInputElement>('opt-shadows');
    const turnBtn = $<HTMLInputElement>('opt-turnbtn');
    music.value = String(this.settings.music);
    sfx.value = String(this.settings.sfx);
    shadows.checked = this.settings.shadows;
    turnBtn.checked = this.settings.turnButtons;
    const emit = () => {
      this.settings = { music: +music.value, sfx: +sfx.value, shadows: shadows.checked, turnButtons: turnBtn.checked };
      h.settingsChanged(this.settings);
    };
    music.oninput = sfx.oninput = shadows.onchange = turnBtn.onchange = emit;
  }

  private show(id: string, on: boolean) {
    $(id).hidden = !on;
  }

  fadeIn(): void {
    setTimeout(() => $('fade').classList.add('clear'), 40);
  }

  async fadeOut(): Promise<void> {
    $('fade').classList.remove('clear');
    await new Promise((r) => setTimeout(r, 1500));
  }

  showTitle(hasSave: boolean): void {
    const t = $('title');
    t.hidden = false;
    t.classList.remove('fading');
    $('btn-continue').hidden = !hasSave;
    $('btn-begin').textContent = hasSave ? 'New journey' : 'Begin';
    this.show('hud', false);
  }

  hideTitle(): void {
    const t = $('title');
    t.classList.add('fading');
    setTimeout(() => { t.hidden = true; }, 1200);
    this.show('hud', true);
  }

  get titleVisible(): boolean {
    return !$('title').hidden && !$('title').classList.contains('fading');
  }

  setPause(on: boolean): void {
    this.show('pause', on);
    if (!on) { this.show('settings', false); this.show('confirm', false); }
  }

  get paused(): boolean {
    return !$('pause').hidden || !$('settings').hidden || !$('confirm').hidden;
  }

  private openSettings(from: 'title' | 'pause') {
    this.settingsReturn = from;
    this.show('pause', false);
    this.show('settings', true);
  }

  private closeSettings() {
    this.show('settings', false);
    if (this.settingsReturn === 'pause') this.show('pause', true);
  }

  private confirm(text: string, action: () => void) {
    $('confirm-text').textContent = text;
    this.confirmAction = action;
    this.show('pause', false);
    this.show('confirm', true);
  }

  chapter(title: string): void {
    const [num, ...rest] = title.split('·');
    const el = $('chapter');
    (el.querySelector('.num') as HTMLElement).textContent = num.trim();
    (el.querySelector('.name') as HTMLElement).textContent = rest.join('·').trim();
    el.classList.add('show');
    clearTimeout(this.chapterTimer);
    this.chapterTimer = window.setTimeout(() => el.classList.remove('show'), 4200);
  }

  whisper(text: string, seconds = 6): void {
    const el = $('hint');
    el.textContent = text;
    el.classList.add('show');
    clearTimeout(this.hintTimer);
    this.hintTimer = window.setTimeout(() => el.classList.remove('show'), seconds * 1000);
  }

  turnTutorial(on: boolean): void {
    const el = $('turn-hint');
    if (on) {
      el.hidden = false;
      setTimeout(() => el.classList.add('show'), 30);
    } else {
      el.classList.remove('show');
      setTimeout(() => { el.hidden = true; }, 1400);
    }
  }

  hud(on: boolean): void {
    this.show('hud', on);
  }

  turnButtons(on: boolean): void {
    this.show('turn-buttons', on);
  }

  showEnding(on: boolean): void {
    const el = $('ending');
    el.hidden = !on;
    this.show('hud', !on);
  }

  debugText(text: string | null): void {
    const el = $('debug-panel');
    el.hidden = text === null;
    if (text !== null) el.textContent = text;
  }
}
