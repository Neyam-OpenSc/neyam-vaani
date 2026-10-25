# Project Structure (monorepo map)

```
neyam-vaani/
├── README.md
├── LICENSE                    # Apache 2.0
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── GOVERNANCE.md
├── SECURITY.md
├── PRIVACY_CHARTER.md         # immutable product guarantees
├── TENDER_UX_PRINCIPLES.md    # the differentiator
├── .cursorrules               # rules for AI coding agents
├── docs/
│   ├── architecture.md
│   ├── use-cases.md
│   ├── language-pack-spec.md
│   ├── project-structure.md
│   ├── roadmap.md
│   └── rfcs/                  # proposals (numbered)
├── app/                       # Flutter application
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app.dart
│   │   ├── core/              # config, constants, errors, Result type
│   │   ├── data/              # services (voice, llm, knowledge, action),
│   │   │                      # repositories, models, local storage
│   │   ├── domain/            # entities, usecases, repository interfaces
│   │   ├── presentation/      # home, conversation, settings, widgets
│   │   └── l10n/              # app_ta.arb, app_hi.arb, …
│   ├── assets/
│   │   ├── audio/             # UI voice cues
│   │   ├── icons/
│   │   └── prompts/           # LLM system prompts (one per use case)
│   ├── android/               # generated per-machine (`flutter create .`)
│   └── test/
├── native/                    # C++ JNI bridges (planned)
│   ├── whisper_bridge/
│   ├── llama_bridge/
│   ├── piper_bridge/
│   └── vosk_bridge/
├── models/                    # model packaging scripts (planned)
├── knowledge/                 # KB build pipelines (planned)
│   ├── wikipedia_dump_processor/
│   ├── govt_schemes_loader/
│   └── form_templates/
├── scripts/                   # build/test/release automation
└── tests/
    ├── unit/
    ├── integration/
    └── e2e/
```

Layer rules (clean architecture):

- `presentation/` may import `domain/`, never `data/` directly.
- `data/` implements `domain/` repository interfaces.
- `core/` has zero dependencies on the other layers.
- Native bridges are consumed only through `data/services/`, never from UI.
