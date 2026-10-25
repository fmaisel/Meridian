// Game: orchestrates rendering, puzzle state, navigation, character, input, UI, audio and progress.
import {
  MeshBasicMaterial, Clock, Matrix4, PCFSoftShadowMap, Raycaster, Scene, SRGBColorSpace, Vector3, WebGLRenderer, NoToneMapping,
  type Object3D,
} from 'three';
import { Animator, clamp, damp, ease } from '../core/anim';
import { buildLevel } from '../level/level';
import { LevelLogic, findPath, reachable, type NavGraph, type WorldBox } from '../logic/LevelLogic';
import { Puzzle, type OperateBlock, type PlateEffect } from '../logic/Puzzle';
import { solve, type Action } from '../logic/solver';
import type { MechDef, ZoneDef } from '../logic/types';
import { CameraRig } from '../render/CameraRig';
import { CharacterView } from '../render/Character';
import { Effects } from '../render/Effects';
import { Environment } from '../render/Environment';
import { LevelView, type HandleView } from '../render/LevelView';
import { atmosphere, MaterialLibrary } from '../render/materials';
import { AudioManager } from './Audio';
import { CharacterController } from './CharacterController';
import { DebugTools } from './Debug';
import { Interaction } from './Interaction';
import { Progress } from './Progress';
import { UIManager, type Settings } from './UI';
import { runFinale } from './Finale';

type Mode = 'title' | 'play' | 'ending';

const BLOCK_WHISPER: Partial<Record<OperateBlock, string>> = {
  locked: 'It will not move yet.',
  occupied: 'Not while you stand upon it.',
  strands: 'That would leave you nowhere to stand.',
};

export class Game {
  readonly renderer: WebGLRenderer;
  readonly scene = new Scene();
  readonly logic: LevelLogic;
  puzzle: Puzzle;
  readonly view: LevelView;
  readonly env: Environment;
  readonly rig = new CameraRig();
  readonly charView = new CharacterView();
  char: CharacterController;
  readonly anim = new Animator();
  readonly effects: Effects;
  readonly audio = new AudioManager();
  readonly ui: UIManager;
  readonly debug: DebugTools;
  readonly mats = new MaterialLibrary();

  params: Record<string, number> = {};
  private busy = new Set<string>();
  private drag: null | {
    mech: MechDef; handle: HandleView; startParam: number; startX: number; startY: number; started: boolean;
    lastX: number; lastY: number; angle0: number; lastDetent: number; lastParam: number; lastT: number;
  } = null;
  private rotating: 1 | -1 | null = null;
  private pendingRotate: 1 | -1 | null = null;
  private prevGraph: NavGraph | null = null;
  private liveKey = '';
  private liveCache: NavGraph | null = null;
  private zone: ZoneDef | null = null;
  private seen = new Set<string>();
  private mode: Mode = 'title';
  private time = 0;
  private clock = new Clock();
  private idle = 0;
  private hintStage = 0;
  private hovered: string | null = null;
  private nodeLocal = new Map<string, { body: string; local: Vector3 }>();
  private fpsAvg = 60;
  private turnTaught = false;
  private inputLock = false;
  private tmpM = new Matrix4();

  constructor(private canvas: HTMLCanvasElement) {
    this.renderer = new WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.75));
    this.renderer.outputColorSpace = SRGBColorSpace;
    this.renderer.toneMapping = NoToneMapping;
    this.renderer.shadowMap.enabled = true;
    this.renderer.shadowMap.type = PCFSoftShadowMap;
    this.renderer.autoClear = false;

    this.logic = new LevelLogic(buildLevel());
    this.puzzle = new Puzzle(this.logic);
    for (const b of this.logic.def.bodies)
      for (const t of b.tiles) this.nodeLocal.set(`${b.id}/${t.id}`, { body: b.id, local: new Vector3(...t.pos) });

    this.view = new LevelView(this.logic, this.mats);
    this.scene.add(this.view.root);
    this.env = new Environment(this.scene);
    this.scene.add(this.charView.root);
    this.effects = new Effects(this.anim);
    this.scene.add(this.effects.group);
    this.debug = new DebugTools(this.logic);
    this.scene.add(this.debug.group);

    this.char = new CharacterController(this.charView, this.logic.def.start);
    this.wireCharacter();

    const settings = Progress.loadSettings();
    this.ui = new UIManager({
      begin: () => this.begin(true),
      continueGame: () => this.begin(false),
      pause: (on) => this.setPause(on),
      hint: () => this.showHint(true),
      restart: () => void this.restart(),
      toTitle: () => this.toTitle(),
      again: () => void this.restart(),
      turn: (d) => this.rotateWorld(d),
      settingsChanged: (s) => this.applySettings(s),
    }, settings);
    this.applySettings(settings);

    new Interaction(canvas, {
      camera: () => this.rig.camera,
      enabled: () => this.mode === 'play' && !this.ui.paused && !this.inputLock,
      handleMeshes: () => this.view.handles.flatMap((h) => h.pick),
      levelMeshes: () => this.view.pickables,
      hoverHandle: (m) => this.hover(m),
      handleDown: (m, x, y) => this.handleDown(m, x, y),
      handleMove: (x, y) => this.handleMove(x, y),
      handleUp: () => this.handleUp(),
      click: (x, y, ray) => this.click(x, y, ray),
      skyDrag: (dx) => this.skyDrag(dx),
      skyRelease: (dx, vx) => this.skyRelease(dx, vx),
      key: (c) => this.key(c),
    });

    this.resetWorld();
    this.rig.frame([-3, 7, 1], 15, true);
    window.addEventListener('resize', () => this.resize());
    this.resize();
    if (new URLSearchParams(location.search).has('debug')) this.debug.toggle(true);
    this.ui.showTitle(!!Progress.load());
    this.ui.fadeIn();
    this.renderer.setAnimationLoop(() => this.frame());
  }

  // ───────────────────────── state ─────────────────────────

  /** Objects added by the finale (removed when a new journey starts). */
  finaleObjects: Object3D[] = [];

  private clearFinale() {
    for (const o of this.finaleObjects) this.scene.remove(o);
    this.finaleObjects = [];
    for (const m of this.view.windowMaterials()) {
      m.color.copy(m.userData.baseColor);
      m.userData.glow.value = 0;
    }
    if (this.view.lamp) (this.view.lamp.material as MeshBasicMaterial).color.set('#d8c7a6');
    this.env.setBrighten(0);
    this.charView.glowBoost = 0;
  }

  private resetWorld(save?: ReturnType<typeof Progress.load>) {
    this.clearFinale();
    this.anim.cancel('mech');
    this.busy.clear();
    this.drag = null;
    this.rotating = null;
    this.pendingRotate = null;
    this.puzzle = save ? new Puzzle(this.logic, save.state, save.charNode) : new Puzzle(this.logic);
    if (!this.puzzle.graph().nodes.has(this.puzzle.charNode)) this.puzzle = new Puzzle(this.logic);
    this.params = {};
    for (const m of this.logic.def.mechs) this.params[m.id] = this.puzzle.state.mech[m.id];
    this.view.pose(this.params);
    this.char = new CharacterController(this.charView, this.puzzle.charNode);
    this.wireCharacter();
    this.seen = new Set(save?.seenZones ?? []);
    this.zone = null;
    this.rig.setQuadrant(this.puzzle.state.cam, false);
    for (const p of this.logic.def.plates) this.setPlateGlyph(p.id, this.puzzle.hasFlag(`plate:${p.id}`));
    this.prevGraph = this.puzzle.graph();
    this.liveCache = null;
    this.idle = 0;
    this.hintStage = 0;
    this.turnTaught = this.puzzle.canRotateWorld;
    this.debug.rebuild(this.prevGraph, this.params);
    this.updateLocks();
    this.char.pos.copy(this.nodeWorld(this.char.node));
    this.charView.setOverlay(false);
  }

  /** Handles that still wait for a flag look dormant (grey pins). */
  private updateLocks(announce = false) {
    for (const m of this.logic.def.mechs) {
      const req = m.control.requires;
      if (!req) continue;
      const h = this.handleOf(m.id);
      if (!h) continue;
      const locked = !this.puzzle.hasFlag(req);
      h.materials[1].color.set(locked ? '#bdb2b8' : '#e9735c');
      h.materials[0].color.set(locked ? '#e6dfe2' : '#fbf3e4');
      if (!locked && announce) {
        this.effects.pulseHandle(h, 4);
        this.effects.shimmer(this.handleWorld(h), '#ffe9c0', 2.2);
      }
    }
  }

  private wireCharacter() {
    const c = this.char;
    c.graph = () => this.liveGraph();
    c.repath = (from, to) => findPath(this.liveGraph(), from, to);
    c.onStep = (i) => this.audio.step(i);
    c.onArrive = (node) => this.arrive(node);
  }

  private save() {
    if (this.mode !== 'play') return;
    Progress.save({ version: 1, state: this.puzzle.state, charNode: this.char.node, seenZones: [...this.seen] });
  }

  private setPlateGlyph(plateId: string, pressed: boolean) {
    const p = this.logic.def.plates.find((x) => x.id === plateId);
    if (!p) return;
    const loc = this.nodeLocal.get(p.tile);
    if (!loc) return;
    this.view.setPressed(loc.body, loc.local.toArray() as [number, number, number], pressed);
  }

  nodeWorld(id: string, out = new Vector3()): Vector3 {
    const loc = this.nodeLocal.get(id);
    if (!loc) return out.set(0, 0, 0);
    const g = this.view.groups.get(loc.body)!;
    return out.copy(loc.local).applyMatrix4(g.matrix);
  }

  private movingBodies(): Set<string> {
    const s = new Set<string>();
    const add = (m: string) => this.logic.bodiesMovedBy(m).forEach((b) => s.add(b));
    this.busy.forEach(add);
    if (this.drag) add(this.drag.mech.id);
    return s;
  }

  /** Graph usable right now: settled graph, minus bodies that are in motion. */
  liveGraph(): NavGraph {
    const moving = this.movingBodies();
    if (!moving.size) return this.puzzle.graph();
    const key = [...moving].sort().join(',') + '|' + this.logic.graphKey(this.puzzle.state);
    if (key !== this.liveKey || !this.liveCache) {
      this.liveKey = key;
      this.liveCache = this.logic.buildGraph(this.puzzle.state.mech, this.puzzle.state.cam, moving);
    }
    return this.liveCache;
  }

  private progressed() {
    this.idle = 0;
    this.hintStage = 0;
  }

  // ───────────────────────── flow ─────────────────────────

  private begin(fresh: boolean) {
    this.audio.start();
    this.audio.setVolumes(this.ui.settings.music, this.ui.settings.sfx);
    if (fresh) {
      Progress.clear();
      this.resetWorld();
    } else {
      this.resetWorld(Progress.load());
    }
    this.mode = 'play';
    this.ui.hideTitle();
    this.rig.setQuadrant(this.puzzle.state.cam, true, 2.6);
    this.rig.drift = 1;
    const node = this.puzzle.graph().nodes.get(this.char.node);
    this.inputLock = true;
    this.anim.add({ duration: 1.4, onDone: () => { this.inputLock = false; } });
    if (node) this.setZone(node.zone, true);
    this.ui.turnButtons(this.ui.settings.turnButtons && this.puzzle.canRotateWorld);
  }

  private async restart() {
    this.ui.setPause(false);
    this.ui.showEnding(false);
    await this.ui.fadeOut();
    Progress.clear();
    this.env.setBrighten(0);
    this.mode = 'title';
    this.begin(true);
    this.ui.fadeIn();
  }

  private toTitle() {
    this.ui.setPause(false);
    this.save();
    this.mode = 'title';
    this.ui.showTitle(!!Progress.load());
  }

  private setPause(on: boolean) {
    if (this.mode !== 'play') return;
    this.ui.setPause(on);
    this.audio.setVolumes(this.ui.settings.music * (on ? 0.5 : 1), this.ui.settings.sfx);
  }

  private applySettings(s: Settings) {
    Progress.saveSettings(s);
    this.audio.setVolumes(s.music, s.sfx);
    this.renderer.shadowMap.enabled = s.shadows;
    this.env.sun.castShadow = s.shadows;
    this.scene.traverse((o) => { const m = (o as { material?: { needsUpdate: boolean } }).material; if (m) m.needsUpdate = true; });
    this.ui.turnButtons(s.turnButtons && this.puzzle?.canRotateWorld && this.mode === 'play');
  }

  private setZone(id: string, force = false) {
    const z = this.logic.def.zones.find((x) => x.id === id);
    if (!z || (this.zone === z && !force)) return;
    const changed = this.zone !== z;
    this.zone = z;
    this.env.setMood(z.mood);
    this.audio.setMood(z.mood);
    if (changed) {
      this.progressed();
      // draw the eye to the handles that belong to this place
      for (const h of this.view.handles) {
        const m = this.logic.mechs.get(h.mech)!;
        if (this.logic.bodies.get(h.body)!.zone !== z.id) continue;
        if (m.control.requires && !this.puzzle.hasFlag(m.control.requires)) continue;
        this.anim.add({ duration: 0.01, delay: 1.6, onDone: () => this.effects.pulseHandle(h, 2) });
      }
    }
    if (z.title && !this.seen.has(z.id)) {
      this.seen.add(z.id);
      const title = z.title;
      this.anim.add({ duration: 0.01, delay: force ? 1.8 : 0.6, onDone: () => { this.ui.chapter(title); this.audio.chapter(); } });
    }
  }

  // ───────────────────────── character ─────────────────────────

  private arrive(node: string): boolean {
    const eff = this.puzzle.visit(node);
    const n = this.liveGraph().nodes.get(node);
    if (n) this.setZone(n.zone);
    if (eff) this.applyPlate(eff);
    if (this.puzzle.atGoal()) {
      this.finish();
      return false;
    }
    this.save();
    return true;
  }

  private applyPlate(eff: PlateEffect) {
    this.progressed();
    this.setPlateGlyph(eff.plate.id, true);
    const pos = this.nodeWorld(eff.plate.tile).add(new Vector3(0, 0.15, 0));
    if (eff.plate.title) {
      const t = eff.plate.title;
      this.anim.add({ duration: 0.01, delay: 2.2, onDone: () => { this.ui.chapter(t); this.audio.chapter(); } });
    }
    if (eff.flags.includes(this.logic.def.rotateFlag)) {
      this.awaken(pos);
      return;
    }
    this.audio.plate();
    this.effects.shimmer(pos, '#bff3e8', 1.2);
    const travel = (to: Vector3) => Math.min(2.2, 0.9 + pos.distanceTo(to) * 0.06);
    if (eff.flags.length) {
      // a light runs from the plate to the wheel it frees
      const lockedMech = this.logic.def.mechs.find((m) => m.control.requires && eff.flags.includes(m.control.requires));
      const h = lockedMech && this.handleOf(lockedMech.id);
      const to = h ? this.handleWorld(h) : pos.clone().add(new Vector3(0, 3, 0));
      const d = travel(to);
      this.effects.trail(pos, to, d);
      this.anim.add({ duration: 0.01, delay: d, onDone: () => { this.updateLocks(true); this.audio.connect(true); } });
      this.ui.whisper('Somewhere above, something wakes.', 4.5);
    }
    // final poses (the puzzle state already holds the new mechanism states)
    const finalMats = this.logic.bodyMatrices(this.puzzle.state.mech);
    let extra = 0;
    for (const ch of eff.mechChanges) {
      const bodies = this.logic.bodiesMovedBy(ch.mech);
      const def = this.logic.bodies.get(bodies[0])!;
      const local = def.tiles[0]
        ? new Vector3(...def.tiles[0].pos)
        : new Vector3(...def.solids[0].min).add(new Vector3(...def.solids[0].max)).multiplyScalar(0.5);
      const to = local.applyMatrix4(finalMats.get(def.id)!);
      const d = travel(to) + extra;
      this.effects.trail(pos, to, d - extra);
      const m = this.logic.mechs.get(ch.mech)!;
      const dur = m.duration ?? 2.2;
      this.animateMech(ch.mech, ch.to, dur, ease.inOutCubic, d);
      this.anim.add({ duration: 0.01, delay: d, onDone: () => this.audio.rumble(dur) });
      this.anim.add({ duration: 0.01, delay: d + dur * 0.85, onDone: () => this.effects.dust(to, 1.4) });
      extra += 0.25;
    }
  }

  private awaken(pos: Vector3) {
    this.audio.awaken();
    this.effects.shimmer(pos.clone().add(new Vector3(0, 0.3, 0)), '#bff3e8', 3);
    this.charView.glowBoost = 1;
    this.anim.add({ duration: 2.4, ease: ease.outCubic, onUpdate: (k) => { this.charView.glowBoost = 1 - k; } });
    // the world sways, hinting that it can turn
    this.anim.add({
      duration: 3.2, delay: 0.6, ease: ease.linear,
      onUpdate: (_k, t) => { this.rig.dragYaw = Math.sin(t * Math.PI * 2) * 0.16 * (1 - t); },
      onDone: () => { this.rig.dragYaw = 0; },
    });
    this.anim.add({ duration: 0.01, delay: 2.2, onDone: () => { if (!this.turnTaught) this.ui.turnTutorial(true); } });
    this.ui.turnButtons(this.ui.settings.turnButtons);
  }

  // ───────────────────────── mechanisms ─────────────────────────

  private animateMech(id: string, to: number, dur: number, fn = ease.outBack, delay = 0, done?: () => void) {
    this.busy.add(id);
    this.liveCache = null;
    const from = this.params[id];
    let last = from;
    this.anim.add({
      duration: dur, delay, ease: fn, tag: 'mech',
      onUpdate: (k) => {
        const v = from + (to - from) * k;
        this.params[id] = v;
        if (Math.round(last) !== Math.round(v)) this.audio.detent(Math.round(v));
        last = v;
      },
      onDone: () => {
        this.params[id] = to;
        this.busy.delete(id);
        this.liveCache = null;
        done?.();
        this.settled();
      },
    });
  }

  private settled() {
    if (this.busy.size || this.drag) return;
    const g = this.puzzle.graph();
    const prev = this.prevGraph;
    this.prevGraph = g;
    this.debug.rebuild(g, this.params);
    if (!prev) return;
    const reach = reachable(g, this.char.node);
    let seamShown = 0;
    let walkShown = 0;
    for (const [id, links] of g.links) {
      for (const l of links) {
        if (l.to < id) continue;
        const had = prev.links.get(id)?.some((x) => x.to === l.to && x.seam === l.seam);
        if (had) continue;
        if (!reach.has(id) && !reach.has(l.to)) continue;
        if (l.seam && seamShown < 2) {
          this.effects.shimmer(l.a.clone().add(new Vector3(0, 0.15, 0)), '#fff1c4', 1.8);
          this.effects.shimmer(l.b.clone().add(new Vector3(0, 0.15, 0)), '#fff1c4', 1.8);
          seamShown++;
        } else if (!l.seam && walkShown < 2) {
          this.effects.shimmer(l.a.clone().add(new Vector3(0, 0.12, 0)), '#ffffff', 1.1);
          walkShown++;
        }
      }
    }
    if (seamShown) this.audio.connect(true);
    else if (walkShown) this.audio.connect(false);
    this.save();
  }

  private handleOf(mech: string): HandleView | undefined {
    return this.view.handles.find((h) => h.mech === mech);
  }

  private hover(mech: string | null) {
    if (mech === this.hovered) return;
    if (this.hovered) {
      const h = this.handleOf(this.hovered);
      h?.materials.forEach((m) => (m.userData.glow.value = 0));
    }
    this.hovered = mech;
    if (mech) {
      const h = this.handleOf(mech);
      h?.materials.forEach((m) => (m.userData.glow.value = 0.22));
    }
  }

  private handleDown(mechId: string, x: number, y: number): boolean {
    const m = this.logic.mechs.get(mechId)!;
    const h = this.handleOf(mechId)!;
    if (this.busy.has(mechId) || this.rotating) return true;
    const block = this.puzzle.canOperate(mechId);
    if (block) {
      this.effects.wiggle(h);
      this.audio.nope();
      const w = BLOCK_WHISPER[block];
      if (w) this.ui.whisper(w, 3.5);
      return true;
    }
    if (this.char.walking) this.char.requestStop();
    const center = this.screenOf(this.handleWorld(h));
    this.drag = {
      mech: m, handle: h, startParam: this.params[mechId], startX: x, startY: y, started: false, lastX: x, lastY: y,
      angle0: Math.atan2(-(y - center.y), x - center.x), lastDetent: Math.round(this.params[mechId]),
      lastParam: this.params[mechId], lastT: performance.now(),
    };
    this.liveCache = null;
    this.audio.tap();
    return true;
  }

  private handleWorld(h: HandleView): Vector3 {
    return h.local.clone().applyMatrix4(this.view.groups.get(h.body)!.matrix);
  }

  private screenOf(p: Vector3): { x: number; y: number } {
    const v = p.clone().project(this.rig.camera);
    const r = this.canvas.getBoundingClientRect();
    return { x: r.left + ((v.x + 1) / 2) * r.width, y: r.top + ((1 - v.y) / 2) * r.height };
  }

  private handleMove(x: number, y: number) {
    const d = this.drag;
    if (!d) return;
    d.lastX = x;
    d.lastY = y;
    if (this.char.walking) return; // wait for the wanderer to stop
    if (!d.started) {
      // (re)anchor the gesture once movement is allowed
      d.started = true;
      d.startX = x;
      d.startY = y;
      const c = this.screenOf(this.handleWorld(d.handle));
      d.angle0 = Math.atan2(-(y - c.y), x - c.x);
      d.startParam = this.params[d.mech.id];
    }
    const m = d.mech;
    let raw: number;
    if (m.kind === 'rotator') {
      const c = this.screenOf(this.handleWorld(d.handle));
      const a = Math.atan2(-(y - c.y), x - c.x);
      let delta = a - d.angle0;
      while (delta > Math.PI) delta -= Math.PI * 2;
      while (delta < -Math.PI) delta += Math.PI * 2;
      d.angle0 = a;
      const axis = new Vector3(...m.axis).normalize();
      const sign = axis.dot(this.rig.viewDir()) >= 0 ? 1 : -1;
      raw = this.params[m.id] + (sign * delta) / (Math.PI / 2);
    } else {
      const p0 = this.handleWorld(d.handle);
      const step = m.kind === 'slider' ? m.step : 1;
      const p1 = p0.clone().addScaledVector(new Vector3(...(m.kind === 'slider' ? m.axis : [0, 1, 0])), step);
      const s0 = this.screenOf(p0);
      const s1 = this.screenOf(p1);
      const sx = s1.x - s0.x;
      const sy = s1.y - s0.y;
      const len2 = Math.max(1, sx * sx + sy * sy);
      raw = d.startParam + ((x - d.startX) * sx + (y - d.startY) * sy) / len2;
    }
    const full = m.kind === 'rotator' && m.states.length === 4;
    if (!full) {
      const lo = Math.min(...m.states);
      const hi = Math.max(...m.states);
      if (raw < lo) raw = lo - rubber(lo - raw);
      if (raw > hi) raw = hi + rubber(raw - hi);
    }
    this.params[m.id] = raw;
    const det = Math.round(raw);
    if (det !== d.lastDetent) {
      d.lastDetent = det;
      this.audio.detent(det);
    }
    const now = performance.now();
    const vel = Math.abs(raw - d.lastParam) / Math.max(0.001, (now - d.lastT) / 1000);
    d.lastParam = raw;
    d.lastT = now;
    this.audio.grindLevel(clamp(vel / 2.5, 0, 1));
  }

  private handleUp() {
    const d = this.drag;
    if (!d) return;
    this.audio.grindLevel(0);
    const m = d.mech;
    const cur = this.params[m.id];
    const full = m.kind === 'rotator' && m.states.length === 4;
    const mod = (v: number) => (full ? ((v % 4) + 4) % 4 : v);
    const startState = this.puzzle.state.mech[m.id];
    // candidates ordered by distance from the current parameter
    const cands: number[] = [];
    const r = Math.round(cur);
    for (const off of [0, 1, -1, 2, -2]) cands.push(r + off);
    let target = d.startParam;
    let targetState = startState;
    for (const c of cands.sort((a, b) => Math.abs(a - cur) - Math.abs(b - cur))) {
      const st = mod(c);
      if (!m.states.includes(st)) continue;
      if (st !== startState && this.puzzle.canSetState(m.id, st)) continue;
      if (Math.abs(c - cur) > 0.75 && st !== startState) continue;
      target = c;
      targetState = st;
      break;
    }
    if (targetState === startState && Math.abs(target - d.startParam) > 0.01 && !full) target = d.startParam;
    this.drag = null;
    const dur = 0.35 + Math.min(0.5, Math.abs(target - cur) * 0.35);
    this.busy.add(m.id);
    const from = cur;
    this.anim.add({
      duration: dur, ease: ease.outBack, tag: 'mech',
      onUpdate: (k) => { this.params[m.id] = from + (target - from) * k; },
      onDone: () => {
        this.params[m.id] = target;
        this.busy.delete(m.id);
        this.liveCache = null;
        if (targetState !== startState) {
          this.puzzle.setMech(m.id, targetState);
          this.progressed();
        }
        this.audio.snap();
        this.settled();
      },
    });
  }

  // ───────────────────────── world rotation ─────────────────────────

  rotateWorld(dir: 1 | -1) {
    if (this.mode !== 'play' || this.rotating) return;
    if (!this.puzzle.canRotateWorld) {
      this.anim.add({ duration: 0.6, ease: ease.linear, onUpdate: (_k, t) => { this.rig.dragYaw = Math.sin(t * Math.PI) * 0.035 * -dir; }, onDone: () => { this.rig.dragYaw = 0; } });
      return;
    }
    if (this.busy.size || this.drag) return;
    if (this.char.walking) {
      this.char.requestStop();
      this.pendingRotate = dir;
      return;
    }
    this.rotating = dir;
    this.rig.setQuadrant(this.puzzle.state.cam + dir, true, 1.5);
    this.audio.worldTurn();
    if (!this.turnTaught) {
      this.turnTaught = true;
      this.ui.turnTutorial(false);
    }
  }

  private skyDrag(dx: number) {
    if (this.rotating) return;
    if (!this.puzzle.canRotateWorld) {
      this.rig.dragYaw = -Math.sign(dx) * Math.min(Math.abs(dx) * 0.0004, 0.03);
      return;
    }
    if (this.busy.size || this.char.walking) return;
    this.rig.dragYaw = -clamp(dx * 0.0032, -0.95, 0.95);
  }

  private skyRelease(dx: number, vx: number) {
    if (this.puzzle.canRotateWorld && !this.busy.size && (Math.abs(dx) > 70 || (Math.abs(vx) > 0.55 && Math.abs(dx) > 24))) {
      this.rotateWorld(dx > 0 ? -1 : 1);
    } else {
      this.rig.dragYaw = 0;
    }
  }

  // ───────────────────────── walking ─────────────────────────

  private pickNode(ray: Raycaster, x: number, y: number): string | null {
    const g = this.liveGraph();
    const throughWindow = this.inWindow(x, y);
    const hits = ray.intersectObjects(this.view.pickables, false).filter((h) => !(throughWindow && this.view.fadeOf(h.object.userData.body) > 0.4));
    const hit = hits[0];
    if (hit && hit.face) {
      const n = hit.face.normal.clone().transformDirection(hit.object.matrixWorld);
      if (n.y > 0.6) {
        let best: string | null = null;
        let bestD = Infinity;
        for (const node of g.nodes.values()) {
          if (Math.abs(node.pos.x - hit.point.x) > 0.53 || Math.abs(node.pos.z - hit.point.z) > 0.53) continue;
          const dy = node.pos.y - hit.point.y;
          if (dy > 0.3 || dy < -0.85) continue;
          if (Math.abs(dy) < bestD) { bestD = Math.abs(dy); best = node.id; }
        }
        if (best) return best;
      }
    }
    // fallback: nearest node in screen space, preferring the one closest to the camera
    const vd = this.rig.viewDir();
    let best: string | null = null;
    let bestScore = -Infinity;
    const pxPerUnit = this.canvas.clientHeight / (2 * this.rig.size);
    const thresh = Math.max(16, pxPerUnit * 0.42);
    for (const node of g.nodes.values()) {
      const s = this.screenOf(node.pos);
      const d = Math.hypot(s.x - x, s.y - y);
      if (d > thresh) continue;
      const score = node.pos.dot(vd) - d / pxPerUnit;
      if (score > bestScore) { bestScore = score; best = node.id; }
    }
    return best;
  }

  private click(x: number, y: number, ray: Raycaster) {
    if (this.rotating || this.drag) return;
    const node = this.pickNode(ray, x, y);
    if (!node) return;
    const g = this.liveGraph();
    const pos = g.nodes.get(node)!.pos;
    if (this.char.walking) {
      const path = findPath(g, this.char.node, node);
      this.effects.ring(pos, !!path);
      if (path) { this.char.redirect(node); this.audio.tap(); } else this.audio.nope();
      return;
    }
    const path = findPath(g, this.char.node, node);
    if (!path) {
      this.effects.ring(pos, false);
      this.audio.nope();
      return;
    }
    this.effects.ring(pos, true);
    this.audio.tap();
    if (path.length > 1) this.char.follow(path, g);
  }

  private key(code: string) {
    if (code === 'Backquote') {
      this.debug.toggle();
      this.debug.rebuild(this.puzzle.graph(), this.params);
      if (!this.debug.enabled) this.ui.debugText(null);
      return;
    }
    if (this.mode !== 'play') return;
    if (code === 'Escape') { this.setPause(!this.ui.paused); return; }
    if (this.ui.paused) return;
    if (code === 'KeyQ') this.rotateWorld(-1);
    if (code === 'KeyE') this.rotateWorld(1);
    if (code === 'KeyN' && this.debug.enabled) void this.autoStep();
  }

  // ───────────────────────── hints & solver ─────────────────────────

  /** First step toward the next milestone (a new flag, i.e. a plate or the eye) or the goal. */
  nextAction(): Action | null {
    const n = this.puzzle.state.flags.length;
    const res = solve(this.puzzle.clone(), { maxStates: 20000, stopWhen: (p) => p.state.flags.length > n });
    return res.solved ? res.plan[0] ?? null : null;
  }

  private showHint(explicit: boolean) {
    const z = this.zone;
    if (z?.hints?.length) this.ui.whisper(z.hints[Math.min(this.hintStage, z.hints.length - 1)], 7);
    if (!explicit && this.hintStage === 0) { this.hintStage = 1; return; }
    const a = this.nextAction();
    if (!a) return;
    if (a.type === 'mech') {
      const h = this.handleOf(a.mech);
      if (h) this.effects.pulseHandle(h, 4);
    } else if (a.type === 'cam') {
      this.ui.turnTutorial(true);
      this.anim.add({ duration: 0.01, delay: 6, onDone: () => this.ui.turnTutorial(false) });
    } else {
      this.effects.beckon(this.nodeWorld(a.to), 3);
    }
    this.hintStage = Math.min(this.hintStage + 1, 3);
  }

  /** Debug/autoplay: perform the solver's next action. */
  async autoStep(): Promise<Action | null> {
    if (this.char.walking || this.busy.size || this.rotating) return null;
    const a = this.nextAction();
    if (!a) return null;
    if (a.type === 'walk') {
      const g = this.liveGraph();
      const path = findPath(g, this.char.node, a.to);
      if (path && path.length > 1) this.char.follow(path, g);
    } else if (a.type === 'mech') {
      const m = this.logic.mechs.get(a.mech)!;
      const cur = this.params[a.mech];
      let target = a.to;
      if (m.kind === 'rotator' && m.states.length === 4) {
        // shortest rotation in parameter space
        const base = Math.round(cur);
        let best = base;
        for (let k = -3; k <= 3; k++) if (((base + k) % 4 + 4) % 4 === a.to && Math.abs(k) < Math.abs(best - base) + (best === base ? 99 : 0)) best = base + k;
        target = best;
      }
      this.animateMech(a.mech, target, 0.9, ease.inOutCubic, 0, () => { this.puzzle.setMech(a.mech, a.to); this.progressed(); });
    } else {
      this.rotateWorld(a.dir);
    }
    return a;
  }

  /** Debug: jump to the state after the first `n` actions of the solver's solution. */
  debugJump(n: number): string {
    const p = new Puzzle(this.logic);
    const plan = solve(p.clone()).plan;
    for (const a of plan.slice(0, n)) {
      if (a.type === 'walk') p.walk(findPath(p.graph(), p.charNode, a.to) ?? [p.charNode]);
      else if (a.type === 'mech') p.setMech(a.mech, a.to);
      else p.rotateWorld(a.dir);
    }
    const seen = this.logic.def.zones.map((z) => z.id);
    this.resetWorld({ version: 1, state: p.state, charNode: p.charNode, seenZones: seen });
    if (this.mode !== 'play') { this.mode = 'play'; this.ui.hideTitle(); }
    const node = this.puzzle.graph().nodes.get(this.char.node);
    if (node) this.setZone(node.zone, true);
    return `${n}/${plan.length} next: ${JSON.stringify(plan[n] ?? null)}`;
  }

  // ───────────────────────── finale ─────────────────────────

  private finish() {
    this.mode = 'ending';
    this.ui.hud(false);
    this.ui.turnTutorial(false);
    Progress.save({ version: 1, state: this.puzzle.state, charNode: this.char.node, seenZones: [...this.seen], done: true });
    Progress.clear();
    void runFinale(this).then(() => this.ui.showEnding(true));
  }

  // ───────────────────────── loop ─────────────────────────

  private sizeKey = '';
  /** Adaptive resolution: lowered gently if the frame rate stays low. */
  private dprCap = 1.75;
  private slowTime = 0;

  private fastTime = 0;
  private drops = 0;

  private adaptResolution(dt: number) {
    if (document.hidden) return;
    if (this.fpsAvg > 58 && this.dprCap < 1.75 && this.drops < 3) {
      this.fastTime += dt;
      if (this.fastTime > 6) { this.dprCap = Math.min(1.75, this.dprCap + 0.25); this.fastTime = 0; }
    } else this.fastTime = 0;
    if (this.fpsAvg < 46 && this.dprCap > 1) {
      this.slowTime += dt;
      if (this.slowTime > 2.5) {
        this.dprCap = Math.max(1, this.dprCap - 0.25);
        this.slowTime = 0;
        this.drops++;
      }
    } else this.slowTime = Math.max(0, this.slowTime - dt);
  }

  private resize() {
    const w = window.innerWidth;
    const h = window.innerHeight;
    const dpr = Math.min(window.devicePixelRatio || 1, this.dprCap);
    const key = `${w}x${h}@${dpr}`;
    if (key === this.sizeKey) return;
    this.sizeKey = key;
    this.renderer.setPixelRatio(dpr);
    this.renderer.setSize(w, h, false);
    this.rig.aspect = w / h;
  }

  private solidsKey = '';
  private solidsCache: WorldBox[] = [];

  /**
   * Cutaway: architecture standing between the camera and what matters right now — the wanderer,
   * the handles of the current section and its unpressed plates — becomes see-through, in every view.
   */
  private updateCutaway(dt: number) {
    const key = this.logic.def.mechs.map((m) => this.params[m.id].toFixed(3)).join(',');
    if (key !== this.solidsKey) {
      this.solidsKey = key;
      this.solidsCache = this.logic.worldSolids(this.logic.bodyMatrices(this.params));
    }
    const hide = new Set<string>();
    const activeWindows = new Map<string, { p: Vector3; r: number }>();
    if (this.mode === 'play') {
      const dir = this.rig.viewDir();
      const charBody = this.nodeLocal.get(this.char.node)?.body;
      const charP = this.char.pos.clone().add(new Vector3(0, 0.38, 0));
      const foci: { key: string; p: Vector3; probes: Vector3[]; own?: string; r: number }[] = [
        { key: 'char', p: charP, probes: [this.char.pos.clone().add(new Vector3(0, 0.12, 0)), this.char.pos.clone().add(new Vector3(0, 0.7, 0))], own: charBody, r: 1.45 },
      ];
      const zoneOf = (body: string, tile?: string) => {
        const b = this.logic.bodies.get(body)!;
        return (tile && b.tileZones?.[tile]) || b.zone;
      };
      for (const h of this.view.handles) {
        const inZone = this.zone && zoneOf(h.body) === this.zone.id;
        const carrying = charBody && this.logic.isWithin(charBody, h.body);
        if (inZone || carrying || this.drag?.handle === h) {
          const p = this.handleWorld(h);
          foci.push({ key: `h:${h.mech}`, p, probes: [p], own: h.body, r: 1.25 });
        }
      }
      for (const pl of this.logic.def.plates) {
        if (this.puzzle.hasFlag(`plate:${pl.id}`)) continue;
        const loc = this.nodeLocal.get(pl.tile)!;
        if (this.zone && zoneOf(loc.body, pl.tile.split('/')[1]) !== this.zone.id) continue;
        const p = this.nodeWorld(pl.tile).add(new Vector3(0, 0.1, 0));
        foci.push({ key: `p:${pl.id}`, p, probes: [p], own: loc.body, r: 1.0 });
      }
      for (const f of foci) {
        let hit = false;
        for (const sol of this.solidsCache) {
          if (sol.body === f.own) continue;
          if (f.probes.some((q) => rayHitsBox(q, dir, sol.min, sol.max))) { hide.add(sol.body); hit = true; }
        }
        if (hit) activeWindows.set(f.key, { p: f.p, r: f.r });
      }
    }
    // windows open and close softly; their centres follow what they reveal
    const kw = damp(5, dt);
    for (const [key, w] of activeWindows) {
      const cur = this.windows.get(key);
      if (cur) { cur.p.copy(w.p); cur.r = w.r; cur.target = 1; } else this.windows.set(key, { p: w.p.clone(), r: w.r, w: 0, target: 1 });
    }
    for (const [key, w] of this.windows) {
      if (!activeWindows.has(key)) w.target = 0;
      w.w += (w.target - w.w) * kw;
      if (w.target === 0 && w.w < 0.01) this.windows.delete(key);
    }
    const dpr = this.renderer.getPixelRatio();
    const pxPerUnit = this.canvas.clientHeight / (2 * this.rig.size);
    const list = [...this.windows.values()].sort((x, y) => y.w - x.w).slice(0, 6);
    const rect = this.canvas.getBoundingClientRect();
    list.forEach((w, i) => {
      const sp = this.screenOf(w.p);
      const r = w.r * pxPerUnit * (0.35 + 0.65 * w.w);
      atmosphere.uFoci.value[i].set((sp.x - rect.left) * dpr, (rect.bottom - sp.y) * dpr, r * dpr);
    });
    atmosphere.uFociN.value = list.length;
    this.windowList = list.map((w) => ({ p: w.p, r: w.r * pxPerUnit }));
    const k = damp(4.2, dt);
    for (const id of this.view.groups.keys()) {
      const cur = this.view.fadeOf(id);
      const target = hide.has(id) ? 1 : 0;
      const next = cur + (target - cur) * k;
      this.view.setFade(id, Math.abs(next - target) < 0.004 ? target : next);
    }
  }

  private windows = new Map<string, { p: Vector3; r: number; w: number; target: number }>();
  private windowList: { p: Vector3; r: number }[] = [];

  /** Is a screen point inside an open cutaway window? */
  private inWindow(x: number, y: number): boolean {
    return this.windowList.some((w) => {
      const s = this.screenOf(w.p);
      return Math.hypot(s.x - x, s.y - y) < w.r * 0.85;
    });
  }

  /** Slow orbit around the monument; on wide screens the monument sits right of the title. */
  private titleCamera(dt: number) {
    this.rig.yaw += dt * 0.035;
    const c = new Vector3(-3, 7.5, 1);
    const wide = this.rig.aspect > 1.15;
    if (wide) {
      const right = new Vector3(Math.cos(this.rig.yaw), 0, -Math.sin(this.rig.yaw));
      c.addScaledVector(right, -15 * this.rig.aspect * 0.4);
    }
    this.rig.frame(c, wide ? 15 : 16.5);
    document.body.classList.toggle('wide', wide);
  }

  /** Deterministic stepping for automated tests (independent of requestAnimationFrame). */
  advance(seconds: number, step = 1 / 60): void {
    const n = Math.ceil(seconds / step);
    for (let i = 0; i < n; i++) this.frame(step, i === n - 1);
  }

  private frame(dtOverride?: number, render = true) {
    const dt = dtOverride ?? Math.min(0.05, this.clock.getDelta());
    this.time += dt;
    atmosphere.uTime.value = this.time;
    this.fpsAvg += (1 / Math.max(dt, 1e-4) - this.fpsAvg) * 0.05;

    if (dtOverride === undefined) this.adaptResolution(dt);
    this.resize();
    const paused = this.ui.paused;
    if (!paused) {
      this.anim.update(dt);
      this.char.update(dt);
      if (this.mode === 'play') this.updatePlay(dt);
    }
    if (this.mode === 'title') this.titleCamera(dt);

    this.view.pose(this.params);
    this.updateCutaway(dt);
    if (!this.char.walking) this.nodeWorld(this.char.node, this.char.pos);
    this.charView.root.position.copy(this.char.pos);
    this.charView.update(dt, this.char.walking, 1, this.time);

    this.rig.update(dt, this.time);
    this.env.yaw = this.rig.yaw + this.rig.dragYaw;
    atmosphere.uFocus.value.copy(this.rig.target);
    this.rig.viewDir(atmosphere.uViewDir.value);
    this.env.update(dt, this.rig.target, this.time, this.rig.aspect);

    if (!render) return;
    this.renderer.clear();
    this.env.renderBackground(this.renderer);
    this.renderer.clearDepth();
    this.renderer.render(this.scene, this.rig.camera);

    if (this.debug.enabled) {
      const a = this.drag ? `drag ${this.drag.mech.id} ${this.params[this.drag.mech.id].toFixed(2)}` : '';
      this.ui.debugText(this.debug.describe(this.puzzle, this.fpsAvg, `${a} busy:${[...this.busy].join(',')}`));
    }
  }

  private updatePlay(dt: number) {
    // camera framing: zone composition, gently leaning toward the wanderer
    if (this.zone) {
      const t = new Vector3(...this.zone.target).lerp(this.char.pos, 0.16);
      this.rig.frame(t, this.zone.size);
    }
    if (this.rotating && !this.rig.rotating) {
      this.puzzle.rotateWorld(this.rotating);
      this.rotating = null;
      this.liveCache = null;
      this.progressed();
      this.settled();
    }
    if (this.pendingRotate && !this.char.walking) {
      const d = this.pendingRotate;
      this.pendingRotate = null;
      this.rotateWorld(d);
    }
    // drag waits for the wanderer to stop
    if (this.drag && !this.drag.started && !this.char.walking) this.handleMove(this.drag.lastX, this.drag.lastY);

    // gentle hints when idle for a long time
    if (!this.char.walking && !this.drag && !this.busy.size) {
      this.idle += dt;
      if ((this.hintStage === 0 && this.idle > 55) || (this.hintStage === 1 && this.idle > 110)) {
        this.showHint(false);
        if (this.hintStage < 2) this.idle = this.hintStage === 1 ? 56 : 0;
      }
    }
    void this.tmpM;
  }

  /** Expose for debugging / automated playtests. */
  meshesForPick(): Object3D[] {
    return this.view.pickables;
  }
}

/** Does the ray p + t·d (t > 0) pass through the box (and not merely start inside it)? */
function rayHitsBox(p: Vector3, d: Vector3, min: Vector3, max: Vector3): boolean {
  let t0 = 0.05;
  let t1 = 400;
  for (const ax of ['x', 'y', 'z'] as const) {
    const o = p[ax];
    const v = d[ax];
    if (Math.abs(v) < 1e-9) {
      if (o <= min[ax] || o >= max[ax]) return false;
      continue;
    }
    let a = (min[ax] - o) / v;
    let b = (max[ax] - o) / v;
    if (a > b) [a, b] = [b, a];
    t0 = Math.max(t0, a);
    t1 = Math.min(t1, b);
    if (t0 > t1) return false;
  }
  const inside = p.x > min.x && p.x < max.x && p.y > min.y && p.y < max.y && p.z > min.z && p.z < max.z;
  return !inside;
}

function rubber(x: number): number {
  return 0.25 * (1 - Math.exp(-x * 3));
}
