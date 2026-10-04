# CH — the client hosted on slingfall.bal7hazar.com (files for the owner, on Grim World's model)

Profile `impl-sonnet` (a build output, a script and a doc section). Lot id `ch-client-hosting`, branch
`feat/ch-client-hosting`.

## 1. Goal and context

The attestation service is online at `https://attest.bal7hazar.com`, and it allows the browser origin
`https://slingfall.bal7hazar.com` only. The client should be served from that origin.

The project manager's request: prepare it on the model of Grim World's site. That means three things, and the owner
sets the Caddy site and the DNS:
- a build output;
- an install step;
- a `docs/hosting.md` section with the exact Caddy block.

**GitHub Pages stays as it is** (`ci.yml`'s `pages` job) until the owner says otherwise.

**Grim World's model, as it stands on the VPS** (read-only; touch nothing there):
- `/home/claude/site/grimworld/releases/<sha>-<UTC time>/`, one directory per deploy;
- a `current` symlink to the live release;
- `deploy.lock`, and `deploy.log` (one line per deploy: time, sha, result, duration);
- `deployed`, holding the last sha.
Find, read-only, which script writes it (look for its log format), and follow its conventions where they fit. If you
cannot find it, design the same layout from what you see, and say so.

## 2. Transactions

None.

## 3. Scope (allowlist)

- `scripts/site-deploy.sh` (new), the install step. Given a commit (default: `origin/main`'s), it:
  - builds the client's Sepolia build from a clean export of that commit (`git archive`, not the working tree), with
    the base path `/`;
  - copies it to `/home/claude/site/slingfall/releases/<sha>-<UTC time>/` and flips `current` atomically
    (`ln -sfn` on a temporary name, then `mv -T`);
  - runs under `flock` on `deploy.lock`, appends to `deploy.log` and writes `deployed`;
  - keeps the last five releases, and removes only directories it created, by exact name, never by wildcard.
  It installs no timer and no service: when and how often it runs is decided later.
- `scripts/play/vite.config.mts` or `client/vite.config.ts`: only if the base path or the wasm's content type needs
  it.
- `docs/hosting.md`: a new section "The client on slingfall.bal7hazar.com", with:
  - the exact Caddy site block for the owner: `root` on `/home/claude/site/slingfall/current`, `file_server`,
    `encode zstd gzip` (the wasm included), a fallback to `index.html` for the page's routes if it has any, long-lived
    cache headers on hashed assets and `no-cache` on `index.html`, and `application/wasm` served right;
  - how to run `scripts/site-deploy.sh`, roll back (point `current` at an older release), and read `deploy.log`;
  - the note that Caddy's admin API is off, so a config change takes `systemctl restart caddy`;
  - the note that Pages stays as it is.
- `REPORT.md` (not committed).
- Not `.github/**`; not the attestation service's files.

## 4. Work

1. Write the script and the section.
2. Run the script once on the VPS into `/home/claude/site/slingfall/`. Serve that `current` locally with a static
   server on 127.0.0.1 (for example `npx serve` or `python3 -m http.server`). Load it in headless Chromium (the
   harness of `docs/captures/m6/capture.mjs`): the page reaches its first playable frame, and the wasm loads with the
   right content type.
3. Check the Caddy block with `caddy validate` or `caddy adapt` on a temporary file, if the binary is available to
   you. Otherwise say it was not checked.
4. Run the script a second time: two releases, `current` flipped, the log has two lines. Then roll back once and show
   `current` again.

## 5. Machine

The VPS. No Cairo build: the client uses the committed executables, and the wasm runner is built by
`client/vm/scripts/build.sh` if the build needs it. Foreground only.

## 6. Definition of done

- Conventional commits with your model's trailer. Run `scripts/prepush.sh` before pushing.
- Push `feat/ch-client-hosting` once, then `gh pr create`. At most one `gh` call every 5 minutes.
- Never merge; launch no agent and no review.
- `REPORT.md`: the script, the two deploys and the rollback, the headless check, the Caddy check.

Work autonomously, do not ask questions, do not widen the scope.
