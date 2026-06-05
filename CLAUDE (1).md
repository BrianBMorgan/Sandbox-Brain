# CLAUDE.md

Guidance for working in this repo. Read alongside README.md (product + API surface), PLAN.md (strategy + roadmap archive), WORKING-STATE.md (live pointer — where we are right now), and docs/CI-AND-PR-CHECKS.md (pre-commit code check). For the shared code-graph brain (querying the codebase structurally via the GitNexus MCP, and indexing repos into it), see the skill files in `.claude/skills/gitnexus/`. Pitch Box **is** indexed into GitNexus as `Pitch-Box` — the generated section at the bottom of this file (and `AGENTS.md`) carries the live graph stats. Re-run `npx gitnexus analyze` after significant code changes to refresh it.

## Role and Persona
You are an expert, highly autonomous software engineering assistant operating in the Claude Code cloud environment (web/desktop-launched sessions against a fresh clone of this repo — no local working directory attached).

## Core Rules
Be Concise: Provide focused responses. Skip non-essential context, preamble, and over-explaining unless explicitly asked.
Write First: Write the implementation directly. Do not waste tokens asking for permission to make obvious changes.
Verify Before Committing: Run lighters/tests on the code before suggesting a commit or marking a task as complete.
Use Exact Language: Prefer hard numbers and specific facts over vague adjectives.

## Coding Standards
Prioritize clean, readable, and maintainable code.
Follow the established architecture and patterns of this codebase.
Avoid unnecessary abstractions.
Write unit tests for new features.

## Workflow Guidelines
Read the relevant codebase context using /context before making changes.
Use /goal to define clear terminal states or multi-step objectives you need to reach autonomously.
For large-scale refactors, break tasks down into smaller, iterative chunks to prevent memory overload.

## Bootstrap (every session)

The agent should orient itself in this order:

1. **`CLAUDE.md`** (repo root) — entry point for code intelligence.
2. **`WORKING-STATE.md`** (repo root) — current pointer for what's in flight, what just shipped, and what's next. ~100 lines max. The single source of truth for "where are we right now."
3. **`PLAN.md`** (repo root) — long-form retrospective archive. Search by date or topic when context is missing.

## Branch and PR workflow (non-negotiable)

The repo uses a **trunk → integration → production** model:

- `main` — production. The single Render service (`srv-d8h5g66q1p3s73fol5b0`) deploys from here. **This is the only branch that deploys.**
- `development` — integration / extra-hardening layer. All feature/fix work merges here first; it does **not** have its own Render service.

**Standard flow per change:**

1. `git fetch origin development` then `git switch -c <branch> origin/development`
2. Edit locally via `Edit` / `Write` tools (not GitHub Contents API — that's a deprecated workflow)
3. Syntax-check before commit: `node --check server.js` (the app is a plain-JS Express monolith + static `index.html` — no TypeScript, no build step).
4. `git add` + `git commit` with a real commit message (multi-line, why-focused, ending with the Claude session URL)
5. `git push -u origin <branch>`
6. Open a **draft PR** against `development` via `mcp__github__create_pull_request`. PR body should include: why, what, test plan, rollback if non-trivial.
7. Brian reviews + merges. **Never merge your own PR unless explicitly authorized.**
8. If you're subscribed to the PR via `subscribe_pr_activity`, wait for the webhook. Don't poll.

**Promotion to main** happens via a `development → main` rollup PR. Brian merges that one too. Since `main` is the only branch that deploys, the rollup is what ships to production.

## Concurrency safety

Local-git workflow makes the "two parallel sessions overwrote each other" disaster structurally impossible — `git push` rejects non-fast-forward updates. But the discipline still matters:

- **Always `git fetch origin <base>` before branching.** Don't branch off a stale local ref.
- **If `git push` is rejected as non-fast-forward**, never `--force` blindly. Pull, rebase, re-test, then push. Force-push to a feature branch is fine ONLY if you authored every commit on it; force-push to `development` or `main` is never authorized without explicit user approval.
- **For Edit tool replacements**, the harness errors if `old_string` is not unique in the file. Trust that — don't try to defeat it with `replace_all` unless every occurrence really should change.

## Render operations

- **Never use Render's bulk env-var PUT** (`PUT /v1/services/{id}/env-vars`). It REPLACES ALL VARS and has wiped production secrets historically. Use the dashboard manually or single-key PATCH (`PUT /v1/services/{id}/env-vars/{KEY}`).
- **No linked Environment Group** for this app — secrets (`DATABASE_URL`, `ADMIN_RELAY_PASSWORD`, etc.) live in the single service's own internal environment. Set them on the service directly.
- **Deploys take ~1–3 minutes** after merge to `main` (the only deploying branch). First boot of a deploy that adds new npm deps runs ~1 minute longer.

## Database operations

- The app's SQL relay (`POST /api/admin/relay` on the production host) accepts `{ adminPassword, query, values }` — use it for ad-hoc DB inspection rather than direct psql connections. Full writeup + operating rules: `docs/RENDERNEONSQLRELAY.md`.
- **Relay code map:** the endpoint is `app.post('/api/admin/relay', …)` in `server.js`, running caller SQL via the app's `@neondatabase/serverless` `sql` helper (bound to `DATABASE_URL`) — `sql(query, values)`. Gate is hardened: constant-time compare of `req.body.adminPassword` against `process.env.ADMIN_RELAY_PASSWORD` (`crypto.timingSafeEqual`), plus a disabled-when-unset `503` gate (no secret set → relay is off). Responses: `200 { success:true, rows, rowCount }`; bad/missing auth → `403`; missing query → `400`; SQL/driver error → `500 { success:false, error }`. One light audit line per call (timestamp + rowCount + truncated SQL); no persisted audit. Keep `ADMIN_RELAY_PASSWORD` set + secret — env-only, rotate if exposed.
- **Destructive operations** (`DELETE`, `DROP`, `UPDATE` without WHERE): always run `SELECT` first to count and inspect rows. Then run the mutation as a separate explicit command.
- **JSONB updates**: prefer `||` merge or `jsonb_set()` over full overwrite. Wholesale overwrite destroys concurrent edits.

## PR activity subscriptions

After opening a draft PR you can subscribe to its webhook stream with `mcp__github__subscribe_pr_activity`. The session then receives `<github-webhook-activity>` events for CI completion, review comments, and merges.

- **Don't poll.** No `sleep` loops, no repeated status checks. The webhook will wake the session.
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

Append the session's net changes to `PLAN.md` AND update `WORKING-STATE.md`. The first is archive; the second is the live pointer. Both have to be touched or the next session loses context.

If significant code work happened (a feature shipped, an architecture changed), also re-run `npx gitnexus@latest analyze` and commit the refreshed `CLAUDE.md` if the graph stats moved meaningfully.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **Pitch-Box** (176 symbols, 174 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/Pitch-Box/context` | Codebase overview, check index freshness |
| `gitnexus://repo/Pitch-Box/clusters` | All functional areas |
| `gitnexus://repo/Pitch-Box/processes` | All execution flows |
| `gitnexus://repo/Pitch-Box/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
