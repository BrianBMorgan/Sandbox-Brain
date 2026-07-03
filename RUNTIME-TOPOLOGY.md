# Runtime topology — the live deploy DIVERGES from the recipe

> **Read this before trusting any "HAProxy fronts everything / enforces `API_KEY`" statement in `CLAUDE.md` or `README.md`.** Written 2026-07-03 after the 2026-07-02→03 credential incident. `CLAUDE.md`'s "Request routing (HAProxy fronts everything…)" bullets and the "Auth: … gated by an `API_KEY` Bearer" claim describe the *entrypoint* path, which the live deploy does not execute.

## The divergence

The Render service runs a **Docker Command override** (`gitnexus serve --host 0.0.0.0 --port 10000`) that **bypasses `entrypoint.sh` entirely**. All of the following are currently true in production:

- **HAProxy is NOT running.** The override starts `gitnexus serve` directly on the service port. Every "HAProxy fronts `/api/*`", "enforces the `API_KEY` Bearer at the edge", and the QUIC/TLS plumbing describes code that never runs.
- **`/api/analyze`, `DELETE /api/repo`, and `/api/mcp` are UNAUTHENTICATED.** `gitnexus serve` has no built-in auth (verified in 1.6.5 source — the `API_KEY` gate lives *only* in the HAProxy config the entrypoint generates). A no-auth `POST /api/analyze` returns `202 + jobId`; anyone who can reach the public URL can trigger server-side clones or delete repos. **Compounding this: the service has no `API_KEY` env var set at all** (the client key is stored as `BRAIN_API_KEY`), so even restoring HAProxy would not gate until `API_KEY` is wired (`validate_api_key` treats empty as "no auth").
- **The entrypoint credential helper (PR #31) never runs**, and #34's boot-purge wouldn't either — both edit the entrypoint the override skips. The incident was resolved with **service-env `GIT_CONFIG_*`** instead (below), not the entrypoint.
- **`GITNEXUS_HOME` is load-bearing.** `getGlobalDir()` = `process.env.GITNEXUS_HOME || os.homedir()/.gitnexus` — defined in the **upstream gitnexus package** (`dist/storage/repo-manager.js`, ~line 286), *not* a file in this recipe repo; cited only to explain the resolution the deploy depends on. The override supplies `HOME=/data`, so the persistent index at `/data/.gitnexus` is found. Clearing the override *without* setting `GITNEXUS_HOME` makes the entrypoint's `gosu node gitnexus serve` resolve `~/.gitnexus` → `/home/node/.gitnexus` (ephemeral) → **the brain boots with 0 repos.**

## Credential handling as it ACTUALLY works now (env-var, not entrypoint)

Git auth is supplied entirely through **service env vars**, independent of the entrypoint:

- `GIT_CREDENTIAL_TOKEN` — a **classic** PAT (`repo` scope; works across both `Sandbox-Group-LLC` and `BrianBMorgan`, which a single-owner fine-grained PAT cannot).
- `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=credential.helper`, `GIT_CONFIG_VALUE_0=!f() { if [ "$1" = "get" ]; then printf "username=x-access-token\npassword=%s\n" "$GIT_CREDENTIAL_TOKEN"; fi; }; f` — an env-reading helper injected at git's highest-priority `GIT_CONFIG_*` level.
- `GIT_CONFIG_GLOBAL=/dev/null` — **load-bearing.** A dead credential baked into `/data/.gitconfig` (plus a `.git-credentials` file) outranked the env helper and poisoned exactly one repo's plain-URL clones (SYSOI.ai) while others sailed. Pointing `--global` at `/dev/null` silenced the ghost; the ghost files were then deleted from `/data`.

**Rotation is now a one-var update** (`GIT_CREDENTIAL_TOKEN`) + auto-deploy — proven live 2026-07-03.

## Operating this service (there is no shell tab)

- The container has no interactive shell wired, but **Render one-off Jobs** (`POST /v1/services/<id>/jobs {"startCommand":"…"}`) run arbitrary commands in the container with the service env — the de-facto diagnostic shell. Read output via `GET /v1/logs?ownerId=<o>&resource=<jobId>`. `HOME=/data` there.
- **Disk cleanup pattern:** temporarily PATCH `dockerCommand` to `rm -fv /data/<paths>` → deploy (it "fails" with no port bind — expected) → restore `gitnexus serve …` → deploy. The `-v` output is the receipt in logs. (This removed the ghost `/data/.gitconfig` + `.git-credentials`.)
  - **⚠️ `rm -fv` on `/data` is destructive and irreversible** — `/data` is the persistent disk holding the entire code-graph index (`/data/.gitnexus/`). Enumerate the **exact** file paths first (via a read-only Job, e.g. `ls -la /data /data/.gitnexus`), never pass a directory or glob that could catch `/data/.gitnexus`, and never `rm -rf /data`. A too-broad delete wipes every repo's index (recoverable only by a full re-clone + re-embed sweep — ~1 hour). Prefer listing what you'll delete in one Job, then deleting the named paths in the next.

## Restoring the intended architecture (entrypoint + HAProxy + auth) — staged cutover

Prerequisites (set + verify in current mode first; each is a no-op there):

1. `GITNEXUS_HOME=/data/.gitnexus` — pins the index location user-independently. ✅ set 2026-07-03; 9 repos confirmed to survive.
2. `PORT=10000` — the entrypoint binds HAProxy to `$PORT` (default `8010`); Render routes to `10000`, so pin it or the service comes up unreachable. ✅ set 2026-07-03; 9 repos hold.
3. `API_KEY=<the BRAIN_API_KEY value>` — **required to actually gate**; 5–256 chars, no whitespace. **Not yet set — the piece that closes the unauth hole.**

Then clear the `dockerCommand` (one deploy) → the entrypoint runs → HAProxy fronts serve, `GIT_CONFIG_*` still supplies git auth, `GITNEXUS_HOME` keeps the index on `/data`.

**Verify:** `GET /api/repos` = 9 · no-auth `POST /api/analyze` → 401 · an authed call succeeds.
**Rollback (proven, fast):** restore `dockerCommand` to `gitnexus serve --host 0.0.0.0 --port 10000` → 9 repos return.

The entrypoint's boot-analyze loops `/data/*/` and misfires harmlessly on `/data/.gitnexus` (repos are one level deeper), so it does **not** trigger a heavy re-index on boot.
