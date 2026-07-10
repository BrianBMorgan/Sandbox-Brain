# WORKING — session handoff

Live pointer for cross-repo brain state so the next session resumes without
re-discovery. This repo (Sandbox-Brain) is the **host** for the brain; the
work below also touches **Content-Brain** (the indexed content repo) and
**SYSOI** (the Brain console UI), which are separate repos.

Last updated: 2026-07-10

---

## Convention: the newest `###` block below is the live pointer

The session hooks read this file: `session-start.sh` prints the first `### `
block at boot, and the per-message status line shows its heading. Start each
significant session by prepending a `### YYYY-MM-DD — <headline>` block here.

### 2026-07-10 — Brain tools design settled: Composio, gated, audited (docs/BRAIN-TOOLS.md)

- Decision (Brian + session, same day): the brain gets **hands** via a
  **dedicated brain-scoped Composio project** — allowlisted toolkits,
  default-deny, workbench included. NOT the personal Composio account.
  **Email is FORBIDDEN outright, read and send.**
- The firewall invariant: tool output is turn-ephemeral — never
  `storeLearning`, never Content-Brain writes outside the existing draft-PR
  gate. The web is a tool, not a teacher.
- `[do]` prefix gates the loop; default `@brain` stays pure Q&A. Rollout:
  Stage 0 research-only → Stage 1 CRM read → Stage 2 confirmed drafts.
  Prereq #1 before any stage: fix the Slack `orgId=null` audit gap +
  `tool_runs` (also the Phase-1 training-pair seam).
- On the record: **`docs/BRAIN-TOOLS.md`** (full design) + PLAN.md Phase 0.5
  insert + decision log 2026-07-10 + next actions 6-8. Implementation is
  SYSOI work; this repo needs no changes at any stage.
- Landed same day: **`COMPOSIO_BRAIN_API_KEY` is live in SYSOI's Render
  env** (Brian, 2026-07-10, redeployed). Inert until the SYSOI `brainAct`
  PR declares it (`env.ts` + a `hasComposio` gate, `hasNango` pattern).
  Remaining Brian-side: finish the project's connection roster (research +
  CRM read + workbench; email/payments never connected).

### 2026-07-10 — Slack chat client documented (docs/SLACK-INTEGRATION.md)

- The brain's Slack client (SYSOI `src/modules/brain/slack.ts` + `chat.ts`,
  live in the Sandbox workspace) is now documented host-side in
  **`docs/SLACK-INTEGRATION.md`**: event flow, message grammar
  (`[RepoName]` / `[all]` / `[learn]` / threaded corrections), the
  per-question MCP load this service sees (~9 parallel `query` sessions in
  the default fleet-strategist mode), SYSOI env surface, and gotchas.
- Two SYSOI-side facts recorded there: (1) a pgvector semantic **sidecar**
  (`content_semantic_chunks`, H2-chunked books) now gives Content-Brain real
  semantic recall — the brain's `embeddings:0` stays correct; the 07-02
  "markdown can't embed" gap is routed around on SYSOI's side, not fixed in
  the fork; (2) a learnings loop (`brain_learnings`) stores Slack
  corrections and injects the top matches into future answers.
- Content-Brain sits at 279 files in the registry (91 on 07-02) — the
  book corpus Brian has been feeding it.

### 2026-07-10 — Session bootstrap landed (.claude hooks + capabilities.json + env setup)

- `.claude/` hooks ported from Forge-Intelligence: SessionStart brief (git
  state + this block + a live brain-registry probe against GET /api/repos),
  per-message status line, and the preflight edit gate driven by
  `capabilities.json` (watched env: `BRAIN_API_KEY`, `RENDER_API_KEY`).
- Preflight also enforces the 3-place pin agreement (PINS.md ·
  DockerfileModifier.sh · build.yml) — warn-only, never blocks.
- `.claude/env-setup.sh` is the environment Setup script: registers the brain
  itself as the `gitnexus` MCP (Bearer `BRAIN_API_KEY`) + boot smoke probes.
  Full doc: `docs/SESSION-BOOTSTRAP.md`.

---

## CURRENT STATE: the brain is healthy and self-defending

- **Roster (9):** `SYSOI.ai`, `Forge-Intelligence`, `Pitch-Box`, `Sandbox-GTM`,
  `Sandbox-ERP`, `ForgeOS`, `Content-Brain`, `Marquee`, `Changebase` — the
  `REPOS` list in `scripts/refresh-brain.sh`. All under `Sandbox-Group-LLC`.
- **Four refresh slots/day**, all serialized via the `brain-refresh`
  concurrency group: GTM solo 02:00 UTC (+ 14:00 backup) in `refresh-gtm.yml`;
  the non-GTM sweep 08:00 UTC (+ 18:00 backup) in `refresh-cron.yml`. Backups
  exist because GitHub silently drops scheduled events; each is an incremental
  no-op when its primary ran.
- **Three self-heals** in `refresh-brain.sh`: git-wedge (delete + re-clone),
  docs-only embeddings (re-analyze without embeddings), and **orphaned clone**
  (post-OK registry verification -> `force:true` re-analyze). See CLAUDE.md
  "The self-heals".
- **Independent detector:** `freshness-check.yml` (21:00 UTC, read-only, no
  secret) fails red if any roster repo is missing from `GET /api/repos` or the
  brain is unreachable. Deliberately does not heal — the sweep heals, the
  detector screams.

### The July incident this machinery came from (know the shape)

SYSOI.ai's registry entry silently vanished (~late June) while every nightly
reported green: with the graph gone but the on-disk clone intact, analyze
false-completed in ~1s at `phase=pulling` and the sweep's error-greps saw
"complete" as OK. Separately, a 2026-06-27 web-UI rename of the script
(`refreshbrain.sh` -> `refresh-brain.sh`) broke both workflows at the `run:`
step (exit 127) for two days — also invisible without checking run logs.
Fixed across PRs #24 (rename references), #25 (orphan-clone self-heal), #26
(roster 9 + freshness detector), #27 (detector jq fix). SYSOI.ai re-indexed
2026-07-02 (447 files / 8,347 nodes / 7,403 embeddings). **Lesson: workflow
green != brain healthy; the registry is the truth. The detector now encodes
that.**

---

## IN FLIGHT (opened 2026-07-02): strategist-intelligence roadmap — see PLAN.md

**`PLAN.md` now exists in this repo** — the slow-changing strategy for the
event-strategist intelligence: rent the engine, own memory / voice / judgment /
the data flywheel. Five-phase ladder: Phase 0 (voice wire + evals) -> Phase 1 (data engine) -> Phase 2 (LoRA) -> Phase 3 (provenance) -> Phase 4 (pretraining). This file stays the fast-changing handoff; the strategy
lives there.

**Immediate next (Phase 0):**

1. **Voice wire** — SYSOI `src/modules/brain/chat.ts`: Content-Brain queries
   get the strategist persona + `voice/brand-voice.md` (+ relevant
   `personas/*.md`) prepended to grounding; today the console answers as "a
   senior engineer." Draft PR off SYSOI `development` per that repo's workflow.
2. **Eval set** — seed SYSOI `evals/` with ~20 held-out brief->output scenarios
   (Brian picks the cuts). NOT Content-Brain — real briefs aren't public-safe
   (Rule 0).

---

## DONE: Content-Brain built out (see that repo for detail)

- **`prospects/`** (lowercase — renamed from `PROSPECTS/` in Content-Brain
  PR #6): scaffold merged in PR #2, then **8 public-safe prospect snapshots**
  seeded via the pilot-then-batch process in PR #4 (2026-06-17/18). The Rule-0
  guard held: snapshots carry public facts + abstracted ICP fit only; pitch
  internals (gap/wedge/economics/buyer path) stay in the operational apps.
- Repo has since grown: consolidated single root README (PR #9), `personas/`
  with six cited ICP buyer personas (PR #11), `industries/` incl. a
  customer-success-platforms record (PR #10), refreshed `voice/brand-voice.md`
  (PR #8), and `.claude/` session-bootstrap hooks + `capabilities.json` (PR #7).
- House style for content files: **no em/en dashes** — downstream LLMs mimic
  the docs they're grounded on.
- Indexed into the brain **without embeddings** (pure markdown): retrieval is
  keyword + graph; the SYSOI Brain console fetches whole files at query time.

## DONE: SYSOI Brain console — shipped to production

- PR #435 (whole-file markdown source for brain chat) and #438 (propose-edit
  file picker) were promoted via the `development -> main` promotion PR #439
  and are **live in prod** (SYSOI main is now well past PR #490). The prod env
  (`BRAIN_GITHUB_TOKEN` write scope, `FORGE_SCRAPE_SERVICE_KEY`) is set.
- PR #440 fixed the console's repo map: `ForgeOS` -> `Sandbox-Group-LLC/ForgeOS`
  (the repo transferred from the personal account mid-June; the brain's clone
  URL got the same fix in this repo's PR #18).

---

## Open threads (nothing blocking)

1. The user-side scheduled Claude routine that used to *run* the refresh
   should be a **notifier only** (unattended sessions can't execute scripts —
   the auto-mode classifier blocks them). Point it at the latest
   `freshness-check.yml` run and/or the open `GET /api/repos` endpoint.
2. Outbound (Mailforge, `Sandbox-Group-LLC/ForgeOS` branch `apps/mailforge`):
   enrichment + fit-scoring sweep completed mid-June; draft sequence
   generation is parked pending a human call. Details live in the private
   operational tooling, not here.

---

## Reference: where things live

- **Brain console (UI + BFF):** SYSOI repo, `src/modules/brain/` +
  `web/src/screens/Brain.tsx`, served at `SYSOI.ai/app/brain` (platform-admin
  gated). PRs target SYSOI `development`, then promote to `main`.
- **Content-Brain:** `Sandbox-Group-LLC/Content-Brain` — pure markdown
  (`companies/` · `customers/` · `industries/` · `personas/` · `prospects/` ·
  `voice/`), indexed into the brain WITHOUT embeddings. In
  `scripts/refresh-brain.sh` REPOS.
- **Mailforge:** `Sandbox-Group-LLC/ForgeOS` branch `apps/mailforge` — outbound
  engine; brand-profile pull in `lib/forge.js`, pitch engine in `lib/pitch.js` /
  `lib/autopitch.js`. Deploys to `mailforge.forge-os.ai`.

## 2026-07-02 — Markdown repos cannot take embeddings (upstream gap, loud by design)

Attempted the Content-Brain embeddings flip (the corpus outgrew the July-1
deferral: 91 files and the stacker about to add ~58 more). Result, verbatim:
"Embedding generation completed without persisted embeddings. The index was
not registered to avoid silently reporting embeddings: 0."

Diagnosis: the embedder covers code symbols; a markdown-only repo yields zero
embeddable units, so generation "completes" with nothing to persist and the
registration guard (correctly) refuses. Consequences:

- Content-Brain semantic retrieval is blocked UPSTREAM, not by a flag. The
  July-1 "taxonomy IS the retrieval system" posture is involuntarily true.
- Keyword+graph retrieval verified healthy post-restore (definitions come
  back for conceptual queries; ranking is lexical, so synonym asks drift).
- The real fix is teaching the embedder to embed File/Section nodes for
  markdown repos: a fork change here, not a SYSOI change. Candidate for the
  PLAN alongside the Phase-2 embedder pin bump.
- Until then: dense headings, index cards, and cross-links in Content-Brain
  are literally the search index. Write books accordingly.

Content-Brain was restored to the working embeddings:false config within the
minute (91f/798n). No data lost; the failed flip never registered.
