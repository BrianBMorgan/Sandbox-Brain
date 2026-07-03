# Runtime topology — how the live deploy is actually wired

> Written 2026-07-03 (credential incident + auth-gate work). Supersedes `CLAUDE.md`/`README.md` where they conflict. History first, then the current (fully-gated, normalization-hardened) state, then the operational gotchas.

## History: the override that bypassed the entrypoint (pre-2026-07-03)

For an unknown period the Render service ran a **Docker Command override** (`gitnexus serve --host 0.0.0.0 --port 10000`) that **bypassed `entrypoint.sh` entirely**. Consequences while it was in place — all since resolved, recorded so the failure mode is recognizable:

- **HAProxy never started.** `gitnexus serve` ran directly on the service port, so every "HAProxy fronts `/api/*`", "enforces the `API_KEY` Bearer at the edge", and the QUIC/TLS plumbing in `CLAUDE.md` described code that didn't run.
- **All REST + MCP routes were unauthenticated.** `gitnexus serve` has no built-in auth (verified in 1.6.5 source — the `API_KEY` gate lives *only* in the HAProxy config the entrypoint generates), and `API_KEY` wasn't even set on the service.
- **The entrypoint credential helper (PR #31) never ran** (nor would #34's boot-purge) — both edit the entrypoint the override skipped. Credentials were fixed with **service-env `GIT_CONFIG_*`** instead (see below).

## Current state (2026-07-03) — entrypoint + HAProxy + auth, all live

The override was **removed** — the service boots through `entrypoint.sh`, HAProxy fronts `gitnexus serve`, and the auth gate is active. Env vars pinned to make that safe:

- `GITNEXUS_HOME=/data/.gitnexus` — pins the index location user-independently. `getGlobalDir()` = `process.env.GITNEXUS_HOME || os.homedir()/.gitnexus` (upstream gitnexus `dist/storage/repo-manager.js`, ~line 286; **not** a file in this recipe repo). Without it, the entrypoint's `gosu node gitnexus serve` resolves `~/.gitnexus` → `/home/node/.gitnexus` (ephemeral) → **the brain boots with 0 repos.** With it, the persistent `/data/.gitnexus` index (9 repos) is found.
- `PORT=10000` — the entrypoint binds HAProxy to `$PORT` (default `8010`); Render routes to `10000`, so this must be pinned or the service is unreachable.
- `API_KEY` = the `BRAIN_API_KEY` value — HAProxy's gate (`validate_api_key` treats empty as "no auth", so it must be set to actually gate).

### Clone persistence — `HOME=/data` for the serve process (PRs #44–46)

`GITNEXUS_HOME` pins the **registry** to `/data/.gitnexus` (persistent), but gitnexus resolves the **clone dir** for `POST /api/analyze` from `os.homedir()` (= `$HOME`), **not** from `GITNEXUS_HOME`. Under `gosu node` the node user's `HOME` is `/home/node` (ephemeral), so clones landed there and were lost on every redeploy while the persistent registry kept pointing at them — each refresh then re-cloned under a fresh path and the console **listed every repo twice**. Three coupled fixes make persistent, refreshable clones work — each uncovered the next:

1. **`HOME=/data` for serve** (PR #44) — `start_web_ui()` launches `gosu node env HOME=/data gitnexus serve …` so `os.homedir()` resolves to the mounted disk and clones land in `/data/.gitnexus/repos`, surviving redeploys.
2. **`safe.directory` written to `/data/.gitconfig`** (PR #45) — with `HOME=/data`, serve's git reads `/data/.gitconfig`, not `/home/node/.gitconfig`. The entrypoint writes `safe.directory '*'` to **both** (`gosu node env HOME=/data git config --global …`); otherwise git's dubious-ownership check fires on the `/data` clones. (Credentials are unaffected — they come from the `GIT_CONFIG_*` env helper, which is HOME-independent.)
3. **`chown /data/.gitnexus` to node** (PR #46) — the real blocker under the ownership check: serve runs as `node`, but pre-existing `/data` clones were owned by a differing uid, so `git reset` during a refresh failed **`EACCES` on `.git/index.lock`** (surfaced as the generic "git reset failed exit 128"). The entrypoint recursively chowns `/data/.gitnexus` to `PUID:PGID`, mirroring the existing `/home/node/.gitnexus` chown — but with `find … \( ! -user PUID -o ! -group PGID \) -exec chown … +` (only mismatched inodes) rather than a blanket `-R`, since this persistent tree grows with every indexed repo and a full recursive chown every boot would scale into real startup cost.

**Diagnosis note:** the symptom was a hard `git reset failed (exit code 128)` on **every** refresh — reproduced on a *healthy* repo (ForgeOS), not just a wedged clone, which is what proved it systemic rather than one bad clone. The generic wrapper message hid the cause; reproduce the git op in serve's exact context via a `dockerCommand` deploy (`gosu node env HOME=/data git config --list --show-origin` showed `safe.directory=*` *was* resolved from `/data/.gitconfig`, and the boot log carried the real `git reset stderr: … index.lock: Permission denied`). End state after the fix: a clean **9 repos**, no duplicates.

### Auth matrix (verified live)

HAProxy's `__API_KEY_CHECK__` block exempts `/api/*` from the `API_KEY` gate (they're the web-UI backend), then **re-gates specific routes** — `/api/mcp` plus the two mutating REST routes (PR #36 + #38):

| Route | No auth | Authed (`Bearer $BRAIN_API_KEY`) |
|---|---|---|
| `POST /api/analyze` | **401** | 202 (runs) |
| `DELETE /api/repo` | **401** | works |
| `GET /api/mcp` | **401** | reaches handler |
| `GET /api/repos` | 200 (open by design) | 200 |
| `GET /api/analyze/{job}` | 200 (open by design) | 200 |
| `GET /` + `/assets` (web UI) | 200 | 200 |
| `/healthz` (localhost only) | 200 from localhost | — |

The mutating-route deny rules are **method-scoped** (`METH_POST is_analyze_path`, `METH_DELETE is_repo_path`) so the read endpoints (`GET /api/repos`, `GET /api/analyze/{job}`) stay open. Both ACLs use `path_beg`, and `http-request normalize-uri` (path-merge-slashes / path-strip-dot / path-strip-dotdot) canonicalizes the request path **before** the auth decision — so trailing-slash / double-slash / dot-segment variants (`/api/repo/`, `/api//repo`, `/api/repo/x/..`, …) can't dodge the gate by exploiting a path-parse mismatch with the Express backend (which routes them all to the same handler). Every such variant is verified to return 401 (PR #40 + #41). `is_repo_path` matching `/api/repos` is harmless — it's only in the `METH_DELETE` rule, and there's no `DELETE /api/repos` route. See gotcha #5.

## Credential handling (env-var, survives the entrypoint either way)

Git auth is supplied through **service env vars**, so it worked in override mode and keeps working under the entrypoint:

- `GIT_CREDENTIAL_TOKEN` — a **classic** PAT (`repo` scope; works across both `Sandbox-Group-LLC` and `BrianBMorgan`, which a single-owner fine-grained PAT cannot).
- `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=credential.helper`, `GIT_CONFIG_VALUE_0=!f() { if [ "$1" = "get" ]; then printf "username=x-access-token\npassword=%s\n" "$GIT_CREDENTIAL_TOKEN"; fi; }; f` — an env-reading helper at git's highest-priority `GIT_CONFIG_*` level. **Because auth is env-supplied it is HOME-independent** — the `HOME=/data` serve process authenticates the same as any other context. Only `safe.directory` (which is *not* in the env helper) had to be relocated to `/data/.gitconfig`; see "Clone persistence" above.

**Rotation is a one-var update** (`GIT_CREDENTIAL_TOKEN`) + auto-deploy — proven live 2026-07-03.

## Gotchas (each of these cost real time — read before editing the template/entrypoint or deploying)

### 1. Never put a `__PLACEHOLDER__` token inside a template comment
`generate_haproxy_config` substitutes placeholders with `awk '/__API_KEY_CHECK__/ { print replacement }'` (and the same for `__CORS_CHECK__`, `__WEB_AUTH_CHECK__`, `__RATE_LIMIT_*__`, `__IP_ACCESS_CHECK__`). The match is **any line containing the token** — including a comment that merely *mentions* it. A comment reading `# ... re-gated in __API_KEY_CHECK__ ...` caused the entire deny block to be emitted **twice**: once (wrongly) at the comment's position, *before* the ACLs it references were defined → `haproxy -c` failed with `no such ACL : 'is_web_ui'` → the entrypoint (running under `set -e`) exited 1 on **every** boot → the gate silently never came up. When referring to a placeholder in prose, spell it differently (e.g. "the generated auth block").

### 2. `GIT_CONFIG_GLOBAL=/dev/null` is fatal to the entrypoint
The ghost `/data/.gitconfig` (a dead credential that outranked the env helper and poisoned SYSOI.ai's plain-URL clones) was silenced with `GIT_CONFIG_GLOBAL=/dev/null`, then the ghost files were **deleted** from `/data`. But `/dev/null` breaks the entrypoint's PR #31 step (`git config --global …` can't lock `/dev/null` → `could not lock config file /dev/null: Permission denied` → status 255). Fine for `serve` (read-only); fatal for the entrypoint (writes config). **With the ghost gone, `GIT_CONFIG_GLOBAL` was removed.** The `--global` write now lands per each context's `HOME`: root has `HOME=/data` → `/data/.gitconfig`, the `gosu node` context uses `/home/node` → `/home/node/.gitconfig` (and, for the serve process, `HOME=/data` → `/data/.gitconfig` — see "Clone persistence"). Which file git reads for auth is moot — the `GIT_CONFIG_*` env helper supplies credentials at a higher-priority level regardless; `safe.directory` is the one setting that *does* depend on the file, hence PR #45.

### 3. Don't use `clearCache` on this image service
A deploy with `clearCache: true` early in the auth-gate debugging produced a confusing exit-1 and muddied the diagnosis. It's an image-backed service — there's nothing useful to clear, and it can disturb runtime caches. Deploy plainly, or by digest (below).

### 4. Deploy by digest to dodge the stale-tag footgun
Render can keep running an **old digest** for a tag (`:1.6.5`) even after a fresh push — a plain redeploy pulled the previous image more than once here. To force the new image deterministically: fetch the current digest and deploy it explicitly. Anonymous GHCR token works for the public package:
```
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:brianbmorgan/sandbox-brain:pull&service=ghcr.io" | jq -r .token)
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  https://ghcr.io/v2/brianbmorgan/sandbox-brain/manifests/1.6.5 | grep -i docker-content-digest
# then POST a deploy with {"imageUrl":"ghcr.io/brianbmorgan/sandbox-brain@sha256:<digest>"}
```
Changing the image ref (digest) or `dockerCommand` triggers a **recreate**; a same-ref redeploy is a **rolling** deploy. Confirm freshness by reading the image config's `created` timestamp (pull the amd64 sub-manifest → config blob → `.created`) — it should be minutes old, matching the build you just ran.

### 5. `normalize-uri` is experimental — it needs `expose-experimental-directives`
HAProxy path ACLs (`path`/`path_beg`) and the backend (Express, non-strict routing) canonicalize paths differently, so `DELETE /api/repo/`, `/api//repo`, `/api/repo/x/..` etc. slipped past the gate and reached the mutating handlers **unauthenticated** — an unauthenticated repo-deletion bypass. The fix is three separate directives (`http-request normalize-uri path-merge-slashes`, `http-request normalize-uri path-strip-dot`, `http-request normalize-uri path-strip-dotdot`) as the first frontend actions, so HAProxy evaluates the same canonical path Express resolves. **But** `normalize-uri` is flagged experimental in HAProxy 3.x — the config won't parse without `expose-experimental-directives` in the **`global`** section (`'normalize-uri' action is experimental, must be allowed via a global 'expose-experimental-directives'` → entrypoint exit 1). Both pieces ship together.

## Operating this service (there is no shell tab)

- **Render one-off Jobs** (`POST /v1/services/<id>/jobs {"startCommand":"…"}`) run a command in the container with the service env. Read output via `GET /v1/logs?ownerId=<o>&resource=<jobId>`. `HOME=/data` there. Two caveats, both load-bearing:
  - **Jobs do NOT mount the persistent `/data` disk.** A Job runs in a *separate instance* where `/data` is empty — `ls /data/.gitnexus` in a Job returns "No such file or directory" even though the live web container's disk is fully populated (9 repos). Jobs are fine for reading **env** (`printenv GIT_CONFIG_COUNT`) or probing the **network** (`git ls-remote <url> HEAD`), but for anything that must touch the real `/data` (inspect clones, chown, remove a wedged clone) use the `dockerCommand` pattern below — it runs in the web container, which has the disk.
  - **`startCommand` is argv-split on whitespace *without* shell quote-parsing**, so multi-word `sh -c '…'` scripts don't survive (they arrive as one giant argv and error `not found`). A single-token command with plain args works (`git ls-remote <url> HEAD`); anything with pipes/`;`/`&&`/globs does not. One fact per Job, or read it out of boot logs.
- **Disk cleanup / inspection pattern (runs in the web container, has the disk):** temporarily PATCH `dockerCommand` to a single command → deploy (it "fails" with no port bind — expected) → read the boot logs → clear `dockerCommand` → deploy (or deploy by digest). `dockerCommand` is argv-split exactly like Jobs (`main()` does `exec "$@"`), so **the same single-command / no-`sh -c` rule applies** — one fact or one mutation per deploy. Read-only inspection (`ls -la /data/.gitnexus`, `git config --list --show-origin`) is how the git-reset-128 EACCES was diagnosed.
  - **⚠️ `rm -fv` / destructive commands on `/data` are irreversible** — `/data` is the persistent disk holding the entire code-graph index (`/data/.gitnexus/`). Enumerate the **exact** file paths first (via a read-only `dockerCommand`, e.g. `ls -la /data /data/.gitnexus`), never pass a directory or glob that could catch `/data/.gitnexus`, and never `rm -rf /data`. A too-broad delete wipes every repo's index (recoverable only by a full re-clone + re-embed sweep — ~1 hour). `chown -R` / conditional `find … -exec chown` on `/data/.gitnexus` is safe (metadata only) and is what unblocked the refresh EACCES.

## Rollback (if an entrypoint boot ever misbehaves)

Set `dockerCommand` back to `gitnexus serve --host 0.0.0.0 --port 10000` → deploy → repos return on the direct-serve path (no HAProxy, **no auth gate** — serve mode has no built-in auth, so this is a get-it-back-up measure, not a resting state). Proven fast and reliable. Return to entrypoint mode by clearing `dockerCommand` again once the boot issue is fixed.
