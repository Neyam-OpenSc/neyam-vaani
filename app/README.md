# Vaani — Flutter app

The application layer of Neyam Vaani. Clean architecture:
`data/` · `domain/` · `presentation/` (see `docs/project-structure.md`).

## One-time setup

Platform folders are generated per machine (not committed):

```bash
cd app
flutter create . --platforms android --org org.neyamopensc --project-name neyam_vaani
flutter pub get
```

## Everyday commands

```bash
flutter analyze   # must be clean — CI enforces this
flutter test      # constants test runs today; more arrive with each phase
flutter run       # run on a connected device/emulator
```

## Phase status (post-sprint)

- [x] Clean-architecture folder skeleton
- [x] Language-first settings screen (all 9 languages, endonyms shown, fully localized)
- [x] Home screen with the single primary action: talk
- [x] Conversation screen with honest state panes
- [x] Calm error + loading widgets (reduced-motion aware, semantics labeled)
- [x] l10n string tables for all 9 languages (`lib/l10n/`, steward-review workflow)
- [x] Test suite across services and core (analyze-clean, CI-green)
- [ ] `flutter create .` platform folders (per machine)
- [ ] On-device validation with native model files (next milestone)

## What exists so far

- Voice services: audio capture, VAD, STT and TTS with native-bridge bindings
- LLM service + prompt router (on-device llama.cpp bindings)
- Intent classifier + 20-intent training corpus + slot extractor
- Action layer (SMS, calls, reminders, clipboard, torch, …) + encrypted-storage interfaces
- Knowledge base pipeline + hybrid search (FTS5 + embeddings)
- OCR service + document reading flow
- Translation service (NLLB bindings + offline dictionary fallback)
- Localization for 9 languages (`lib/l10n/`, steward-review pending per language)
- Test suite (`flutter analyze` clean, `flutter test` green in CI)

All of the above is code scaffolding: written and CI-green, but not yet
validated on hardware or with real native model files.
