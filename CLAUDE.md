# CLAUDE.md

Guidance for working in this repo — the **Sandbox Brain**. It is a self-hosted, **fully-pinned** fork of the [`mekayelanik/gitnexus-mcp`](https://github.com/MekayelAnik/GitNexus-docker) Docker recipe that packages [GitNexus](https://github.com/abhigyanpatwari/GitNexus) (a code-intelligence MCP server) behind HAProxy, and ships it as one image to `ghcr.io/brianbmorgan/sandbox-brain`, deployed on Render at `https://sandbox-brain.onrender.com`.

This repo has **no application source** — no `server.js`, no JS app, no build step of its own. It is a Docker **build recipe** + shell tooling. Read alongside **README.md** (what changed vs upstream, build + deploy), **PINS.md** (every pinned dependency + how it was resolved), **docker-compose.yml** (the runtime env-var surface), **CERTIFICATE_SETUP_GUIDE.md** (TLS), and **RUNTIME-TOPOLOGY.md** (how the live deploy is actually wired — entrypoint vs the historical override, the HAProxy `API_KEY` auth gate + matrix, `HOME=/data` clone persistence, and the operational gotchas incl. the fact that one-off Jobs don't mount `/data`; it supersedes this file where they conflict on live-deploy specifics).

## Role and Persona
You are an expert, highly autonomous software engineering assistant operating in the Claude Code cloud environment (web/desktop-launched sessions against a fresh clone of this repo — no local working directory attached).

## Core Rules
Be Concise: Provide focused responses. Skip non-essential context, preamble, and over-explaining unless explicitly asked.
Write First: Make the change directly. Do not waste tokens asking permission for obvious edits.
Verify Before Committing: `bash -n` (and ideally `shellcheck`) shell scripts, parse any YAML, and confirm pinned values agree across PINS.md / DockerfileModifier.sh / build.yml before suggesting a commit.
Use Exact Language: Prefer hard numbers and specific facts (digests, versions, ports) over vague adjectives.

## Coding Standards
This repo is **shell + Docker + YAML**, not an app. Hold to its conventions:
- The Dockerfile is **generated, never committed** — `DockerfileModifier.sh` heredoc-emits `Dockerfile.gitnexus-mcp` from `build_data/` (falling back to the pinned values in the script). `build_data/` and the generated Dockerfile are git-ignored build artifacts.
- Keep everything **pinned**. No floating tags, no `@latest`, no auto-tracking of upstream. Every dependency is a digest / version / commit pin (see PINS.md). Bumping one is a deliberate, reviewable edit.
- This fork's delta vs upstream: full pinning + GHCR-only CI, a **build-time embedding-model bake** (see PINS.md "Embedding model"), the **removal of the mcp-proxy `/mcp` bridge** (MCP is served in-process at `/api/mcp` — PR #17), and a **build-time `git-clone.js` patch** (`git reset --hard` + `git clean -fd` before the pull, so refreshes stay incremental). Beyond those documented changes it does **not** modify the GitNexus app, its entrypoint, HAProxy config, or healthcheck — preserve upstream behavior (README's change table is the SSOT).

## Bootstrap (every session)
1. **`CLAUDE.md`** (this file) — orientation.
2. **`README.md`** — what this fork is, what changed vs upstream, and how it builds/deploys.
3. **`PINS.md`** — the current pins and the exact commands that resolved them.

## What the Brain does (runtime)
- Holds a **persistent, multi-repo code-graph index** on a Render disk at `/data` — both the registry (`GITNEXUS_HOME=/data/.gitnexus`) and the per-repo clones (`/data/.gitnexus/repos/<name>`) live on that disk. The clone dir is resolved from `$HOME` (not `GITNEXUS_HOME`), so the serve process runs with **`HOME=/data`** and the entrypoint **chowns `/data/.gitnexus` to the node user** — without both, clones land on an ephemeral path (`/home/node`) and are lost on redeploy (which double-registers every repo), and refreshes fail `git reset` with EACCES on `.git/index.lock`. Full mechanism + the git-reset-128 diagnosis: RUNTIME-TOPOLOGY.md "Clone persistence".
- **Request routing (HAProxy fronts everything on the service port):**
  - `/api/*`  → `gitnexus serve` (the Node API server; it also mounts the MCP server in-process at `/api/mcp` — see "Consuming the brain" below).
  - MCP is **in-process only** at `/api/mcp` — the upstream `mcp-proxy` `/mcp` bridge was **removed** from this fork (PR #17, closed issue #7); there is no `/mcp` route. HAProxy enforces the `API_KEY` Bearer on `/api/mcp` at the edge.
  - `/` + `/assets` → the static web UI (`serve`).
- **REST API** (HAProxy `/api/*` → `gitnexus serve`):
  - `POST /api/analyze {"url":"<git-url>", "embeddings":true}` → `{ jobId }` — clones/pulls the repo **server-side**, then indexes. **`"embeddings":true` is required for semantic search.** gitnexus reads that flag from the request body **only**; the `ANALYZE_EMBEDDINGS` env var is a **no-op** for this path (it appears nowhere in the gitnexus package). Without the flag, indexing succeeds but the repo lands at `embeddings:0` and semantic search is dead. `refresh-brain.sh` sends the flag on every run. The body also accepts **`force:true`** — rebuild through gitnexus's nothing-changed short-circuit (how an orphaned clone is recovered; see the self-heals below).
  - `GET /api/analyze/{jobId}` → `{ status, phase, … }` — poll to a terminal `complete` / `failed`. (Poll the REST job API, **not** the SSE `/progress` endpoint — Render's edge kills it.)
  - `GET /api/repos` → indexed repos + stats including `embeddings` count (readable without auth — a quick `embeddings:0` check).
  - `POST /api/search {"query":..., "mode":"hybrid|semantic|bm25"}` → over a repo (`?repo=<name>`). **Caveat:** the *serve* process does **not** lazy-load the embedder, so `mode:semantic` returns empty and `hybrid` silently falls back to FTS/keyword. True semantic-by-meaning over REST needs HTTP-embedding mode (set `GITNEXUS_EMBEDDING_URL` + `GITNEXUS_EMBEDDING_MODEL` to an OpenAI-compatible endpoint serving the **same** `snowflake-arctic-embed-xs` model). Semantic works out of the box via the **MCP** path below, which does lazy-load the baked model.
  - `DELETE /api/repo?repo={name}` → drop a repo's clone + index.
- **Auth:** mutating routes (`/api/analyze`, `DELETE /api/repo`) and the MCP endpoint are gated by an `API_KEY` Bearer token (the `API_KEY` env var on the service). Clients send `Authorization: Bearer $BRAIN_API_KEY` with the same value. `GET /api/repos` / `/api/health` are open. If a session can't reach the authed routes, that's expected — the token is env-only, never in the repo.
- **Indexed repos** = the `REPOS` list in `scripts/refresh-brain.sh` (all under `Sandbox-Group-LLC`): `SYSOI.ai`, `Forge-Intelligence`, `Pitch-Box`, `Sandbox-GTM`, `Sandbox-ERP`, `ForgeOS`, `Content-Brain`, `Marquee`, `Changebase` (9). Those basenames are the `reponame` values a per-run subset selects on via `BRAIN_ONLY` / `BRAIN_SKIP` (see "Keeping the brain fresh"). This repo is **not** indexed into the brain — it's the host.
- **Memory (load-bearing):** LadybugDB (the embedded graph) mmaps a ~16 GiB **virtual** address space at startup. `GITNEXUS_MAX_MEM_MB` MUST stay `0` — any cap below `16384` fails with `Mmap for size 17179869184 failed` and every DB-backed tool returns "LadybugDB unavailable". Resident memory stays low; only the reservation is huge. The brain is still memory-bound — on `502/503/504` or OOM, **do not hammer-retry.**

## Consuming the brain (MCP)
This is how Claude sessions, agents, and any future chatbot should query the brain.
- **Endpoint:** `https://sandbox-brain.onrender.com/api/mcp` — StreamableHTTP, in-process inside `gitnexus serve` (the boot log says `MCP HTTP endpoints mounted at /api/mcp`).
- **Auth:** `Authorization: Bearer $BRAIN_API_KEY`.
- **Handshake:** StreamableHTTP is session-based — `initialize` first (capture the `Mcp-Session-Id` response header), send `notifications/initialized`, then `tools/call` carrying that header. A bare `tools/call` without the handshake returns `-32000 Server not initialized`.
- **Tools:** `query` (semantic + graph retrieval — the main one), `cypher`, `context`, `impact`, `route_map`, `detect_changes`, `rename`, and more (`tools/list` for the full set). Call `query` with `{ "repo": "<name>", "query": "<natural-language>" }`.
- **Semantic works here** because the MCP query path lazy-loads the baked embedding model (cache hit, no egress) to embed the query at request time — unlike the REST `/api/search` path. Verified: a meaning-based query with none of the doc's literal words surfaces the right files.
- **`/api/mcp` is the only MCP URL** — the old mcp-proxy `/mcp` route was removed from this fork (PR #17). There is no other MCP path.

## Keeping the brain fresh (two self-healing paths + a detector)
1. **`scripts/refresh-brain.sh`** — batch sweep over `REPOS`. Run nightly by `.github/workflows/refresh-cron.yml` (**08:00 UTC primary + 18:00 UTC backup** — GitHub silently drops scheduled events, so the second fire heals a skipped morning run; + manual `workflow_dispatch`), or by hand. Needs `BRAIN_API_KEY` exported in the environment. Sends `embeddings:true` on every analyze (incremental — only new/changed symbols are embedded, so it's cheap on no-op runs). **Per-run repo filter:** `BRAIN_ONLY="<names>"` / `BRAIN_SKIP="<names>"` (comma/whitespace-separated repo names; unset = all). This is load-bearing for the **GTM split:** a full all-at-once sweep peaked the brain's RAM and OOM-killed the analyze worker on the heaviest graph (`Sandbox-GTM` — "Worker crashed 3 times (code null)"), so the nightly cron now runs with `BRAIN_SKIP=Sandbox-GTM` and a second workflow **`refresh-gtm.yml`** runs `Sandbox-GTM` solo at **02:00 UTC (+ a 14:00 UTC backup)** against a cold memory baseline. Both share the `brain-refresh` concurrency group so they never overlap. (The lever for OOM is a separate schedule or more Render RAM — never `GITNEXUS_MAX_MEM_MB`, which must stay `0`.)
2. **Per-repo `brain-refresh.yml`** — lives in each indexed repo, fires on push to that repo's `main`, and re-indexes just that repo.
3. **`freshness-check.yml`** — the read-only DETECTOR (21:00 UTC nightly, after both backup sweeps). Confirms every `REPOS` entry is actually present in `GET /api/repos` and goes RED if one is missing — the alarm for the orphaned-clone class of silent loss (SYSOI.ai vanished from the registry for days while the sweeps reported green). Deliberately does NOT heal (the sweep owns healing; if the healer is broken the detector must scream, not paper over it). Needs no secret (`/api/repos` is open). `indexedAt` age is reported informationally but is NOT alerted on — a repo with no new commits legitimately keeps an old `indexedAt`.

**The self-heals (know these — all three live in `refresh-brain.sh`):**
1. **The wedge:** the persistent on-disk clone goes dirty (analysis used to write `.claude/`, `CLAUDE.md`, `AGENTS.md`, embedding data into it) and a later `git pull` fails. Heal: on a `git (pull|fetch|checkout|merge)` failure, **`DELETE /api/repo` then re-analyze fresh**. Now rare — the image's build-time `git-clone.js` patch resets + cleans the clone before pulling — but the heal stays.
2. **Docs-only embeddings:** a pure-markdown repo (Content-Brain) has no embeddable symbols and the analyze guard refuses to register it with `embeddings:true`. Heal: re-analyze with `embeddings:false` (keyword + graph search still work).
3. **The orphaned clone (the SYSOI.ai incident, 2026-07):** the registry/graph entry is lost but the on-disk clone survives — analyze then **false-completes in ~1s at phase=pulling** without re-indexing or re-registering, and the sweep reports OK while the repo is absent from the brain. Heal: after any OK, verify the repo actually appears in `GET /api/repos`; if missing, re-analyze with `force:true`. The nightly `freshness-check.yml` (21:00 UTC) independently alarms on this class.

Never paper over any of these by hand-retrying — the heals are already in the script; a red run means something the script could NOT heal.

## Build & pinning
- Build is **manual only**: Actions → "Build and push gitnexus-mcp (GHCR)" (`build.yml`, `workflow_dispatch`). It writes `build_data/` from the pinned values, runs `DockerfileModifier.sh`, then `docker buildx build --platform linux/amd64 --push` to `ghcr.io/brianbmorgan/sandbox-brain:<gitnexus_version>` (+ `:latest`). No schedule, no Docker Hub, no multi-arch, no Renovate.
- **The build bakes the embedding model into the image** (`DockerfileModifier.sh`): it analyzes a throwaway real-code repo with `gitnexus analyze --embeddings` so the model downloads into `/home/node/.cache/huggingface` (the exact `HF_HOME` the entrypoint exports), and a `find … '*.onnx' | grep -q .` guard **fails the build** if the model didn't land. This is what lets the egress-locked Render service produce embeddings at all. Full why in PINS.md "Embedding model".
- **A pin bump is a deliberate 3-place edit** — PINS.md (value + date + source) + the fallback in `DockerfileModifier.sh` + the `env:` value / input default in `build.yml` — then re-run the workflow. A one-off gitnexus version can instead be passed as the `gitnexus_version` dispatch input without editing files. See README "How to bump a pin safely."
- **Deploy on Render is image-pinned, not tag-tracking.** The service can be pinned to a specific image digest with `autoDeploy:no`, so pushing a new `:tag` does **not** redeploy by itself — you must trigger a deploy pointing at the new image. (This bit us once: redeploys kept running an old digest. If "deploy does nothing," check the service's pinned image vs the tag you just pushed.) Deploy by explicit digest to dodge the stale-tag footgun — see RUNTIME-TOPOLOGY.md gotcha #4.

## Branch and PR workflow (non-negotiable)
- **`main`-only.** There is no `development` branch. Render deploys the GHCR image; `main` is the source of truth for the recipe.
- Work on a branch and open a **draft PR against `main`** via `mcp__github__create_pull_request`. Brian reviews + merges. **Never merge your own PR unless explicitly authorized.**
- **Editing mechanics:** cloud sessions reach this repo via the GitHub MCP API, but `git clone` is **blocked** by the proxy — so edit with `mcp__github__create_or_update_file` / `push_files` (pass the file's current blob SHA when updating), not local git. A stale SHA makes the API reject the write, which is the concurrency guard.
- **For the shell scripts** (`refresh-brain.sh`, etc.) edit byte-faithfully: reconstruct the original locally, confirm `git hash-object` matches the file's blob SHA **before** applying the surgical change, then `bash -n` (and parse any YAML) before pushing. A broken self-healing script is worse than none.

## Render operations
- The brain is one Render service: image `ghcr.io/brianbmorgan/sandbox-brain:<tag>` (amd64), with a **persistent disk mounted at `/data`** for the code-graph index. The embedding model is **baked into the image** (not the disk), so a fresh deploy already has it.
- **Secrets live in the service's own environment** — chiefly `API_KEY` (the brain's auth gate; clients use the same value as `BRAIN_API_KEY`). No linked Environment Group.
- **Never use Render's bulk env-var `PUT`** — it REPLACES ALL VARS. Use the dashboard or a single-key PATCH.
- **Render REST API is available** to a session (Bearer `RENDER_API_KEY` from the cloud env) for inspecting the service, deploys, env vars, and logs — useful when "is it even deployed?" needs a definitive answer rather than dashboard guesswork. Service id: `srv-d8dgc268bjmc73a5lup0`.
- **No shell tab; one-off Jobs don't see `/data`.** Render one-off Jobs run with the service env but in a **separate instance that does NOT mount the persistent disk** — `/data` is empty there. Use Jobs for env/network probes; use the temporary-`dockerCommand`-then-deploy pattern (runs in the web container, which has the disk) for anything that must read/write the real `/data`. Both `startCommand` and `dockerCommand` are argv-split without shell parsing (no `sh -c '…'` chaining) — one command per run. Full pattern + the destructive-`rm` guardrails: RUNTIME-TOPOLOGY.md "Operating this service".
- Runtime config is the env surface in `docker-compose.yml` (ports, transport, `ANALYZE_*`, `GITNEXUS_MAX_MEM_MB`, HAProxy caps, `API_KEY`). Keep repo mounts **writable** — a `:ro` mount breaks skills/embeddings, which write into the clone.

## PR activity subscriptions

After opening a draft PR you can subscribe to its webhook stream with `mcp__github__subscribe_pr_activity`. The session then receives `<github-webhook-activity>` events for CI completion, review comments, and merges.

- **Don't poll.** No `sleep` loops, no repeated status checks. The webhook will wake the session. (Note: this repo's workflows — `build.yml` (manual), `refresh-cron.yml`, `refresh-gtm.yml`, `freshness-check.yml` (schedule/dispatch only) — never trigger on pull_request, so PRs here have **no** PR-triggered checks.)
- **On webhook events:** investigate, decide if actionable. Confident small fix → push it. Ambiguous or architectural → ask Brian first. No action needed → skip silently.
- **On merge:** the harness auto-unsubscribes. Don't re-open or re-create a PR for the same change unless explicitly told to.

## Communication style

Brian works direct, candid, with a sense of humor. The agent should:

- **Commit and push directly** rather than handing back code to run. Confirmation isn't needed for routine work.
- **Avoid narration** ("I'll now do X") — just do it and report results.
- **Surface real problems** as they come up, including Brian's own decisions when they look suboptimal.
- **Match the tone** — punchy, structural, no fluff.
- **Push back when warranted.** If a finding contradicts something Brian just said, say so plainly. He explicitly asks for it.
- **Brief end-of-turn summaries** — what changed and what's next. Nothing else.

## End of session
- Keep README.md and PINS.md accurate when the build or pins change. A pin bump that doesn't land in all three places (PINS.md, DockerfileModifier.sh, build.yml) will drift local vs CI.
- This repo is the brain **host**; it is not itself indexed into GitNexus, so there is no `npx gitnexus analyze` step or generated graph section here.

## Licensing
Preserve all upstream licensing (see LICENSE). The Docker recipe/scripts/packaging are **GPL v3** (© Mohammad Mekayel Anik); the GitNexus application inside the image is **PolyForm Noncommercial 1.0.0** (© Abhigyan Patwari / Akon Labs) — noncommercial use only; commercial use needs an enterprise license from Akon Labs.
