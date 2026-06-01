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

---

## How it builds

The Dockerfile is **generated**, not committed. `DockerfileModifier.sh` reads
`build_data/{base-image,haproxy-image,version,mcp_proxy_version}` (falling back
to the pinned values above) and heredoc-emits `Dockerfile.gitnexus-mcp`. The CI
workflow writes those `build_data` files from the pinned values, runs the
generator, then `docker buildx build … --push`.

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

This fork changes only the build/distribution plumbing (pinning + GHCR-only CI).
It does not modify the GitNexus application or its license, and it does not
relicense MekayelAnik's recipe.

---

## Non-goals (by design)

- **No auto-tracking of upstream.** No schedule, no `repository_dispatch`, no
  npm-release monitor, no Renovate. New versions land only when a human edits a
  pin and re-runs the workflow.
- **No Docker Hub.** The image is published exclusively to GHCR under
  `ghcr.io/brianbmorgan/sandbox-brain`. All upstream Docker Hub / multi-
  registry / README-sync machinery was removed.
- **No multi-arch.** amd64 only (Render target).
