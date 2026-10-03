# PH — CI fails when `c1main`'s program hash differs from the pin

Profile `impl-sonnet` (a CI job following a documented recipe). Lot id `ph-program-hash-gate`, branch
`ci/ph-program-hash-gate`.
**Workflow file changed by this lot: `.github/workflows/ci.yml`** (rule nexus #60).

## 1. Goal and context

Sepolia's contract accepts proofs only of the pinned `c1main` program. The pin is
`0x5dc8c8e25ea0b022da820ca7c14ce16cc228f24677a6c8a3c46bb0f9d41360` today, and it appears in:
- `deploy/slingfall.ts` (`CHILD_PROGRAM_HASH`);
- `deploy/sepolia.json` (`program.current`);
- the latest record, `fixtures/proofs/atlantic/child-hash-scarb-2.20.1.json`.

**No CI job recomputes that hash.** `client/src/chain/config.test.ts` only compares committed files with each other.
A Cairo change that moves the program (rapier, the game rules, the replay, the toolchain) therefore passes CI with a
stale pin, and the mismatch shows only on Sepolia. The split class-hash pins are already gated (`test (slingfall_split)`
and the probe step); this lot gates the program hash the same way.

The program hash is CASM-side and does not depend on the build root (the TC record says so, measured), so CI's runner
computes the same value as the VPS.

**How to edit:** with the file-editing tool only, never by a script that rewrites the workflow. Refused constructs:
`continue-on-error` (except the nexus #69 setup retry form), `if: false`, a narrowed test command, a deleted job.

## 2. Transactions

None. The lot only reads the pin; it never sends a re-pin.

## 3. Scope (allowlist)

- `.github/workflows/ci.yml`: one new job, `program-hash`, its `changes` filter, and its place in `all-checks`.
- `tools/atlantic/program-hash.sh` (new), if a script keeps the job short. It is the recipe of `docs/proving.md`
  ("Reproduce"), trimmed to the hash.
- `docs/proving.md`: one line saying CI checks the pin.
- `REPORT.md` (not committed).

## 4. Work

1. **The `program-hash` job** follows the recipe of `docs/proving.md` "Reproduce", up to the hash:
   - check out HerodotusDev/starkware-cairo-vm at `da8e48c62ab1383f6d7a410e5d2151033e40b544`, apply
     `tools/atlantic/cairo-vm-cairo-lang-2.20.0.patch`, and build `cairo1-run` with `cargo build --release`.
     - Pin the Rust toolchain (`cargo +<version>`, say which), or put the `rustc --version` output in the cache key.
     - Cache the built binary, keyed on the revision, the patch's hash and that toolchain, like the `prove` job's stwo
       cache.
   - set up scarb in the **wretry form the other jobs use**, never with `continue-on-error`;
   - build `tools/atlantic/c1main` with `RAYON_NUM_THREADS=1` (already set workflow-wide);
   - `tracec.py args` on `one_block --shot=-150,-150`, `atlantic.py c1-input`, `cairo1-run … --cairo_pie_output`, then
     `atlantic.py program-hash --pie`;
   - read the pins strictly. Each must be present and match `^0x[0-9a-f]{1,64}$`, or the job fails: a missing or
     unparsable pin is a failure, never an empty match.
     - `CHILD_PROGRAM_HASH` in `deploy/slingfall.ts` (`const CHILD_PROGRAM_HASH = '0x…'`);
     - `program.current` in `deploy/sepolia.json` (read with `json`, not grep);
     - **the record:** exactly one `fixtures/proofs/atlantic/child-hash-*.json` must have `child_program_hash` equal to
       the computed hash. Today that is `child-hash-scarb-2.20.1.json`. Name order means nothing: `alpha8` sorts after
       `scarb-2.20.1`, and the older files hold older hashes.
   - compare the computed hash with the first two pins, and check that the record exists. **Fail on any mismatch**,
     printing the
     computed hash and each pinned one, and the line "the c1main program moved: this PR must carry the Sepolia re-pin
     plan (OPERATIONS.md §7): its brief names the pin_program transaction".
2. **Path gating** (CP's `changes` job): the job runs only when `c1main`'s inputs or the pins change:
   - `tools/atlantic/**` (c1main's sources, the patch, atlantic.py);
   - `crates/**` (the replay and the crates it depends on);
   - `tools/tracec/**`, `fixtures/levels/**`;
   - `deploy/slingfall.ts`, `deploy/sepolia.json`, `fixtures/proofs/atlantic/**`;
   - `T`: the toolchain, every `Scarb.toml` and `Scarb.lock`, the workflow.
   On push to main it always runs.
3. **`all-checks`**, with the same fail-closed logic as the other jobs. In `ci.yml` that takes three places:
   - a new filter key and output in the `changes` job;
   - `program-hash` in `all-checks`'s `needs:`;
   - a `program-hash:${{ needs.changes.outputs.<key> }}:${{ needs.program-hash.result }}` entry in its `JOBS` list.
   Adding `needs` alone would leave the job unchecked.
4. **Verification:**
   - the PR's own run (it touches the workflow, so the job runs): the job passes on main's code, showing the computed
     hash equal to the pin;
   - **prove once, in this PR, that it fails on a wrong pin:** a scratch commit that changes one digit of the pin in
     `deploy/slingfall.ts` **and** one digit of `program.current` in `deploy/sepolia.json`, pushed. Its run must show the
     job red, with both mismatches named; the `client` job's `config.test.ts` also goes red, as expected. Then a revert
     commit, pushed. Both stay in the PR's history and are squashed at the merge. No separate scratch PR.
   - The push hook runs on both commits. Never skip it. If it refuses the scratch commit, stop and report its output.
   - Report the job's wall time, cold and with the cache, measured from the runs.
     - **Target: at most 5 minutes with the cache.**
     - If the cached run exceeds 10 minutes, stop before choosing another way, and report the measured times of each
       step (the fork build, the `c1main` build, `cairo1-run`, `program-hash`).
     - A cold run may be longer: report it.

## 5. Machine

The VPS and CI. If you build `cairo1-run` or `c1main` on the VPS to test the script, do it under
`flock -w <s> ~/orchestrator/heavy-build.lock env HEAVY_BUILD_LOCK_HELD=1 …`. When you build `c1main` there, wrap the
build in `/usr/bin/time -v` and report its peak RSS, its wall time and `free -m` at the start (a programme
measurement).

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing.
- Push `ci/ph-program-hash-gate` once, then `gh pr create`. At most one `gh` call every 5 minutes.
- Never merge; launch no agent and no review.
- `REPORT.md`: the job, the runs (passing and the scratch failure), the wall times.

Work autonomously, do not ask questions, do not widen the scope.
