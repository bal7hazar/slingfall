# D1 — every hashed, sized or measured build runs on one compiler thread (compile drift, SPK-13)

## 1. Facts (measured by the Grim World project on this VPS, Scarb 2.20.1 and 2.19.4, relayed 2026-10-01)
The Cairo compiler's Sierra output is not deterministic across builds when it runs on several threads: 20 clean
builds of a minimal case gave 20 distinct Sierra files (a `withdraw_gas` check placed in one function 12 times, in
another 8 times); with `RAYON_NUM_THREADS=1`, 6 of 6 builds were identical. The machine's `scarb` / `snforge` shims
set `RAYON_NUM_THREADS=4`. This game pins class hashes (`crates/slingfall_split/src/hashes.cairo`, the bundle hash), a
program hash on Sepolia (`c1main`), class sizes against a 73,728-felt gate, and step snapshots: all of them depend on
the exact output.

## 2. Read first
`AGENTS.md`; `OPERATIONS.md`; `tools/classsize/classsize.py`, `crates/slingfall_split/scripts/{pin,classes,heavy}.py`,
`scripts/steps.py`, `tools/golden/golden.py`, `client/vm/scripts/fetch-executables.sh`, `tools/atlantic/atlantic.py`
(`program-hash`), `deploy/split.ts` (`deploy-split` builds), `deploy/devnet.sh proven`, `scripts/play.sh` (split build),
`.github/workflows/ci.yml`.

## 3. Scope (allowlist)
The scripts above, `.github/workflows/ci.yml`, `docs/proving.md` (one paragraph "Deterministic builds"),
`docs/research/07-split-game-step.md` ("Status after D1"). No Cairo source change, no deployment, no credentials.

## 4. Work
1. Every build whose output is hashed, sized, declared, snapshotted or measured runs with `RAYON_NUM_THREADS=1`
   (set by the script itself, not left to the caller): class sizes and pins, the bundle, `c1main` and the replay
   executables, step snapshots, goldens, the devnet declarations, the client's executables. Builds that only run
   tests may keep the shim's threads.
2. A determinism check in CI: the split classes are built twice from clean in the `build` job (one thread) and their
   class hashes compared; the job fails on a difference. Also compare the pinned hashes with a one-thread build of
   `main` today and report whether they move (if they do, say which classes, and regenerate the pins in this PR:
   that is a hash change for the devnet only, Sepolia v3 is not deployed).
3. Measure and report: the build time of the split classes with 1 thread versus 4 (the cost of the rule), and whether
   `c1main`'s program hash on one thread equals the pinned Sepolia hash `0x580ef5d1…edf75a` (if not, STOP and report:
   a re-pin is a transaction the project manager decides).
4. Document the rule in `docs/proving.md`.

## 5. Definition of done
`AGENTS.md` §6; conventional commits with the trailer of the model you are; push `feat/d1-deterministic-builds`;
`gh pr create`; `gh pr checks --watch` in the foreground until green; never merge; `REPORT.md`. Foreground only: never
end your turn on a background command or a watcher. Heavy builds under the heavy-run lock. Work autonomously, do not
ask questions, do not widen the scope.
