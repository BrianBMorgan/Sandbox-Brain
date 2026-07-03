# Runtime topology — how the live deploy is actually wired

> Written 2026-07-03 (credential incident) and updated the same day after the entrypoint cutover. Supersedes `CLAUDE.md`/`README.md` where they conflict. History first, then the current state and the one remaining gap.

## History: the override that bypassed the entrypoint (pre-2026-07-03)

For an unknown period the Render service ran a **Docker Command override** (`gitnexus serve --host 0.0.0.0 --port 10000`) that **bypassed `entrypoint.sh` entirely**. Consequences while it was in place — all since resolved, recorded so the failure mode is recognizable:

- **HAProxy never started.** `gitnexus serve` ran directly on the service port, so every "HAProxy fronts `/api/*`", "enforces the `API_KEY` Bearer at the edge", and the QUIC/TLS plumbing in `CLAUDE.md` described code that didn't run.
- **All REST + MCP routes were unauthenticated.** `gitnexus serve` has no built-in auth (verified in 1.6.5 source — the `API_KEY` gate lives *only* in the HAProxy config the entrypoint generates), and `API_KEY` wasn't even set on the service.
- **The entrypoint credential helper (PR #31) never ran** (nor would #34's boot-purge) — both edit the entrypoint the override skipped. Credentials were fixed with **service-env `GIT_CONFIG_*`** instead (see below).

## Current state (post-cutover, 2026-07-03)

The override was **removed** — the service now boots through `entrypoint.sh`. Env vars pinned to make that safe:

- `GITNEXUS_HOME=/data/.gitnexus` — pins the index location user-independently. `getGlobalDir()` = `process.env.GITNEXUS_HOME || os.homedir()/.gitnexus` (upstream gitnexus `dist/storage/repo-manager.js`, ~line 286; **not** a file in this recipe repo). Without it, the entrypoint's `gosu node gitnexus serve` resolves `~/.gitnexus` → `/home/node/.gitnexus` (ephemeral) → **the brain boots with 0 repos.** With it, the persistent `/data/.gitnexus` index (9 repos) is found.
- `PORT=10000` — the entrypoint binds HAProxy to `$PORT` (default `8010`); Render routes to `10000`, so this must be pinned or the service is unreachable.
- `API_KEY` = the `BRAIN_API_KEY` value — HAProxy's gate (`validate_api_key` treats empty as "no auth", so it must be set to actually gate).

Confirmed after cutover: HAProxy running (boot log `Starting HAProxy on port 10000` + `Git credential helper enabled`), 9 repos intact, authed clones/pulls work.

### ⚠️ The one remaining gap — mutating REST routes are STILL open

Restoring HAProxy did **not** close the whole hole. HAProxy's `__API_KEY_CHECK__` block **exempts `/api/*`** (`!is_api_path`) and only re-gates `/api/mcp`. Verified post-cutover:

- `/api/mcp` — **gated** ✅ (no-auth → 401, authed → reaches handler).
- `POST /api/analyze` — **still open** (no-auth → 202, kicks off a server-side clone).
- `DELETE /api/repo` — **still open** (no-auth drops a repo's index).

> An earlier version of this doc claimed the cutover would make no-auth `POST /api/analyze` → 401. **That was wrong** — the `/api/*` exemption means the mutating REST routes were never gated even in the intended architecture.

**Fix:** PR #36 (`fix/haproxy-gate-mutating-routes`) adds method-scoped deny rules for `POST /api/analyze` + `DELETE /api/repo` (mirroring the `/api/mcp` rules), leaving `GET /api/repos` and `GET /api/analyze/{job}` open. Ships on the next image build + deploy.

## Credential handling (env-var, survives the entrypoint either way)

Git auth is supplied through **service env vars**, so it worked in override mode and keeps working under the entrypoint:

- `GIT_CREDENTIAL_TOKEN` — a **classic** PAT (`repo` scope; works across both `Sandbox-Group-LLC` and `BrianBMorgan`, which a single-owner fine-grained PAT cannot).
- `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=credential.helper`, `GIT_CONFIG_VALUE_0=!f() { if [ "$1" = "get" ]; then printf "username=x-access-token\npassword=%s\n" "$GIT_CREDENTIAL_TOKEN"; fi; }; f` — an env-reading helper at git's highest-priority `GIT_CONFIG_*` level.

**Rotation is a one-var update** (`GIT_CREDENTIAL_TOKEN`) + auto-deploy — proven live 2026-07-03.

### The `GIT_CONFIG_GLOBAL=/dev/null` gotcha (cutover boot-failure)
While the ghost `/data/.gitconfig` existed (a dead credential that outranked the env helper and poisoned SYSOI.ai's plain-URL clones), `GIT_CONFIG_GLOBAL=/dev/null` was set to silence it, and the ghost files were then **deleted** from `/data`. But `/dev/null` is **fatal to the entrypoint**: its PR #31 step runs `git config --global …`, which can't lock `/dev/null` → boot dies with `could not lock config file /dev/null: Permission denied` → status 255. It's fine for `serve` (read-only) but not the entrypoint (which writes config). **With the ghost deleted, `GIT_CONFIG_GLOBAL` was removed** — the entrypoint's PR #31 step now re-creates the `--global` credential.helper without error. Where that `--global` write lands depends on each context's `HOME`: the **root** entrypoint process has `HOME=/data` (service env) → `/data/.gitconfig`, and the **`gosu node`** context uses `/home/node` → `/home/node/.gitconfig` (verified via a Render Job). Which file git ends up reading is moot — the `GIT_CONFIG_*` env helper supplies auth at a higher-priority level regardless.

## Operating this service (there is no shell tab)

- The container has no interactive shell wired, but **Render one-off Jobs** (`POST /v1/services/<id>/jobs {"startCommand":"…"}`) run arbitrary commands in the container with the service env — the de-facto diagnostic shell. Read output via `GET /v1/logs?ownerId=<o>&resource=<jobId>`. `HOME=/data` there. (Note: Render exec's the `startCommand` as argv — wrap multi-step scripts in `sh -c '…'` or `;`/`&&`/redirects won't be interpreted.)
- **Disk cleanup pattern:** temporarily PATCH `dockerCommand` to `rm -fv /data/<paths>` → deploy (it "fails" with no port bind — expected) → clear `dockerCommand` (or restore the prior value) → deploy. The `-v` output is the receipt in logs. (This removed the ghost `/data/.gitconfig` + `.git-credentials`.)
  - **⚠️ `rm -fv` on `/data` is destructive and irreversible** — `/data` is the persistent disk holding the entire code-graph index (`/data/.gitnexus/`). Enumerate the **exact** file paths first (via a read-only Job, e.g. `ls -la /data /data/.gitnexus`), never pass a directory or glob that could catch `/data/.gitnexus`, and never `rm -rf /data`. A too-broad delete wipes every repo's index (recoverable only by a full re-clone + re-embed sweep — ~1 hour).

## Rollback of the cutover (if the entrypoint boot ever misbehaves)

Set `dockerCommand` back to `gitnexus serve --host 0.0.0.0 --port 10000` → deploy → 9 repos return on the direct-serve path. Proven fast and reliable during the 2026-07-03 cutover (which took two attempts — the first hit the `/dev/null` gotcha above).
