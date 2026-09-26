# G7c — two-class contract: `Slingfall` (registry, submit) + `SlingfallSim` (simulate) via `library_call_syscall`

## 1. Read first
`AGENTS.md`; `docs/DESIGN.md` D9 (two-class layout decided 2026-09-26); on `main`: `crates/slingfall_contract/`
(the `Slingfall` contract under `submit`, `simulate.cairo` + `simulate/replay_hook.cairo`, `verifier.cairo`,
tests), `crates/slingfall_sizes/` (G7b: `SplitCore` / `SplitSim` fixtures and their two tests are the measured
model: reuse their shape), `tools/classsize/classsize.py`.

## 2. Scope (allowlist)
`crates/slingfall_contract/**`, `crates/slingfall_sizes/**` (retire the split fixtures if they duplicate the
real contract, keep the (a)-(e) ladder), `steps/slingfall_contract/*.snap`, `tools/classsize/**` (a `check`
subcommand: the registry class under the three limits, in CI), `.github/workflows/ci.yml` ONLY to run
`classsize.py check` in the existing `steps` or `build` job.

## 3. Work
1. `SlingfallSim`: a `#[starknet::contract]` (or a library class: no storage) exposing
   `simulate(level: Array<felt252>, inputs: Array<felt252>) -> Outputs` (pure: decode, validate, `play` with
   `NoopObserver`); declared separately; its class hash stored in `Slingfall` (`sim_class_hash`, admin-settable,
   like `virtual_os_hash`).
2. `Slingfall::simulate(level_hash, inputs)`: loads the level felts, `library_call_syscall(sim_class_hash,
   selector!("simulate"), calldata)`, deserialises `Outputs`, sends the D9 message from its own context, returns
   the outputs. Everything else unchanged (`submit`, verifiers, registry, admin, events).
3. Tests: the existing 41 + the G4b golden (`simulate(pile10, reference)` ≡ `main`'s felts) through the
   library call (`declare` both classes in snforge, set the hash); a test that an unset `sim_class_hash`
   panics `'simulate: class'`; steps of `submit` unchanged; `steps_simulate__pile10_reference` reported
   (expected +≈ 6 800 over the single-class golden).
4. `classsize.py check`: fails if `Slingfall` exceeds 81 920 Sierra felts, 81 920 CASM felts (compile CASM with
   `starknet-sierra-compile` if present in the toolchain, else skip with a note) or 4 089 446 bytes; prints
   `SlingfallSim`'s figures without failing (known 5.3x, rapier CS lots).

## 4. Budget
`simulate` through the library call ≤ +0.05 % steps vs the single-class golden.

## 5. Tests
As above; `snforge test -p slingfall_contract`, `scarb build -p slingfall_contract` must show the `Slingfall`
class under the limits (no size warning for it; the warning for `SlingfallSim` remains and is expected).

## 6. Definition of done
`AGENTS.md` §6; conventional commits with the trailer `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`; push
`feat/g7c-two-class-contract`; `gh pr create`; `gh pr checks --watch` until green; never merge; `REPORT.md`
(Summary · API · Size table of both classes · Steps · Deviations · Escalations · PR URL).

## 7. Work autonomously, do not ask questions, do not widen the scope.
