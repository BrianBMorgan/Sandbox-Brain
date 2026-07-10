# Slack integration — the brain's chat client in Slack

> How the Sandbox Brain answers questions in Slack. The client code lives in
> **`Sandbox-Group-LLC/SYSOI.ai`** (not this repo); this doc records how it is
> wired **to the brain** so the host side stays operable without spelunking
> SYSOI. Verified against SYSOI.ai `main` @ `775c715` (2026-07-10, the brain's
> indexed commit). File paths below are SYSOI.ai paths unless prefixed
> otherwise.

## The one-paragraph version

Mention `@brain` in the Sandbox Slack workspace (or DM the bot). Slack POSTs
the event to SYSOI at **`POST /api/slack/events`** (signature-verified,
acked in <3 s). SYSOI's `brainChat` engine then retrieves grounding — the
brain's MCP `query` tool fanned across all 9 indexed repos, plus SYSOI's own
pgvector sidecars (Content-Brain book sections + past corrections) and
GitHub source enrichment pinned to the indexed commit — and makes one Claude
call that answers **only from that context**. The reply lands back in the
Slack thread via `chat.postMessage`, formatted for mrkdwn, with up to 5
source citations. Threaded follow-ups are captured as **corrections** and
fed back into future answers.

## Architecture

```
Slack workspace (@brain mention / DM)
      │  Events API (HMAC-signed)
      ▼
SYSOI  POST /api/slack/events          src/modules/brain/slack.ts
      │  verify sig → ack 200 → async
      ▼
   handleBrainQuestion ── [learn] / correction? ──► brain_learnings (pgvector)
      │ parseQuestion → repo + voice mode
      ▼
   brainChat                            src/modules/brain/chat.ts
      │
      ├─ 1. retrieve   brain MCP query per repo   ──► THIS SERVICE /api/mcp
      │                (fallback: POST /api/search) ─► THIS SERVICE /api/search
      ├─ 1.5 identity  voice/brand-voice.md + personas/*.md (Content-Brain, via GitHub)
      ├─ 2. enrich     real source @ indexed commit (GitHub, BRAIN_GITHUB_TOKEN)
      ├─ 2.2 semantic  content_semantic_chunks (SYSOI pgvector — book sections)
      ├─ 2.5 learnings brain_learnings (SYSOI pgvector — past corrections)
      ▼
   one Claude call (tier "reason", answers ONLY from grounding)
      │  markdownToSlack + ≤5 citations (+ ungrounded warning)
      ▼
   chat.postMessage — Nango proxy (slack-brain) → fallback SLACK_BOT_TOKEN
```

Two clients share `brainChat`: the **Brain console** (`SYSOI.ai/app/brain`,
platform-admin-gated, `POST /api/brain/chat`) and the **Slack bot** (public
endpoint, Slack-signature-gated). Everything below the route is identical.

## Inbound: `POST /api/slack/events` (`src/modules/brain/slack.ts`)

- **Events handled:** `app_mention` (any channel the bot is in) and `message`
  with `channel_type: "im"` (DMs). Everything else is acked and dropped.
- **Loop guard:** events with `bot_id`, `subtype: bot_message`, or
  `subtype: message_changed` are ignored — the bot never answers itself, and
  message edits do not re-trigger.
- **`url_verification`** (Slack app setup challenge) is answered **before**
  signature verification, deliberately, so initial setup works before
  `SLACK_SIGNING_SECRET` is deployed. Every real `event_callback` after that
  is verified.
- **Signature verification** (`verifySlackSignature`): HMAC-SHA256 over
  `v0:${timestamp}:${rawBody}` against `SLACK_SIGNING_SECRET`,
  constant-time compare, and a **±5-minute timestamp window** for replay
  protection. Requires the raw request body, which SYSOI captures app-wide
  for exactly this (`req.rawBody`). Bad signature → 401.
- **Ack discipline:** Slack requires a response within 3 seconds. The route
  acks `200` immediately and runs `handleBrainQuestion` fire-and-forget;
  failures are logged (`slack.bot.handler_failed`), never re-acked.
- **Rate limit:** 120 requests/min (express-rate-limit) — this is a public,
  Clerk-unauthenticated endpoint.
- **Not configured?** `SLACK_SIGNING_SECRET` missing → the route answers 503
  (`hasSlackBot` gate).

## Message grammar (what users can type)

| Message | Mode | System prompt | Retrieval |
|:--|:--|:--|:--|
| `@brain <question>` (default) | **Fleet-grounded strategist** | `STRATEGIST_FLEET_SYSTEM` | Fans across **all** indexed repos; ≥4 of 12 grounding slots reserved for Content-Brain |
| `@brain [RepoName] <question>` | Single-repo | `STRATEGIST_SYSTEM` if Content-Brain, else code-engineer `SYSTEM` | That repo only |
| `@brain [all] <question>` | **Neutral fleet librarian** | `FLEET_SYSTEM` | All repos, no voice layer, cites `[Repo] path` per claim |
| `@brain [learn] <fact>` | Manual teaching | — (no LLM call) | Stores the fact as a learning, replies "✅ Got it" |
| `@brain` (empty) | Help | — | Posts the usage tips message |
| Threaded reply under a bot answer | **Correction capture** | — | Reply >10 chars is stored as a learning against that Q/A (best-effort, non-blocking) |

`parseQuestion` strips the `<@MENTION>`, then matches `[all]` / `[RepoName]`
prefixes (repo name = the brain's registry name, e.g. `[SYSOI.ai]`,
`[Forge-Intelligence]`). Default is `repo=Content-Brain, fleet=true` — the
strategist voice with the whole fleet in reach. Voice-mode precedence lives
in one unit-tested function (`pickSystem`, `chat.ts`): fleet-strategist >
neutral fleet > single-repo strategist > code engineer.

## How it talks to THIS service (the part that matters here)

SYSOI's brain client is `src/modules/brain/service.ts`. Base URL
`BRAIN_API_URL` (default `https://sandbox-brain.onrender.com`); every call
sends `Authorization: Bearer $BRAIN_API_KEY` when set.

1. **Semantic retrieval — MCP `query`** (`brainQuery`): full StreamableHTTP
   handshake per request against **`POST /api/mcp`** — `initialize`
   (protocol `2024-11-05`, client `sysoi-brain-console`) → capture the
   `Mcp-Session-Id` header → `notifications/initialized` → `tools/call`
   `query {repo, query}`. The reply is SSE-framed JSON-RPC; SYSOI parses the
   last result frame and extracts the **first balanced JSON object** from the
   tool text — necessary because the tool appends a `**Next:** context({…})`
   usage hint whose braces broke a naive parse (that bug silently forced
   keyword fallback for a while; fixed). 60 s timeout, returns null on any
   failure → keyword fallback. In fleet modes this fans out to **one MCP
   query per registry repo** (`Promise.allSettled`, so ~9 concurrent MCP
   sessions per Slack question); the roster comes live from `GET /api/repos`.
2. **Keyword fallback — `POST /api/search`** (`searchBrain`, mode `hybrid`):
   used only when MCP returned nothing. Consistent with this repo's README
   caveat — the serve process doesn't lazy-load the embedder, so hybrid is
   effectively FTS/keyword there. Results dedup by `filePath` (markdown
   matches as several section nodes). Answers built this way still work but
   `grounded` stays false unless the semantic sidecar (below) hits.
3. **Source enrichment — GitHub, not the brain:** the brain stores only
   paths + line ranges. `getSource` fetches real file content from GitHub
   **pinned to the repo's `lastCommit` from `GET /api/repos`** (so snippets
   can't drift from what was indexed), using `BRAIN_GITHUB_TOKEN`. Top 6
   sources, 24 k char shared budget, 6 k/8 k per-snippet caps.
4. **Timeouts + failure shape:** REST 45 s, MCP 60 s, GitHub 30 s. Brain
   unreachable → SYSOI surfaces "the brain did not respond (it may be
   cold-starting or memory-bound — try again shortly)" and the Slack user
   gets the generic error reply. This matches the host-side rule: on
   502/503/504 **do not hammer-retry** (CLAUDE.md "Memory").

> Note: a header comment in `service.ts` still says the MCP endpoint is
> "currently open" — stale since 2026-07-03, when HAProxy started 401-gating
> `/api/mcp` (RUNTIME-TOPOLOGY.md auth matrix). Harmless: the client always
> sends the Bearer when `BRAIN_API_KEY` is set, which prod has.

## Grounding assembly (`brainChat`, `chat.ts`)

The context block is assembled in a fixed order, then **one**
`completeWithMeta({ tier: 'reason', maxTokens: 1400 })` call answers from it:

1. **PAST CORRECTIONS** — `searchLearnings(question)`: pgvector cosine
   search over `brain_learnings` (k=3, similarity floor 0.40, only
   `status='active'` rows). Injected as "apply these — do not repeat the
   same mistakes".
2. **Identity layer** (Content-Brain modes only): `voice/brand-voice.md` is
   ALWAYS prepended ("house rules — these win"), plus up to 2
   `personas/*.md` whose slug tokens all match the question
   (`matchPersonaPaths`, precision-first). 16 k char budget, separate from
   snippets. Best-effort — without `BRAIN_GITHUB_TOKEN` the strategist
   prompt still applies, just voiceless.
3. **MOST RELEVANT BOOK SECTIONS** — the Content-Brain **semantic sidecar**
   (`searchContentSemantic`): SYSOI's own pgvector index of book sections
   (see next section). k=6, 2 k chars/section, 12 k budget. A hit here sets
   `grounded=true` even if the brain's index returned nothing.
4. **RELEVANT EXECUTION FLOWS** — process summaries from the MCP query.
5. **RELEVANT DOCS & SYMBOLS** — the merged hit list. Fleet merging
   (`mergeFleetHits`) is round-robin across repos, deduped, capped at 12,
   with a **≥4-slot floor for Content-Brain** in default strategist mode so
   code volume can't crowd out business grounding.
6. **SOURCE SNIPPETS** — the GitHub-enriched real code/prose.

The strategist-fleet prompt enforces the business/code split: capability
claims must cite a code repo source, positioning/ICP claims cite the books,
and code is rendered as capabilities ("what we can DO"), never endpoints or
file internals.

## The Content-Brain semantic sidecar (important context for this repo)

The brain **cannot embed markdown** — gitnexus's embedder covers code
symbols only, so Content-Brain is registered `embeddings:false` and shows
`embeddings: 0` in `GET /api/repos` (see WORKING-STATE.md 2026-07-02; the
docs-only self-heal in `refresh-brain.sh` exists for exactly this).

SYSOI closed that gap **on its side**: `src/modules/brain/semantic-index.ts`
chunks every Content-Brain book by H2 section (`chunkMarkdownBook`), embeds
the chunks (OpenAI, `lib/embeddings`), and stores them in a
`content_semantic_chunks` pgvector table. Reindexing is incremental by
content-sha (cheap no-op runs) and prunes deleted files/sections. At answer
time the question is embedded and the cosine-nearest sections are injected
as primary grounding.

Consequences for the host side:

- The brain's registry stays `embeddings:0` for Content-Brain — that is
  **still correct** and the freshness/refresh machinery is unchanged.
- Real semantic recall over the ~279-file book corpus exists, but it lives in
  SYSOI's Postgres, not on the brain's disk. The "teach gitnexus to embed
  File/Section nodes" fork idea (WORKING-STATE 2026-07-02, PLAN.md) is now
  an optimization, not a blocker.
- The sidecar indexes from GitHub directly (`listMarkdownFiles` +
  `readFileOnBranch`), not from the brain — so its freshness is independent
  of this repo's refresh sweeps.

## The learnings loop (`learnings.ts`)

- **Capture:** two paths — threaded replies under a bot answer (auto,
  >10 chars, matched via an in-memory `recentExchanges` map: 500 entries max,
  24 h TTL) and explicit `[learn] <fact>` messages.
- **Store:** `brain_learnings` row (channel, thread_ts, user, Q, A,
  correction, combined text) with per-thread dedup via a DB unique
  constraint (`ON CONFLICT DO NOTHING`); the embedding is written async so
  the Slack reply is never blocked.
- **Recall:** every `brainChat` call (Slack AND console) searches learnings
  and injects the top 3 above the 0.40 similarity floor. Rows have a
  `status` column — set a row inactive to retire a bad learning.
- **Caveat:** the exchange map is **in-memory** — a SYSOI redeploy or a
  second replica loses thread→answer linkage for auto-correction capture
  (explicit `[learn]` is unaffected). Acceptable at current scale; known.

## Replying (`postToSlack`)

Order: **Nango proxy first** — `POST /proxy/chat.postMessage` with
`Provider-Config-Key: slack-brain` and the system-level connection id
`SLACK_BRAIN_NANGO_ID` (reuses the org's managed Slack OAuth) — then
**direct `SLACK_BOT_TOKEN`** fallback, else throw. Replies are always
in-thread (`thread_ts || ts`), links unfurled off. A 🧠 `reactions.add` on
the question doubles as the "thinking" indicator (best-effort). Answers run
through `markdownToSlack` (headers→bold, `**`→`*`, links→`<url|text>`,
code spans protected). Up to 5 citations in a fenced block; answers whose
retrieval found nothing carry "⚠️ this answer was not grounded in indexed
context". Errors get a friendly threaded apology and a
`slack.bot.brain_chat_failed` log line.

## SYSOI env surface (where this is configured — Render env of SYSOI, not this service)

| Var | Role |
|:--|:--|
| `SLACK_SIGNING_SECRET` | Gates the whole feature (`hasSlackBot`); verifies event signatures |
| `SLACK_BRAIN_NANGO_ID` + `NANGO_SECRET_KEY` | Primary posting path (Nango proxy, provider key `slack-brain`) |
| `SLACK_BOT_TOKEN` | Direct-token fallback for posting/reactions |
| `BRAIN_API_URL` | This service (default `https://sandbox-brain.onrender.com`) |
| `BRAIN_API_KEY` | Bearer for `/api/mcp` (and any gated route) — same value as this service's `API_KEY` |
| `BRAIN_GITHUB_TOKEN` | Source enrichment + identity/sidecar reads (private repos) |
| `ANTHROPIC_API_KEY` | The answer call (`tier: reason`) |
| `OPENAI_API_KEY` | Embeddings for learnings + the Content-Brain sidecar |
| `DATABASE_URL` | pgvector home of `brain_learnings` + `content_semantic_chunks` |

Slack-app side (inferred from the API calls in code): event subscriptions
for `app_mention` + `message.im` pointed at
`https://<sysoi-host>/api/slack/events`, and scopes covering
`app_mentions:read`, `im:history`, `chat:write`, `reactions:write`.

## Operational notes

- **Load shape on the brain:** one default-mode Slack question ≈ 9 parallel
  MCP `query` sessions (one per registry repo) + up to ~6 GitHub reads. The
  brain is memory-bound (CLAUDE.md) — if Slack answers start failing with
  the cold-start message, check the brain first, and do not hammer-retry.
  **There is no SYSOI-side concurrency limiter or queue on this fan-out
  today** — the only throttles are the endpoint's 120/min rate limit and
  organic Slack traffic. If usage grows into real bursts, the lever is a
  queue/limiter in SYSOI (same lesson as the GTM refresh split: concurrent
  heavy load is what pressures the brain) — never a brain-side memory cap
  (`GITNEXUS_MAX_MEM_MB` stays `0`).
- **Auditing gap (by design, know it):** the Slack path calls
  `brainChat(null, …)` — no org context — so `agent_runs` rows are NOT
  written for Slack questions (the `recordRun` insert requires an orgId).
  Console questions ARE audited. Slack traffic is visible via SYSOI logs
  (`slack.bot.*`, `brain.chat` warns) instead.
- **No secrets in this repo:** everything above lives in SYSOI's Render
  env. This repo only needs to keep `/api/mcp` + `/api/repos` + `/api/search`
  behaving as documented (routing + auth matrix: RUNTIME-TOPOLOGY.md).
- **Registry names are the contract:** `[RepoName]` targeting and the fleet
  fan-out both key off `GET /api/repos` names — the same basenames as the
  `REPOS` roster in `scripts/refresh-brain.sh`. Renaming an indexed repo
  breaks Slack targeting for it.
