# PLAN — the strategist-intelligence roadmap

**What this is.** The slow-changing strategy doc for one cross-repo initiative:
building a specialized **event-strategist intelligence** on the Sandbox stack —
bootstrap-grade, owned, compounding. Settled with Brian 2026-07-01.

Doc roles in this repo: **CLAUDE.md** = how to work here · **WORKING.md** =
fast-changing session handoff · **PLAN.md** (this file) = why + what's next.
If it's not in a markdown file, it never happened.

Last updated: 2026-07-10

---

## Thesis

**Don't build the engine — rent fluency, own everything that makes it ours.**
The scarce input for a specialized model was never compute; it's **paired data
with outcomes** (context in → draft → human-final → result), and SYSOI mints
exactly that as operating exhaust. Models got cheap; judgment didn't.

The stack, by layer:

| Layer | Asset | State (2026-07-01) |
|:--|:--|:--|
| **Engine** | Claude via SYSOI `lib/claude.ts` (`deep`/`reason`/`fast` tiers) | Live |
| **Memory** | Sandbox Brain (this repo → GitNexus @ `sandbox-brain.onrender.com`, MCP `/api/mcp`) | Live; 9 repos indexed |
| **Knowledge** | Content-Brain (curated markdown: companies · customers · industries · personas · prospects · voice) | Seeded (27 files); indexed WITHOUT embeddings (deliberate — curate first) |
| **Voice / judgment** | `voice/brand-voice.md` + `personas/` | **Wired** — SYSOI #499 (strategist persona + voice prepend + persona matcher), promoted to prod via #500/#502 |
| **Console** | SYSOI `src/modules/brain/` — grounded chat + propose-edit (draft PR) + research-propose | Live on `main` (verified byte-level 2026-07-01) |
| **Audit** | `agent_runs` (model/tokens/latency/status on every AI call) | Live — telemetry only, not yet training pairs |
| **Parallel proof** | Forge Intelligence (Forge-Scrape → brand profile → compounding context → AI-citable content) | Live — same architecture, different domain |

## The ladder

Each rung is optional-until-earned. Costs are all-in estimates, not budgets.

### Phase 0 — voice wire + eval set (~$0, now)

- **Voice wire:** in SYSOI `src/modules/brain/chat.ts`, when
  `repo === 'Content-Brain'`, swap the "senior engineer" system prompt for the
  strategist persona and prepend `voice/brand-voice.md` (+ the relevant
  `personas/*.md`) to the grounding context. One conditional. Ships per SYSOI
  workflow: branch off `development`, draft PR, CI green, auto-merge.
- **Eval set:** ~100 held-out scenarios from the archive — real brief in,
  what-the-senior-person-did out. **The un-skippable rung**: without it, every
  later dollar is spent on vibes. Home: SYSOI `evals/` (private, versioned next
  to the consumer). **NOT Content-Brain** — real briefs aren't public-safe
  (Rule 0).

### Phase 0.5 — hands (tools via Composio, ~$0 infra) — ADDED 2026-07-10

The brain graduates from telling to **doing**: a new SYSOI `brainAct`
tool-use loop (engaged only by an explicit `[do]` prefix) backed by a
**dedicated, brain-scoped Composio project** — allowlisted toolkits,
default-deny, read-heavy start, mutations draft-only behind Slack-button
confirms. **Email is FORBIDDEN outright (read and send).** The one
load-bearing invariant: **tool output never writes to knowledge** — the web
is a tool, not a teacher; the three human-gated knowledge paths (learn /
corrections / draft PRs) stay the only ingestion. Full design, tiers,
prerequisites (audit identity first), and rollout stages:
**`docs/BRAIN-TOOLS.md`**. Strategic tie-in: every confirmed action mints a
Phase-1 training pair — the tool layer is the data engine's second surface.

### Phase 1 — the data engine (schema-cheap, this quarter)

`agent_runs` logs telemetry, not training data. Extend capture to full pairs:
**context in → AI draft → human-final version → downstream outcome**
(merged / published / sent / won). The edit distance between draft and shipped
IS the judgment — collected as exhaust, not homework.

- **First surfaces (human gate already exists):** Brain-console propose-edit
  (AI draft vs merged file), Dispatch pieces (draft → edited → published →
  analytics), contact recaps, Coda narratives.
- **Mechanism sketch:** a `training_pairs` table (or `agent_runs` extension)
  written at the merge/publish seams; provenance fields from day 1 (source,
  approver, rights-clean flag). Design doc first: SYSOI `docs/TRAINING-PAIRS.md`.
- **Boundary (settled — see WORKING.md, Mailforge split):** pitch-angle
  material (wedge / gap / economics / buyer path) stays in private surfaces;
  training pairs inherit the same IN/OUT line.
- Every week this isn't running is training data burned.

### Phase 2 — LoRA at ~1–5k pairs ($100s–low $1,000s)

Fine-tune an open model (Llama/Qwen class) on the pairs for **voice + volume
paths**: Dispatch drafts, recaps, mini-dossiers — pennies per call, owned
weights. Frontier stays rented for the reasoning tiers. **Portfolio, not
replacement.** Same visit: bump the embedder pin
(`snowflake-arctic-embed-xs` → a larger sibling; see PINS.md), re-embed, and
run the ten known-answer retrieval tests on Content-Brain the day embeddings
flip on.

### Phase 3 — provenance discipline (free, load-bearing, continuous)

Train only on **human-approved shipped artifacts + outcomes**. Never raw
frontier output. Better signal AND a clean rights trail — "doing it right"
includes the paper trail.

### Phase 4 — continued pretraining ($10–50k, only if fine-tunes ceiling out)

Named for completeness. Most people never need the rung.

## Decision log — 2026-07-01

- **Content-Brain embeddings: deferred** until the corpus outgrows
  read-the-files. Flip = already in `REPOS` with `embeddings:true` on the
  nightly sweep; until then the taxonomy IS the retrieval system.
- **Open item — README honesty:** Content-Brain's README claims semantic
  searchability; with embeddings effectively keyword-only, an agent that
  queries and misses concludes the knowledge doesn't exist. Add a "read files
  directly" note until the flip.
- **Eval home:** SYSOI `evals/`, not Content-Brain (Rule 0).
- **Console `DEFAULT_MAP` drift:** Marquee + Changebase are indexed in the
  brain but unmapped in SYSOI `src/modules/brain/repos.ts` → source enrichment
  silently dead for them. Patch via `BRAIN_REPO_MAP` env (no deploy) or a
  one-line PR.
- **Forge-LLM + the self-host box: abandoned, correctly.** The value was never
  in owning the window or the weights.

## Decision log — 2026-07-10

- **Tool layer: Composio, dedicated brain-scoped project** — one surface +
  workbench over provisioning 30+ MCPs. NOT the personal Composio account
  (its connections act as Brian; the Slack bot is workspace-wide).
- **Email: FORBIDDEN entirely — read and send.** Enforced by absence (never
  connected to the brain project), not just policy.
- **`[do]` prefix gates the loop** — default `@brain` mentions stay pure
  grounded Q&A. No prefix, no hands.
- **The firewall invariant:** tool output is turn-ephemeral; it never calls
  `storeLearning` and never writes Content-Brain outside the existing
  draft-PR gate. Design record: `docs/BRAIN-TOOLS.md`.
- **Audit before hands:** the Slack path's `orgId=null` audit gap gets fixed
  (system audit identity + per-call `tool_runs`) before Stage 0 ships.

## Next actions

1. [x] **Phase 0 voice wire** — SYSOI #499 merged; promoted to `main` (#500/#502). Live in prod.
2. [x] **Seed `evals/`** — done 2026-07-02: Brian authored EVAL-001..020
   (the archive cuts) on SYSOI `development`. His fifteen set a richer rubric
   format than the template; a normalization PR aligned the template + the
   early five to it. Per this plan: ~20 unblocks Phase 1.
3. [x] **`docs/TRAINING-PAIRS.md`** design doc — SYSOI #501 merged. The
   Phase 1 schema PR is now unblocked.
4. [ ] **`BRAIN_REPO_MAP`** patch for Marquee/Changebase.
5. [x] **Content-Brain README** — already true on `main`: the consolidated
   README states keyword+graph / no embeddings in two places. Fixed by a
   parallel session before this list existed.
6. [x] **Composio brain project + connections** (Brian, 2026-07-10):
   `COMPOSIO_BRAIN_API_KEY` deployed to SYSOI's Render env (inert until
   `brainAct` lands); roster v1 = GitHub + Drive + Docs + Sheets, grown
   gradually (research/CRM at Stage 2; email/payments never). GitHub
   action-scoped read-only same day — caveat resolved; provisioning done.
7. [x] **SYSOI audit identity** — SYSOI #563 (2026-07-10): migration 0057,
   null-org `agent_runs` + `brain_tool_runs` (sanitized args + hash).
8. [x] **SYSOI `brainAct` Stage 0** — SYSOI #563 (2026-07-10): the `[do]`
   loop, static read-only allowlist, default-deny + caps + FINAL TURN.
   Live in Slack on the next `development → main` promotion (env already
   set). Confirm buttons arrive with Stage 1.
9. [ ] **Action/injection evals** in SYSOI `evals/` (Brian picks the
   cases) — the gate before Stage-1 confirmed draft mutations.
