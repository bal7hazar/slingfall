# H4 — `play-local` CI job: wait for the finalize receipt; `doctor` accepts any Node 24 that asdf has

## 1. Read first
`AGENTS.md`; `OPERATIONS.md`; `scripts/play.sh`, `scripts/play/**` (`check.ts`, `doctor.sh`), `docs/play-local.md`,
`.github/workflows/ci.yml` (job `play-local`); the failing run on `main`: CI run 36732025089, job `play-local`:
`Error: pile10-reference: attempt() = 1 after the proven job (... "finalizeTransactionHash": "0x1d13…", "relayState": "off" ...)`.

## 2. Defects
1. **Race in `check.ts`**: after the proven job reports `proven`, the check reads `attempt()` before the `finalize`
   transaction is included (the job carries its hash). The job passed on the L1 pull request and fails on `main`
   since (two runs). Wait for the receipt of `finalizeTransactionHash` (and of the relay's settle transaction for the
   settled tier) before reading `attempt()`, with a bounded timeout and a clear message.
2. **`doctor` on a Mac with several Node versions** (lot L2's report): it found Node 22 on PATH and stopped, while
   asdf may hold a 24.x. `doctor` and `play.sh` accept any Node with major 24: if the shell's `node` is not 24 but
   asdf has a 24.x installed, use it through `asdf exec` / `ASDF_NODEJS_VERSION` for the commands `play.sh` runs, and
   say so; if none is installed, the `MISS` line stays with its install hint.

## 3. Scope (allowlist)
`scripts/play.sh`, `scripts/play/**`, `docs/play-local.md`, `.github/workflows/ci.yml` (the `play-local` job only).
No Sepolia access, no credentials.

## 4. Definition of done
`AGENTS.md` §6 (client lint / test if `client/` is touched: it is not); the `play-local` job green on the pull
request twice (re-run it once); conventional commits with the trailer of the model you are; push
`feat/h4-play-local-ci-race`; `gh pr create`; `gh pr checks --watch` in the foreground until green; never merge;
`REPORT.md`. Foreground only. Work autonomously, do not ask questions, do not widen the scope.
