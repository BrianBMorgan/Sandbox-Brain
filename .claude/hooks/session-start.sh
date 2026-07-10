#!/usr/bin/env bash
# SessionStart — records the session id, force-feeds a Sandbox-Brain briefing
# into context (git state, recent commits, the live WORKING-STATE pointer, a
# live brain-registry probe), and runs the capability preflight (which opens
# the edit gate when required caps are present).
#
# Sandbox-Brain: base branch is `main` (main-only repo — no development
# branch). This is a Docker build recipe + shell tooling — there is no
# package.json and no dependency install step.
set -uo pipefail
BASE_BRANCH="${BASE_BRANCH:-main}"
BRAIN="${BRAIN_URL:-https://sandbox-brain.onrender.com}"

INPUT="$(cat)"
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
mkdir -p "$ROOT/.claude/.state"
SID=$(printf '%s' "$INPUT" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{let j={};try{j=JSON.parse(d)}catch{}process.stdout.write(j.session_id||"")})')
[ -n "$SID" ] && echo "$SID" > "$ROOT/.claude/.state/session-id"

cd "$ROOT" 2>/dev/null || true
git fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
echo "════════════ Sandbox Brain session brief ════════════"
echo "branch: $(git branch --show-current 2>/dev/null)  ·  behind origin/$BASE_BRANCH by $(git rev-list --count HEAD..origin/$BASE_BRANCH 2>/dev/null || echo '?') commit(s)"
echo "recent commits:"; git log --oneline -6 2>/dev/null | sed 's/^/  /'
echo "uncommitted: $(git status --porcelain 2>/dev/null | wc -l | tr -d ' ') file(s)"

# Live pointer: print the newest WORKING-STATE session block (### heading) so a
# cold session lands on "where we are right now" without opening the file.
# Stops at the next ###-or-## heading so it never swallows the archive below.
if [ -f "$ROOT/WORKING-STATE.md" ]; then
  echo "WORKING-STATE (newest block):"
  awk '/^### /{c++; if(c==2) exit} c==1 && /^(## |---$)/{exit} c==1{print "  "$0}' "$ROOT/WORKING-STATE.md"
fi

# Live brain probe (open endpoint, no secret): is the registry reachable, and
# is every roster repo (parsed from scripts/refresh-brain.sh, same grep as
# freshness-check.yml, so this can never drift from the roster) present?
# Non-fatal by design — Render cold starts and egress policy are normal causes.
if command -v jq >/dev/null 2>&1; then
  REG=$(curl -sS -m 8 "$BRAIN/api/repos" 2>/dev/null) || REG=""
  if printf '%s' "$REG" | jq -e 'type == "array"' >/dev/null 2>&1; then
    N=$(printf '%s' "$REG" | jq 'length')
    mapfile -t ROSTER < <(grep -oE 'https://github\.com/[^"]+\.git' "$ROOT/scripts/refresh-brain.sh" 2>/dev/null \
                          | sed -E 's#.*/##; s#\.git$##')
    MISSING=""
    for r in "${ROSTER[@]:-}"; do
      [ -n "$r" ] || continue
      printf '%s' "$REG" | jq -e --arg n "$r" 'any(.[]; .name == $n)' >/dev/null || MISSING="$MISSING $r"
    done
    echo "brain: reachable · registry=$N repo(s) · roster=${#ROSTER[@]}${MISSING:+ · ‼️ MISSING from registry:$MISSING (see the orphaned-clone self-heal)}"
  else
    echo "brain: UNREACHABLE or non-JSON from $BRAIN/api/repos (Render cold start? egress policy?) — registry state unknown"
  fi
fi
echo
node "$ROOT/.claude/hooks/preflight.mjs" || true
echo
echo "→ Read CLAUDE.md (rules) · RUNTIME-TOPOLOGY.md (live wiring — supersedes CLAUDE.md on deploy specifics) · WORKING-STATE.md (handoff)."
echo "  VERIFY MCPs against your tools: required github (mcp__github__*); gitnexus = the brain itself (smoke test: query any roster repo)."
echo "  This repo is main-only: branch + DRAFT PR, never self-merge. Editing/committing is GATED on preflight."
