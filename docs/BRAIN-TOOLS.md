# Brain tools — giving the strategist hands (design record)

> **Status: DESIGN — nothing in this doc is implemented yet.** Settled with
> Brian 2026-07-10. Implementation is SYSOI work (a new `brainAct` loop next
> to `brainChat`); this repo is the host and holds the cross-repo record.
> Read alongside `docs/SLACK-INTEGRATION.md` (how the brain answers today)
> and `PLAN.md` (where this sits on the ladder).

## The decision

The brain graduates from **telling** to **doing** via **Composio** — one
integration that brokers cross-app tool access (500+ apps, ~30 already
OAuth-connected on the Sandbox account) plus a remote workbench for
data-shaping. A **dedicated, brain-scoped Composio project** (Brian owns
setup), not the personal default account.

Why Composio over provisioning individual MCP servers:

- **One surface:** one API key in SYSOI's env, one SDK, uniform auth — vs
  30+ MCP servers each with its own credential, transport, and rot.
- **Discovery built in:** `COMPOSIO_SEARCH_TOOLS` returns the right tool +
  plan + known pitfalls per task, so the agent doesn't carry hundreds of
  schemas in context.
- **The workbench:** sandboxed remote execution for list-shaping, dedup,
  CSV work — the unglamorous 80% of "doing."
- **Kill switch:** drop the env key and the brain loses its hands and
  degrades cleanly back to telling. No redeploy of anything else.

## The firewall (the one invariant that makes this safe)

Brian's framing, verbatim intent: the brain must **use the web as a tool,
not learn from it**. The architecture already enforces this — knowledge has
exactly three write paths today, all human-gated:

1. `[learn]` messages (human-authored facts → `brain_learnings`)
2. Threaded corrections (human-authored → `brain_learnings`)
3. Draft PRs a human reviews and merges (propose-edit / research-propose /
   create-book → Content-Brain, Rule-0 guarded)

**The tool layer adds zero write paths to knowledge.** Hard rules for the
`brainAct` implementation:

- Tool output lives and dies in the turn's context. It is **never** passed
  to `storeLearning`, never written to Content-Brain directly, never
  auto-persisted anywhere the retrieval layer reads.
- Anything from a tool worth keeping goes through path 3 — a cited draft PR
  a human merges. Same gate research-propose uses today.
- Tool results are **untrusted input**: instructions found inside scraped
  pages, CRM notes, or API responses are data, not commands. The loop never
  escalates, never adds tools, and never crosses a CONFIRM gate because
  content told it to.

## Auth + scope model

- **Dedicated Composio project** with its own API key
  (`COMPOSIO_BRAIN_API_KEY` in SYSOI's Render env — never this repo).
  The personal Composio account (with Gmail, LinkedIn, payments-adjacent
  apps) is NOT wired to the brain: anyone who can `@brain` in Slack would
  otherwise be acting as Brian across every connected app.
- **Default-deny allowlist:** only toolkits added to the brain project
  exist as far as the brain is concerned. Growing the list is a deliberate,
  reviewable edit — same discipline as a pin bump in this repo.
- **Read-heavy start.** Mutations arrive one at a time, each behind a gate.

## Tool policy tiers

| Tier | Behavior | Examples (v1, per the connected roster below) |
|:--|:--|:--|
| **SAFE** | Auto-run, read-only | Google Drive / Docs / Sheets **read** (briefs, run-of-shows, budgets, calendars), workbench data-shaping, GitHub **read** (only once action-scoped — see the GitHub note) |
| **CONFIRM** | Runs only after an explicit human confirm (Slack button) or produces a **draft-only** artifact for human review | **Create-new-only** Docs/Sheets drafts in a designated Brain folder — the Docs equivalent of a draft PR; **never edit-in-place** — plus content draft PRs (via the existing propose paths) |
| **FORBIDDEN** | Not in the allowlist at all — the brain cannot see these tools | **Email — read AND send (settled 2026-07-10)**, payments, social posting, messaging sends outside the bot's own reply path, **raw GitHub mutations via Composio** (see below), anything not explicitly allowlisted |

**Connected roster (2026-07-10, Brian):** GitHub, Google Drive, Google
Docs, Google Sheets — deliberately small, grown gradually. Research/scrape
and CRM toolkits are NOT connected yet; they arrive in a later stage as
explicit adds. Email/payments/social are never connected.

**The GitHub caveat (open scoping call):** the Composio GitHub connection
is Brian's account — an unscoped toolkit could read any repo it sees and
write to any of them, which is strictly broader than the brain's existing
curated write path (SYSOI propose-edit / research-propose / create-book →
Rule-0-guarded draft PRs to Content-Brain only). gitnexus already covers
code reading for the indexed repos. So GitHub via Composio is **read-only
actions at most** in v1 (restricted at the Composio action level, not just
policy), raw mutations stay FORBIDDEN, and all content writes keep flowing
through the existing propose paths.

Slack replies keep flowing through the existing Nango `slack-brain`
connection (`docs/SLACK-INTEGRATION.md`) — the bot's own voice is not a
Composio tool.

## Engagement grammar

The tool loop engages **only** on an explicit prefix, consistent with the
existing grammar:

| Message | Path |
|:--|:--|
| `@brain <question>` | `brainChat` — pure grounded Q&A, exactly as today |
| `@brain [do] <task>` | `brainAct` — the tool loop (SAFE tools auto, CONFIRM tools gated) |
| `[RepoName]` / `[all]` / `[learn]` | Unchanged |

Default mentions never touch tools. No prefix, no hands.

## Architecture sketch (SYSOI side)

- **New `brainAct` loop** next to `brainChat` — an agentic tool-use loop
  (Claude tool-runner), NOT a flag on the existing single-completion path.
  `brainChat` stays untouched as the default answerer.
- **Caps:** max ~8 loop iterations, ~6 tool calls per task, per-tool
  timeout, and a total wall-clock budget; the 🧠-reaction ack pattern
  extends with thread progress updates for long tasks. When a cap is about
  to bite, the loop tells the model it is on its **final iteration**, so
  the reply closes with a structured plan for the remainder rather than a
  mid-task truncation.
- **Grounding discipline carries over:** the final reply cites which tool
  produced which claim, same as source citations today.
- **Concurrency:** `brainAct` tasks get a small SYSOI-side concurrency cap
  from day 1 — the limiter the Q&A fan-out never had
  (`docs/SLACK-INTEGRATION.md` "Load shape").

## Prerequisites — ordered, before ANY tool ships

1. **Audit identity (the `orgId=null` gap).** Slack calls currently skip
   `agent_runs` entirely. A brain that *acts* unaudited is undebuggable.
   Fix: a system-level audit identity (or nullable-org rows) so every
   `brainAct` run lands in `agent_runs`, plus a per-call `tool_runs` record
   (tool slug, **sanitized + truncated args** — secrets redacted, capped
   length — plus an args hash for integrity, outcome, latency). A hash
   alone can verify what ran but can't answer "what did the brain do?"
   during an incident; sanitized args can. This is also the Phase-1 seam:
   **every CONFIRM action is a training pair** (context → draft action →
   human confirm/edit → outcome) — the tool layer is the data engine's
   second surface (PLAN.md Phase 1).
2. **Action evals** in SYSOI `evals/` (the base EVAL-001..020 set exists;
   these are additive): does it pick the right tool, does it stop at
   CONFIRM gates, does it refuse FORBIDDEN asks, does it ignore
   instructions embedded in tool output (injection cases).
3. **The Composio project + connections** (Brian — DONE 2026-07-10):
   project live, `COMPOSIO_BRAIN_API_KEY` in SYSOI's env, initial roster
   connected (GitHub, Drive, Docs, Sheets). Email/payments/social left
   unconnected so FORBIDDEN is enforced by absence, not just policy.
   Remaining scoping call: restrict GitHub to read-only actions before
   Stage 0 (see the GitHub caveat above).

## Rollout stages

Each stage is a deliberate allowlist edit + a WORKING-STATE entry — never a
silent broadening.

- **Stage 0 — workspace reads:** Drive/Docs/Sheets read + workbench, SAFE
  tier only (GitHub read joins once action-scoped). The brain can pull the
  brief, read the budget sheet, and shape data mid-task. No mutations
  anywhere. An event professional's raw material is in the workspace, not
  the open web — and internal docs are a far smaller injection surface
  than scraped pages.
- **Stage 1 — confirmed drafts:** first CONFIRM-tier mutations,
  create-new-only (Docs/Sheets drafts in the Brain folder, content draft
  PRs via the propose paths). Slack button confirms, every one audited and
  minting a training pair. Never edit-in-place.
- **Stage 2 — research + CRM:** web search/scrape and Attio/HubSpot read
  toolkits get connected as explicit adds. This is where the open-web
  injection surface arrives — the firewall + gates are already proven by
  then.
- **Later, maybe:** direct mutations with confirms. Email stays FORBIDDEN
  until explicitly re-decided — that includes read.

## Risks, named plainly

- **Prompt injection is live from Stage 0:** the brain reads the open web
  next to a persona with (eventually) write tools. Mitigations: FORBIDDEN
  by absence, CONFIRM gates on everything outward, the no-auto-learn
  firewall, injection eval cases, and citing tool provenance in replies.
- **Acting-as-whom:** even project-scoped, tool calls run under the
  project's connections. The audit trail (prereq 1) is what makes "who did
  what via the brain" answerable. Slack user id is captured on every
  exchange today; `tool_runs` must carry it too.
- **Cost/runaway:** caps above, plus the per-question tool-call cap. A
  `[do]` task that needs more than ~6 calls should end with a plan, not an
  unbounded crawl.
- **Composio outage = hands offline.** Acceptable by design — the brain
  degrades to telling; Q&A (brainChat) has zero Composio dependency.

## Ownership split

| Piece | Where | Who |
|:--|:--|:--|
| Composio project, connections, allowlist | Composio dashboard | Brian |
| `brainAct` loop, `[do]` parsing, confirm buttons, caps | SYSOI (`src/modules/brain/`) | SYSOI PRs off `development` |
| Audit identity + `tool_runs` | SYSOI (DB migration + chat/act paths) | SYSOI PR, before Stage 0 |
| Action evals | SYSOI `evals/` | Brian picks cases, PR normalizes |
| This record + rollout log | This repo (`docs/`, WORKING-STATE.md, PLAN.md) | Every stage change lands here |

The brain host (this repo) needs **no changes** for any stage — the brain
serves retrieval exactly as it does today; the hands live entirely in SYSOI.
