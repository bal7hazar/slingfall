# S1 — substeps and tick rate: measure ×2 (and ×1, 30 Hz) on the six levels; switch if stability holds

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D1, D5, D10; rapier-cairo `docs/BUDGETS.md` "Cost of a level" and ADR 0001 entry 9
(read-only at `/home/claude/projects/rapier-cairo/`): upstream fidelity is identical at ×4 / ×2 / ×1 / 30 Hz up to the
impact tick, so only the game's stability decides; on `main`: `crates/slingfall_rules/src/world.cairo`
(`IntegrationParameters`, `num_solver_iterations`, dt), `tools/levelc/rules.py` (`check --rules`: rest, awake-at-rest,
settle), `tools/settle/settle.py`, `tools/golden/golden.py`, `fixtures/golden/`, `docs/levels.md`.

## 2. Scope (allowlist)
`crates/slingfall_rules/src/**` (a `SimConfig` / constants: substeps and dt read from the `Level` if you add an
optional field with default ×4 / 60 Hz, else crate constants; keep the felt layout of `Level` unchanged unless you
add a trailing optional field with a version bump of `LEVEL_VERSION`: prefer crate constants for this lot),
`tools/levelc/rules.py` (`--substeps`, `--hz` switches passed to the executables via an env / argument the rules
crate reads at build time: `SLINGFALL_SUBSTEPS` scarb feature or a `cfg`), `tools/golden/**`, `fixtures/golden/**`
(new cases per setting, existing ones untouched unless the default changes), `docs/levels.md`, `steps/**`,
`docs/briefs/s1-substeps.md` (this file: append your results table).

## 3. Work
1. Make the substep count and tick rate a build-time choice of `slingfall_rules` (Scarb features
   `substeps_2`, `substeps_1`, `hz_30`; default ×4 / 60 Hz) so that every tool can run the matrix without editing levels.
2. Matrix on the six levels: ×4 (baseline), ×2, ×1, 30 Hz ×4: for each, `levelc check --rules --jobs 2` (rest and
   awake-at-rest: zero damage lines, zero moved bodies, settle idempotent), the reference pull(s): destroyed set,
   score, won, end tick, steps; a jitter test: 300 ticks awake at rest, count wake-ups / poses drift (mm);
   the pebble at 25 m/s vs the 0.5 m plank (tunnelling) at each setting.
3. Decision rule (apply it, report it): switch the default to the cheapest setting where every level passes the
   stability checks, every reference pull still wins with the same destroyed set (or a superset), tunnelling does
   not appear, and the client's exact flight arc (`client/src/aim/arc.ts`, 60 Hz Euler) still matches the engine's
   free flight (if 30 Hz is chosen, the arc changes: report and do not switch to 30 Hz in this lot; only substeps).
4. If the default changes: regenerate goldens / executables / steps, and note it in `docs/levels.md`
   ("numeric change: MINOR" for the game).

## 4. Budget
Report steps per reference shot per setting; expected ×2 ≈ −25 to −35 %.

## 5. Tests
`levelc check --rules` on all six levels at the chosen default; goldens green; snforge rules tests green.

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/s1-substeps`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · Matrix
table · Decision · Deviations · Escalations · PR URL). At most 2 parallel jobs; never two golden runs at once.

## 7. Work autonomously, do not ask questions, do not widen the scope.


---

# Results (executor, 2026-09-26)

Measured with `tools/golden/matrix.py` (reference shots), `tools/levelc/rules.py` (`check --rules --jobs 2`
under each setting) and `snforge test -p slingfall_rules jitter` / `tunnel` (in a scratch copy of the workspace
with `SOLVER_ITERATIONS` / `TICK_DT_RAW` changed: the manifests are orchestrator-owned, so there is no Scarb
feature; see REPORT.md, Deviations). "Substeps" is rapier's `num_solver_iterations`.

## 1. Reference shots (the pull of the x4 golden `*-reference` case at every setting)

Steps are `main` (proof build). `one_block` uses its `delay30` case (pull (-600, -392), delay 30). "Same or
superset" compares the destroyed handles with the x4 baseline. The arc column is the free flight of the pebble
against `client/src/aim/arc.ts` (60 Hz, one Euler step per tick): engine ticks of free flight / of them
bit-identical / largest deviation.

| setting | level | shots | won | score | ticks | steps | vs baseline | destroyed | same or superset | arc: flight ticks / bit-identical / max deviation |
|---|---|---|---|---|---|---|---|---|---|---|
| x4 60 Hz | pile10 | 1 | 1 | 5200 | 107 | 8,783,663 | +0 % | [8, 9, 10] | yes | 82 / 0 / 83.794 mm |
| x4 60 Hz | cores3 | 1 | 1 | 11050 | 180 | 11,847,276 | +0 % | [3, 6, 7, 8] | yes | 79 / 0 / 80.728 mm |
| x4 60 Hz | one_block | 1 | 0 | 0 | 150 | 1,774,344 | +0 % | [] | yes | 111 / 0 / 113.428 mm |
| x4 60 Hz | tower | 1 | 1 | 6200 | 180 | 22,416,600 | +0 % | [5, 6, 9, 10] | yes | 78 / 0 / 79.706 mm |
| x4 60 Hz | bridge | 1 | 1 | 6250 | 180 | 9,325,546 | +0 % | [3, 4, 5, 7, 9, 10] | yes | 119 / 0 / 121.603 mm |
| x4 60 Hz | twin | 2 | 1 | 4200 | 306 | 21,675,360 | +0 % | [6, 7, 11, 12] | yes | 76 / 0 / 77.662 mm |
| x4 60 Hz | **total** | | | | | **75,822,789** | **+0.0 %** | | | |
| x2 60 Hz | pile10 | 1 | 1 | 5200 | 106 | 6,888,957 | -22 % | [8, 9, 10] | yes | 82 / 0 / 55.862 mm |
| x2 60 Hz | cores3 | 1 | 1 | 11050 | 180 | 9,557,773 | -19 % | [3, 6, 7, 8] | yes | 79 / 0 / 53.819 mm |
| x2 60 Hz | one_block | 1 | 0 | 0 | 150 | 1,716,495 | -3 % | [] | yes | 111 / 0 / 75.619 mm |
| x2 60 Hz | tower | 1 | 0 | 1200 | 180 | 17,847,631 | -20 % | [5, 6, 9] | NO | 78 / 0 / 53.137 mm |
| x2 60 Hz | bridge | 1 | 1 | 6200 | 180 | 9,122,167 | -2 % | [3, 4, 5, 9, 10] | NO | 119 / 0 / 81.069 mm |
| x2 60 Hz | twin | 2 | 1 | 4200 | 304 | 17,593,712 | -19 % | [6, 7, 11, 12] | yes | 76 / 0 / 51.775 mm |
| x2 60 Hz | **total** | | | | | **62,726,735** | **-17.3 %** | | | |
| x1 60 Hz | pile10 | 1 | 1 | 5000 | 108 | 7,872,055 | -10 % | [10] | NO | 81 / 81 / 0.0 mm |
| x1 60 Hz | cores3 | 1 | 0 | 0 | 180 | 11,539,600 | -3 % | [] | NO | 79 / 79 / 0.0 mm |
| x1 60 Hz | one_block | 1 | 0 | 0 | 150 | 1,623,287 | -9 % | [] | yes | 110 / 110 / 0.0 mm |
| x1 60 Hz | tower | 1 | 0 | 1200 | 180 | 15,089,016 | -33 % | [5, 6, 9] | NO | 78 / 78 / 0.0 mm |
| x1 60 Hz | bridge | 1 | 1 | 6100 | 180 | 11,555,227 | +24 % | [4, 9, 10] | NO | 119 / 119 / 0.0 mm |
| x1 60 Hz | twin | 2 | 0 | 1100 | 306 | 17,715,256 | -18 % | [6, 7] | NO | 76 / 76 / 0.0 mm |
| x1 60 Hz | **total** | | | | | **65,394,441** | **-13.8 %** | | | |
| x4 30 Hz | pile10 | 1 | 1 | 5200 | 62 | 7,135,399 | -19 % | [8, 9, 10] | yes | 41 / 0 / 55.862 mm |
| x4 30 Hz | cores3 | 1 | 1 | 11100 | 158 | 13,793,709 | +16 % | [3, 4, 6, 7, 8] | yes | 40 / 0 / 54.5 mm |
| x4 30 Hz | one_block | 1 | 0 | 0 | 150 | 2,641,991 | +49 % | [] | yes | 56 / 0 / 76.3 mm |
| x4 30 Hz | tower | 1 | 1 | 6200 | 128 | 17,902,758 | -20 % | [5, 6, 9, 10] | yes | 39 / 0 / 53.137 mm |
| x4 30 Hz | bridge | 1 | 0 | 0 | 180 | 36,218,432 | +288 % | [] | NO | 60 / 0 / 81.75 mm |
| x4 30 Hz | twin | 2 | 1 | 4200 | 254 | 25,720,931 | +19 % | [6, 7, 11, 12] | yes | 38 / 0 / 51.775 mm |
| x4 30 Hz | **total** | | | | | **103,413,220** | **+36.4 %** | | | |

Steps: x2 saves 17.3 % over the six references (from 2 % on `bridge` to 22 % on `pile10`; the brief expected
25-35 %), x1 13.8 % (`bridge` +24 %: its collapse is longer), 30 Hz x4 costs +36 % (`bridge` never wins and runs
its 180 ticks = 6 s; a 30 Hz tick is twice the flight time, so `tick_cap`, delays and the 120-tick pebble flight
cap all double in meaning).

## 2. `levelc check --rules --jobs 2` (12-pull grid, at rest, awake, reference shots)

| setting | levels passing | failing levels and why |
|---|---|---|
| x4 60 Hz | 6 / 6 (`one_block`: LEGACY warning, as on `main`) | none |
| x2 60 Hz | 2 / 6 (`bridge`, `one_block`) | `cores3` (4 bodies move on a settle), `pile10` (1), `tower` (1), `twin` (1 + 4): the stored poses are not a fixed point of the x2 settle; no damage line, every pile asleep again |
| x1 60 Hz | 1 / 6 (`one_block`, warning) | `bridge` (all 10 bodies move), `cores3` (5), `pile10` (1), `tower` (7 move and 1 + 2 damage lines: a support over its force threshold), `twin` (pile 1 still awake at tick 120; 1 + 4 move) |
| x4 30 Hz | 2 / 6 (`bridge`, `one_block`) | `cores3` (3 move), `pile10` (1), `tower` (1), `twin` (1 + 4) |

At rest: 0 damage lines at every setting (66 ticks at x4 / x2, 70 at x1, 44 at 30 Hz before the calm rule ends
the shot). Every core stays reachable by the grid at every setting, and the best grid pull of every level wins
at every setting (the rules check re-picks it: `tower` needs (-770, -359) at x2, (-543, -472) at x1; `bridge`
(-543, -472) at x1, (-770, -359) at 30 Hz; `twin` (-503, -327) + (-770, -359) at x1). The failures are the
pre-settled poses (and at x1 real instability): they would have to be re-settled at the new setting
(`tools/settle/settle.py` follows `SLINGFALL_SUBSTEPS`).

## 3. Jitter: 300 ticks, every dynamic body woken, rapier alone (`world/jitter.cairo`)

Force events over a material threshold (each would be a damage line in the game) are counted, not asserted:
`pile10` and `cores3` carry a static load over a timber threshold at every setting, as the G8 test
`test_awake_pile10_load_damage_is_the_inner_bottom_timber` documents (the settle-probe wake of the rules check is
gentler and reports 0). Cells: force events, first tick every body sleeps (rapier's own sleep timer), peak drift
of a body from its start in mm.

| level | x4 60 Hz | x2 60 Hz | x1 60 Hz | x4 30 Hz |
|---|---|---|---|---|
| one_block | 0, 32, 0 | 0, 32, 0 | 0, 33, 3 | 0, 17, 0 |
| cores3 | 66, 32, 0 | 68, 32, 1 | 87, 38, 7 | 38, 17, 1 |
| pile10 | 59, 32, 1 | 60, 33, 2 | 67, 39, 8 | 31, 17, 2 |
| tower | 0, 32, 1 | 0, 37, 5 | 2, 56, **22** | 0, 20, 4 |
| bridge | 0, 32, 0 | 0, 33, 3 | 0, 41, 12 | 0, 17, 3 |
| twin | 0, 32, 1 | 0, 38, 5 | 0, **never**, **156** (a body collapses) | 0, 20, 5 |

No wake-up after the pile slept at any setting. x1 fails the probe's 20 mm limit on `tower` and `twin`.

## 4. Tunnelling: pebble at 25 m/s against the 0.5 m plank (`test_pebble_at_25_mps_...`)

The pebble bounces at every setting: the largest x is 5.50 m (the plank's front face 5.75 m minus the radius)
and the final vx about -2.3 m/s at x4 / x2 / x1 (-2.2 at 30 Hz). At 30 Hz the pebble moves 0.83 m per tick
against the plank's 1 m overlap window and still does not tunnel. No tunnelling at any setting.

## 5. Flight arc (`client/src/aim/arc.ts`)

At the **x4 default the arc is already inexact**. rapier integrates a free flight as k Euler steps of `dt / k`
(`v_y += mul(g, h); y += mul(v_y, h)` with `h = dt // k`; bit-exact model in `matrix.py`), which puts the pebble
`0.375 g dt^2 = 1.02 mm` per tick above the single-step arc of `arc.ts` (x2: 0.25 g dt^2 = 0.68 mm; x1: exactly
`arc.ts`, bit-identical over the whole free flight on all six levels). The deviation when the pebble arrives is
78-122 mm at x4, 52-81 mm at x2, 0 at x1, 52-82 mm at 30 Hz (30 Hz also changes the arc itself). Escalated
(REPORT.md).

## 6. Decision (the rule of section 3, applied)

Switch to the cheapest setting where (a) every level passes the stability checks, (b) every reference pull wins
with the same destroyed set or a superset, (c) no tunnelling, (d) the arc still matches (not worse than x4):

* **x1**: fails (a) (5 of 6 levels; `tower` and `twin` are unstable) and (b) (`cores3`, `tower`, `twin` lose
  the win; `pile10` and `bridge` destroy fewer bodies), and the jitter limit.
* **x2**: (c) holds and (d) improves (the arc error is a third smaller), but (a) fails on the fixed point of the
  pre-settled poses of four levels and (b) fails on `tower` (no longer wins: core 9 only) and `bridge` (body 7 is
  no longer destroyed). The gain is 17 % of the steps, below the 25-35 % expected.
* **30 Hz x4**: not switched in this lot by the brief; it fails (a) and (b) (`bridge`) anyway and costs +36 %.

**No switch: x4 / 60 Hz stays the default; no golden, level or executable changes.** A later lot can adopt x2:
re-settle four levels, re-pick the reference pulls of `tower` and `bridge` (the grid has winning pulls at x2),
regenerate the goldens, and weigh the 17 % step gain; the client arc needs a fix in any case (the substepped
model of `matrix.arc_points(..., substeps=4)`, or run at x1).
