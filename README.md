# Meridian — a quiet geometry

A perspective architecture puzzle for desktop browsers. One large, continuous level: a floating monument
that spirals around a central tower, where staircases, bridges and turning crowns only connect when you
look at them the right way.

## Run

```bash
npm install
npm run dev        # http://127.0.0.1:5183
```

```bash
npm run build      # static build in dist/ (open with any static server)
npm test           # solver: solvability, no dead ends, no interpenetration, every mechanic necessary
```

## Controls

| Action | Mouse / touch | Keys |
|---|---|---|
| Walk | click / tap a tile | |
| Turn a crank, slide a lift | drag the ivory handle | |
| Turn the world (after the Eye) | drag the sky sideways | `Q` / `E` |
| Pause | ring button, top left | `Esc` |
| Debug view | | `` ` `` (or `?debug` in the URL) |
| Debug: perform the solver's next step | | `N` (debug view on) |

## How it works

- **Exact isometric camera.** Points that differ by `k·(±1, 1, ±1)` project onto the same pixel. That is the
  whole trick behind every illusion.
- **Navigation graph.** Every walkable tile has open edges with a surface height. Two tiles connect when their
  edge midpoints coincide in 3D (physical link), or — for edges explicitly marked as *seams* — when the midpoints
  coincide in the current projection, face each other, and are otherwise apart (perspective link). Overlap alone
  never connects anything. Crossing a seam moves the wanderer along the view axis, which is invisible on screen.
- **Deterministic state.** Mechanism states, flags (pressed plates, the Eye) and the camera quadrant fully define
  the world. The renderer only interpolates between states.
- **Solver.** `src/logic/solver.ts` searches the whole state space. The tests prove that the level is solvable,
  that no reachable state is a dead end, that no moving parts interpenetrate, and that removing any mechanism (or
  world rotation) makes the level unsolvable. The same solver powers in-game hints.

```
src/
  core/      easing + tweens (AnimationSystem)
  logic/     LevelLogic (transforms, solids, nav graph, seams), Puzzle (rules), solver, types
  level/     kit (box, stairs, arch, dome, pavilion …) and level.ts (the single level)
  render/    palette, materials (height mist shader), geometry, LevelView, Environment, Character, CameraRig, Effects
  game/      Game (orchestration), CharacterController, Interaction, UI, Audio (WebAudio synthesis), Progress, Debug, Finale
tests/       solver.test.ts
```

Everything — geometry, textures, music and sound — is generated procedurally at runtime. No external assets.
Progress is saved in `localStorage`.

See `DESIGN.md` for the design document, level structure and solution.

## Chapters (native iOS app)

`ios/MeridianNative` adds five small chapters before Meridian, chosen in a gallery of floating shrines
(`Logic/Chapters.swift`, `Logic/ChaptersLate.swift`, `UI/ChapterUI.swift`). Each one introduces new architecture:

| # | Chapter | New mechanic |
|---|---|---|
| I | The Drawbridge | Hinged rotators on horizontal axes: a wall lowers into a bridge |
| II | The Counterweight | Coupled mechanisms: one knob, two platforms moving in opposite directions (`BodyDef.mechSign`) |
| III | The Clockwork | Step switches (`PlateDef.repeatable`, `.turn`): the clock hand turns a quarter each time you reach its hub; combined with the Eye and a seam |
| IV | The Twin Gears | Geared rotators with their own pivots (`BodyDef.pivot`): one wheel turns two bridges in opposite senses |
| V | The Tumbling Hall | Faced tiles (`TileDef.up`): every face of a turning block is a road whenever it faces the sky |
| VI | Meridian | The original monument, unchanged |

Chapters unlock one after another; progress is saved per chapter. Every chapter passes the same solver checks
(`ios/MeridianNative/Tools/LogicCheck/run.sh`: solvable, no dead ends, no overlaps, nothing floats, every mechanism
necessary), and Meridian's logic dump is still identical to the TypeScript version. The web build has the original
single level only.

Launch arguments for development: `-unlockAll`, `-select`, `-chapter <id>` (add `-intro` to stop at the chapter card),
`-autoplay`.
