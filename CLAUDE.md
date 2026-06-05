# CLAUDE.md

Guidance for working in this repo — the **Sandbox Brain**. It is a self-hosted, **fully-pinned** fork of the [`mekayelanik/gitnexus-mcp`](https://github.com/MekayelAnik/GitNexus-docker) Docker recipe that packages [GitNexus](https://github.com/abhigyanpatwari/GitNexus) (a code-intelligence MCP server) behind HAProxy + an `mcp-proxy` stdio↔HTTP bridge, and ships it as one image to `ghcr.io/brianbmorgan/sandbox-brain`, deployed on Render at `https://sandbox-brain.onrender.com`.

This repo has **no application source** — no `server.js`, no JS app, no build step of its own. It is a Docker **build recipe** + shell tooling. Read alongside **README.md** (what changed vs upstream, build + deploy), **PINS.md** (every pinned dependency + how it was resolved), **docker-compose.yml** (the runtime env-var surface), and **CERTIFICATE_SETUP_GUIDE.md** (TLS).

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
- This fork changes only build/distribution plumbing (pinning + GHCR-only CI). It does **not** modify the GitNexus app, its entrypoint, HAProxy config, or healthcheck — preserve upstream behavior.

## Bootstrap (every session)
1. **`CLAUDE.md`** (this file) — orientation.
2. **`README.md`** — what this fork is, what changed vs upstream, and how it builds/deploys.
3. **`PINS.md`** — the current pins and the exact commands that resolved them.

## What the Brain does (runtime)
- Holds a **persistent, multi-repo code-graph index** on a Render disk at `/data` (registry under `~/.gitnexus`, per-repo clones under `/data/.gitnexus/repos/<name>`).
- Exposes a REST API (HAProxy → `mcp-proxy` → GitNexus):
  - `POST /api/analyze {"url":"<git-url>"}` → `{ jobId }` — clones/pulls the repo **server-side**, then indexes.
  - `GET /api/analyze/{jobId}` → `{ status, phase, … }` — poll to a terminal `complete` / `failed`. (Poll the REST job API, **not** the SSE `/progress` endpoint — Render's edge kills it.)
  - `GET /api/repos` → indexed repos + stats (readable without auth).
  - `DELETE /api/repo?repo={name}` → drop a repo's clone + index.
- **Auth:** mutating routes (`/api/analyze`, `DELETE /api/repo`) are gated by an `API_KEY` Bearer token (the `API_KEY` env var on the service). Clients send `Authorization: Bearer $BRAIN_API_KEY` with the same value. If a session can't reach the authed routes, that's expected — the token is env-only, never in the repo.
- **Indexed repos** = the `REPOS` list in `scripts/refreshbrain.sh`: `Sandbox-Group-LLC/SYSOI.ai`, `Forge-Intelligence`, `Pitch-Box`. This repo is **not** indexed into the brain — it's the host.
- **Memory (load-bearing):** LadybugDB (the embedded graph) mmaps a ~16 GiB **virtual** address space at startup. `GITNEXUS_MAX_MEM_MB` MUST stay `0` — any cap below `16384` fails with `Mmap for size 17179869184 failed` and every DB-backed tool returns "LadybugDB unavailable". Resident memory stays low; only the reservation is huge. The brain is still memory-bound — on `502/503/504` or OOM, **do not hammer-retry.**

## Keeping the brain fresh (two self-healing paths)
1. **`scripts/refreshbrain.sh`** — batch sweep over `REPOS`. Run nightly by `.github/workflows/refresh-cron.yml` (08:00 UTC + manual `workflow_dispatch`), or by hand. Needs `BRAIN_API_KEY` exported in the environment.
2. **Per-repo `brain-refresh.yml`** — lives in each indexed repo, fires on push to that repo's `main`, and re-indexes just that repo.

**The wedge + self-heal (know this):** the persistent on-disk clone goes **dirty** because analysis writes into it (`ANALYZE_SKILLS` + `ANALYZE_EMBEDDINGS` → `.claude/`, `CLAUDE.md`, `AGENTS.md`, embeddings). A later `git pull` then fails (`git pull failed (exit code 1)`). Both refresh paths recover the same way: on a `git (pull|fetch|checkout|merge)` failure, **`DELETE /api/repo` then re-analyze fresh**. Never paper over a wedge by retrying the pull — delete + re-clone.

## Build & pinning
- Build is **manual only**: Actions → "Build and push gitnexus-mcp (GHCR)" (`build.yml`, `workflow_dispatch`). It writes `build_data/` from the pinned values, runs `DockerfileModifier.sh`, then `docker buildx build --platform linux/amd64 --push` to `ghcr.io/brianbmorgan/sandbox-brain:<gitnexus_version>` (+ `:latest`). No schedule, no Docker Hub, no multi-arch, no Renovate.
- **A pin bump is a deliberate 3-place edit** — PINS.md (value + date + source) + the fallback in `DockerfileModifier.sh` + the `env:` value / input default in `build.yml` — then re-run the workflow. A one-off gitnexus version can instead be passed as the `gitnexus_version` dispatch input without editing files. See README "How to bump a pin safely."

## Branch and PR workflow (non-negotiable)
- **`main`-only.** There is no `development` branch. Render deploys the GHCR image; `main` is the source of truth for the recipe.
- Work on a branch and open a **draft PR against `main`** via `mcp__github__create_pull_request`. Brian reviews + merges. **Never merge your own PR unless explicitly authorized.**
- **Editing mechanics:** cloud sessions reach this repo via the GitHub MCP API, but `git clone` is **blocked** by the proxy — so edit with `mcp__github__create_or_update_file` / `push_files` (pass the file's current blob SHA when updating), not local git. A stale SHA makes the API reject the write, which is the concurrency guard.
- **For the shell scripts** (`refreshbrain.sh`, etc.) edit byte-faithfully: reconstruct the original locally, confirm `git hash-object` matches the file's blob SHA **before** applying the surgical change, then `bash -n` (and parse any YAML) before pushing. A broken self-healing script is worse than none.

## Render operations
- The brain is one Render service: image `ghcr.io/brianbmorgan/sandbox-brain:<tag>` (amd64), with a **persistent disk for `/data`** plus the HF/ONNX model cache.
- **Secrets live in the service's own environment** — chiefly `API_KEY` (the brain's auth gate; clients use the same value as `BRAIN_API_KEY`). No linked Environment Group.
- **Never use Render's bulk env-var `PUT`** — it REPLACES ALL VARS. Use the dashboard or a single-key PATCH.
- Runtime config is the env surface in `docker-compose.yml` (ports, transport, `ANALYZE_*`, `GITNEXUS_MAX_MEM_MB`, HAProxy caps, `API_KEY`). Keep repo mounts **writable** — a `:ro` mount breaks skills/embeddings, which write into the clone.

## PR activity subscriptions

After opening a draft PR you can subscribe to its webhook stream with `mcp__github__subscribe_pr_activity`. The session then receives `<github-webhook-activity>` events for CI completion, review comments, and merges.

- **Don't poll.** No `sleep` loops, no repeated status checks. The webhook will wake the session. (Note: this repo's CI is `workflow_dispatch`-only `build.yml` + a scheduled `refresh-cron.yml`, so most PRs here have **no** PR-triggered checks.)
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
