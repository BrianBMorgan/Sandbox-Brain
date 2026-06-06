#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Sandbox Brain — resilient, self-healing refresh
# ---------------------------------------------------------------------------
# Re-indexes each repo into the shared GitNexus brain. On the known `git pull`
# wedge (a dirty on-disk clone) it deletes the clone and re-clones fresh — the
# exact recovery that previously had to be done by hand. Polls the REST job API
# only (never the SSE /progress endpoint, which Render's edge kills). Stops and
# reports on OOM/gateway instead of hammering.
#
# This matters now that the index is PERSISTENT (/data): a wedged clone would
# survive redeploys, so the routine must heal it rather than wait for a wipe.
#
# EMBEDDINGS: the analyze POST sends `embeddings:true`. The serve API reads that
# flag from the request body ONLY — there is no ANALYZE_EMBEDDINGS env fallback
# in gitnexus (see gitnexus dist/server/api.js, `const { ..., embeddings } =
# req.body`). Without the flag every run produces embeddings:0 and semantic
# search is dead. Embedding is incremental (only new/changed symbols), so the
# flag is cheap on no-op runs. Requires the model baked into the image (it is)
# so the embedder gets a cache hit with no egress.
# ---------------------------------------------------------------------------
set -uo pipefail

BRAIN="https://sandbox-brain.onrender.com"

# Bearer auth for the brain HAProxy API_KEY gate. Token is env-only; never
# hardcode it. Export BRAIN_API_KEY in the environment that runs this script.
API_KEY="${BRAIN_API_KEY:-}"
AUTH=()
[ -n "$API_KEY" ] && AUTH=(-H "Authorization: Bearer $API_KEY")
[ -z "$API_KEY" ] && echo "WARNING: BRAIN_API_KEY not set; brain now requires API_KEY (calls will 401)." >&2

# Repos to keep indexed (HTTPS git URLs). Add/remove freely.
REPOS=(
  "https://github.com/Sandbox-Group-LLC/SYSOI.ai.git"
  "https://github.com/Sandbox-Group-LLC/Forge-Intelligence.git"
  "https://github.com/Sandbox-Group-LLC/Pitch-Box.git"
  "https://github.com/Sandbox-Group-LLC/Sandbox-GTM.git"
  "https://github.com/Sandbox-Group-LLC/Sandbox-ERP.git"
)

ALWAYS_FRESH=false   # false = pull, heal only on failure (fast) | true = delete+clone every run (bulletproof)
MAX_WAIT=300         # seconds to wait per repo before declaring it stuck/OOM
POLL=5               # seconds between status polls

reponame(){ local u="${1##*/}"; printf '%s' "${u%.git}"; }   # URL -> "SYSOI.ai"

# Analyze one repo and wait for a terminal state.
# Prints "code|detail" on stdout; rc: 0=complete 2=failed 3=gateway 4=timeout
run_analyze(){
  local url="$1" name="$2" resp http body jid st ph start el gw=0 payload
  # Build JSON with jq so a URL with special chars can't break the payload.
  payload=$(jq -n --arg url "$url" '{url: $url, embeddings: true}')
  resp=$(curl -sS "${AUTH[@]}" -m 60 -w $'\n%{http_code}' -X POST "$BRAIN/api/analyze" \
         -H 'Content-Type: application/json' -d "$payload" 2>/dev/null)
  http=$(printf '%s' "$resp" | tail -n1); body=$(printf '%s' "$resp" | sed '$d')
  jid=$(printf '%s' "$body" | grep -oE '"(jobId|id)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"/\1/')
  [ -z "$jid" ] && { printf 'failed|POST returned no jobId (HTTP %s)' "$http"; return 2; }
  start=$(date +%s)
  while true; do
    el=$(( $(date +%s) - start ))
    [ "$el" -ge "$MAX_WAIT" ] && { printf 'timeout|>%ss without finishing (likely OOM)' "$MAX_WAIT"; return 4; }
    resp=$(curl -sS "${AUTH[@]}" -m 30 -w $'\n%{http_code}' "$BRAIN/api/analyze/$jid" 2>/dev/null)
    http=$(printf '%s' "$resp" | tail -n1); body=$(printf '%s' "$resp" | sed '$d')
    case "$http" in
      502|503|504) gw=$((gw+1)); [ "$gw" -ge 3 ] && { printf 'gateway|HTTP %s x%s (brain down/OOM)' "$http" "$gw"; return 3; }; sleep "$POLL"; continue;;
    esac
    gw=0
    st=$(printf '%s' "$body" | grep -oE '"status"[^,}]*' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/')
    ph=$(printf '%s' "$body" | grep -oE '"phase"[^,}]*'  | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/')
    printf '    [%s +%ss] %s/%s\n' "$name" "$el" "${st:-?}" "${ph:-?}" >&2
    case "$st" in
      complete|completed) printf 'ok|%ss' "$el"; return 0;;
      failed|error) printf 'failed|%s (phase %s)' \
        "$(printf '%s' "$body" | grep -oE '"error"[^,}]*' | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/')" "${ph:-?}"; return 2;;
    esac
    sleep "$POLL"
  done
}

echo "=== Sandbox Brain refresh @ $(date -u +%FT%TZ) ==="
ok=true; declare -a REPORT
for url in "${REPOS[@]}"; do
  name=$(reponame "$url"); act="refreshed"
  if $ALWAYS_FRESH; then
    curl -sS "${AUTH[@]}" -m 30 -X DELETE "$BRAIN/api/repo?repo=$name" >/dev/null 2>&1; act="rebuilt fresh"
  fi
  res=$(run_analyze "$url" "$name"); rc=$?
  # Self-heal: a git pull/fetch/checkout failure means the on-disk clone is wedged.
  if [ "$rc" -eq 2 ] && printf '%s' "$res" | grep -qiE 'git (pull|fetch|checkout|merge)'; then
    echo "    [$name] pull wedge detected -> deleting clone + re-cloning"
    curl -sS "${AUTH[@]}" -m 30 -X DELETE "$BRAIN/api/repo?repo=$name" >/dev/null 2>&1
    res=$(run_analyze "$url" "$name"); rc=$?; act="HEALED (re-cloned)"
  fi
  if [ "$rc" -eq 0 ]; then REPORT+=("OK   | $name | $act | ${res#*|}")
  else ok=false;          REPORT+=("FAIL | $name | ${res%%|*} | ${res#*|}"); fi
done

echo; echo "=== per-repo result ==="; printf '%s\n' "${REPORT[@]}"
echo; echo "=== brain state (stats + persistence path) ==="
curl -sS "${AUTH[@]}" -m 30 "$BRAIN/api/repos" 2>/dev/null | jq -r '.[] |
  "\(.name)  [\(.path)]\n  files=\(.stats.files) nodes=\(.stats.nodes) edges=\(.stats.edges) comm=\(.stats.communities) proc=\(.stats.processes) emb=\(.stats.embeddings // 0) commit=\(.lastCommit[0:10]) indexed=\(.indexedAt)"' 2>/dev/null \
  || curl -sS "${AUTH[@]}" -m 30 "$BRAIN/api/repos" 2>/dev/null
echo
if $ok; then
  echo "RESULT: all repos refreshed OK"; exit 0
else
  echo "RESULT: FAILURE(S) above. If gateway/timeout, the brain likely OOM'd (Render 'pro' — bump the plan or set GITNEXUS_MAX_MEM_MB). Do not hammer-retry."; exit 1
fi
