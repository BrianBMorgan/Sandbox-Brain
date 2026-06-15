# Content Brain

The **content layer** of the Sandbox Brain. Where the GitNexus code brain knows how the
software is wired, this knows the *business* — companies, customers, industries, and voice —
so Claude sessions can generate content (site copy, pitch briefs, decks, outbound) that
already sounds like us and knows who we're selling to.

It's just **markdown**. No app, no service, no database. It lives in the **Sandbox-Brain
repo** — the brain's own host — so the business knowledge sits right next to the brain it
feeds. Any Claude session can read these files directly, and once this repo is indexed into
the brain (see the note below) everything here is semantically searchable alongside the code.

> **Searchability note.** Sandbox-Brain is the brain's *host* and isn't indexed into GitNexus
> by default (it's the recipe, not an indexed codebase). To make this content brain-searchable
> rather than just directly readable, add the Sandbox-Brain repo to the indexed `REPOS` in
> `scripts/refreshbrain.sh` — the markdown then lands in the graph as searchable sections.

---

# 🤖 AGENTS: READ THIS BEFORE YOU WRITE A SINGLE FILE

If you're an agent populating this brain (e.g. from Google Drive), this section is your
contract. Follow it exactly. Getting it wrong leaks private data into a system every other
agent can read — that's the one unforgivable mistake here.

## ⛔ Rule 0 — the PII / confidential gate (non-negotiable)

**Everything you commit here gets indexed into the brain and read by every agent.** So you
are not a file converter — you are a **filter**. Classify every source doc. Public-safe
business knowledge in; everything else **out**.

**NEVER put any of this in the Content Brain (no exceptions):**
- **People:** non-public individuals; unannounced hires/roles/titles; anyone's personal email, phone, address; org charts of private staff.
- **Money:** revenue, margins, P&L, budgets, pricing, quotes, rates, deal economics, bank/payment details, invoices.
- **Contracts/legal:** MSAs, SOWs, NDAs, anything under an NDA, legal correspondence, terms.
- **Customer confidential:** anything a customer shared in confidence, internal customer data, anything not already public about them.
- **Secrets:** credentials, API keys, passwords, tokens, internal URLs.
- **HR / personal:** personnel files, reviews, health, salaries.
- **Anything marked** "confidential," "internal," "do not distribute," or a private/unpublished draft.

**OK to include (public-safe only):**
- Published company facts, publicly announced funding/clients/partnerships, public exec names + titles.
- Industry/market context, public product info, public events/news.
- **Our own** positioning, voice, methodology, and anonymized learnings/patterns.
- Case studies **only** where the client has publicly agreed to be referenced.

**When in doubt, leave it out.** If a doc is *valuable but mixed*, extract only the
public-safe insight and drop the rest — do **not** copy the doc. If you can't confirm
something is public, it does not go in. Do **not** "quarantine" uncertain content into a
committed file; list it in the PR description for a human to rule on instead.

## ✍️ Rule 1 — synthesize, don't dump

The brain is memory-bound; the value is *curated knowledge*, not a Drive mirror. Do **not**
1:1 convert every document. **One dense file per entity** (company / customer / industry
topic), synthesized from many sources. Tight, scannable, sourced where a claim needs backing
(public links only). If you find yourself making `meeting-notes-2024-03-14.md`, stop —
fold the durable insight into the entity file and discard the rest.

## 📁 Rule 2 — where things go

```
companies/      our companies — who they are, what they do, positioning
customers/      target & active accounts — public-safe profiles and angles
industries/     reusable market context (a buyer's world, deadlines, dynamics)
voice/          brand voice, tone rules, do/don't — the "sound like us" layer
case-studies/   our proven, publicly-referenceable work, framed as reuse-ready proof
```
- **Filenames:** kebab-case, one per entity — `customers/nova-intelligence.md`, `industries/sap-modernization.md`.
- **Update in place** as knowledge grows. Don't create duplicates or dated variants.
- Match the shape of the existing seed files (`companies/sandbox-xm.md`, `customers/nova-intelligence.md`) — snapshot, the relevant facts, the angle. Dense and skimmable.

## 🔀 Rule 3 — branch → draft PR → wait (never commit straight to main)

- Work on a **branch**; open a **draft PR into `main`**. The Sandbox-Brain repo is
  **`main`-only** — there is no `development` branch. **Do not merge your own PR.**
- **PILOT FIRST:** your *first* PR covers **one company or customer only.** Stop and wait for
  human review so your judgment (especially the PII gate) gets calibrated before you go wide.
- After the pilot is approved, batch sensibly (a few entities per PR) so reviews stay possible.
- In each PR description, note: what sources you drew from (no private contents), and any
  items you *skipped/flagged* as possibly-private for a human to decide.

---

## How to use it (for content generation)

- **Writing content with Claude?** Point the session at the relevant files first:
  `voice/brand-voice.md` + the `customers/<account>.md` + the `industries/<topic>.md`.
  That's the context pack — it grounds the output so you stop rewriting.
- **Via the brain:** once this repo is indexed (see the Searchability note above), ask the
  GitNexus brain for the topic — these docs are then semantically searchable alongside the
  code, scoped with `"repo":"Sandbox-Brain"`.

> **The line that governs everything here:** the private working surface — PII, confidential,
> deal data — lives in the operational apps (the SYSOI app, CRM databases, etc.), never here.
> This repo is the *public-safe* knowledge layer. Keep them apart and the brain stays safe to
> share.
