#!/bin/bash
set -euxo pipefail
# Set variables first
REPO_NAME='gitnexus-mcp'
# Fully-pinned fallbacks (self-hosted fork). Resolved 2026-06-01 — see PINS.md.
# build_data/* inputs (written by the CI workflow) override these, but the
# fallbacks are the source of truth for reproducible local runs.
BASE_IMAGE=$(cat ./build_data/base-image 2>/dev/null || echo "node:22-trixie-slim@sha256:e637ac91fb4f2f40761d217c5d48c41a05edf0b65eb9c34e72c27cce55af9e65")
HAPROXY_IMAGE=$(cat ./build_data/haproxy-image 2>/dev/null || echo "haproxy:lts@sha256:74735a91316c777de22894a4216729bfee79500caf5ed27dacf92dcd88b22f1c")
GITNEXUS_VERSION=$(cat ./build_data/version 2>/dev/null || echo "1.6.5")
GITNEXUS_MCP_PKG="gitnexus@${GITNEXUS_VERSION}"
# Frontend pinned to a fixed upstream commit (not main) — see PINS.md.
GITNEXUS_FRONTEND_COMMIT="4f7697c43b1aff0662eae528fc8a1bc01db6a284"
# serve: static file server for the web UI. Pinned.
SERVE_PKG="serve@14.2.6"
DOCKERFILE_NAME="Dockerfile.$REPO_NAME"

# Create a temporary file safely
TEMP_FILE=$(mktemp "${DOCKERFILE_NAME}.XXXXXX") || {
    echo "Error creating temporary file" >&2
    exit 1
}

# Check if this is a publication build
if [ -e ./build_data/publication ]; then
    # For publication builds, create a minimal Dockerfile that just tags the existing image
    {
        echo "ARG BASE_IMAGE=$BASE_IMAGE"
        echo "ARG GITNEXUS_VERSION=$GITNEXUS_VERSION"
        echo "FROM $BASE_IMAGE"
    } > "$TEMP_FILE"
else
    # Write the Dockerfile content to the temporary file first
    {
        echo "ARG BASE_IMAGE=$BASE_IMAGE"
        echo "ARG GITNEXUS_VERSION=$GITNEXUS_VERSION"
        cat << EOF
FROM $HAPROXY_IMAGE AS haproxy-src

# ── Frontend build stage (discarded — only dist/ is copied) ──
# Pinned to a fixed upstream commit (NOT main) for reproducibility — see PINS.md.
# The web UI is a generic graph viewer compatible with all API versions.
FROM $BASE_IMAGE AS frontend-builder
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /build
RUN git init -q . \\
    && git remote add origin https://github.com/abhigyanpatwari/GitNexus.git \\
    && git -c advice.detachedHead=false fetch --depth 1 origin ${GITNEXUS_FRONTEND_COMMIT} \\
    && git -c advice.detachedHead=false checkout ${GITNEXUS_FRONTEND_COMMIT}
# Build gitnexus-shared first (file: dep of gitnexus-web)
RUN --mount=type=cache,target=/root/.npm \
    cd gitnexus-shared && npm install --ignore-scripts --no-audit --no-fund && npx tsc
# Build gitnexus-web (produces dist/)
RUN --mount=type=cache,target=/root/.npm \
    cd gitnexus-web && npm install --ignore-scripts --no-audit --no-fund && npm run build
# Strip source maps and unnecessary files from dist
RUN find /build/gitnexus-web/dist -name '*.map' -delete 2>/dev/null; true

FROM $BASE_IMAGE AS build

# Author info:
# Self-hosted, fully-pinned fork. Docker recipe (GPL v3) by MOHAMMAD MEKAYEL ANIK;
# this fork is maintained by Sandbox Group LLC and built to ghcr.io/brianbmorgan/sandbox-brain.
LABEL org.opencontainers.image.authors="MOHAMMAD MEKAYEL ANIK <mekayel.anik@gmail.com>"
LABEL org.opencontainers.image.source="https://github.com/BrianBMorgan/sandbox-brain"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
LABEL org.opencontainers.image.description="Self-hosted fully-pinned fork of mekayelanik/gitnexus-mcp (GPL v3 recipe). Upstream GitNexus by Abhigyan Patwari / Akon Labs, PolyForm Noncommercial 1.0.0."

# Generate build timestamp (ARG busts cache when version changes)
ARG GITNEXUS_VERSION
RUN echo "Built: \$(date -u '+%Y-%m-%d %H:%M:%S UTC') | GitNexus v\${GITNEXUS_VERSION}" > /tmp/build-timestamp.txt

# Copy the entrypoint script into the container and make it executable
COPY ./resources/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/banner.sh /usr/local/bin/optimize.sh /usr/local/bin/healthcheck.sh \
    && mv -f /tmp/build-timestamp.txt /usr/local/bin/build-timestamp.txt \
    && chmod +r /usr/local/bin/build-timestamp.txt \
    && mkdir -p /etc/haproxy \
    && mv -vf /usr/local/bin/haproxy.cfg.template /etc/haproxy/haproxy.cfg.template \
    && ls -la /etc/haproxy/haproxy.cfg.template

# Install runtime packages (keep apt haproxy for shared libraries, binary replaced below)
# python3 stays for node-gyp (native module compilation during the gitnexus install).
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash haproxy gosu netcat-openbsd openssl ca-certificates iproute2 tzdata git wget procps \
    python3 && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man /usr/share/info /usr/share/locale /usr/share/lintian

# CUDA runtime libraries are NOT baked into the image to keep it slim.
# For GPU inference, mount the host's CUDA libs into the container:
#   volumes:
#     - /usr/local/cuda/lib64:/usr/local/cuda/lib64:ro
# The entrypoint registers mounted paths with ldconfig automatically.

# HAProxy with native QUIC/H3 support from official image
COPY --from=haproxy-src /usr/local/sbin/haproxy /usr/sbin/haproxy
RUN mkdir -p /usr/local/sbin && ln -sf /usr/sbin/haproxy /usr/local/sbin/haproxy

# Copy pre-built frontend static files from build stage
COPY --from=frontend-builder /build/gitnexus-web/dist /usr/local/share/gitnexus-web

# Create the data directory for repositories and state directory for lifecycle sentinels
RUN mkdir -p /data /state && chown node:node /data /state

# Install build tools, compile native deps, optimize, then remove build tools in single layer
# onnxruntime-node postinstall downloads CUDA EP binaries (~400MB) for GPU inference.
# At runtime, GPU is auto-detected: CUDA EP if --gpus all, otherwise CPU fallback.
# ONNXRUNTIME_NODE_INSTALL forces the postinstall to download CUDA binaries on linux/x64.
# On linux/arm64 the postinstall has no CUDA manifest and exits cleanly (CPU-only).
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    make g++ binutils && \
    echo "Installing ${GITNEXUS_MCP_PKG}..." && \
    ONNXRUNTIME_NODE_INSTALL=true \
    npm install -g ${GITNEXUS_MCP_PKG} --omit=dev --no-audit --no-fund --loglevel warn && \
    CUDA_SO=\$(find /usr/local/lib/node_modules -name 'libonnxruntime_providers_cuda.so' -type f 2>/dev/null | head -n1) && \
    if [ -n "\$CUDA_SO" ]; then \
      echo "CUDA EP: \$(du -sh "\$CUDA_SO")"; \
    elif [ "\$(uname -m)" = "x86_64" ]; then \
      echo "WARNING: CUDA EP missing on x86_64 — postinstall may have failed"; \
      echo "Checking npm postinstall logs..."; \
      find /root/.npm/_logs -name '*.log' -newer /tmp/build-timestamp.txt -exec tail -20 {} \; 2>/dev/null || true; \
    else \
      echo "CUDA EP: not present (CPU-only, expected on \$(uname -m))"; \
    fi && \
    echo "Installing serve (static file server)..." && \
    npm install -g ${SERVE_PKG} --omit=dev --no-audit --no-fund --loglevel error && \
    bash /usr/local/bin/optimize.sh && \
    rm -f /usr/local/bin/optimize.sh && \
    apt-get purge -y make g++ binutils && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /usr/share/doc /usr/share/man /usr/share/info /usr/share/locale /usr/share/lintian /var/log/*.log

# ── Patch: keep the incremental git pull from wedging on gitnexus's own writes ──
# gitnexus regenerates CLAUDE.md / AGENTS.md / .claude/ INTO each clone on every
# analyze (the /api/analyze route exposes no skip flag — api.js only forwards
# force/embeddings/dropEmbeddings to the worker), which dirties the working tree
# so the next 'git pull --ff-only' (git-clone.js cloneOrPull) refuses to run —
# forcing a full delete + re-clone + re-embed on every nightly refresh. Discard
# that auto-generated dirt (reset --hard + clean -fd) before the pull so updates
# stay INCREMENTAL. The graph + embeddings live under GITNEXUS_HOME, not the
# clone, so the reset is safe. The grep guard FAILS the build if a gitnexus
# version bump moved the pull line, so the un-patched wedge can never ship.
RUN F=/usr/local/lib/node_modules/gitnexus/dist/server/git-clone.js && grep -qF "await runGit(['pull', '--ff-only'], safeTarget);" "\$F" && sed -i "s|await runGit(\['pull', '--ff-only'\], safeTarget);|await runGit(['reset', '--hard', 'HEAD'], safeTarget); await runGit(['clean', '-fd'], safeTarget); await runGit(['pull', '--ff-only'], safeTarget);|" "\$F" && grep -qF "['reset', '--hard', 'HEAD']" "\$F" && node --check "\$F" && echo "PATCHED git-clone.js: reset+clean before ff-only pull"

# ── Bake the embedding model into the image (egress-proof) ──
# Embeddings use @huggingface/transformers (model Snowflake/snowflake-arctic-embed-xs,
# 384-dim, fp32, ~90MB), which downloads from HuggingFace at RUNTIME into the HF cache.
# A locked-down deploy (no egress) can't fetch it, so embeddings silently produce 0.
# Fix: pre-warm the cache HERE (the build has network) by running gitnexus's own embedding
# path on a tiny throwaway CODE repo. It MUST contain real symbols — a trivial file yields
# 0 embeddings and gitnexus refuses to register it (that was the first failed build). Bake
# into /home/node/.cache/huggingface — the exact HF_HOME the entrypoint exports at runtime —
# so runtime gets a cache hit with zero network, and we DON'T touch the upstream entrypoint.
# The find|grep guard FAILS the build if the model didn't land, so a broken bake can't ship.
RUN mkdir -p /home/node/.cache/huggingface /tmp/warmup && cd /tmp/warmup && git init -q . && git config user.email build@local && git config user.name build && printf 'export function greet(n){return "hi "+n;}\nexport function add(a,b){return a+b;}\nexport class Warm{run(){return greet("x")+add(1,2);}}\n' > warmup.js && git add -A && git commit -qm init && HF_HOME=/home/node/.cache/huggingface gitnexus analyze --embeddings && rm -rf /tmp/warmup && find /home/node/.cache/huggingface -iname '*.onnx' | grep -q . && chown -R node:node /home/node/.cache/huggingface

# Use an ARG for the default port
ARG PORT=8010

# Add ARG for API key
ARG API_KEY=""

# NVIDIA GPU support (used by onnxruntime when host passes --gpus)
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Set ENV variables for runtime
ENV PORT=\${PORT}
ENV API_KEY=\${API_KEY}
ENV DATA_DIR=/data

# L7 health check: analysis-aware script that reports healthy during startup phases
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \\
    CMD /usr/local/bin/healthcheck.sh

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

EOF
    } > "$TEMP_FILE"
fi

# Atomically replace the target file with the temporary file
if mv -f "$TEMP_FILE" "$DOCKERFILE_NAME"; then
    echo "Dockerfile for $REPO_NAME created successfully."
else
    echo "Error: Failed to create Dockerfile for $REPO_NAME" >&2
    rm -f "$TEMP_FILE"
    exit 1
fi
