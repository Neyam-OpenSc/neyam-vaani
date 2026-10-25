# 90-Day Roadmap to Public Beta

## Phase status legend
⬜ not started · 🚧 in progress · ✅ done · 🧩 code scaffolded

**Code scaffolded** = implementation written and CI-green; NOT yet
validated on hardware or with native model files.

*Status updated 2026-10-25 after the multi-agent implementation sprint.*

## Days 1–7 · Bootstrap 🚧
- [x] Create the repo + community files (charter, tender UX, governance)
- [x] App skeleton (clean architecture) + CI
- [ ] Flutter platform folders + first build on a real low-end device
- [ ] Recruit 2 Tamil + 2 Hindi native speakers for feedback

## Days 8–21 · Voice pipeline 🧩
- [x] Phase 1: Whisper.cpp JNI bridge, push-to-talk, streaming STT *(code scaffolded)*
- [ ] Tamil + Hindi STT working on-device *(needs device + model files)*
- [x] Phase 2: Piper TTS bridge, Tamil + Hindi voices, interruption handling *(code scaffolded)*
- [ ] Voice quality iteration with native speakers

## Days 22–42 · Intelligence layer 🧩
- [x] Phase 3: llama.cpp + Qwen2.5-3B Q4 on-device, streaming, cancellable *(code scaffolded)*
- [x] Phase 4: intent classifier (top 20 intents, ONNX) + LLM fallback *(code scaffolded)*
- [x] Phase 5: actions — SMS, call, reminder, clipboard, torch *(code scaffolded)*

## Days 43–63 · Knowledge & documents 🧩
- [x] Phase 6: offline KB (Wikipedia + govt schemes, hybrid search) + RAG *(code scaffolded)*
- [x] Phase 7: OCR document reading + medicine-label explainer *(code scaffolded)*
- [x] Phase 8: NLLB translation, Tamil ↔ Hindi first *(code scaffolded)*

## Days 64–90 · Polish & beta 🚧
- [ ] Phase 9: accessibility (WCAG 2.2 AA), tenderness audit, performance — code-level audit done (`docs/accessibility-audit.md`); device verification pending
- [ ] In-person beta with 10 native speakers
- [ ] Fix top 50 beta issues
- [ ] Play Store internal beta (100 users)

## Day 90 · Public beta launch
- [ ] Play Store open beta
- [ ] "Why we built Neyam Vaani" essay
- [ ] Submit to Hacker News, r/India, r/opensource, Tamil tech communities
- [ ] Open external contributions (maintainer applications)

---

## Non-goals guard rail (v1)

Smart home · third-party app integrations · web browsing · image
generation · multi-user accounts · iOS · desktop — all **out of scope**
until v1 ships. PRs adding them will be closed with a link to this file.
