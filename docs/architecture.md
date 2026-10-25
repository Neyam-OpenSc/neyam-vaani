# Architecture

## High-level design

```
┌─────────────────────────────────────────────────────────┐
│                    USER INTERFACE                        │
│            (Voice-first + minimal visual, Flutter)       │
└────────────┬────────────────────────────┬───────────────┘
             │                            │
             ▼                            ▼
┌─────────────────────────┐  ┌────────────────────────────┐
│  VOICE INPUT PIPELINE   │  │   VOICE OUTPUT PIPELINE    │
│                         │  │                            │
│  • Wake word (Vosk)     │  │  • TTS (Piper)             │
│  • VAD (Silero)         │  │  • Audio output            │
│  • STT (Whisper.cpp)    │  │  • Interruption handling   │
│  • Language detection   │  │                            │
└────────────┬────────────┘  └────────────┬───────────────┘
             │                              │
             ▼                              ▲
┌─────────────────────────────────────────────────────────┐
│                INTENT & ORCHESTRATION                    │
│                                                         │
│  • Intent classifier (TF-IDF/ONNX, LLM fallback)        │
│  • Context manager (last 5 turns)                       │
│  • Response formatter (text → speech-ready)             │
└────────────┬────────────────────────────┬───────────────┘
             ▼                            ▼
┌─────────────────────────┐  ┌────────────────────────────┐
│  ON-DEVICE LLM          │  │   LOCAL KNOWLEDGE BASE     │
│                         │  │                            │
│  • Qwen2.5-1.5B/3B      │  │  • Wikipedia dumps (FTS5)  │
│  • GGUF quantized       │  │  • Govt schemes DB         │
│  • llama.cpp runtime    │  │  • Market prices (cached)  │
│  • Multilingual         │  │  • Form templates          │
└────────────┬────────────┘  └────────────┬───────────────┘
             ▼                            ▼
┌─────────────────────────────────────────────────────────┐
│            ACTION LAYER (Android Intents)                │
│  SMS • Call • Calendar • Clipboard • Camera • Share     │
└────────────────────────────┬────────────────────────────┘
                             ▼
┌─────────────────────────────────────────────────────────┐
│          STORAGE (SQLCipher encrypted SQLite + files)    │
└─────────────────────────────────────────────────────────┘
```

## Stack decisions

| Layer | Choice | Why this, not alternatives |
|---|---|---|
| UI framework | Flutter (Dart) | Single codebase (Android now, iOS later), good voice plugins, smooth on low-end Android |
| Wake word / VAD | Vosk + Silero VAD | Offline, Indian language models, run within 2GB RAM |
| STT | Whisper.cpp (small models) | Best multilingual accuracy per MB, offline, quantized |
| TTS | Piper | Neural TTS at ~5MB per voice, CPU-only, MIT licensed, Indian language voices |
| On-device LLM | Qwen2.5-3B-Instruct (GGUF Q4) | Best multilingual model under 3B params, covers all 9 target languages, Apache 2.0 |
| LLM runtime | llama.cpp via FFI | Fastest on-device inference, ARM-optimized, mature |
| Knowledge base | SQLite + FTS5 + local embeddings | Already on every Android device, fast full-text search, no extra deps |
| Storage | SQLCipher | Industry-standard encrypted SQLite, free for OSS |
| OCR | Tesseract 5 + ML Kit (offline) | Tesseract for document photos, ML Kit for live camera OCR |
| Translation | NLLB-200-distilled-600M (on-device) | 200-language coverage in a phone-sized model |
| Background tasks | Android WorkManager | Standard, battery-friendly |

## The hard constraint: on-device model budget

A $200 phone (2GB RAM) must run all of this simultaneously. Budget:

| Component | Storage | RAM (loaded) | CPU/GPU use |
|---|---|---|---|
| Whisper-tiny (STT) | 75MB | 200MB | Brief spikes |
| Piper TTS (2 voices × 1 lang) | 30MB | 100MB | Brief spikes |
| Qwen2.5-3B Q4 (LLM) | 1.8GB | 2.5GB | Sustained during inference |
| NLLB-600M Q4 (translation) | 350MB | 500MB | Brief spikes |
| Embeddings (MiniLM) | 90MB | 200MB | Brief spikes |
| **Total (1 language)** | **~2.4GB** | **~3.5GB peak** | Manageable |

Strategy:

- **Language packs are downloadable per language** — users install only
  what they speak. APK stays under 80MB.
- **Models load lazily** and unload under memory pressure (no OOM crashes).
- **Device-tier auto-selection**: 1.5B model on 2GB devices, 3B on 4GB+.
- The 3B model peaks near device limits on 2GB phones — it *swaps* with the
  STT/TTS models rather than co-residing. This is why the orchestration layer
  exists as a distinct component.

## Data flow: one spoken question

1. Wake word / push-to-talk → mic stream (16kHz mono PCM)
2. Silero VAD detects end of speech
3. Whisper.cpp transcribes + detects language
4. Intent classifier (ONNX, <200ms) picks a handler; LLM fallback if
   confidence < 0.6
5. Handler runs: LLM answer, KB retrieval (hybrid FTS + embeddings),
   or an Android action intent
6. Response formatted → Piper TTS speaks it; interruption kills playback
   instantly if the user talks
7. Turn (text only) stored in encrypted SQLite; recordings never persisted

## Repository layout

See [project-structure.md](project-structure.md) for the full monorepo map.
