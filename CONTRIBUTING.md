# Contributing to Neyam Vaani

வணக்கம் · नमस्ते · নমস্কার · ನಮಸ್ಕಾರ · నమస్కారం · नमस्कार · Hello 👋

Thank you for wanting to help build Vaani. This document tells you
everything you need to make your first contribution.

## Read these first

1. **[PRIVACY_CHARTER.md](PRIVACY_CHARTER.md)** — non-negotiable.
2. **[TENDER_UX_PRINCIPLES.md](TENDER_UX_PRINCIPLES.md)** — non-negotiable.
3. **[docs/architecture.md](docs/architecture.md)** — so your change fits the design.

Every PR includes a **principle compliance checklist** — see the
[pull request template](.github/PULL_REQUEST_TEMPLATE.md).

## Ways to contribute

| Role | What you do |
|---|---|
| 🔊 **Language steward** (most needed!) | Native speaker who owns localization quality for one language: UI strings, prompt review, voice QA |
| 💻 Code | Dart/Flutter, C++/JNI bridges, Python KB pipelines |
| 📚 Knowledge curation | Wikipedia dumps, govt schemes, form templates, health info |
| 🧪 Testing on real devices | Especially low-end Android phones (2–4GB RAM) |
| 📝 Documentation & translation | Docs, READMEs, error messages |

## Development setup

```bash
git clone https://github.com/Neyam-OpenSc/neyam-vaani.git
cd neyam-vaani/app

# One-time: generate Android platform folders (Flutter 3.24+)
flutter create . --platforms android --org org.neyamopensc --project-name neyam_vaani

flutter pub get
flutter analyze
flutter test
flutter run
```

C++ bridges (`native/`) build through the Android NDK via CMake — see
`docs/architecture.md` for the toolchain layout.

## Code style

- **Dart**: follow `flutter_lints` (enforced by `flutter analyze` in CI).
  Clean architecture: `data/` `domain/` `presentation/` layers stay separated.
- **C++**: C++17, RAII, no exceptions across the JNI boundary.
- **All user-facing strings** go through localization (`.arb` files) —
  never hardcoded, never English-only.
- **All errors** surface as kind, plain-language messages in the user's
  language (see Tender UX).
- **Tests first** for domain logic; 90% coverage is the bar for `domain/`.

## The "no" list (do not propose these)

To keep discussions focused, these are settled decisions:

- Cloud AI / OpenAI-style API calls (on-device only)
- Firebase or any analytics/telemetry
- Accounts and logins
- Ads or "monetization hooks"
- Gamification, streaks, badges
- Features outside the [top 20 use cases](docs/use-cases.md) for v1
- A chatbot persona with a name and backstory

See [GOVERNANCE.md](GOVERNANCE.md) for how to propose bigger changes (RFCs).

## Pull request process

1. Fork or branch from `main`.
2. Keep PRs small and single-purpose.
3. Fill in the PR template (including the principle checklist).
4. One maintainer approval from the relevant area merges it.
5. CI must pass: `flutter analyze` + tests.

## Reporting bugs

Use the issue templates — for anything that could be a security issue,
see [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Questions?

Open a [discussion](https://github.com/Neyam-OpenSc/neyam-vaani/discussions).
We are kind to newcomers by policy. 💛
