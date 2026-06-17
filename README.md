# gitnexus-mcp (self-hosted, fully-pinned fork)

A self-hosted, **fully-pinned** fork of the Docker recipe
[`mekayelanik/gitnexus-mcp`](https://hub.docker.com/r/mekayelanik/gitnexus-mcp)
(source: [MekayelAnik/GitNexus-docker](https://github.com/MekayelAnik/GitNexus-docker)),
maintained for the **Sandbox Brain** Render service.

This fork builds **only** to `ghcr.io/brianbmorgan/sandbox-brain`. It does
**not** push to Docker Hub and it does **not** auto-track upstream — every
dependency is pinned to an exact digest / version / commit, and bumping any of
them is a deliberate, reviewable edit.

It packages [GitNexus](https://github.com/abhigyanpatwari/GitNexus) (a code-
intelligence MCP server) behind HAProxy + an `mcp-proxy` stdio↔HTTP bridge, the
same as upstream.

> **In-flight work:** cross-repo brain initiatives currently in progress (e.g.
> the Content-Brain `PROSPECTS/` directory) are tracked in
> [`WORKING.md`](WORKING.md) — a session-handoff doc so the next session resumes
> without re-discovery.

---

## What changed vs. upstream

| Aspect | Upstream `mekayelanik/gitnexus-mcp` | This fork |
|:-------|:------------------------------------|:----------|
| Registry | Docker Hub (multi-registry matrix) | **GHCR only** — `ghcr.io/brianbmorgan/sandbox-brain` |
| CI | Schedule + `repository_dispatch` auto-tracking, multi-arch matrix, registry sync, Docker Hub README sync | **One** `workflow_dispatch`-only workflow ([`.github/workflows/build.yml`](.github/workflows/build.yml)) |
| Auto-tracking | Monitors npm for new gitnexus releases and auto-builds | **None** — no schedule, no auto-check, no Renovate |
| Architectures | `amd64` + `arm64` | **`amd64` only** (Render runs amd64) |
| Base image | `node:22-trixie-slim` (floating tag) | pinned by `@sha256` digest |
| HAProxy source | `haproxy:lts` (floating tag) | pinned by `@sha256` digest |
| `mcp-proxy` | `pip install mcp-proxy` (floating) | pinned `mcp-proxy==X.Y.Z` |
| `serve` | `serve@latest` | pinned `serve@X.Y.Z` |
| Frontend (web UI) | `git clone --depth 1 … main` (moving target) | pinned to a fixed upstream **commit** |
| Embedding model | downloaded from HuggingFace at **runtime** (needs egress) | **baked into the image at build time** (egress-proof) — see [`PINS.md`](PINS.md) |
| Clone refresh | `git pull --ff-only` — **wedges** on gitnexus's own generated files (`CLAUDE.md`/`AGENTS.md`/`.claude/`), forcing a full delete + re-clone + re-embed each run | **build-time patch** to `git-clone.js`: `git reset --hard` + `git clean -fd` before the pull, so refreshes stay **incremental** (guarded — the build fails if a version bump moves the pull line) |
| `gitnexus` | `gitnexus@$VERSION` | unchanged, but the fallback version is pinned |

Everything else (entrypoint, HAProxy config/templating, healthcheck, GPU/CUDA
handling, runtime env vars) is preserved exactly from upstream.

---

## Pins

Resolved **2026-06-01**. Full provenance (resolution commands + sources) is in
[`PINS.md`](PINS.md). These values live in
[`DockerfileModifier.sh`](DockerfileModifier.sh) (fallbacks) and
[`.github/workflows/build.yml`](.github/workflows/build.yml) (CI inputs).

| Dependency | Pinned value |
|:-----------|:-------------|
| Base image | `node:22-trixie-slim@sha256:e637ac91fb4f2f40761d217c5d48c41a05edf0b65eb9c34e72c27cce55af9e65` |
| HAProxy source | `haproxy:lts@sha256:74735a91316c777de22894a4216729bfee79500caf5ed27dacf92dcd88b22f1c` |
| `gitnexus` (npm) | `gitnexus@1.6.5` |
| `mcp-proxy` (PyPI) | `mcp-proxy==0.12.0` |
| `serve` (npm) | `serve@14.2.6` |
| GitNexus frontend (git) | `4f7697c43b1aff0662eae528fc8a1bc01db6a284` |
| Embedding model (HF, baked) | `Snowflake/snowflake-arctic-embed-xs` (384-dim) |

---

## How it builds

The Dockerfile is **generated**, not committed. `DockerfileModifier.sh` reads
`build_data/{base-image,haproxy-image,version,mcp_proxy_version}` (falling back
to the pinned values above) and heredoc-emits `Dockerfile.gitnexus-mcp`. The CI
workflow writes those `build_data` files from the pinned values, runs the
generator, then `docker buildx build … --push`.

The generated Dockerfile also **bakes the embedding model into the image**: it
analyzes a tiny throwaway real-code repo with `gitnexus analyze --embeddings`,
which pulls `Snowflake/snowflake-arctic-embed-xs` into
`/home/node/.cache/huggingface` (the exact `HF_HOME` the entrypoint exports), and
a `find … '*.onnx' | grep -q .` guard **fails the build** if the model didn't
land. This is what lets the egress-locked Render service generate embeddings with
zero runtime network. Full rationale in [`PINS.md`](PINS.md) → "Embedding model".

### Build via GitHub Actions (the supported path)

1. Go to **Actions → "Build and push gitnexus-mcp (GHCR)" → Run workflow**.
2. Inputs:
   - `gitnexus_version` — gitnexus npm version to install (default `1.6.5`).
   - `push_latest` — also tag/push `:latest` (default `true`).
3. The job (on `ubuntu-latest`) checks out, sets up Buildx, logs in to `ghcr.io`
   as `${{ github.actor }}` with the workflow's `GITHUB_TOKEN`, populates
   `build_data/`, runs `DockerfileModifier.sh`, then builds **linux/amd64** and
   pushes:
   - `ghcr.io/brianbmorgan/sandbox-brain:<gitnexus_version>`
   - `ghcr.io/brianbmorgan/sandbox-brain:latest` (when `push_latest`)

   It then prints the pushed image digest via `docker buildx imagetools inspect`.

Required: the repo (or org) must allow GHCR pushes with the default
`GITHUB_TOKEN` — the workflow declares `permissions: { contents: read,
packages: write }`. No extra secrets are needed; **no Docker Hub credentials**.

> Single-arch **amd64 only** by design — the Sandbox Brain Render service runs
> on amd64. To add arm64 later, extend `--platform` in the workflow (and expect
> longer builds / QEMU emulation).

### Generate the Dockerfile locally (no build)

```bash
mkdir -p build_data
printf '%s' "node:22-trixie-slim@sha256:e637ac91fb4f2f40761d217c5d48c41a05edf0b65eb9c34e72c27cce55af9e65" > build_data/base-image
printf '%s' "haproxy:lts@sha256:74735a91316c777de22894a4216729bfee79500caf5ed27dacf92dcd88b22f1c"     > build_data/haproxy-image
printf '%s' "1.6.5"              > build_data/version
printf '%s' "mcp-proxy==0.12.0"  > build_data/mcp_proxy_version
touch build_data/build
bash ./DockerfileModifier.sh   # writes Dockerfile.gitnexus-mcp
```

(`build_data/` and `Dockerfile.gitnexus-mcp` are git-ignored build artifacts.)

---

## How to bump a pin safely

Pins do **not** update themselves. To move one:

1. Resolve the new value (see the exact commands in [`PINS.md`](PINS.md), e.g.
   re-`HEAD` the registry for a new digest, or read `.dist-tags.latest`).
2. Update it in **three** places so local + CI stay in sync:
   - [`PINS.md`](PINS.md) — value + date + source.
   - [`DockerfileModifier.sh`](DockerfileModifier.sh) — the matching fallback
     (`BASE_IMAGE`, `HAPROXY_IMAGE`, `GITNEXUS_VERSION`,
     `GITNEXUS_FRONTEND_COMMIT`, `MCP_PROXY_PKG`, or `SERVE_PKG`).
   - [`.github/workflows/build.yml`](.github/workflows/build.yml) — the matching
     `env:` value (or the `gitnexus_version` input default).
3. For a one-off gitnexus version bump only, you can instead just pass a
   different `gitnexus_version` when running the workflow — no file edit needed.
4. Re-run the workflow.

> Note: `gitnexus_version` selects the **npm** package version. The bundled
> **web UI** is pinned separately by `GITNEXUS_FRONTEND_COMMIT`; bump it too if
> you want the UI to track a newer upstream commit.

---

## Deploying

See [`docker-compose.yml`](docker-compose.yml) for a reference service
definition and [`CERTIFICATE_SETUP_GUIDE.md`](CERTIFICATE_SETUP_GUIDE.md) for
TLS. Point the image at `ghcr.io/brianbmorgan/sandbox-brain:<tag>`. All
runtime configuration (ports, transport, auth, analysis, wiki, GPU) is via the
environment variables consumed by `resources/entrypoint.sh` (unchanged from
upstream).

> **Render deploy gotcha:** the Sandbox Brain service can be **digest-pinned**
> with `autoDeploy:no`, so pushing a new `:tag` to GHCR does **not** redeploy by
> itself — you have to trigger a deploy that points at the new image. If a
> redeploy "does nothing," check the service's pinned image against the tag you
> just pushed.

---

## Using the brain (runtime API + MCP)

Once deployed, clients reach the brain at `https://sandbox-brain.onrender.com`.
Mutating routes and the MCP endpoint require `Authorization: Bearer <API_KEY>`;
`GET /api/repos` and `/api/health` are open.

- **MCP (recommended for agents / a future chatbot):** `POST /api/mcp` —
  StreamableHTTP, served in-process by `gitnexus serve`. Send the Bearer token,
  then call the **`query`** tool with `{ "repo": "<name>", "query": "<text>" }`.
  Semantic-by-meaning search works here because the MCP path lazy-loads the baked
  embedding model.
  > HAProxy also routes `/mcp` to the bundled `mcp-proxy` bridge, but that path
  > currently returns **404** — use `/api/mcp`. Tracked in **issue #7**.
- **Indexing:** `POST /api/analyze {"url":"<git-url>","embeddings":true}`, then
  poll `GET /api/analyze/{jobId}` to `complete`/`failed`. `"embeddings":true` is
  **required** — without it the repo indexes but with `embeddings:0` and no
  semantic search. `scripts/refreshbrain.sh` (nightly cron) keeps the configured
  repos indexed and embedded.
- **Inspect:** `GET /api/repos` → each repo's stats, including the `embeddings`
  count (a quick way to confirm semantic data is present).

> Note: the REST `POST /api/search` endpoint's `semantic` mode returns empty and
> `hybrid` falls back to keyword (FTS) — the *serve* process doesn't lazy-load
> the embedder. For semantic retrieval use the MCP `query` tool, or run an
> external OpenAI-compatible embedding endpoint (same `snowflake-arctic-embed-xs`
> model) via `GITNEXUS_EMBEDDING_URL`/`_MODEL`.

---

## Licensing & attribution

This fork **preserves all upstream licensing and attribution** — see
[`LICENSE`](LICENSE).

- **Docker recipe / scripts / packaging:** **GPL v3**, © Mohammad Mekayel Anik
  ([MekayelAnik/GitNexus-docker](https://github.com/MekayelAnik/GitNexus-docker)).
  This fork is a derivative work distributed under the same GPL v3 terms; the
  original author attribution is retained in [`LICENSE`](LICENSE) and in the
  image's `org.opencontainers.image.authors` label.
- **GitNexus application (the software inside the image):** **PolyForm
  Noncommercial License 1.0.0**, by
  [Abhigyan Patwari / Akon Labs](https://github.com/abhigyanpatwari/GitNexus).
  PolyForm Noncommercial permits **noncommercial use only**; commercial use of
  GitNexus requires an enterprise license from Akon Labs. This notice is
  reproduced from upstream and is your responsibility to comply with.

  > Required Notice: Copyright Abhigyan Patwari
  > (https://github.com/abhigyanpatwari/GitNexus)

This fork changes only the build/distribution plumbing (pinning + GHCR-only CI)
plus the build-time embedding-model bake. It does not modify the GitNexus
application or its license, and it does not relicense MekayelAnik's recipe.

---

## Non-goals (by design)

- **No auto-tracking of upstream.** No schedule, no `repository_dispatch`, no
  npm-release monitor, no Renovate. New versions land only when a human edits a
  pin and re-runs the workflow.
- **No Docker Hub.** The image is published exclusively to GHCR under
  `ghcr.io/brianbmorgan/sandbox-brain`. All upstream Docker Hub / multi-
  registry / README-sync machinery was removed.
- **No multi-arch.** amd64 only (Render target).
