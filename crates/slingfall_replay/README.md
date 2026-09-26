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

On the rules of G3 + G3b (spent pebble), 2026-09-25, `scarb execute --print-resource-usage` (the
executables as run; snforge counts ≈ 0.65M more per pile10 shot, the gas-enabled profile). Pulls:
reference = (-600, -392); the weak shots (-150, -150), (-200, -200) fall before the target.

Whole runs (`scripts/measure.py`):

| level, shots | played | score | won | ticks | `main` | per tick | `main_trace` | trace overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| pile10, reference | 1 | 5 350 | yes | 191 | **31,487,873** | 164,857 | 33,336,475 | +5.9 % |
| cores3, reference | 1 | 11 250 | yes | 143 | **7,394,341** | 51,708 | 8,392,926 | +13.5 % |
| one_block, reference | 1 | 0 | no | 120 | **2,546,605** | 21,221 | 2,975,096 | +16.8 % |

Three shots per level, chunked (`scripts/measure.py --per-shot 20`: a whole 3-shot `main` needs
more memory than the shared machine gives one `scarb execute`, the VM keeps every cell). Net =
the shot's `step_chunk` steps minus one `k = 0` round trip per chunk:

| level | shot | pull | ticks | net steps | per tick | score after |
|---|---:|---|---:|---:|---:|---:|
| pile10 | 0 | weak | 120 | 8,230,518 | 68,587 | 0 |
| pile10 | 1 | weak | 120 | 7,916,380 | 65,969 | 0 |
| pile10 | 2 | reference | 191 | 30,882,364 | 161,687 | 1 350 (won, no shot left) |
| pile10 | level | | 431 | **47,356,253** with `init` | | |
| cores3 | 0 | weak | 120 | 6,169,223 | 51,410 | 0 |
| cores3 | 1 | weak | 120 | 6,033,083 | 50,275 | 0 |
| cores3 | 2 | reference | 143 | 7,185,462 | 50,247 | 7 250 (won) |
| cores3 | level | | 383 | **19,579,605** with `init` | | |

Chunked build: `init` 326,991 (pile10) / 191,837 (cores3); a `step_chunk` round trip (`k = 0`:
decode the state, the level and the inputs, restore and save the world, serialise) 136,301 on
pile10, 82,705 on cores3. K = 60 on the pre-G3b reference shot: 6 chunks, +584k over `main`.

snforge probes (`steps/slingfall_replay/*.snap`), pile10 reference shot: rules alone (`new` +
`play_shot` + hash) 32,129,896; `play` + `NoopObserver` 32,133,817 (**+0.012 %**, budget 1 %);
`main` 32,134,146; `main_trace` 34,167,774 (+6.3 %). The trace costs ≈ 3.5-10k steps per tick,
mostly the decimal formatting of the moving bodies: each body's pose text is cached while it does
not move (−27 % of the trace cost on pile10). It is ≤ 10 % of a shot on pile10 but not on the
light levels, whose ticks cost 21-52k. Rejected candidate (`trace::tests::alternatives`): a
two-digit table, 15,393 vs 14,810 steps for 44 typical values.

## Determinism and budget CI (`tools/golden`, lot G5)

`python3 tools/golden/golden.py` (Python 3 standard library) checks the three builds against each
other and against committed goldens; the CI job `golden` runs it, one leg per level fixture
(pile10, cores3, one_block), then a seeded fuzz.

```sh
scarb build                                                  # here; the script runs `--no-build`
python3 tools/golden/golden.py run --check [--level L] [-j 4] --no-build   # the CI check
python3 tools/golden/golden.py run --update --no-build        # rewrite fixtures/golden/<case>.json
python3 tools/golden/golden.py fuzz --seed 5 --n 6 --no-build  # random inputs, nothing stored
python3 tools/golden/golden.py to-cairo [--check]             # tests/golden.cairo (snforge)
```

`fixtures/golden/cases.json` lists the cases (level fixture, shots, chunk schedules): pile10
reference and three shots, cores3 reference, three shots and a pull outside the disk (clamped),
one_block miss, delay 30 and a pull on the disk boundary. Per case the script runs `main`,
`main_trace` and, per chunk schedule, `init` then `step_chunk(…, K, 1)` chained (a schedule is the
list of tick budgets, its last value repeating: small chunks that cut through delays, the launch
and the end of a shot, then a large tail). A chained run has no `Outputs`, so the script rebuilds
the 10 felts: identity fields by Poseidon from the level and inputs, score / shots / ticks from the
state header, `won` from the printed `body` / `destroyed` lines, `final_state_hash` from the last
printed frame. Failures: outputs of the three builds differ, the chained trace lines differ from
`main_trace`'s, two schedules end on different `ChunkState` felts, outputs differ from the golden,
or `main` takes more than 1.10 × the golden's steps (fewer steps only asks for `--update`).

`golden.py fuzz` draws pulls (inside the disk, on its axes, outside), delays and shot counts per
level from a seed and requires `main` ≡ chained chunks of random sizes. `to-cairo` generates
`tests/golden.cairo`: one snforge test per case, `main` on the golden inputs returns the golden
felts (`--check` fails when the file is stale after a golden changes).

`scarb execute` costs about 10 s of fixed overhead per call whatever the program (VM setup), which
is why chained runs use short schedules rather than K = 1 all along (K = 1 on a 191-tick shot is
191 calls); the exhaustive K = 1, 3, 7, 60 chains stay in `chunk::tests::test_chain_*`.

CI time (ubuntu-latest, PR #11): `golden (pile10)` 6 min 35 s, `golden (one_block)` 5 min 30 s,
`golden (cores3)` 4 min 31 s, each a whole job (checkout, scarb, build, `--check`, fuzz `--n 6`),
in parallel: under the 8-minute budget.
