# WORKING — session handoff

Live pointer for in-flight, cross-repo brain work so the next session resumes
without re-discovery. This repo (Sandbox-Brain) is the **host** for the brain;
the work below mostly touches **Content-Brain** (the indexed content repo) and
**SYSOI** (the Brain console UI), which are separate repos.

Last updated: 2026-06-17

---

## DONE (2026-06-17): `PROSPECTS/` directory stood up in Content-Brain

**Goal (met).** Added a `PROSPECTS/` directory to **Content-Brain**
(`Sandbox-Group-LLC/Content-Brain`) holding public-safe snapshots of accounts
we're pursuing — grounding for outbound, NOT a pitch playbook.

**Shipped.** `PROSPECTS/README.md` (scope contract) + `PROSPECTS/_TEMPLATE.md`
(per-prospect shape) — Content-Brain PR **#2** merged to `main` on 2026-06-17. The prior
blocker (Content-Brain out of the session's repo scope) is gone: the repo is now
in scope and clones locally. File bodies are preserved below for reference; the
live files are in the repo.

**Remaining (optional, needs a human to name targets):** seed real
`PROSPECTS/<name>.md` docs from `_TEMPLATE.md`. **Pilot-first** — Content-Brain's
README mandates the *first* prospect PR cover **one** account so the PII gate is
calibrated before going wide; after that pilot is reviewed, batch a few per PR.

### Decision (settled with Brian)

Scope of a prospect doc = **snapshot + abstracted fit** (chosen over
"public-snapshot-only" and "full dossier incl. wedge/gap"). It mirrors the
existing `customers/` register — "just enough," intentionally borderline — but
**stricter**, because a prospect has no relationship yet.

**The operative guard** (the reframe that matters): the brain grounds
*generated, outward-facing copy*, so the test for every line in a prospect doc
is **"fine if it got quoted back to the prospect, or surfaced in an email we
send them?"**

### How the Mailforge brand profile translates to the guard

Mailforge (`ForgeOS` branch `apps/mailforge`) pulls a **Forge Intelligence brand
profile** per prospect *company* (not per person) via `lib/forge.js`
(`pullBrandProfile` fast / `requestBrandProfile` slow analyze). Split it:

- **IN (public, belongs in `PROSPECTS/`):** what they are / sell, public
  positioning, their own `signatureClaims` + `topicsCovered`, public
  `competitorAnalysis`, sourced recent public news, an abstracted "why they fit
  our ICP."
- **OUT (stays in Mailforge `company_pitches`, never in the brain):** the pitch
  dossier — `fitVerdict` internals, the diagnosed **gap**, the **wedge**,
  **stakes**, **entry offer**, **buyer path** with named contacts, **deal
  range**. (Entry offer / deal range trip the financials guard; buyer path
  trips the unannounced-people guard.)

The brand profile's *facts* translate; the brand profile's *angle* does not.
There is no per-person LinkedIn-style profile here — Mailforge is
company-grounded (per-contact enrichment lives in SYSOI's enrich path).

### Scaffold file 1 — `PROSPECTS/README.md`

```markdown
# Prospects

Public-safe snapshots of accounts we're pursuing — grounding for outbound,
NOT a pitch playbook. These differ from `customers/` in one way that matters:
there's no relationship yet, and the brain grounds generated copy, so the test
for every line is **"fine if it got quoted back to the prospect."**

IN (public / safe to surface):
- What they are, what they sell, public positioning + their own claims
- Public competitive landscape
- Recent public signal (sourced — the research button writes here)
- An abstracted "why they fit our ICP" — the broad value thesis only

OUT (lives in Mailforge `company_pitches`, never here):
- Fit score internals, the diagnosed gap, the wedge, the angle of attack
- Entry offer / deal range / any pricing or deal economics
- Named buyer-path individuals or unannounced contacts
- Anything NDA/confidential, personal contact info

A prospect is not a client — never assert or imply a relationship that doesn't exist.
```

### Scaffold file 2 — `PROSPECTS/_TEMPLATE.md`

```markdown
# <Prospect Name>

> Prospect — not a client. Public-safe snapshot. Last updated: <YYYY-MM-DD>

## Snapshot
- **What they are:** <one line>
- **Segment / industry:**
- **Domain:**
- **Positioning (their words):**
- **What they sell / public priorities:**

## Recent signal — public news
- <sourced bullet> [source](https://…)

## Competitive landscape (public)
- <competitor — public positioning>

## Why they fit our ICP (abstracted)
- <2–4 bullets: where our experience-first craft + SYSOI proof map to their
  public priorities. No wedge, no deal economics, no names.>
```

### Next steps (what's left)

1. ~~Confirm `Sandbox-Group-LLC/Content-Brain` is in the session's repo scope.~~ — done.
2. ~~Create `PROSPECTS/README.md` + `PROSPECTS/_TEMPLATE.md`, open a draft PR.~~ — done (Content-Brain PR #2 merged).
3. Seed real prospect docs from the `_TEMPLATE` (Brian names the prospect +
   domain; pull the public snapshot — ForgeScrape / FI brand profile for the
   public fields only). **Pilot one first**, get it reviewed, then batch a few per PR.
4. The Brain console's **"Research recent news → PR"** button already works on
   any path, so once a `PROSPECTS/<name>.md` exists it refreshes that doc's
   "Recent signal" block for free.

---

## DONE this session (SYSOI Brain console) — pending prod promotion

All merged into SYSOI's `development`; **promote `development → main`** to ship,
then set the env below.

- **PR #435** — brain chat now feeds **whole-file source for content (markdown)
  repos**. Root cause: Content-Brain is pure markdown indexed WITHOUT
  embeddings, so the MCP `query` retriever returns no symbols, chat fell back to
  keyword search, and the enrichment step (which required a `startLine`) dropped
  every path-only hit — the model saw only file paths ("I only have the path").
  Fixed: enrich any hit with a `filePath` (whole file for markdown, line-slice
  for code), shared char budget, dedup. This is what made "overview of the Intel
  client" actually quote `customers/intel.md`.
- **PR #438** — propose-edit **file picker** instead of free-text path. New
  read-only route `GET /api/brain/content-files` (`listMarkdownFiles` over the
  GitHub recursive tree) + a `<select>` in the Brain Chat `ProposeEditPanel`,
  with a graceful fallback to the text input if the list can't load.
- (Earlier) propose-edit + research-propose write paths to Content-Brain are
  live in the console.

**Prod enablement (do after promotion):**
- `BRAIN_GITHUB_TOKEN` needs **write** scope on `Sandbox-Group-LLC/Content-Brain`
  (propose-edit / research open PRs). The read-only source panel only needs read.
- `FORGE_SCRAPE_SERVICE_KEY` set for the "Research recent news" button.

---

## Reference: where things live

- **Brain console (UI + BFF):** SYSOI repo, `src/modules/brain/` +
  `web/src/screens/Brain.tsx`, served at `SYSOI.ai/app/brain` (platform-admin
  gated). PRs target SYSOI `development`, then promoted to `main`.
- **Content-Brain:** `Sandbox-Group-LLC/Content-Brain` — pure markdown
  (`companies/` · `customers/` · `industries/` · `voice/`, soon `PROSPECTS/`),
  indexed into the brain WITHOUT embeddings. In `scripts/refreshbrain.sh` REPOS.
- **Mailforge:** `BrianBMorgan/ForgeOS` branch `apps/mailforge` — outbound
  engine; brand-profile pull in `lib/forge.js`, pitch engine in `lib/pitch.js` /
  `lib/autopitch.js`. Deploys to `mailforge.forge-os.ai`.
