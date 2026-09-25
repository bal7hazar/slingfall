# slingfall_replay

The replay executables (`docs/DESIGN.md` D1, lot G4): one level logic, three builds.

Each is its own target (`[[target.executable]]`, `target/dev/<name>.executable.json`), selected
with `scarb execute --executable-name <name>`.

| executable | function | observer | returns |
|---|---|---|---|
| `main` | `main::main(level, inputs)` | `NoopObserver` (proof build, no prints) | the 10 felts of `Outputs` (D4) |
| `main_trace` | `trace::main_trace(level, inputs)` | `TraceObserver` (trace lines v1) | the same 10 felts |
| `init` | `chunk::init(level)` | prints the level header lines | the `ChunkState` felts |
| `step_chunk` | `chunk::step_chunk(state, inputs, shot, k, trace)` | `TraceObserver` when `trace != 0`, else none | the new `ChunkState` felts |

A nested package with its own `[workspace]`, outside the root one: executables need
`enable-gas = false`, which `snforge` refuses, so tests run under the gas-enabled `snforge`
profile. From this directory:

```sh
scarb build
scarb execute --executable-name main --arguments-file args.json --print-program-output --print-resource-usage
snforge test --profile snforge
python3 scripts/measure.py --chunk 60        # the tables below (from any directory)
```

`python3 tools/tracec/tracec.py args fixtures/levels/pile10.felts.json --shot=-600,-392 --out
args.json` writes the arguments of `main` / `main_trace`; `tracec.py trace lines.txt --out
trace.json` turns the printed lines into trace format v1 (`client/README.md`).
`fixtures/traces/pile10-reference.json` is `main_trace` on pile10 with the reference shot.

## Level logic (`src/main.cairo`)

`play<O, +Observer<O>>(level: @Level, inputs: @Inputs, ref obs: O) -> Outputs`: `LevelTrait::validate`,
`InputsTrait::validate`, `obs.on_level`, `GameTrait::new` (settle step included), then per shot
`step_shot` until the level is won (the shot that wins runs to its end, the rest are not played)
or the inputs end; `Outputs` from the game (`ticks_run` counts every tick, delays included).

`step_shot(ref game, level, shot, ref progress, budget, ref obs) -> (stepped, over)` is
`GameTrait::play_shot` with a tick budget: delay ticks, the launch right before the next tick, ticks
until `TickReport.shot_over` (delay ticks never end a shot), `GameTrait::end_shot`. `play` calls it
with an unbounded budget, `step_chunk` with `k`: the chunked run is the uninterrupted one bit for
bit (tests `chunk::tests::test_chain_*`, K = 1, 3, 7, 60).

`Observer<O>`: `on_level(@Level)` once, `on_tick(ref Game, @TickReport)` after every tick,
`on_shot_end(ref Game, shot)` after `end_shot`. `NoopObserver`'s methods are empty and inlined: the
proof build costs what the rules cost (table below, +0.013 %). Events: `TraceObserver` derives them
(damage from `hp` changes, destroyed from `TickReport.destroyed`, score from the material of each
destroyed body and the unused-shot bonus at `on_shot_end`) and prints them.

Panic messages (`main::errors`, stable API): `replay: level` / `replay: inputs` (the argument is
not exactly one `Level` / `Inputs`), `replay: state` (not exactly one `ChunkState` of version 1),
`replay: shot` (`step_chunk`'s shot is not the one in progress, is past the inputs, or the level is
over); then the level crate's `level: *` / `inputs: *` validation messages.

## Arguments (the client's API)

Every argument is `Serde`: an `Array<felt252>` is its length then its felts; negative values are
`P - x`. `scarb execute --arguments-file` wants a JSON array of `0x` felts; the browser runner
(`client/vm/`) takes the same felts as whitespace-separated decimals.

- `main(level, inputs)`, `main_trace(level, inputs)`: `[len(L), L..., len(I), I...]` with `L` the
  `Level` felts (`levelc.py to-felts`) and `I` = `[player, n, (pull_x, pull_y, delay, ability_tick) × n]`.
- `init(level)`: `[len(L), L...]`.
- `step_chunk(state, inputs, shot, k, trace)`: `[len(S), S..., len(I), I..., shot, k, trace]`
  with `S` the felts returned by `init` or the previous `step_chunk`, `shot` the 0-based shot index,
  `k` the tick budget (0 = a pure round trip), `trace` 0 or 1.

`ChunkState` felts: a 7-felt header, then the level, then the rules' `GameState` (its world a
`rapier2d::WorldState`):

| index | field | meaning |
|---:|---|---|
| 0 | `version` | 1 |
| 1 | `shots_used` | shots finished; the shot in progress (or next) has this index. **Shot `s` is over when this is `s + 1`.** |
| 2 | `over` | 1: the level is over (won or out of shots, no shot in progress); stop |
| 3 | `launched` | the pebble of shot `shots_used` is out (its delay is done) |
| 4 | `shot_ticks` | ticks of that shot stepped so far, delay included |
| 5 | `tick` | ticks since the start of the level (the last frame's tick) |
| 6 | `score` | score so far |

A shot's loop: `state = init(level)`; for `s` in the shots: while `state[1] == s` and `state[2] == 0`,
`state = step_chunk(state, inputs, s, K, 1)`. The inputs may hold fewer shots than `level.shots`.

## Trace lines v1 (`src/trace.cairo`)

One `println!` per line, space-separated, numbers in decimal (raw Q32.32 as signed `i64`):

```text
trace 1
level <gravity_y> <launch_scale> <pull_radius> <shots> <min_x> <min_y> <max_x> <max_y> <anchor_x> <anchor_y> <bodies>
material <index> <score>
body <handle> <kind> <material> <x> <y> <re> <im> ball <r> | cuboid <hx> <hy> | polygon <n> <x> <y>... | halfspace <nx> <ny>
frame <tick> (<handle> <x> <y> <re> <im> <asleep>)*
damage <tick> <handle> <hp>
destroyed <tick> <handle>
score <tick> <points> <total>
shot_end <tick> <shot>
```

`kind`: 0 static, 1 block, 2 core. A level body's handle is its index in `level.bodies`; the
pebble of shot `s` has handle `bodies + s` (never rapier's handle: a freed slot may be reused), so
a handle in no `body` line is a pebble. A frame lists the live dynamic bodies, ascending, the
pebble last; static bodies never appear. Per tick: damage lines (ascending), each destroyed body
followed by its `score` line, then the frame; at a shot's end, the unused-shot bonus (`score`) then
`shot_end`, both at the shot's last tick. `main_trace` prints the header, then every tick;
`init` prints the header; `step_chunk` with `trace = 1` prints its ticks.

## Steps

See "Steps per shot and per level" below (`scarb execute --print-resource-usage`, the proof
executables as run; snforge counts about 1M more per shot, the gas-enabled profile).
