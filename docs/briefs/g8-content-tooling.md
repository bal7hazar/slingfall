# G8 — content and editor tooling: pre-settle, level validator, five levels, material tuning

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D2, D5, D6, D7, D10, D12; `docs/PLAN.md` (budgets; the G3 static-load note in
`crates/slingfall_rules/README.md`); on `main`: `tools/levelc/` (JSON <-> felts, `to-cairo`), `tools/golden/golden.py`
(how a level is run through `scarb execute`; the `fuzz` machinery), `tools/tracec/tracec.py`,
`crates/slingfall_replay/README.md` (argument layouts), `fixtures/levels/*.json` (hand-placed poses),
`client/public/levels/` (served copies, see `client/README.md`).

## 2. Scope (allowlist)
`tools/settle/**` (new, Python stdlib + `scarb execute`), `tools/levelc/**` (validator additions),
`fixtures/levels/**`, `client/public/levels/**` (served copies + the index the client reads, if one exists;
else escalate), `fixtures/golden/**` ONLY new cases for the new levels (run `tools/golden/golden.py --update`
for them; existing goldens untouched), `docs/levels.md` (new: authoring guide).

## 3. Work
1. **Pre-settle tool** `tools/settle/settle.py <level.json> --ticks N --out settled.json`: runs the replay
   with no shots (`init` then `step_chunk` with an empty shot? if the executables cannot step without a shot,
   add nothing to Cairo: instead use `main_trace` with a shot whose pull is (0, 0) on a level with `shots = 1`
   and `tick_cap = N` and read the last frame's poses; document the trick) until every dynamic body is asleep,
   writes the settled poses back (raw felts, exact), and reports the settle tick and the total drift.
2. **Level validator** in `levelc.py check --rules`: zero damage over 120 ticks at rest (run `main_trace`
   with a (0,0) pull and assert no `damage` line), every core reachable by at least one pull of a small
   grid (a coarse search of 12 pulls: at least one `destroyed` core event), `tick_cap ≥ 140`, step budget:
   the reference-style best pull under `3e7` (or the interim 1e8) Cairo steps, reporting the number.
3. **Five levels** (8-10 blocks + 2-3 cores each, pre-settled, validated): `pile10` (fixed), `cores3`
   (fixed), plus three new ones with distinct structures (a tower, a bridge with a hanging core on a
   plank, a two-pile layout); names are the working names of D12 (no reference to any existing game).
4. **Material tuning** (D12 values): adjust `force_threshold` / `damage_per_impulse_dt` / `hp` so that a
   pre-settled level at rest takes zero damage even when awake (the G3 static-load note), a direct pebble
   hit destroys 1-3 timber blocks, slate needs a good hit, frost shatters; document the measured values and
   the pulls used in `docs/levels.md`. Do not change `Material`'s layout.
5. Golden cases for the three new levels (reference pull each) via `golden.py --update` on the new cases only.

## 4. Budget
Each new level's reference shot ≤ 1e8 steps (interim), report the figure; aim under 3e7 where the layout allows.

## 5. Tests
`levelc.py check --rules` green on the five levels (in CI through the existing `golden` job only if it stays under
its time; else document the command); `settle.py` round trip: settling an already settled level moves no pose.

## 6. Definition of done
`AGENTS.md` §6 (tools + fixtures only; run `tools/golden/golden.py --check` on the touched cases); conventional commits
with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push `feat/g8-content-tooling`;
`gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md` (Summary · Levels table (blocks, cores,
settle tick, reference pull, steps, score) · Materials table · Deviations · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
