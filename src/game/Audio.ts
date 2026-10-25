// AudioManager: generative ambient music and soft, tonal effects, synthesized with WebAudio.
// Music and effects have independent volume controls.

type MoodName = 'dawn' | 'noon' | 'dusk' | 'radiant';

// Chord progressions per mood as MIDI notes (calm modal harmony).
const PROGRESSIONS: Record<MoodName, number[][]> = {
  dawn: [[50, 57, 62, 66], [47, 54, 59, 62], [43, 50, 55, 59], [45, 52, 57, 61]], // D major-ish
  noon: [[48, 55, 60, 64], [45, 52, 57, 60], [41, 48, 53, 57], [43, 50, 55, 62]], // C / Am / F / G
  dusk: [[46, 53, 58, 62], [43, 50, 55, 58], [39, 46, 51, 55], [41, 48, 53, 57]], // Bb lydian colour
  radiant: [[50, 57, 62, 69], [52, 59, 64, 71], [47, 54, 62, 66], [45, 52, 61, 66]],
};
const SCALES: Record<MoodName, number[]> = {
  dawn: [62, 64, 66, 69, 71, 74, 76, 78, 81],
  noon: [60, 62, 64, 67, 69, 72, 74, 76, 79],
  dusk: [58, 60, 62, 65, 67, 70, 72, 74, 77],
  radiant: [62, 64, 66, 69, 71, 74, 76, 78, 81, 83],
};

const mtof = (m: number) => 440 * Math.pow(2, (m - 69) / 12);

export class AudioManager {
  private ctx: AudioContext | null = null;
  private master!: GainNode;
  private musicBus!: GainNode;
  private sfxBus!: GainNode;
  private reverb!: ConvolverNode;
  private reverbSend!: GainNode;
  private noiseBuf!: AudioBuffer;
  private mood: MoodName = 'dawn';
  private chordIdx = 0;
  private nextChordAt = 0;
  private nextPluckAt = 0;
  private padVoices: { osc: OscillatorNode[]; gain: GainNode }[] = [];
  private grind: { src: AudioBufferSourceNode; gain: GainNode; filt: BiquadFilterNode } | null = null;
  musicVolume = 0.6;
  sfxVolume = 0.8;
  private timer = 0;

  get ready(): boolean {
    return !!this.ctx;
  }

  /** Must be called from a user gesture. */
  start(): void {
    if (this.ctx) {
      void this.ctx.resume();
      return;
    }
    const Ctx = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    const ctx = new Ctx();
    this.ctx = ctx;
    this.master = ctx.createGain();
    this.master.gain.value = 0.9;
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -16;
    comp.ratio.value = 3;
    this.master.connect(comp).connect(ctx.destination);
    this.musicBus = ctx.createGain();
    this.sfxBus = ctx.createGain();
    this.musicBus.connect(this.master);
    this.sfxBus.connect(this.master);
    this.reverb = ctx.createConvolver();
    this.reverb.buffer = this.impulse(3.6, 2.4);
    this.reverbSend = ctx.createGain();
    this.reverbSend.gain.value = 0.9;
    this.reverbSend.connect(this.reverb).connect(this.master);
    this.noiseBuf = this.makeNoise(2);
    this.applyVolumes();
    this.nextChordAt = ctx.currentTime + 0.2;
    this.nextPluckAt = ctx.currentTime + 2.5;
    this.timer = window.setInterval(() => this.tick(), 120);
  }

  setVolumes(music: number, sfx: number): void {
    this.musicVolume = music;
    this.sfxVolume = sfx;
    this.applyVolumes();
  }

  private applyVolumes() {
    if (!this.ctx) return;
    const t = this.ctx.currentTime;
    this.musicBus.gain.setTargetAtTime(this.musicVolume * 0.55, t, 0.3);
    this.sfxBus.gain.setTargetAtTime(this.sfxVolume * 0.9, t, 0.1);
  }

  suspend(on: boolean): void {
    if (!this.ctx) return;
    if (on) void this.ctx.suspend();
    else void this.ctx.resume();
  }

  setMood(m: string): void {
    if (m in PROGRESSIONS && m !== this.mood) {
      this.mood = m as MoodName;
      this.chordIdx = 0;
      if (this.ctx) this.nextChordAt = Math.min(this.nextChordAt, this.ctx.currentTime + 1.5);
    }
  }

  private impulse(seconds: number, decay: number): AudioBuffer {
    const ctx = this.ctx!;
    const len = Math.floor(ctx.sampleRate * seconds);
    const buf = ctx.createBuffer(2, len, ctx.sampleRate);
    for (let c = 0; c < 2; c++) {
      const d = buf.getChannelData(c);
      for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, decay);
    }
    return buf;
  }

  private makeNoise(seconds: number): AudioBuffer {
    const ctx = this.ctx!;
    const len = Math.floor(ctx.sampleRate * seconds);
    const buf = ctx.createBuffer(1, len, ctx.sampleRate);
    const d = buf.getChannelData(0);
    let b = 0;
    for (let i = 0; i < len; i++) {
      b = 0.97 * b + 0.03 * (Math.random() * 2 - 1); // brownish noise
      d[i] = b * 6;
    }
    return buf;
  }

  // ───────────── music ─────────────

  private tick() {
    const ctx = this.ctx;
    if (!ctx || ctx.state !== 'running') return;
    const now = ctx.currentTime;
    if (now >= this.nextChordAt - 0.05) {
      const prog = PROGRESSIONS[this.mood];
      this.playChord(prog[this.chordIdx % prog.length], this.nextChordAt, 11);
      this.chordIdx++;
      this.nextChordAt += 9;
    }
    if (now >= this.nextPluckAt) {
      const sc = SCALES[this.mood];
      const n = sc[Math.floor(Math.random() * sc.length)];
      this.pluck(mtof(n), now + 0.02, 0.07 + Math.random() * 0.05, this.musicBus);
      if (Math.random() < 0.35) this.pluck(mtof(n + (Math.random() < 0.5 ? 7 : 12)), now + 0.42, 0.04, this.musicBus);
      this.nextPluckAt = now + 2.2 + Math.random() * 4.5;
    }
  }

  private playChord(notes: number[], at: number, dur: number) {
    const ctx = this.ctx!;
    const gain = ctx.createGain();
    gain.gain.setValueAtTime(0, at);
    gain.gain.linearRampToValueAtTime(0.11, at + 3.5);
    gain.gain.setValueAtTime(0.11, at + dur - 4);
    gain.gain.linearRampToValueAtTime(0, at + dur);
    const filt = ctx.createBiquadFilter();
    filt.type = 'lowpass';
    filt.frequency.setValueAtTime(700, at);
    filt.frequency.linearRampToValueAtTime(1500, at + dur / 2);
    filt.frequency.linearRampToValueAtTime(600, at + dur);
    filt.Q.value = 0.4;
    gain.connect(filt);
    filt.connect(this.musicBus);
    const send = ctx.createGain();
    send.gain.value = 0.5;
    filt.connect(send).connect(this.reverbSend);
    const osc: OscillatorNode[] = [];
    notes.forEach((n, i) => {
      for (const det of [-6, 6]) {
        const o = ctx.createOscillator();
        o.type = i === 0 ? 'sine' : 'triangle';
        o.frequency.value = mtof(n);
        o.detune.value = det + (Math.random() - 0.5) * 3;
        const g = ctx.createGain();
        g.gain.value = i === 0 ? 0.5 : 0.22;
        o.connect(g).connect(gain);
        o.start(at);
        o.stop(at + dur + 0.1);
        osc.push(o);
      }
    });
    this.padVoices.push({ osc, gain });
    if (this.padVoices.length > 4) this.padVoices.shift();
  }

  private pluck(freq: number, at: number, vol: number, bus: AudioNode, decay = 2.6, type: OscillatorType = 'sine') {
    const ctx = this.ctx!;
    const o = ctx.createOscillator();
    o.type = type;
    o.frequency.value = freq;
    const o2 = ctx.createOscillator();
    o2.type = 'sine';
    o2.frequency.value = freq * 2.01;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, at);
    g.gain.linearRampToValueAtTime(vol, at + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, at + decay);
    const g2 = ctx.createGain();
    g2.gain.value = 0.25;
    o.connect(g);
    o2.connect(g2).connect(g);
    g.connect(bus);
    const send = ctx.createGain();
    send.gain.value = 0.7;
    g.connect(send).connect(this.reverbSend);
    o.start(at);
    o2.start(at);
    o.stop(at + decay + 0.05);
    o2.stop(at + decay + 0.05);
  }

  // ───────────── effects ─────────────

  private noiseHit(at: number, dur: number, freq: number, vol: number, q = 1, type: BiquadFilterType = 'lowpass') {
    const ctx = this.ctx!;
    const src = ctx.createBufferSource();
    src.buffer = this.noiseBuf;
    const f = ctx.createBiquadFilter();
    f.type = type;
    f.frequency.value = freq;
    f.Q.value = q;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0, at);
    g.gain.linearRampToValueAtTime(vol, at + Math.min(0.05, dur * 0.2));
    g.gain.exponentialRampToValueAtTime(0.0001, at + dur);
    src.connect(f).connect(g).connect(this.sfxBus);
    src.start(at, Math.random());
    src.stop(at + dur + 0.05);
  }

  private get t(): number {
    return this.ctx ? this.ctx.currentTime : 0;
  }

  private scaleNote(i: number): number {
    const sc = SCALES[this.mood];
    return sc[((i % sc.length) + sc.length) % sc.length] + 12 * Math.floor(i / sc.length);
  }

  tap(): void {
    if (!this.ctx) return;
    this.pluck(mtof(this.scaleNote(4) + 12), this.t, 0.05, this.sfxBus, 0.6);
  }

  nope(): void {
    if (!this.ctx) return;
    this.pluck(mtof(this.scaleNote(0) - 12), this.t, 0.06, this.sfxBus, 0.5, 'triangle');
    this.noiseHit(this.t, 0.15, 300, 0.05);
  }

  step(i: number): void {
    if (!this.ctx) return;
    this.noiseHit(this.t, 0.07, 900 + (i % 2) * 300, 0.035, 0.7, 'bandpass');
  }

  /** Continuous stone grind while architecture moves; intensity 0..1. */
  grindLevel(v: number): void {
    if (!this.ctx) return;
    if (!this.grind && v > 0.01) {
      const src = this.ctx.createBufferSource();
      src.buffer = this.noiseBuf;
      src.loop = true;
      const filt = this.ctx.createBiquadFilter();
      filt.type = 'lowpass';
      filt.frequency.value = 220;
      filt.Q.value = 2;
      const gain = this.ctx.createGain();
      gain.gain.value = 0;
      src.connect(filt).connect(gain).connect(this.sfxBus);
      src.start();
      this.grind = { src, gain, filt };
    }
    if (this.grind) {
      const t = this.t;
      this.grind.gain.gain.setTargetAtTime(Math.min(0.32, v * 0.32), t, 0.05);
      this.grind.filt.frequency.setTargetAtTime(160 + v * 260, t, 0.08);
    }
  }

  /** Tonal click whenever a mechanism passes a detent. */
  detent(i: number): void {
    if (!this.ctx) return;
    this.pluck(mtof(this.scaleNote(i + 2)), this.t, 0.07, this.sfxBus, 1.6);
  }

  snap(): void {
    if (!this.ctx) return;
    this.noiseHit(this.t, 0.25, 180, 0.22, 1);
    this.pluck(mtof(this.scaleNote(0) - 12), this.t, 0.07, this.sfxBus, 1.2);
  }

  plate(): void {
    if (!this.ctx) return;
    const t = this.t;
    this.pluck(mtof(this.scaleNote(0) - 12), t, 0.12, this.sfxBus, 3.5);
    this.pluck(mtof(this.scaleNote(2)), t + 0.12, 0.06, this.sfxBus, 2.5);
    this.pluck(mtof(this.scaleNote(4)), t + 0.24, 0.05, this.sfxBus, 2.5);
  }

  rumble(dur = 1.6): void {
    if (!this.ctx) return;
    this.noiseHit(this.t, dur, 120, 0.35, 1.5);
  }

  /** A connection formed (physical or perspective). */
  connect(seam: boolean): void {
    if (!this.ctx) return;
    const t = this.t;
    const base = seam ? 5 : 3;
    for (let i = 0; i < (seam ? 4 : 2); i++) this.pluck(mtof(this.scaleNote(base + i * 2) + (seam ? 12 : 0)), t + i * 0.09, 0.05, this.sfxBus, 2.4);
  }

  worldTurn(): void {
    if (!this.ctx) return;
    const t = this.t;
    this.noiseHit(t, 1.3, 140, 0.18, 0.8);
    this.pluck(mtof(this.scaleNote(0) - 12), t, 0.08, this.sfxBus, 3);
    this.pluck(mtof(this.scaleNote(4) - 12), t + 0.5, 0.06, this.sfxBus, 3);
  }

  awaken(): void {
    if (!this.ctx) return;
    const t = this.t;
    [0, 2, 4, 7, 9].forEach((d, i) => this.pluck(mtof(this.scaleNote(d)), t + i * 0.16, 0.06, this.sfxBus, 4));
    this.noiseHit(t, 2.5, 2500, 0.05, 0.5, 'bandpass');
  }

  chapter(): void {
    if (!this.ctx) return;
    const t = this.t;
    this.pluck(mtof(this.scaleNote(0)), t, 0.05, this.sfxBus, 4);
    this.pluck(mtof(this.scaleNote(4)), t + 0.3, 0.04, this.sfxBus, 4);
  }

  finale(): void {
    if (!this.ctx) return;
    const t = this.t;
    this.setMood('radiant');
    [0, 2, 4, 7, 9, 11, 14].forEach((d, i) => this.pluck(mtof(this.scaleNote(d)), t + i * 0.22, 0.07, this.sfxBus, 5));
    this.playChord(PROGRESSIONS.radiant[0], t + 0.1, 14);
  }

  dispose(): void {
    window.clearInterval(this.timer);
    void this.ctx?.close();
  }
}
