# Neyam Vaani — Governance

## Roles

| Role | Who | Powers |
|---|---|---|
| **Project Lead** | Founder (initially) | Final say on direction; veto on principle violations |
| **Lead Maintainers** (3–5) | Own a layer each: voice, LLM, knowledge, UX, native bridges | Merge PRs in their layer; vote on RFCs |
| **Maintainers** (10–20) | Trusted contributors | Merge PRs in their area |
| **Language Stewards** (1 per language) | Native speakers | Own localization quality for their language |
| **Contributors** | Anyone with a merged PR | Everyone who builds Vaani |

## How decisions are made

| Decision size | Process |
|---|---|
| Small (bug fixes, docs, refactors) | PR + 1 maintainer approval |
| Medium (new dependency, UX change) | RFC in `docs/rfcs/` → 1 week discussion → maintainers vote |
| Large (architecture, new features, scope changes) | RFC → 2 weeks discussion → lead maintainers vote → Project Lead may veto |
| **Principle violations** | Project Lead can veto immediately, no vote |

An RFC is a short markdown document under `docs/rfcs/` describing the
problem, proposed solution, alternatives, and risks.

## Principle protection

The [Privacy Charter](PRIVACY_CHARTER.md) and
[Tender UX Principles](TENDER_UX_PRINCIPLES.md) can only be changed by
unanimous lead maintainer vote **and** Project Lead approval — and only
ever to *strengthen* them, never to weaken them.

## Language stewardship

Each supported language has one steward who:

- Reviews and approves UI strings, prompts, and error messages for that language
- QA-tests voices (STT accuracy, TTS naturalness) with native speakers
- Has merge authority over files under `app/lib/l10n/` and prompt
  translations for their language

No machine translation ships to users without steward review.

## Sustainability

The project is funded by grants and sponsorships (see README) — never by
ads, data, or feature lockouts. Paid maintainer roles are published
openly when they exist.
