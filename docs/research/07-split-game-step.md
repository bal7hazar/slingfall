# 07 — The game's chunk on declared classes (SNIP-36 path): sizes and steps measured (S36a)

Date: 2026-09-28. Author: S36a executor (Opus 5.5). Toolchain: scarb / Cairo 2.19.4, snforge 0.61.0,
`rapier2d` / `rapier2d_classes` `=0.1.0-alpha.7` (alpha.8 since lot B6: "Status after B6"). Base: `main` at `36def9d`. Code: `crates/slingfall_split`
(spike, not published). Sizes: `python3 tools/classsize/classsize.py split` (dev profile; the release profile gives the
same figures). Steps: exact Cairo steps from `snforge test --detailed-resources` (the library-called classes and the
syscalls included), each probe's own setup subtracted.

## Summary

**Question.** Is there a class layout in which a whole shot runs as a chain of transactions of at most 10M steps,
every declared class at most 73,728 Sierra and CASM felts, results bit-identical to `main`?

**Answer: yes, today, with layout (b).** In layout (b), the game class owns the chunk loop, the rules and the World edits,
and hands the world to a step class once per engine step. Every class fits the gate:

- the game class: 72,752 CASM (margin 976);
- the step class: 72,397 (margin 1,331);
- the settle class of `init`: 72,555 (margin 1,173);
- rapier's stage classes: at most 57,299.

It is bit-identical to `main` after every tick of both reference shots. **But it is expensive.** The owner's shot
((-1022, -63), 151 ticks) costs:

- 49.7M steps, +106 % over `main` in process;
- 9 proven transactions: `init`, 7 chunks of at most 8.30M, `outputs`.

The world crosses the class boundary twice per tick (the basic codec both ways): 172k steps per flight tick against 20k
in process.

**The cheap layout misses the gate by 3,192 felts.** In layout (e), the world class keeps the world for the whole
chunk. Per tick it library-calls a rules class with compact data: force events in; edits, watched bodies and status out.
On the ticks that edit the world (removals, sleeps, the pebble's launch), the world crosses to an edit class. Figures on
the owner's shot:

- 37.5M steps, +58 %;
- 7 transactions: `init`, 5 chunks of at most 8.96M, `outputs`;
- the world class is **76,920 CASM felts**, 3,837 above rapier's slim caller. The slim caller's margin is 645.

76,920 is under Starknet's own limit (81,920): only the programme's gate excludes it.

**The smallest change.** Either of these makes (e) meet the gate:

- **rapier's slim caller 3,192 CASM felts smaller** (`SlimSplitStep` at most 69,891). With the force events in
  `ForceEventsClass` (layout (f), +2.4M steps), 2,620 smaller.
- **A programme decision** to accept 76,920 for the world class (it is declarable).

The game side cannot close the gap alone. The chunk plumbing alone (the entry point, the loop, no rule, no view, no
edit) already costs 2,164 felts over the slim caller (§3.5).

**A `TickHook` stage slot, as hinted, does not close it either.** Its plumbing costs 379 CASM felts (measured through the
`Forces` slot). But the game still needs, next to the step:

- the calm rule's per-tick body views;
- the World edits: 9.1k (removal), 10.3k (sleep), 16.9k (insert) in the caller, or a world crossing.

Applying removals "inside the step" means compiling removal code into the caller.

| layout | world / game class (CASM) | owner's shot | Δ vs main | tx ≤ 10M (chunks) | fits the gate |
|---|--:|--:|--:|--:|---|
| main, in process (the baseline) | one class, not declarable (D9, D11) | 23.77M | | 3 | no |
| (a) game tick in the world class | 115,733 | 34.51M | +45.2 % | 4 | no (−42,005) |
| **(b) game class + step class per engine step** | **72,752 / 72,397** | **49.05M** | **+106.3 %** | **7** | **yes** |
| (c) world class + rules class, edits in the world class | 104,726 | 36.86M | +55.0 % | 4 | no (−30,998) |
| (d) (c) with the edits across a world crossing | 80,848 | 37.24M | +56.7 % | 5 | no (−7,120) |
| (e) (d) with the least code in the world class | 76,920 | 37.60M | +58.1 % | 5 | no (−3,192) |
| (f) (e) with the force events in `ForceEventsClass` | 76,348 | 39.97M | +68.1 % | 5 | no (−2,620) |

Shot steps are sums of 10-tick windows, each a chunk with its own entry and exit. Transactions are the greedy packing of
those windows. The chain measured through the deployed contract (§4) is slightly cheaper, with fewer chunk boundaries.

## Status after H2 (2026-09-28)

Lot H2 moved `crates/slingfall_split` into the root workspace (alpha.7 since lot B5; the shims, the nested `[workspace]`
and the crate's `Scarb.lock` are gone) and implemented the programme's decision on this report's escalation 2.

- **The game's layout is (e).** `slingfall_split::lean::WorldClass` (was `LayoutE`, with `lean::RulesClass`, was
  `LeanRulesClass`, and `classes::EditClass`). **Layout (b) is the fallback that passes 73,728 everywhere:**
  `classes::FallbackGame` (was `LayoutB`) with `classes::StepClass`.
- **Gates** (`python3 tools/classsize/classsize.py split`, in the CI `build` job, margins in the job summary): every
  declared class at most **73,728** Sierra and CASM felts, **except the world class, at most 78,000** (Starknet: 81,920).
  `WorldClass` is 76,920 CASM (margin 1,080 under 78,000); the tightest class under 73,728 is rapier's `OrchestratorClass`
  (73,554, margin 174), then `FallbackGame` (72,752, 976), `SettleClass` (1,173), `StepClass` (1,331). rapier is asked to
  shrink its slim caller so that the world class comes back under 73,728; the gate is then one constant
  (`WORLD_GATE`).
- **Layouts (a), (c), (d), (f) and the size fixtures** (`Plus*`, `Minus*`, `Stage*`, the tick-hook emulation) left the
  default build: they are `slingfall_split::probes`, built with the feature `probes` (`snforge test --features probes`,
  which `scripts/windows.py run` passes). `EditClass` keeps `apply` and `insert` (layout (d)'s entry points) so that
  the class is the same in both builds. The old `RulesClass` of (c) and (d) is `TypedRulesClass`.
- **Same figures.** Reproduced on the workspace build: the window probes of `m`, `e` (all 21), the owner's flight window
  of `a`, `b`, `c`, `d`, `f`, every transaction probe of the chain, both shots: identical to the tables above, to the
  step. Every declared class has the size it had (the table above), and `EditClass`, `StepClass` and rapier's stage
  classes keep their class hashes.
- **Hashes.** Every declared class's hash is a constant of `slingfall_split::hashes` (`pinned()`);
  `tests::hashes::test_pinned_class_hashes` fails, printing the stale ones, when a class changes without its constant;
  `python3 crates/slingfall_split/scripts/pin.py` regenerates them (`--probes` for the alternatives' class).
- **CI.** The default suite (6 tests: init, the chain of layout (e) on the reference shot, its two revert checks, the
  hashes) runs in the test matrix; the heavy probes stay `#[ignore]`. Two of them are recorded step probes
  (`steps/slingfall_split/`).

## Status after H3 (2026-09-28)

Lot H3 builds, gates, pins and declares only the classes the game's layout calls.

- **Measured** (`tests/called.cairo`, `python3 crates/slingfall_split/scripts/classes.py --measure`): the reference shot's
  whole chain, once per rapier class with that class left undeclared. Layout (e) (`WorldClass`) and the fallback (b)
  (`FallbackGame`) both fail on the same eight classes (`Class with hash ... is not declared`): `NarrowPhaseClass`,
  `ContactBallClass`, `ContactPolygonClass` (still called on alpha.7), `SolveAdvanceClass`, `IslandsClass`,
  `BroadPhaseClass`, `MassClass`, `ActiveSetClass`. They complete without `SolverClass` and without `ForceEventsClass`
  (`SlimSplitStages` solves in `SolveAdvanceClass` and collects the force events in process). That is the rapier
  orchestrator's list, without `ForceEventsClass`. `OrchestratorClass` (73,554 CASM) was built by the `::*` glob only.
- **One list**: `crates/slingfall_split/classes.json`. `scripts/classes.py` derives from it `Scarb.toml`'s
  `build-external-contracts` (module paths, not `rapier2d_classes::*`), the test harness's declarations,
  `hashes::pinned()` and the client's `SPLIT_BUNDLE_CLASSES`; `snip36.BUNDLE_CLASSES` reads it; `deploy-split` declares
  the bundle in `SPLIT_BUNDLE_CLASSES` order; `classsize split` fails on a built class that is not in the list. The
  service's unit test runs `classes.py --check`, the client's test compares the two orders.
- **Classes** 20 -> 17 built by the crate, 17 -> 15 declared by `deploy-split` (`OrchestratorClass`, `SolverClass`,
  `ForceEventsClass` gone). Every remaining class has the same size and the same class hash as after H2 (the two unused
  `ClassHashes` methods return an undeclared class hash and the compiler drops them), so the margins are H2's: the
  tightest are `FallbackGame` 976, `SettleClass` 1,173, `StepClass` 1,331 (gate 73,728) and `WorldClass` 1,080 (gate 78,000).
  Rapier's `OrchestratorClass` (margin 174) is out of the table.
- **Bundle hash**: `0x31e8cf85968b72f60645e8687591a8c7dacb476f60cbfe07fb9ef3341351fbd` (was `0x5bb15de9...c06f`).
- **Build** of `slingfall_split` (`scarb clean` then `scarb build -p slingfall_split`): 44.2 s before,
  45.9 s after, within noise: the crate's compile is dominated by the classes that stay.
- **Layout (f)** (`ForceEventsClass`, probes) is no longer built: re-running its probes needs
  `rapier2d_classes::forces::ForceEventsClass` added to `classes.json`'s `rapier` (and `classes.py`, `pin.py`).

## Status after B6 (2026-09-29)

Lot B6 moves the crate to rapier2d / rapier2d_classes / rapier_dynamics2d `=0.1.0-alpha.8` (`fixed` 0.4.0, `glam_core`
0.4.1). Step results are unchanged (the 11 goldens bit-identical with the same steps; the window probes of `m`
reproduce main's states), every class hash changes, and rapier's slim caller is smaller (`SlimSplitStep` 67,076 CASM,
was 73,083).

- **The world class fits the gate.** `WorldClass` is **71,076 CASM** (28,203 Sierra), margin 2,652 under 73,728:
  `WORLD_GATE = GATE` in `tools/classsize`. Every declared class is gated at 73,728; the smallest CASM margins are
  `WorldClass` 2,652, `NarrowPhaseClass` 5,356 (rapier's, now holding the polygon contacts), `FallbackGame` 6,102,
  `StepClass` 7,338, `SettleClass` 7,356.
- **Rapier's `WorldEditClass` replaces the game's `EditClass`.** The rules class writes the tick's edits as
  `rapier2d_classes::WorldEdit`s (`world::world_edits`: `Remove`, `Sleep`, and the pebble as a `BodyInsert` built
  from the same values as `insert_pebble`), `WorldClass` forwards them to `WorldEditClass::edit` unchanged, and
  `init`'s sleeps go through it too (`BuildClass` writes them, `SettleClass` returns `edit`'s calldata beside the
  rules, `SplitChain::init` splits it without decoding). The game's `EditClass` is `probes::layouts::EditClass`
  (layout (d) only). Measured both ways on alpha.8, same transaction boundaries:

  | | game's `EditClass` | rapier's `WorldEditClass` |
  |---|--:|--:|
  | edit class (CASM) | 55,440 | 51,865 |
  | `WorldClass` (CASM) | 71,076 | 71,076 |
  | owner's shot, 7 transactions (alpha.7 boundaries) | 35.43M | 35.52M |
  | of which `init` | 0.749M | 0.833M |
  | reference shot, 4 transactions | 15.84M | 15.93M |

  The world class compiles the same code (only the class-hash constant differs); the chunks cost 2-3k steps more
  each, `init` 84k more (the sleeps' framing through three classes). Not worse on the gate, the class count (one
  class of the game's less to keep) or the transactions; +0.25 % steps on a shot. Adopted.
- **Classes.** `ContactPolygonClass` is not called any more (its pairs are in `NarrowPhaseClass`), `WorldEditClass`
  is: `classes.py --measure` gives exactly `classes.json` (layout (e) and the fallback (b) both call
  `ActiveSetClass`, `BroadPhaseClass`, `ContactBallClass`, `IslandsClass`, `MassClass`, `NarrowPhaseClass`,
  `SolveAdvanceClass`, `WorldEditClass`). 16 classes built (was 17), **14 declared** by `deploy-split` (was 15).
  Bundle order: `SplitChain`, `BuildClass`, `SettleClass`, `WorldClass`, `OutputsClass`, `RulesClass`,
  `WorldEditClass`, `ContactBallClass`, `SolveAdvanceClass`, `IslandsClass`, `BroadPhaseClass`, `MassClass`,
  `NarrowPhaseClass`, `ActiveSetClass`. Bundle hash
  `0x8a629c64c8e6c34dcc4cd0f29fd51c2c34d19cefe83647335a98825ddd7368`, pinned in Cairo (`hashes::BUNDLE_HASH`, checked
  by `test_pinned_class_hashes`; `pin.py` rewrites it) and checked by the prover service's and the client's tests.
- **Bit-identity.** The 21 window probes of `e` and `m`, the 16 tick-by-tick probes (`ticks_`, layouts (b) and (e),
  both shots: main's state after every tick) and the whole chain on the reference shot (main's first state, main's
  outputs) pass on alpha.8 with `WorldEditClass`.
- **Steps, layout (e).** Window probes (each window its own chunk):

  | | flight | impact, owner | impact, reference | steady, owner | owner's shot | reference shot |
  |---|--:|--:|--:|--:|--:|--:|
  | main (`m`), unchanged | 20,208 | 211,631 | 266,250 | 198k | 23.77M | 9.79M |
  | (e) alpha.7 | 57,548 | 337,670 | 404,585 | 298k | 37.60M | 16.91M |
  | **(e) alpha.8** | **58,356** | **323,017** | **384,748** | **281k** | **35.61M** (+49.8 %) | **16.28M** |

  The greedy packing of the owner's windows under 10M is now 4 chunks (0-60, 60-90, 90-120, 120-151), was 5.
  Measured through `SplitChain` (`tests/transactions.cairo`, regenerated with those boundaries):

  | owner's shot, (e) | `init` | 0-60 | 60-90 | 90-120 | 120-151 | `outputs` | total |
  |---|--:|--:|--:|--:|--:|--:|--:|
  | steps | 0.833M | 8.414M | 9.215M | 8.190M | 8.556M | 0.077M | **35.29M in 6 transactions** (alpha.7: 37.50M in 7) |

  Reference shot: `init` 0.833M, 0-90 7.820M, 90-107 7.170M, `outputs` 0.105M (15.93M in 4). The fallback (b):
  owner 50.10M in 9, reference 30.03M in 6 (its chunk 0-50 is 9.64M, close to the limit). Step probes
  `steps_chain_e_reference` 16,268,725 (was 16,888,755), `steps_init_world_is_mains` 898,449 (was 934,075).
- **Proofs** (the planner budgets the node's L2 gas, 1.0e9 per virtual transaction; `docs/proving.md` "Cost sheet on
  alpha.8"): owner's shot 6 proofs, 10.12 STRK; reference shot 3 proofs, 5.25 STRK.

## 1. How it was measured

**Build.** `crates/slingfall_split` is its own workspace. The root workspace resolves one `rapier2d` version and is on
alpha.6 until lot B5 lands. It uses the game crates' own sources through `shims/`: manifests pinned to alpha.7 whose
`src` are symlinks to `crates/slingfall_{level,rules,game}/src`. Nothing is copied, and the shims go when B5 lands
(Escalations).

**The rules without the world (`src/rules.cairo`).** This is main's tick orchestration, line for line:

- `GameTrait::tick`, `CalmTrait::update`, `damage::apply` / `remove`, `sling::launch`, `GameTrait::end_shot`,
  `step_shot`;
- run on the entities rather than the world, with main's pure helpers reused (`damage_of`, `entity_of`, `clamp_pull`,
  `launch_velocity`, the D5 constants).

What the rules read of the world:

- the tick's force events as `Hit`s (both colliders and `total_force_magnitude`);
- a `View` of each watched body (sleeping, or translation and velocities).

What they return: `Op`s in main's order (removals, `sleep_all`'s sleeps), the pebble to insert before the next step,
and the bodies to watch.

Main's tick reads the world twice: the force events after the step, and the bodies after the damage removals. The
removals wake contact partners, and the calm test sees them. On a tick whose damage destroys something, the rules
therefore answer "calm pending": the world side applies the removals, takes fresh views, and calls `calm`.

**Slots (`src/world.cairo`, `src/chunk.cairo`).** One chunk loop (main's `step_shot` with a tick budget) and three
slots:

- the step: in process with `SlimSplitStages`, or a world crossing per step;
- the rules: in process, or a library call;
- the World edits: in process, or a world crossing.

Layouts (a)-(d) are instantiations. (e) and (f) have their own lean loop (`src/lean.cairo`).

**Against main.** Every check is bit for bit on the whole state: the world's felts (bodies, colliders, contact pairs with
their force-event statuses) and the rules state (every entity's `hp` and `alive`, the score, the calm counter, the pebble
and its contact flags).

- `scripts/fixtures.py`: main's own chunk states (its alpha.6 `init` / `step_chunk` executables, `scarb execute`) at
  ticks 0, 40, then every 10 ticks, for both shots, plus main's outputs.
- **Window probes** (`tests/windows_*.cairo`, every layout, 21 windows): each window runs in one chunk from main's state
  at its start and must end on main's state at its end. The `m` probes run main's own `chunk::step_state` on alpha.7 in
  the same harness (the in-process baseline); they also reproduce every alpha.6 state, which confirms B5's "step results
  unchanged".
- **Tick by tick** (`tests/ticks.cairo`, layouts (b) and (e), both shots, every tick): the world class steps one tick per
  chunk next to main's `step_state`, and the state must be equal after every tick. The force events are compared through
  their whole effect: the pairs' event statuses in the world, and every entity's `hp`.
- **The chain** (`tests/chain.cairo`, (b) and (e), the reference shot): `init` equals main's first state, the messages
  link, and `outputs` equals main's golden outputs.

| shot | player | pull | ticks | outputs (score, won, ticks) | `final_state_hash` |
|---|---|---|--:|---|---|
| reference | `'player'` | (-604, -392) | 107 | 5,200, 1, 107 | `0x3d6ed9e7…69db9f` |
| owner's | `'player'` (123610794124658) | (-1022, -63) | 151 | 5,300, 1, 151 | `0x64b76446…d6db7f48` |

## 2. Inventory: what each part of the game costs in a class

The first table gives each stage alone in a class. The second gives each part as the delta it adds to the class that
holds the world (`Plus*` fixtures minus `SlimCaller`). `SlimCaller` is rapier's `SlimSplitStep` rebuilt here at the
game's class hashes: 28,522 / **73,083** (margin 645), rapier's figure.

| stage alone (`src/inventory.cairo`, `src/chain.cairo`) | Sierra | CASM |
|---|--:|--:|
| world build (`StageBuild`: level validated, builders, inserts, basic codec out) | 13,114 | 34,857 |
| damage and removal bookkeeping (`StageDamage`, D6-D7, `Rules` codec both ways) | 2,370 | 6,276 |
| calm, out of bounds, tick cap, end of shot, scoring (`StageCalm`, D5-D7) | 3,812 | 9,450 |
| main's `ChunkState` decoded, encoded, hashed (`StageChunkCodec`, full `WorldState` codec) | 11,191 | 32,781 |
| the split state (basic codec and `Rules`) decoded, encoded, hashed (`StageSplitCodec`) | 9,383 | 27,595 |
| all the rules as a class (`RulesClass` / `LeanRulesClass`) | 5,609 / 6,174 | 14,114 / 15,165 |
| all the World edits as a class (`EditClass`: removal, sleep, pebble insert, init's sleeps) | 19,484 | 60,566 |

Scoring (D7) is a few additions inside the damage and calm stages and cannot be measured apart.

| next to the step (delta over `SlimCaller`) | Sierra | CASM |
|---|--:|--:|
| pebble insertion (`World::insert`, builders) | +6,202 | **+16,940** |
| one removal (`World::remove_body`) | +1,766 | **+9,103** |
| one sleep (`body`, `sleep`, `set_body`) | +2,037 | **+10,283** |
| the World edits together, in process (`PlusEdits`) | +8,796 | **+28,978** |
| the rules together, in process (`PlusRules`) | +5,376 | +15,573 |
| views of watched bodies: three field reads / one `body()` read / `iter()` | +476 / +321 / +408 | +1,826 / +1,309 / +1,392 |
| chunk loop and views (`PlusLoop`) | +698 | +2,244 |
| chunk loop, views, typed rules call (`PlusRulesCall`) | +1,619 | +4,904 |
| chunk loop, views, typed edit crossing (`PlusEditCrossing`) | +1,060 | +5,114 |
| SNIP-36 binding: Poseidon of the state in and out, the message (`PlusBinding`) | +385 | +747 |
| force events in `ForceEventsClass` (`MinusForceEvents`) | −204 | −572 |
| tick-hook plumbing in the `Forces` slot (`PlusHook`, §3.7) | +204 | +379 |

What the table says:

- **The World edits are what cannot sit next to the step**: 16.9k for the launch, 9.1k for a removal, 10.3k for a sleep.
  In one class ((a), (c)) they cost 29k.
- Crossing the world to a class that holds them costs 1-3k. The basic codec is already in the class, but its Serde is
  instantiated again at a new call site unless one decoding and one encoding site are shared (§3.5).
- **The rules are cheap anywhere**: a library call and compact data.

## 3. Layouts

Every layout uses rapier's stage classes as built here (alpha.7, `build-external-contracts`):

| stage class | Sierra | CASM |
|---|--:|--:|
| `NarrowPhaseClass` | 11,319 | 23,597 |
| `ContactBallClass` | 14,950 | 41,560 |
| `ContactPolygonClass` | 14,515 | 57,299 |
| `SolveAdvanceClass` | 37,044 | 58,547 |
| `IslandsClass` | 7,952 | 19,083 |
| `BroadPhaseClass` | 4,525 | 9,841 |
| `MassClass` | 13,297 | 35,686 |
| `ActiveSetClass` | 4,381 | 10,930 |
| `ForceEventsClass` (f only) | 2,832 | 6,202 |

Their hashes are rapier's pins (`tests/hashes.cairo`). The game's classes are pinned the same way (`scripts/pin.py`).

Steps per tick are window averages:

- **flight**: ticks 0-40 of either shot;
- **impact**: the window of the first contact (owner 40-50, reference 80-90);
- **steady**: owner 100-150.

| layout | flight | impact, owner | impact, reference | steady, owner | reference shot | Δ | tx |
|---|--:|--:|--:|--:|--:|--:|--:|
| main (`m`) | 20,208 | 211,631 | 266,250 | 198k | 9.79M | | 1 |
| (a) | 37,964 | 304,803 | 371,419 | 280k | 14.54M | +48.5 % | 2 |
| (b) | 171,960 | 412,929 | 483,328 | 356k | 28.08M | +186.9 % | 4 |
| (c) | 52,969 | 322,008 | 388,624 | 296k | 16.20M | +65.5 % | 2 |
| (d) | 55,903 | 334,843 | 401,469 | 296k | 16.53M | +68.9 % | 2 |
| (e) | 57,548 | 337,670 | 404,585 | 298k | 16.91M | +72.8 % | 2 |
| (f) | 68,084 | 357,815 | 426,093 | 314k | 18.36M | +87.5 % | 3 |

The heaviest 10-tick windows: owner 60-70 (421k per tick in (b), 348k in (e)); reference 100-107 (539k per tick in (b),
473k in (e)). A transaction always has room for a tick of any kind.

### 3.1 (a) The game tick inside the class that holds the world

`LayoutA`: the rules and the World edits in the slim caller's class. **115,733 CASM felts** (45,922 Sierra), 42,005
over the gate and over Starknet's 81,920. The overhead over main, +45 %, is `SlimSplitStages`' own (rapier measured
+47 % on its pile10 reproduction). Layout (a) is the step floor of every split layout.

### 3.2 (b) A game class owning the loop; rapier's slim caller once per engine step

`LayoutB` (the loop, the rules and the World edits, in process; the world decoded) and `StepClass`. Once per tick the
world crosses to `StepClass` and back with the basic codec; `StepClass` steps it with `SlimSplitStages` and returns it
with the force events. It is rapier's route (b) with the game in the orchestrated class.

- **Sizes:** `LayoutB` 23,658 / **72,752** (margin 976); `StepClass` 28,455 / **72,397** (margin 1,331). Both fit.
- **Steps:** the two codec round trips and the transfer of about 3,000 felts each way cost about 134k steps per tick
  over (a) (flight: 172k against 38k). Owner's shot 49.05M, +106 %; reference 28.08M, +187 %.
- **Transactions (chain, §4):** owner's shot 7 chunks (at most 8.30M) + `init` + `outputs`; reference 4 chunks.

A cheaper variant was not built: the step class could return the watched bodies' views, and the game class could keep the
world as felts (one codec round trip per tick instead of two, about −47k per tick, about −7M on the owner's shot). The
views add about 1.3k to `StepClass` (1,331 left), so that variant is borderline in size (§5).

### 3.3 (c) The world kept for K ticks, the rules called back per tick

`LayoutC` + `RulesClass`. The world class keeps the world for the chunk and applies the World edits itself. Per tick, one
rules call (two on a tick whose damage destroys) with the force events as hits and the watched bodies' views; the
removals, sleeps and pebble come back.

- **Sizes:** `LayoutC` **104,726** (30,998 over, and over 81,920): the World edits (§2). `RulesClass` 14,114.
- **Steps:** 36.86M (+55 %). The rules call costs about 15k steps per tick over (a): the rules state (148 felts)
  decoded and encoded in the class, the views, the call.

### 3.4 (d) (c) with the World edits across a crossing

`LayoutD` + `RulesClass` + `EditClass`. On the ticks that edit (the launch; a destruction; the end of the shot's sleeps and
pebble removal: 4-8 ticks per shot), the world crosses to `EditClass` and back. No edit, no crossing.

- **Sizes:** `LayoutD` **80,848** (7,120 over). `EditClass` 60,566.
- **Steps:** 37.24M (+56.7 %): the crossings cost about 0.4M over (c).

### 3.5 (e) (d) with the least code in the world class

`LayoutE` + `LeanRulesClass` + `EditClass`, the same rules and edits behind a leaner protocol:

- one rules call site, with the same calldata and the same answer for `begin`, `tick` and `calm`;
- the edit request is opaque to the world class, forwarded verbatim;
- the tick's edits and the next tick's launch go in one crossing;
- the views and hits are written straight into the calldata;
- one decoding site and one encoding site of the world (`#[inline(never)]` `load` / `save`), shared by the entry point
  and the edit crossing (−1.3k);
- the loop has one tail. The first version cloned its loop body per selector constant (Cairo's const specialization:
  three loops, +5.2k).

- **Sizes:** `LayoutE` **76,920** (3,192 over, 5,000 under 81,920). `LeanRulesClass` 15,165.
- **Steps:** 37.60M (+58.1 %).

Where its 3,837 felts over `SlimCaller` go (`scripts/levers.py`, throwaway builds, sizes only):

| lever on `LayoutE` | CASM | saves |
|---|--:|--:|
| `LayoutE` | 76,920 | |
| without the views | 76,136 | 784 |
| without the edit crossing | 75,960 | 960 |
| without the rules call and its answer | 76,377 | 543 |
| without the force events in the calldata | 76,796 | 124 |
| **the chunk plumbing alone** (entry point, loop, no rule, view or edit) | **75,247** | (+2,164 over `SlimCaller`) |

`scripts/attribution.py LayoutE SlimCaller` gives the same split in Sierra: 2,897 statements, the loop body 1,433 and the
entry point 648.

Slicing the answers instead of decoding them was measured and rejected: 77,743 (more code for the conversions).

### 3.6 (f) (e) with the force events in `ForceEventsClass`

`LayoutF`: (e) with rapier's `LibraryCallForceEvents` (CS6's lever 3, `src/stages.cairo`).

- **Sizes:** **76,348** (2,620 over): −572 as rapier measured.
- **Steps:** 39.97M (+68.1 %): +2.4M over (e), as rapier measured. The crossing sends every collider and every pair every
  step.

### 3.7 The tick hook (brief §7), emulated

A `TickHook` slot of `StageConfig` needs a `rapier2d` change: the spike cannot vendor `rapier2d`, and `rapier2d_classes`
does not own `StageConfig`. Its caller side is emulated in the slot the game can fill: `HookForces`, a `ForceEventStage`
that collects the force events in process (`collect_convex`, the game has no composite shape), then library-calls the
game's class with them in compact form.

- **Size:** `PlusHook`: **73,462** (+379 over `SlimCaller`, margin 266).

What the hook would not remove from the caller:

- the calm rule's views (+1.3-1.8k), since the hook gets no body motion;
- the World edits. Applied "inside the step", the removals compile removal code into the caller (`World::remove_body`:
  +9.1k); the sleeps (+10.3k) and the launch (+16.9k) too, unless they cross.

**So the hook alone does not make (c) fit.** A hook that received the watched bodies' motion (which the step holds after
the solve) and the force events, and left the edits to the game's crossing, would carry (e)'s protocol inside the step.
It would save at most the views and the loop's call site, not the 2.2k of chunk plumbing.

Folding the damage rule into `ForceEventsClass` (hint 2) would drop the events from the rules call (−124 CASM, lever
above). It would keep (f)'s +2.4M steps, because that class receives every pair every step.

## 4. Transactions: the chain

`src/chain.cairo`. One deployed contract, `SplitChain`. Its three entry points are the three kinds of proven
transaction; each library-calls the declared classes and sends **one L2→L1 message**, P1b's binding header with the new
state replaced by its hash. `to` is `'SLINGFALL'`; a hash is `hash_felts` (Poseidon, no length prefix) of the argument's
felts. The state is `world ++ rules`: the basic codec's felts (the `WorldState` felts), then the `Rules` felts,
length-prefixed.

| transaction | calls | message payload |
|---|---|---|
| `init(level)` | `BuildClass.build`, `SettleClass.settle` (the `dt = 0` step with `SlimSplitStages`), `EditClass.sleep_all` | `[LEVEL_HASH, STATE_OUT_HASH]` |
| `step_chunk(state, inputs, shot, k)` | the world class (`LayoutB` or `LayoutE`) | `[STATE_IN_HASH, INPUTS_HASH, shot, k, STATE_OUT_HASH]` |
| `outputs(state, inputs)` | `OutputsClass.outputs` | `[STATE_IN_HASH, INPUTS_HASH] ++ outputs` (the 10 D4 felts) |

| class | Sierra | CASM | margin |
|---|--:|--:|--:|
| `SplitChain` (deployed) | 1,515 | 3,218 | 70,510 |
| `BuildClass` | 13,364 | 35,335 | 38,393 |
| `SettleClass` | 28,464 | 72,555 | 1,173 |
| `OutputsClass` | 7,826 | 25,144 | 48,584 |

**Measured through `SplitChain`.** Each transaction is its own probe (`tests/transactions.cairo`), from main's state and
checked against main's. Steps include the hashing and the message. Calldata is the router's (the state, the inputs, shot
and `k`: world + rules + 11 felts). Owner's shot:

| tx | (b) steps | (e) steps | calldata in (felts) |
|---|--:|--:|--:|
| `init` | 767,511 | 767,475 | 147 (the level) |
| chunks | 0-40: 6.98M; 40-60: 8.24M; 60-80: 8.30M; 80-100: 7.24M; 100-120: 7.07M; 120-140: 7.09M; 140-151: 3.95M | 0-60: 8.76M; 60-80: 6.79M; 80-110: 8.96M; 110-140: 8.75M; 140-151: 3.39M | 2,906 at tick 0; 3,137 at 40; 1,998 at 60-80; 1,581 from 90 |
| `outputs` | 70,692 | 70,656 | 1,493 |
| **total** | **49.69M in 9 transactions** | **37.50M in 7 transactions** | |

Reference shot: (b) 0-50 8.62M, 50-80 5.21M, 80-90 4.91M, 90-107 9.02M (6 transactions, 28.62M); (e) 0-90 7.99M,
90-107 7.69M (4 transactions, 16.55M).

The whole-chain tests (`test_chain_b_reference`, `test_chain_e_reference`) run the shot through `init`, the chunks and
`outputs`, and check:

- one message per transaction, from `SplitChain`, to the marker;
- each chunk's `STATE_IN_HASH` is the previous `STATE_OUT_HASH`;
- `init`'s state is main's;
- the outputs are main's golden.

**What the proven transactions check themselves.** A transaction that fails a check reverts, and the virtual OS proves
no reverted transaction. P1b's verifier could read the public states; now the states are only hashes, so its state checks
run inside the transactions:

- **check 5** (the chunk's shot is the one in progress, is in the inputs, and the level is not over): the rules'
  `check_turn`, `'replay: shot'`, `test_chain_wrong_shot`;
- **check 6** (the last state is finished): `OutputsClass`, `'split: not finished'`, `test_chain_outputs_unfinished`;
- the inputs are validated against the level in `check_turn` (`inputs: *`).

**No panic on a valid level's path.** Every `unwrap` of the world side reads a body the rules watch: a live entity or the
pebble. The rules return exactly one view slot per watched body, and `shots − shots_used` never underflows after
`check_turn`. The remaining panics are:

- malformed calldata;
- a class hash that is not declared (a deployment error);
- the 10M-step limit. The prover's scheduler runs the chain locally first (the prover executes before proving) and picks
  `k` so that each transaction stays under about 9M. A tick costs at most about 540k in (b) and 473k in (e) on these
  shots, so there is always room for one more tick.
- `l2_gas.max_amount` must be about 1.1e9 (SN1's trap: 1e8 is about 1M steps).

**How a real contract links and finalises the chain** (R6 §1a "Parallel", contract v3; not built here):

1. **Prove in parallel.** The prover runs the chain locally, then proves every transaction at once, each in its own
   virtual block on the same base block. The state travels as calldata, so no chunk needs the previous one on chain. The
   same account and nonce may sign every virtual transaction, since none executes on chain (inf). `SplitChain` must be
   deployed, and every class declared, at least 10 blocks before the base block.
2. **Submit.** One real Invoke per proof carries `proof` and `proof_facts`. `submit_chunk(kind, payload)` checks the facts
   as SN1 §4 prescribes:
   - `facts[2]` is in the allowed virtual-OS program set;
   - `n = facts[7]`;
   - `Poseidon([SplitChain, MARKER, len(payload), ...payload])` is among `facts[8 .. 8 + n)`.

   Then it stores by kind:
   - `init`: `start[LEVEL_HASH] ∋ STATE_OUT_HASH`;
   - chunk: `edge[(INPUTS_HASH, STATE_IN_HASH)] = (shot, k, STATE_OUT_HASH)`;
   - `outputs`: `end[(INPUTS_HASH, STATE_IN_HASH)] = outputs`.

   Submissions are idempotent and may come in any order and from any account.
3. **Finalise in the `outputs` submission** (or a separate `finalize`), given `level_hash`, `inputs_hash` and the list of
   state hashes `H_0 … H_n`:
   - `H_0 ∈ start[level_hash]`;
   - every `edge[(inputs_hash, H_i)]` leads to `H_{i+1}`;
   - `end[(inputs_hash, H_n)]` exists;
   - its outputs carry `level_hash` and `inputs_hash` (P1b checks 7-8).

   Then the contract records the result as `submit_settled` does today (nullifier `poseidon(level_hash, player,
   inputs_hash)`, `player == caller` or a relayed settled record). That is n + 2 proofs and n + 2 real transactions per
   shot (a real transaction carries one proof), at SN1's flat 75M L2 gas each: 9 for (b), 7 for (e) on the owner's shot.

## 5. Verdict

- **A layout fits today: (b).** Every class is at most 73,728, the results are bit-identical tick by tick, and the owner's
  shot is 9 proven transactions of at most 8.30M, 49.7M steps. Price: +106 % steps over `main` in process, and 2 more
  proofs than (e).
- **The layout the game wants is (e)** (+58 %, 7 transactions). It is **3,192 CASM felts over the gate** and declarable
  on Starknet (76,920 < 81,920). The smallest change that makes it fit is on rapier's side: `SlimSplitStep` at most
  **69,891 CASM felts** with the same results (or at most 70,463 if the game takes `ForceEventsClass`'s +2.4M steps).

  Where the slim caller's code is (`scripts/attribution.py SlimCaller --modules`, Sierra statements, 50,939 in all):

  | module | share |
  |---|--:|
  | `rapier2d::pipeline::active_set` (of which `sparse_step` 13.3 %) | 21.0 % |
  | the basic codec | 5.7 % |
  | `step_internal` | 5.4 % |
  | arenas | 5.2 % |
  | user changes | 4.9 % + 3.4 % |
  | collision inputs | 3.9 % |
  | sleeping | 3.2 % |

  The alternative is the programme's: accept the world class at 76,920 (the gate is the programme's margin under
  Starknet's limit).
- **Not recommended:** (a) and (c) (the World edits next to the step, 29k); (f) (+2.4M steps for 572 felts); a
  `TickHook` slot as the fix (§3.7).
- A cheaper (b) is possible (§3.2): the step class returns the views, and the game class keeps the world as felts. It
  was not built: it is borderline in size and saves about 7M steps, leaving it still about 1.7× (e).

## 6. Reproduction

```
python3 crates/slingfall_split/scripts/fixtures.py            # main's chunk states (alpha.6 executables)
python3 tools/classsize/classsize.py split                     # every class, margins to 73,728
python3 crates/slingfall_split/scripts/levers.py               # throwaway lever builds of LayoutE
python3 crates/slingfall_split/scripts/attribution.py LayoutE SlimCaller
python3 crates/slingfall_split/scripts/windows.py gen          # the probe files
python3 crates/slingfall_split/scripts/windows.py run setup m a b c d e f tx   # heavy lock, one thread   # (a), (c), (d), (f): feature `probes`, passed by the script
python3 crates/slingfall_split/scripts/windows.py table crates/slingfall_split/target/logs/*.log
python3 crates/slingfall_split/scripts/heavy.py snforge test ticks_ --include-ignored --max-threads 1
python3 crates/slingfall_split/scripts/heavy.py snforge test          # the default suite
```

Peak RSS: at most 4.4 GiB per run (one thread). No run was killed.
