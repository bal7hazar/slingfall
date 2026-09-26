# Authoring levels

How a Slingfall level is written, settled, validated and put under a golden (lot G8). The format is
`docs/DESIGN.md` D2 and `tools/levelc/README.md`; this page is the workflow, the material values and
what was measured.

## Workflow

1. Write `fixtures/levels/<name>.json` (decimal values; poses as `x`, `y`, `angle_deg`). Conventions
   of the five levels: gravity -9.81, sling anchor (3, 2.5), pull radius 1024, launch scale 0.02,
   ground = a static half space through the origin (normal (0, 1)), materials in the order timber,
   slate, frost, core (indices 0..3), 8-10 blocks and 2-3 cores placed 15-25 m from the sling, exact
   contacts (a block on the ground has `y = hy`), `tick_cap` 180 (see "Tick cap").
2. `python3 tools/settle/settle.py fixtures/levels/<name>.json --ticks 120 --out <name>.settled.json`
   pre-settles the poses (below). Copy the result over the level.
3. `python3 tools/levelc/levelc.py to-felts fixtures/levels/<name>.json --out fixtures/levels/<name>.felts.json`
   and copy both files to `client/public/levels/` (`client/src/game/levels.test.ts` compares them).
4. `python3 tools/levelc/levelc.py check fixtures/levels/<name>.json --strict --rules` validates it
   (below). It needs the replay executables (`scarb --manifest-path crates/slingfall_replay/Scarb.toml
   build`, or drop `--no-build`).
5. Add a case to `fixtures/golden/cases.json` with the reference shots the validator reported, then
   `python3 tools/golden/golden.py run --update --no-build --case <name>-reference` and
   `python3 tools/golden/golden.py to-cairo` (`tests/golden.cairo`).

## Pre-settle: `tools/settle/settle.py`

D2 stores dynamic bodies pre-settled and asleep: the game's `GameTrait::new` sleeps every body, so a
level never moves until something touches it. There is no "step without a shot", and nothing is
added to Cairo. The trick: run `main_trace` on a **probe copy** of the level (`shots = 1`,
`tick_cap = N`) whose sling anchor is moved next to the pile, with one shot whose pull is
`(ceil(1 / launch_scale), 0)`: the pebble is launched on the ground, its side touching the
outermost bottom block of the pile (a horizontal contact: no load), at about 1 m/s **away** from
the pile. Touching wakes the pile's island; the pebble rolls on (there is no damping, D5), so the
calm rule cannot end the shot after 20 ticks and cut the pile off while it is still creeping; the
pile settles and falls asleep by itself (D5 (1), tick 32 on every level here). The poses of the
last frame (raw Q32.32 felts, exact) are written back.

- One pebble wakes one island: bodies are grouped into piles (boxes within 2 cm) and every pile
  gets its own probe (`twin` has two). `--wake X,Y` overrides the pebble position for a pile that
  does not stand on the flat ground.
- Poses are rounded onto a 1 mm grid and 0.1 degree (`--step`): a woken pile never comes back to a
  bit-identical pose, but it does come back to the same cell. Rounds repeat until one moves no pose,
  so **settling a settled level is the identity** (checked: `settle.py fixtures/levels/twin.json`
  writes a file identical to its input; `SETTLE_ROUND_TRIP=<level> python3 tools/settle/test_settle.py`).
- The report gives, per pile and round: the settle tick, the tick the probe shot ended on, the drift
  (sum of the displacements) and the `damage` lines a badly loaded pile suffers while settling.
  The probe takes 15-30 M Cairo steps and up to 7 GB per pile.

Settling moved the authored (exact) poses by 14-27 mm in total, in 2-3 rounds:

| level | piles | first round drift | rounds |
|---|---:|---:|---:|
| tower | 2 | 0.027 m | 2 |
| bridge | 1 | 0.014 m | 3 |
| twin | 2 | 0.023 m | 3 |

## Validator: `levelc.py check --rules`

Runs the level through the replay executables (`tools/levelc/rules.py`):

1. `tick_cap >= 140`, at least one core.
2. **At rest**: `main_trace`, pull (0, 0): no `damage` line. The level starts asleep, so this is weak
   (the pebble falls at the sling and the pile is untouched).
3. **Awake** (the G3 static-load note, `crates/slingfall_rules/README.md`): every pile is woken by the
   settle probe: no `damage` line, asleep again within 120 ticks, and it ends on the poses it
   started on (pre-settled).
4. **Reachable cores**: 12 pulls (angles 25 / 33 / 41 / 50 degrees x pull 600 / 720 / 850, i.e.
   launch speeds 12 / 14.4 / 17 m/s), each through `main_trace`: every core is destroyed by at least
   one. `--pulls=PX,PY;PX,PY` replaces the grid (probing a hit).
5. **Step budget**: the reference shots (the best winning pull of the grid; when no single pull wins,
   as on a two-pile level, one grid pull per core, one shot each) must win in `main`; steps under
   `--budget` (default 1e8, interim) and, per shot, a warning above D10's 3e7.

`pile10`, `cores3` and `one_block` were hand-placed before this tooling, so `rules.py` lists them as
`LEGACY` (the awake test is a warning for them, not a failure). Lot G8b retuned and pre-settled
`pile10` and `cores3`: both now pass the awake test with no warning (`one_block` has a single block
and is still `LEGACY`; its poses and goldens are unchanged).

```sh
python3 tools/levelc/levelc.py check fixtures/levels/tower.json fixtures/levels/bridge.json \
    fixtures/levels/twin.json fixtures/levels/pile10.json fixtures/levels/cores3.json \
    --strict --rules --jobs 3 --no-build
```

It is **not** in CI: a level costs 6-8 minutes on the free runners (12 grid shots of 20-45 M steps
and 6 GB each), which is more than the `golden` job's budget. The goldens of all five levels and
`one_block` are checked by the `golden` job's `golden.py run --check` (one matrix leg per level,
G8b).

## Simulation setting: substeps and tick rate (lot S1)

The game runs at 60 Hz with `num_solver_iterations = 4` (rapier's "substeps"; D1). Lot S1 measured
x2, x1 and 30 Hz x4 on the six levels and **kept the default**: no level, golden or executable
changed ("numeric change: MINOR" for the game applies the day a setting is adopted; not this lot).
The two constants live in `crates/slingfall_rules/src/world.cairo` (`SOLVER_ITERATIONS`,
`TICK_DT_RAW`); the manifests declare no Scarb feature, so the other settings are built by the
tools in a scratch copy of the workspace:

```sh
python3 tools/levelc/rules.py --substeps 2 fixtures/levels/*.json            # levelc check --rules, x2
python3 tools/levelc/rules.py --hz 30 --no-build fixtures/levels/tower.json  # 30 Hz x4 (after a build)
python3 tools/golden/matrix.py --substeps 2 --out /tmp/x2.json               # reference shots + arc
python3 tools/golden/matrix.py table /tmp/x4.json /tmp/x2.json               # markdown rows
SLINGFALL_SUBSTEPS=2 python3 tools/golden/golden.py run --check              # any golden tool, same env
```

`snforge test -p slingfall_rules jitter` prints the 300-tick jitter probe of the six levels
(`world/jitter.cairo`). A reference shot is not portable across settings: the same pull gives a
different collapse (results in `docs/briefs/s1-substeps.md`). A switch is a retune of the levels
(re-settle, re-pick the pulls), not a constant.

**Flight arc.** rapier integrates a free flight as `k` Euler steps of `dt / k` per tick (gravity
included in each), so at x4 the pebble sits 0.375 g dt^2 = 1.02 mm per tick *above* the single-step
arc of `client/src/aim/arc.ts` (8 cm at the first contact, 12 cm on the longest flight); x1 is
bit-identical to `arc.ts`. `arc.ts` is exact at x1 only.

## Materials

Tuned on the three new levels and, in G8b, applied unchanged to `pile10` and `cores3` (`materials` of each level; `Material`'s layout is unchanged). D12's
values are in brackets. `damage_per_impulse_dt` is D6's factor: `hp -= floor((F - force_threshold) *
damage_per_impulse_dt)` per contact event and tick, F in newtons (one tick of contact force).

| material | density | friction | restitution | hp | force_threshold | damage_per_impulse_dt | score |
|---|---:|---:|---:|---:|---:|---:|---:|
| timber | 1 | 0.6 | 0.1 | 100 | **150** (40) | **0.15** (1) | 50 |
| slate | 2.5 | 0.8 | 0.05 | 300 | **350** (120) | **0.15** (0.333) | 150 |
| frost | 0.9 | 0.05 | 0.2 | 40 | **40** (15) | 2 | 100 |
| core | 1 | 0.6 | 0.1 | 30 | 10 | 1 | 1 000 |

How the values were found (measured with `force_threshold = 0`, `hp = 1e9`, `damage_per_impulse_dt
= 1`, so that the hp lost by a body in a tick is the sum of its contact forces; `scratch` probes,
not committed):

- **At rest, awake.** Summed contact force per tick on the supports once the woken piles settle
  (tick 8-32, N): slate 258 (tower base slab, three contacts), 178 (bridge pillar), 119 (tower
  upper slab); timber 146 (bridge deck), 96 (twin bottom block), 94 (tower column); frost 33 (tower)
  / 23 (bridge); cores 4-6. One contact event carries part of that sum and the transient of the
  first ticks peaks 1.3-1.8x higher (`pile10`, D12's 40 N: two inner bottom blocks carried 41-43 N
  each and lost 19 hp in 20 ticks). Thresholds: timber 150 and slate 350 clear the sums (a margin of
  1.8x or more per event), frost 40 (was 15: frost carries stacked slate and timber), core 10 kept.
  `check --rules` confirms zero damage on every pile of the three levels.
- **A direct pebble hit** is one tick of about 1 100-1 200 N on the block it strikes (tower probe,
  pull (-503, -327), launch 12 m/s: 1 125 N on the base slab, 1 190 N on a column), then 200-400 N
  on its neighbours while the pile collapses. With `damage_per_impulse_dt` 0.15: timber takes
  (1 150 - 150) * 0.15 = 150 hp in the hit tick (dead, hp 100) but a neighbour at 240 N takes 13 per
  tick; slate takes (1 150 - 350) * 0.15 = 120 of 300 hp (survives one hit, dies after about three
  hit ticks: "needs a good hit"); frost takes 2 * (F - 40): any real contact shatters it. The first
  tuning (timber 100 N / 0.5, slate 300 N / 0.4) let one hit bring the whole tower down (8 of 8
  blocks); 100 / 0.2 still lost 8 of 8 in the collapse; 150 / 0.15 destroys what the pebble hits.
- **Measured hits** (`check --rules`, "first hit" = destroyed bodies in the tick of the first
  destruction and the two after): tower, low flat pulls (-836, -147) and (-800, -200): 1 timber and
  1-2 frost; bridge (-463, -552): 1 timber and 1 frost, 3 timber in the whole shot; the steeper
  pulls of the grid hit frost and cores first (frost 1-2, cores). Slate is never destroyed by the
  grid pulls of the new levels. (`pile10` / `cores3` had the old D12 values: 3-4 timber, slate and
  frost in a hit. With the tuned values, `pile10`'s winning pulls destroy 2 frost and the core in the
  first hit, `cores3`'s one timber post at most.)

## Tick cap

Every level has `tick_cap` 180 (`pile10` and `cores3` had 360 before G8b). A rolling core or
pebble never calms (D5, no damping), so a shot that does not end by itself runs to the cap: 360
ticks of a busy pile cost 70 M steps (tower, measured), 180 ticks 42 M. The validator only requires
140 or more (a pebble takes about 100 ticks to arrive and settle).

## The five levels

Blocks / cores exclude the ground. Settle tick and drift: `settle.py`, first round. Reference =
what `check --rules` chose (steps: `main`, the proof build, one `scarb execute`). G8b retuned and
pre-settled `pile10` and `cores3` (G8's materials, `tick_cap` 180): their historic golden pull
(-600, -392) no longer suits them, so the references are the validator's pulls, (-604, -392) on
`pile10` (one shot wins; 31.5 M steps, 5 350 points before) and (-653, -304) on `cores3` (7.4 M
steps, 11 250 points before).

| level | id | blocks | cores | structure | settle tick | drift (m) | reference pull(s) | steps | score | ticks |
|---|---:|---:|---:|---|---:|---:|---|---:|---:|---:|
| `pile10` | 2 | 9 | 1 | pyramid of timber, slate, frost | 32 | 0.006 | (-604, -392) | 20 742 085 | 5 200 | 107 |
| `cores3` | 3 | 3 | 3 | two timber posts, a slate deck, three cores | 32 | 0.004 | (-653, -304) | 22 801 514 | 11 050 | 180 |
| `tower` | 4 | 8 | 2 | slate slab, timber columns, slate slab, frost, timber slab and block, a core on top; a lone core on the ground | 32 | 0.027 | (-604, -392) | 42 399 252 | 6 200 | 180 |
| `bridge` | 5 | 8 | 2 | two slate pillars, a timber deck, a frost / timber hut under a timber roof holding a core, a timber stack with a core on the deck's right end | 32 | 0.014 | (-463, -552) | 19 090 613 | 6 250 | 180 |
| `twin` | 6 | 10 | 2 | a three-row pyramid with a core (x 15-18) and a stack with a slate board (x 25-26): two piles | 32 | 0.023 | (-503, -327) then (-543, -472) | 47 579 795 (2 shots) | 4 200 | 306 |

- `tower`: 6 200 = frost 2 x 100 + two cores + two unused shots (2 x 2 000). 42.4 M steps is over
  D10's 3e7 (ten bodies awake for 180 ticks); under the interim 1e8.
- `bridge`: the reference shot also destroys 3 timber blocks and 1 frost block: 19.1 M steps.
- `twin`: no single pull wins (the piles are 6.5 m apart); each shot costs about 24 M steps. Score:
  two cores, two frost and one unused shot.
- `pile10`: 5 200 = core 1 000 + frost 2 x 100 + two unused shots (2 x 2 000). Only some pulls win
  (of the grid: (-453, -394), (-653, -304) and (-604, -392)); the shot ends by the calm rule at
  tick 107.
- `cores3`: the reference shot (-653, -304) destroys the three cores and one timber post and runs
  to the cap (180 ticks): 11 050 = 3 x 1 000 + 50 + four unused shots (4 x 2 000). Three of the
  twelve grid pulls win.
- G8b settled both (`settle.py`, 2 rounds: drift 6 mm on `pile10`, 4 mm on `cores3`) and gave them
  G8's materials, so their level hashes and every golden built on them changed (G8b's PR lists
  each). Before, they failed the awake test (`pile10`: 45 damage lines; `cores3`: bodies
  destroyed while settling).
- Budget: every reference shot is under the interim 1e8 steps; those above D10's 3e7 are `tower`
  (42.4 M) and `twin` (2 shots, 47.6 M in all, about 24 M each, so each shot is under 3e7).
