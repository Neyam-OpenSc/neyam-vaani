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

## Phase 0 status (this skeleton)

- [x] Clean-architecture folder skeleton
- [x] Language-first settings screen (all 9 languages, endonyms shown)
- [x] Home screen with the single primary action: talk
- [x] Placeholder conversation screen
- [ ] `flutter create .` platform folders (per machine)
- [ ] Whisper.cpp bridge → real STT (Phase 1)
