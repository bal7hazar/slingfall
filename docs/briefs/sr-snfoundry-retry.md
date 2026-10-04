# SR — a retry for `setup-snfoundry` in the `test` job

Profile `impl-sonnet` (a small workflow change, the form given). Lot id `sr-snfoundry-retry`, branch
`ci/sr-snfoundry-retry`.
**Workflow file changed by this lot: `.github/workflows/ci.yml`** (rule nexus #60).

## 1. Goal and context

CP (#76) retries `setup-scarb` through `Wandalen/wretry.action`. It cannot do the same for
`foundry-rs/setup-snfoundry@v6`: that is a composite action, and wretry runs only JavaScript and Docker actions. So the
`test` job (`ci.yml` around line 233) installs snforge with no retry, and an HTTP 500 on the download fails the leg.

The owner's decision, installed as nexus #69, allows this one form, under three conditions:
- the first attempts may carry `continue-on-error: true`;
- a **last step re-runs the same `setup-snfoundry` action with the same inputs, without `continue-on-error`**;
- that last step's `if:` is true **only when every earlier attempt failed**, for example
  `steps.snf1.outcome == 'failure' && steps.snf2.outcome == 'failure'`;
- **`continue-on-error` appears on no other step and on no job.**

**How to edit:** with the file-editing tool only, never by a script that rewrites the workflow.

## 2. Transactions

None.

## 3. Scope (allowlist)

- `.github/workflows/ci.yml`: the `setup-snfoundry` step of the `test` job, and its comment.
- `REPORT.md` (not committed).

## 4. Work

1. Replace the single `uses: foundry-rs/setup-snfoundry@v6` with three steps:
   - `id: snf1`, `continue-on-error: true`;
   - `id: snf2`, `if: steps.snf1.outcome == 'failure'`, `continue-on-error: true`, after a short pause: a
     `run: sleep 10` step guarded by the same `if:`;
   - the last one, `if: steps.snf1.outcome == 'failure' && steps.snf2.outcome == 'failure'`, with **no**
     `continue-on-error`, after a second pause guarded by that same two-outcome `if:`.
   The pause steps carry no `continue-on-error`. Note that `steps.snf1.outcome` is `success` when the first attempt
   works, so the other steps are skipped, as intended.
   All three use the same action and the same inputs (none today). Use `outcome`, not `conclusion`:
   `conclusion` is `success` when `continue-on-error` hid a failure.
2. Update the comment above the steps: no wretry here, for the reason given, and this three-step form per nexus #69.
3. Check, by reading the whole file, that `continue-on-error` appears on these two steps only (`grep -n
   continue-on-error .github/workflows/ci.yml`), and on no job.
4. **Verification:** both paths, since the happy path alone cannot tell a working retry from a dead one (a typo in an
   `id` leaves the retry skipped forever).
   - The happy path: the PR's own run touches the workflow, so every job runs. The `test` legs pass with `snf1`
     succeeding, and the log shows `snf2`, the pauses and the last step skipped.
   - The retry path, proven once in this PR: a scratch commit that makes `snf1` and `snf2` fail on purpose, for
     example by giving those two steps only a `version:` that does not exist. Its run must show `snf2` run after `snf1`
     failed, the last step run and succeed, and the `test` legs pass. Then push a revert commit. Both commits stay in
     the PR's history and are squashed at the merge.

## 5. Machine

The VPS. No Cairo build. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer.
- Run `scripts/prepush.sh` before pushing.
- Push `ci/sr-snfoundry-retry` once, then `gh pr create`. At most one `gh` call every 5 minutes.
- Never merge; launch no agent and no review.
- `REPORT.md`: the diff, the grep of `continue-on-error`, and the run's links.

Work autonomously, do not ask questions, do not widen the scope.
