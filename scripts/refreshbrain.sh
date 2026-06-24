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

# Repos to keep indexed (HTTPS git URLs). Add/remove freely. A subset can be
# selected per run via BRAIN_ONLY / BRAIN_SKIP (see the filter below) so the
# heaviest repo can run on its own off-peak schedule.
REPOS=(
  "https://github.com/Sandbox-Group-LLC/SYSOI.ai.git"
  "https://github.com/Sandbox-Group-LLC/Forge-Intelligence.git"
  "https://github.com/Sandbox-Group-LLC/Pitch-Box.git"
  "https://github.com/Sandbox-Group-LLC/Sandbox-GTM.git"
  "https://github.com/Sandbox-Group-LLC/Sandbox-ERP.git"
  "https://github.com/Sandbox-Group-LLC/ForgeOS.git"
  "https://github.com/Sandbox-Group-LLC/Content-Brain.git"
)

ALWAYS_FRESH=false   # false = pull, heal only on failure (fast) | true = delete+clone every run (bulletproof)
MAX_WAIT=1200        # seconds to wait per repo. The persistent clone wedges most
                     # runs (analysis dirties it), so the heal path re-clones and
                     # re-embeds from scratch — a full embed of the big repos
                     # (Sandbox-GTM ~8.5k, Sandbox-ERP ~5.7k) runs 8–10 min. 300s
                     # used to time out mid-embed, abandoning a still-running job
                     # and 409-poisoning every repo after it.
POLL=5               # seconds between status polls

reponame(){ local u="${1##*/}"; printf '%s' "${u%.git}"; }   # URL -> "SYSOI.ai"

# Analyze one repo and wait for a terminal state.
# Prints "code|detail" on stdout; rc: 0=complete 2=failed 3=gateway 4=timeout
run_analyze(){
  local url="$1" name="$2" emb="${3:-true}" resp http body jid st ph start el gw=0 payload pstart
  # Build JSON with jq so a URL with special chars can't break the payload.
  # $emb (default true) drops to false for docs-only repos with no embeddable
  # symbols — see the embeddings self-heal in the sweep loop below.
  payload=$(jq -n --arg url "$url" --argjson emb "$emb" '{url: $url, embeddings: $emb}')
  # The brain serializes analyze jobs: POSTing while another repo is still
  # indexing returns 409. Back off and wait for the in-flight job to finish
  # rather than failing (and cascading the failure to every later repo).
  pstart=$(date +%s)
  while true; do
    resp=$(curl -sS "${AUTH[@]}" -m 60 -w $'\n%{http_code}' -X POST "$BRAIN/api/analyze" \
           -H 'Content-Type: application/json' -d "$payload")
    http=$(printf '%s' "$resp" | tail -n1); body=$(printf '%s' "$resp" | sed '$d')
    [ "$http" != "409" ] && break
    [ "$(( $(date +%s) - pstart ))" -ge "$MAX_WAIT" ] && { printf 'failed|brain busy (409) >%ss' "$MAX_WAIT"; return 2; }
    printf '    [%s] brain busy (409) - waiting for the in-flight job...\n' "$name" >&2
    sleep "$POLL"
  done
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

# Optional repo filter (NAME-matched, comma- or whitespace-separated):
#   BRAIN_ONLY="Sandbox-GTM"   -> sweep ONLY these repos
#   BRAIN_SKIP="Sandbox-GTM"   -> sweep all EXCEPT these
# Unset (both) = every repo, unchanged. This lets the heaviest repo run on its
# own off-peak schedule: a full all-repos sweep peaks the persistent brain's RAM
# and OOM-kills the analyze worker on the biggest graph (a killed worker reports
# "code null"). Isolating that repo to its own run keeps each analyze against a
# cold memory baseline. (Do NOT reach for GITNEXUS_MAX_MEM_MB to fix OOM — it
# must stay 0 or LadybugDB can't mmap its 16 GiB reservation and every brain
# tool returns "LadybugDB unavailable".)
_only="${BRAIN_ONLY:-}"; _skip="${BRAIN_SKIP:-}"
if [ -n "${_only}${_skip}" ]; then
  in_list(){ local n="$1" i; shift; for i in "$@"; do [ "$i" = "$n" ] && return 0; done; return 1; }
  read -r -a _onlyA <<< "${_only//,/ }"
  read -r -a _skipA <<< "${_skip//,/ }"
  declare -a _filtered=()
  for url in "${REPOS[@]}"; do
    n=$(reponame "$url")
    if [ -n "$_only" ]; then
      in_list "$n" ${_onlyA[@]+"${_onlyA[@]}"} && _filtered+=("$url")
    elif in_list "$n" ${_skipA[@]+"${_skipA[@]}"}; then
      continue
    else
      _filtered+=("$url")
    fi
  done
  REPOS=(${_filtered[@]+"${_filtered[@]}"})
  [ "${#REPOS[@]}" -eq 0 ] && { echo "ERROR: repo filter matched no repos (BRAIN_ONLY='$_only' BRAIN_SKIP='$_skip')" >&2; exit 2; }
  printf 'Repo filter active -> %s repo(s):' "${#REPOS[@]}"; for url in "${REPOS[@]}"; do printf ' %s' "$(reponame "$url")"; done; echo
fi

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
  # Self-heal: a docs-only repo (pure markdown, no code symbols) yields 0
  # embeddings, and the analyze guard refuses to register it with embeddings:true
  # ("without persisted embeddings"). Re-analyze without embeddings — keyword +
  # graph search still work; there are no symbols to embed anyway.
  if [ "$rc" -eq 2 ] && printf '%s' "$res" | grep -qiE 'without persisted embeddings|embeddings: ?0'; then
    echo "    [$name] no embeddable symbols (docs-only) -> re-analyzing without embeddings"
    res=$(run_analyze "$url" "$name" false); rc=$?; act="indexed (no embeddings)"
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
  echo "RESULT: FAILURE(S) above. A killed worker (code null), gateway, or timeout on a big repo is almost always the brain OOMing — give the heavy repo its own off-peak run (BRAIN_ONLY) or bump the Render plan. Do NOT set GITNEXUS_MAX_MEM_MB (it must stay 0 or LadybugDB can't mmap). Do not hammer-retry."; exit 1
fi
