// WebAudio reference render of the AudioCheck scripted session, using the ORIGINAL src/game/Audio.ts
// (types stripped, otherwise unmodified) inside an OfflineAudioContext. Math.random is replaced by the
// same xorshift128+ generator (seed 12345) that the native harness uses, and the 120 ms tick and the
// script events are fired at exactly the same render-quantum frames as in the native harness, so both
// renders consume random numbers in the same order and can be compared sample by sample.
(async function () {
  const log = (...a) => console.log('[ref] ' + a.join(' '));
  try {
    const sr = 48000, duration = 60, total = sr * duration;
    // --- RNG identical to SynthRNG ---
    const M = (1n << 64n) - 1n;
    const st = { x: 12345n };
    const splitmix = () => {
      st.x = (st.x + 0x9E3779B97F4A7C15n) & M;
      let z = st.x;
      z = ((z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n) & M;
      z = ((z ^ (z >> 27n)) * 0x94D049BB133111EBn) & M;
      return z ^ (z >> 31n);
    };
    let s0 = splitmix(), s1 = splitmix();
    Math.random = () => {
      let a = s0; const b = s1; s0 = b;
      a ^= (a << 23n) & M;
      s1 = a ^ b ^ (a >> 17n) ^ (b >> 26n);
      return Number(((s1 + b) & M) >> 11n) * 2 ** -53;
    };
    // --- context shims ---
    const ctx = new OfflineAudioContext(2, total, sr);
    Object.defineProperty(ctx, 'state', { get: () => 'running' }); // tick() runs inside suspend handlers
    window.AudioContext = function () { return ctx; };
    window.setInterval = () => 1;
    window.clearInterval = () => {};
    const mgr = new AudioManager();
    mgr.start();

    // --- script (mirror of main.swift) ---
    const ev = [];
    const at = (t, run) => ev.push({ t, run });
    at(1.0, m => m.tap()); at(1.5, m => m.tap()); at(2.0, m => m.nope());
    for (let i = 0; i < 8; i++) at(3.0 + i * 0.3, m => m.step(i));
    for (let k = 0; k <= 180; k++) { const v = k <= 90 ? k / 90 : (180 - k) / 90; at(5.0 + k / 60, m => m.grindLevel(v)); }
    for (let i = 0; i < 7; i++) at(5.2 + i * 0.4, m => m.detent(i));
    at(8.2, m => m.snap()); at(10.0, m => m.setMood('noon')); at(11.0, m => m.plate()); at(13.0, m => m.rumble(1.6));
    at(15.0, m => m.connect(false)); at(16.0, m => m.connect(true)); at(20.0, m => m.setMood('dusk'));
    at(21.0, m => m.worldTurn()); at(24.0, m => m.awaken()); at(28.0, m => m.chapter());
    at(30.0, m => m.setVolumes(0.3, 0.5)); at(33.0, m => m.setVolumes(0.6, 0.8)); at(35.0, m => m.setMood('radiant'));
    for (let k = 0; k <= 180; k++) { const v = k <= 60 ? k / 60 : (k <= 120 ? 1.0 : (180 - k) / 60); at(36.0 + k / 60, m => m.grindLevel(v)); }
    for (let i = 0; i < 10; i++) at(36.1 + i * 0.28, m => m.detent(-3 + i));
    at(40.0, m => m.rumble(2.5)); at(42.0, m => m.setMood('dawn')); at(45.0, m => m.finale());
    ev.sort((a, b) => a.t - b.t); // stable, like Swift's sort for equal keys in practice

    // --- schedule: same quantum frames as the native core ---
    const inv = 1 / sr;
    let nextTickAt = 0.12, next = 0, plans = 0, mismatches = 0;
    for (let f = 0; f < total; f += 128) {
      const now = f * inv;
      const actions = [];
      if (f % 512 === 0) { const tNow = f / sr; while (next < ev.length && ev[next].t <= tNow) actions.push(ev[next++]); }
      let tick = false;
      if (now >= nextTickAt) { tick = true; nextTickAt += 0.12; if (nextTickAt <= now) nextTickAt = now + 0.12; }
      if (!actions.length && !tick) continue;
      plans++;
      ctx.suspend(f / sr).then(() => {
        if (Math.round(ctx.currentTime * sr) !== f) mismatches++;
        for (const a of actions) a.run(mgr);
        if (tick) mgr.tick();
        ctx.resume();
      });
    }
    const t0 = performance.now();
    const buf = await ctx.startRendering();
    log('rendered', duration, 's in', ((performance.now() - t0) / 1000).toFixed(2), 's; suspends', plans, 'frame mismatches', mismatches);
    const L = buf.getChannelData(0), R = buf.getChannelData(1);

    // --- native output ---
    const nat = await new Promise((res, rej) => {
      const x = new XMLHttpRequest();
      x.open('GET', NATIVE_URL); x.responseType = 'arraybuffer';
      x.onload = () => res(new Float32Array(x.response)); x.onerror = rej; x.send();
    });
    const db = v => v <= 0 ? '  -inf' : (20 * Math.log10(v)).toFixed(1).padStart(6);
    log('native samples', nat.length / 2);
    log('segment     ref peak  ref RMS | nat peak  nat RMS | diff RMS (dB rel ref)');
    let allD = 0, allR = 0;
    for (let s = 0; s < duration; s += 5) {
      let pr = 0, sr2 = 0, pn = 0, sn = 0, sd = 0;
      for (let i = s * sr; i < (s + 5) * sr; i++) {
        const l = L[i], r = R[i], nl = nat[2 * i], nr = nat[2 * i + 1];
        pr = Math.max(pr, Math.abs(l), Math.abs(r)); sr2 += l * l + r * r;
        pn = Math.max(pn, Math.abs(nl), Math.abs(nr)); sn += nl * nl + nr * nr;
        sd += (l - nl) ** 2 + (r - nr) ** 2;
      }
      allD += sd; allR += sr2;
      const n = 2 * 5 * sr;
      log(`${String(s).padStart(2)}-${String(s + 5).padStart(2)} s  ${db(pr)}   ${db(Math.sqrt(sr2 / n))} | ${db(pn)}   ${db(Math.sqrt(sn / n))} | ${db(Math.sqrt(sd / n))} (${(10 * Math.log10(sd / sr2)).toFixed(1)} dB)`);
    }
    log('total diff energy rel. reference:', (10 * Math.log10(allD / allR)).toFixed(1), 'dB');
    log('DONE');
  } catch (e) {
    log('ERROR', e && e.stack || e);
    log('DONE');
  }
})();
