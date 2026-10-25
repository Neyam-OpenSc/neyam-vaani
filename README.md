<div align="center">

<img src="assets/logo.png" width="150" alt="Neyam Vaani logo" />

# 🪔 Neyam Vaani

**A voice-first, offline AI assistant for Indian vernacular languages.**
*Built tenderly, for billions.*

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-C05621?style=flat-square)](LICENSE)
[![Platform: Android](https://img.shields.io/badge/platform-Android-4D7C0F?style=flat-square)](docs/architecture.md)
[![Status: Phase 0](https://img.shields.io/badge/status-Phase%200%20·%20bootstrap-D97706?style=flat-square)](docs/roadmap.md)
[![Privacy: on-device](https://img.shields.io/badge/privacy-on--device-181717?style=flat-square)](PRIVACY_CHARTER.md)
[![Website](https://img.shields.io/badge/website-github.io%20·%20llms.txt%20ready-C05621?style=flat-square&logo=githubpages)](https://neyam-opensc.github.io/neyam-vaani/)

</div>

---

> **Neyam Vaani runs on cheap phones, works with zero internet, and speaks
> the languages Silicon Valley ignores.** Tamil, Hindi, Bengali, Kannada,
> Telugu, Marathi, Bhojpuri, Maithili — at parity, not as an afterthought.

## ✨ Why this exists

Hundreds of millions of people in India own a smartphone but can't
comfortably *use* it — because it demands typing in English, constant
internet, and expensive hardware. Vaani is the opposite of all three:

- **Voice-first** — speak to it, it speaks back. No typing required.
- **Offline-first** — every core feature works with zero connectivity.
- **Cheap-hardware-first** — targets a $200 Android phone with 2GB RAM.
- **Vernacular-first** — 9 Indian languages at full parity.
- **Private by default** — everything runs on-device. No cloud, no accounts, no telemetry.
- **Tender UX** — no dark patterns, no engagement hooks, no noise. Ever.
- **Grandmother-usable** — if a 70-year-old in a Tamil village can't use it
  without help, it's broken.

Read the full principles: **[Tender UX Principles](TENDER_UX_PRINCIPLES.md)** ·
**[Privacy Charter](PRIVACY_CHARTER.md)**

## 🏗️ How it works

```
Voice in (Whisper.cpp)  →  Intent & orchestration  →  On-device LLM (Qwen 2.5, llama.cpp)
                              ↓                                ↓
                        Local knowledge base        →  Voice out (Piper TTS)
                        (SQLite FTS5 + embeddings)      + Actions (SMS, calls, reminders…)
```

Full architecture and the reasoning behind every choice:
**[docs/architecture.md](docs/architecture.md)**

## 📦 Repository layout

| Path | What lives there |
|---|---|
| `app/` | Flutter application (clean architecture: data / domain / presentation) |
| `app/assets/prompts/` | The LLM prompt library (one system prompt per use case) |
| `docs/` | Architecture, use cases, language pack spec, roadmap |
| `knowledge/` | Knowledge-base build pipelines (Wikipedia dumps, govt schemes) — *planned* |
| `models/` | Model download / quantization / packaging scripts — *planned* |
| `native/` | C++ JNI bridges (whisper, llama, piper, vosk) — *planned* |

## 🗺️ Roadmap

| Phase | Scope | Status |
|---|---|---|
| 0 | Bootstrap — Flutter skeleton, CI, community files | 🚧 In progress |
| 1 | Voice input — Whisper.cpp bridge, push-to-talk, STT in 3 languages | ⬜ |
| 2 | Voice output — Piper TTS, 9 languages, interruptible | ⬜ |
| 3 | On-device LLM — Qwen 2.5-3B Q4 via llama.cpp | ⬜ |
| 4 | Intent classification + orchestration | ⬜ |
| 5 | Actions — SMS, calls, reminders, clipboard, torch | ⬜ |
| 6 | Offline knowledge base + RAG | ⬜ |
| 7 | OCR & document reading | ⬜ |
| 8 | On-device translation (NLLB-200) | ⬜ |
| 9 | Polish — accessibility, tenderness audit, performance | ⬜ |

Full 90-day plan: **[docs/roadmap.md](docs/roadmap.md)**

## 🛠️ Getting started

> **Note:** the repo is in Phase 0. The Flutter platform folders are
> generated on your machine (they are device-specific and not committed yet).

```bash
git clone https://github.com/Neyam-OpenSc/neyam-vaani.git
cd neyam-vaani/app

# Generate the Android platform folders (requires Flutter 3.24+)
flutter create . --platforms android --org org.neyamopensc --project-name neyam_vaani

flutter pub get
flutter run
```

## 🤝 Contributing

We'd love your help — especially **language stewards** (native speakers who
own localization quality for their language). Start with
**[CONTRIBUTING.md](CONTRIBUTING.md)**, and look for issues labeled
[`good first issue`](https://github.com/Neyam-OpenSc/neyam-vaani/labels).

## 📄 License & conduct

- Code is licensed under **[Apache 2.0](LICENSE)**.
- Docs, prompts, and language data under **CC-BY-SA 4.0** (upon first release).
- Every interaction is governed by our **[Code of Conduct](CODE_OF_CONDUCT.md)**.

---

<div align="center">
<sub>A project of <a href="https://github.com/Neyam-OpenSc"><b>Neyam OpenSc</b></a> · open source, built for people.</sub>
</div>
