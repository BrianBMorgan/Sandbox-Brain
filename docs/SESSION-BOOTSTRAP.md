# Session bootstrap (Claude Code on the web)

Makes a fresh Sandbox-Brain session boot **warm, gated, and self-aware**
instead of cold and silently-missing-things. Ported from the
Forge-Intelligence bootstrap and adapted to this repo: base branch `main`
(main-only — no `development`), no dependency install (this is a Docker build
recipe, not an app), a **live brain-registry probe** in the boot brief, and a
**3-place pin-agreement check** in the preflight.

## What it does

```
session boots
  └─ SessionStart (.claude/hooks/session-start.sh)
        · prints a brief: branch · behind origin/main · recent commits ·
          newest WORKING-STATE block · live brain probe (GET /api/repos vs
          the refresh-brain.sh roster — same grep as freshness-check.yml)
        · runs the capability preflight → opens/closes the edit gate
every message
  └─ UserPromptSubmit (user-prompt-status.sh)
        · one-line live status: branch · behind · gate · current task ·
          MISSING watched secrets (BRAIN_API_KEY / RENDER_API_KEY)
any edit / commit / push
  └─ PreToolUse (pre-tool-gate.sh)
        · blocked (exit 2) unless the preflight passed THIS session
```

The payoff for this repo specifically:

- The **brain probe** catches the SYSOI.ai-class silent loss at boot — a
  roster repo missing from `GET /api/repos` is flagged before any work starts,
  independent of what the sweeps claimed overnight.
- The **pins check** enforces the "pin bump = 3-place edit" rule (PINS.md ·
  `DockerfileModifier.sh` fallback · `build.yml` default/env) every session,
  warn-only, so drift is caught at boot instead of in a failed GHCR build.
- The **status line** surfaces a wiped `BRAIN_API_KEY` at the first prompt —
  the exact failure where every authed call (analyze / delete / MCP) starts
  401ing mid-task.

## Files

| File | Role |
|------|------|
| `capabilities.json` | Source of truth: required CLIs, required vs **watched** env, MCPs, knownBlockers. |
| `.claude/hooks/session-start.sh` | SessionStart: brief + brain probe + preflight. `BASE_BRANCH=main`. |
| `.claude/hooks/preflight.mjs` / `.sh` | Capability check + pins check; writes/removes `.claude/.state/preflight-ok`. |
| `.claude/hooks/pre-tool-gate.sh` | PreToolUse: deny edits/commits until preflight passes this session. |
| `.claude/hooks/user-prompt-status.sh` | UserPromptSubmit: live status line. `WATCH_ENV=` the wipe-prone secrets. |
| `.claude/settings.json` | Hook registration (ACTIVE — committed; landed via reviewed PR). |
| `.claude/settings.json.example` | Reference copy for restoring/regenerating the registration. |
| `.claude/env-setup.sh` | Environment **Setup script** (paste into Environment settings): registers the `gitnexus` MCP + smoke probes. |

## Required vs watched env

- **required** (currently empty): a missing one **closes the gate** and blocks
  all edits. Keep tiny — doc and script edits need no secret.
- **watched**: never blocks, but a missing one is printed on every message.
  - `BRAIN_API_KEY` — bearer for the brain's HAProxy gate (`/api/analyze`,
    `DELETE /api/repo`, `/api/mcp`) AND the value the `gitnexus` MCP
    registration expands at connect time.
  - `RENDER_API_KEY` — Render REST inspection of the live service
    (`srv-d8dgc268bjmc73a5lup0`): deploys, env, logs, deploy-by-digest.

## The environment Setup script (one-time, per environment)

Paste the body of `.claude/env-setup.sh` into **Environment settings → Setup
script** of the dedicated Sandbox-Brain environment, and set `BRAIN_API_KEY`
in the environment config. It registers the brain itself as the `gitnexus`
MCP (StreamableHTTP at `https://sandbox-brain.onrender.com/api/mcp`) and
smoke-probes the service.

Three non-obvious traps, each of which has cost real time elsewhere:

- **`|| true` on the `claude mcp remove`** — the Setup script runs under
  `set -e`; on a fresh container there's no server to remove, and without it
  the whole script aborts (exit 1).
- **`tr -d '<>'` on the URL** — a pasted URL tends to get wrapped as
  `<https://…>` (markdown autolink); a bracketed URL registers literally and
  never connects.
- **SINGLE quotes around the `Authorization` header** — bash must NOT expand
  `${BRAIN_API_KEY}` at setup time (the Setup script context doesn't have it;
  double quotes bake an empty Bearer and every call 401s). Single quotes store
  the literal placeholder; Claude Code expands it at **connect** time from the
  session env.

**Smoke test once connected:** call the `gitnexus` MCP's `query` tool against
any roster repo (e.g. `{ "repo": "ForgeOS", "query": "subdomain proxy" }`).
That single call proves bearer → HAProxy gate → gitnexus serve → LadybugDB.
Remember the handshake caveat for raw HTTP clients: `initialize` →
`notifications/initialized` → `tools/call` with the `Mcp-Session-Id` header
(see CLAUDE.md "Consuming the brain").

## Activate

`.claude/settings.json` is **committed** — the reviewed PR that landed it is
the human activation step (the harness blocks the agent from writing its own
hook-registration file locally, and PR review preserves exactly that control).
Hooks bind at session start, so they take effect from the **next** session
after merge. If you ever need to deactivate: delete `.claude/settings.json`
(the `.example` stays as the restore source).

## Honest limits

- A hook can't attach a missing MCP to a *running* session or conjure a secret
  the sandbox can't see — that's harness physics. It makes the gap **loud and
  blocking at boot** so you restart once, deliberately, instead of discovering
  it deep in.
- These hooks only load when Sandbox-Brain is the session's **project root**
  (a dedicated environment). In a foreign/multi-repo session the kit is inert
  — by design.
- The brain probe needs egress to `sandbox-brain.onrender.com`; a blocked
  policy prints UNREACHABLE without failing the boot (don't misread that as
  the brain being down).
