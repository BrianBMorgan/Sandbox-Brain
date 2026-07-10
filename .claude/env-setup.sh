#!/usr/bin/env bash
# Sandbox-Brain — Claude Code environment "Setup script".
# Paste the body of this file into the cloud environment's Setup script field
# (Environment settings → Setup script). It runs at the start of every session
# and bootstraps the dedicated Sandbox-Brain workflow:
#
#   1. Durably registers the brain itself as the `gitnexus` MCP (user-scoped)
#      so code-graph tools (query / context / impact / cypher) are available
#      against the 9 indexed repos.
#   2. Activates this repo's .claude hooks in a multi-repo cwd layout (when the
#      repo is the session root, the committed .claude/settings.json already
#      applies and step 2 is a no-op).
#   3. Smoke-probes the brain so a down/gated service is visible at boot.
#
# PREREQ: BRAIN_API_KEY must be set in the environment config (same value as
# the Render service's API_KEY). It is expanded by Claude Code at MCP *connect*
# time, not here — which is why the header below uses SINGLE quotes (do not let
# bash expand it at setup time).
set -e

# ── 1. Register the gitnexus MCP (durable, user-scoped). Idempotent. ──
# `|| true` on remove: the setup script runs under `set -e`; on a fresh
# container there is no server to remove, and without it the whole script
# aborts (exit 1).
claude mcp remove gitnexus --scope user 2>/dev/null || true
# `tr -d '<>'`: a pasted URL is often wrapped as <https://…> (markdown
# autolink); a bracketed URL registers literally and fails to connect.
u=$(printf %s 'https://sandbox-brain.onrender.com/api/mcp' | tr -d '<>')
# SINGLE quotes around the header: defer ${BRAIN_API_KEY} expansion to connect
# time. Double quotes bake an empty Bearer at setup time and every call 401s.
claude mcp add --transport http --scope user gitnexus "$u" --header 'Authorization: Bearer ${BRAIN_API_KEY}'

# ── 2. Activate the in-repo hooks in a multi-repo layout. ──
# Claude Code reads .claude/settings.json from the session cwd only. When this
# repo is the session root the committed settings.json already applies; in a
# multi-repo environment (cwd = parent dir with repos as subdirs) hooks won't
# load from the subdir — this copy is a best-effort assist for that layout.
for d in . Sandbox-Brain; do
  if [ -f "$d/.claude/settings.json.example" ] && [ ! -f "$d/.claude/settings.json" ]; then
    cp "$d/.claude/settings.json.example" "$d/.claude/settings.json" 2>/dev/null || true
  fi
done

# ── 3. Smoke probes (non-fatal). ──
# /api/repos is open by design: 200 = brain up. /api/mcp without a bearer
# should be 401: up + gated (503/000 = down or egress-blocked).
curl -sS -o /dev/null -w "brain /api/repos probe: %{http_code} (200 = up)\n" --max-time 8 \
  https://sandbox-brain.onrender.com/api/repos || true
curl -sS -o /dev/null -w "brain /api/mcp no-bearer probe: %{http_code} (401 = up + gated)\n" --max-time 8 \
  -X POST https://sandbox-brain.onrender.com/api/mcp -H "Content-Type: application/json" -d '{}' || true
