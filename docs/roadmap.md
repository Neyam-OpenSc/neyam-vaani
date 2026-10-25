# 90-Day Roadmap to Public Beta

## Phase status legend
⬜ not started · 🚧 in progress · ✅ done

## Days 1–7 · Bootstrap 🚧
- [x] Create the repo + community files (charter, tender UX, governance)
- [x] App skeleton (clean architecture) + CI
- [ ] Flutter platform folders + first build on a real low-end device
- [ ] Recruit 2 Tamil + 2 Hindi native speakers for feedback

## Days 8–21 · Voice pipeline
- [ ] Phase 1: Whisper.cpp JNI bridge, push-to-talk, streaming STT
- [ ] Tamil + Hindi STT working on-device
- [ ] Phase 2: Piper TTS bridge, Tamil + Hindi voices, interruption handling
- [ ] Voice quality iteration with native speakers

## Days 22–42 · Intelligence layer
- [ ] Phase 3: llama.cpp + Qwen2.5-3B Q4 on-device, streaming, cancellable
- [ ] Phase 4: intent classifier (top 20 intents, ONNX) + LLM fallback
- [ ] Phase 5: actions — SMS, call, reminder, clipboard, torch

## Days 43–63 · Knowledge & documents
- [ ] Phase 6: offline KB (Wikipedia + govt schemes, hybrid search) + RAG
- [ ] Phase 7: OCR document reading + medicine-label explainer
- [ ] Phase 8: NLLB translation, Tamil ↔ Hindi first

## Days 64–90 · Polish & beta
- [ ] Phase 9: accessibility (WCAG 2.2 AA), tenderness audit, performance
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
