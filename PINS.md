# Pinned dependencies

All pins below were resolved on **2026-06-01** for the self-hosted, fully-pinned
fork that builds to `ghcr.io/brianbmorgan/sandbox-brain`. Each entry records
the exact value, the source it was read from, and how to reproduce it.

This fork intentionally does **not** auto-track upstream. Bumping a pin is a
deliberate edit (update the value here + in `DockerfileModifier.sh` + the
workflow default, then re-run the workflow). See `README.md`.

| Dependency | Pinned value | Source | Resolved (UTC) |
|:-----------|:-------------|:-------|:---------------|
| Base image `node:22-trixie-slim` | `node:22-trixie-slim@sha256:e637ac91fb4f2f40761d217c5d48c41a05edf0b65eb9c34e72c27cce55af9e65` | Docker Hub registry (`registry-1.docker.io`, `library/node`, tag `22-trixie-slim`) | 2026-06-01 |
| HAProxy source `haproxy:lts` | `haproxy:lts@sha256:74735a91316c777de22894a4216729bfee79500caf5ed27dacf92dcd88b22f1c` | Docker Hub registry (`registry-1.docker.io`, `library/haproxy`, tag `lts`) | 2026-06-01 |
| `gitnexus` (npm) | `gitnexus@1.6.5` | npm registry `https://registry.npmjs.org/gitnexus` → `.dist-tags.latest` | 2026-06-01 |
| `mcp-proxy` (PyPI) | `mcp-proxy==0.12.0` | PyPI `https://pypi.org/pypi/mcp-proxy/json` → `.info.version` | 2026-06-01 |
| `serve` (npm) | `serve@14.2.6` | npm registry `https://registry.npmjs.org/serve` → `.dist-tags.latest` | 2026-06-01 |
| GitNexus frontend (git) | `4f7697c43b1aff0662eae528fc8a1bc01db6a284` | GitHub API `repos/abhigyanpatwari/GitNexus/commits/main` → `.sha` (HEAD of `main`) | 2026-06-01 |
| Embedding model (HF, baked) | `Snowflake/snowflake-arctic-embed-xs` (384-dim, fp32, ~90MB) | gitnexus 1.6.5 `DEFAULT_EMBEDDING_CONFIG.modelId` (loaded via `@huggingface/transformers`) | 2026-06-06 |

## How each pin was resolved

### `node:22-trixie-slim` digest

```bash
NODE_TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/node:pull" | jq -r .token)
curl -sI \
  -H "Authorization: Bearer $NODE_TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "https://registry-1.docker.io/v2/library/node/manifests/22-trixie-slim" \
  | grep -i 'docker-content-digest'
# docker-content-digest: sha256:e637ac91fb4f2f40761d217c5d48c41a05edf0b65eb9c34e72c27cce55af9e65
```

This is the multi-arch index digest for the `22-trixie-slim` tag. The build
only consumes `linux/amd64` (see workflow), but the digest pins the whole index
so the manifest resolution is reproducible.

### `haproxy:lts` digest

```bash
HAPROXY_TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/haproxy:pull" | jq -r .token)
curl -sI \
  -H "Authorization: Bearer $HAPROXY_TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
  "https://registry-1.docker.io/v2/library/haproxy/manifests/lts" \
  | grep -i 'docker-content-digest'
# docker-content-digest: sha256:74735a91316c777de22894a4216729bfee79500caf5ed27dacf92dcd88b22f1c
```

Only the `/usr/local/sbin/haproxy` binary is copied from this image into the
final image (`COPY --from=haproxy-src`), to get HAProxy with native QUIC/H3.

### `gitnexus` npm version

```bash
curl -s https://registry.npmjs.org/gitnexus | jq -r '.["dist-tags"].latest'
# 1.6.5   (v1.6.5 published 2026-05-16)
```

Installed in the final image as `gitnexus@1.6.5` (`npm install -g`). The
workflow exposes `gitnexus_version` as a dispatch input (default `1.6.5`) so a
specific build can pin a different gitnexus release without editing files.

### `mcp-proxy` PyPI version

```bash
curl -s https://pypi.org/pypi/mcp-proxy/json | jq -r '.info.version'
# 0.12.0
```

Installed as `mcp-proxy==0.12.0` (`pip install`). Previously floating
(`pip install mcp-proxy`).

### `serve` npm version

```bash
curl -s https://registry.npmjs.org/serve | jq -r '.["dist-tags"].latest'
# 14.2.6
```

Installed as `serve@14.2.6` (`npm install -g`). Previously floating
(`serve@latest`).

### GitNexus frontend commit

```bash
curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  https://api.github.com/repos/abhigyanpatwari/GitNexus/commits/main | jq -r '.sha'
# 4f7697c43b1aff0662eae528fc8a1bc01db6a284
# (HEAD of main on 2026-06-01, committed 2026-06-01T20:08:07Z)
```

The frontend-builder stage previously ran `git clone --depth 1 ... .` against
`main` (a moving target). It now performs a full clone and
`git checkout 4f7697c43b1aff0662eae528fc8a1bc01db6a284`, so the web UI is built
from a fixed commit. Verified at this commit the repo root still contains both
`gitnexus-shared/` and `gitnexus-web/` (the two packages the build compiles).

### Embedding model (baked into the image)

Confirmed from the pinned package's own source (`gitnexus@1.6.5`):

```bash
# node_modules/gitnexus/dist/core/embeddings/types.js
#   DEFAULT_EMBEDDING_CONFIG.modelId = 'Snowflake/snowflake-arctic-embed-xs'
#   dimensions: 384        # node_modules/gitnexus/dist/core/lbug/schema.js (GITNEXUS_EMBEDDING_DIMS default 384)
# node_modules/gitnexus/dist/core/embeddings/embedder.js
#   loaded via @huggingface/transformers: pipeline('feature-extraction', modelId, { dtype: 'fp32' })
#   env.allowLocalModels = false  → model MUST come from the HF cache, not a loose dir
```

This is **not a separately versioned pin** — it's gitnexus's hardcoded default,
so it only moves when `gitnexus` itself is bumped. It exists here to document the
why: gitnexus downloads this model from HuggingFace **at runtime** into the HF
cache, and the locked-down Render service has no egress to fetch it (and no
persistent cache), so embeddings silently produced `0`.

**Fix — baked into the image at build time** (`DockerfileModifier.sh`): a
throwaway repo is analyzed with `HF_HOME=/home/node/.cache/huggingface gitnexus
analyze --embeddings`, which downloads the model into
`/home/node/.cache/huggingface` — **the exact `HF_HOME` the upstream entrypoint
already exports at runtime** (`resources/entrypoint.sh`). So the runtime reuses
the baked cache with **zero network**, and the upstream entrypoint stays
untouched (no `ENV HF_HOME` override needed). The baked revision is whatever
HuggingFace `main` is for that model **at build time** (gitnexus doesn't pass a
fixed revision). A `find … -iname '*.onnx' | grep -q .` guard fails the build if
the model didn't land, so a silent regression can't ship.
