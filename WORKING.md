# WORKING — session handoff

Live pointer for cross-repo brain state so the next session resumes without
re-discovery. This repo (Sandbox-Brain) is the **host** for the brain; the
work below also touches **Content-Brain** (the indexed content repo) and
**SYSOI** (the Brain console UI), which are separate repos.

Last updated: 2026-07-02

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
