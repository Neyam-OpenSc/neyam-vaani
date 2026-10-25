# Language Pack Specification

A language pack is everything Vaani needs to fully serve one language,
downloadable on demand. The APK ships small; the language comes after.

## Contents (~600–900MB per language)

| Component | Size | Source |
|---|---|---|
| Whisper STT model (fine-tuned) | 75MB | OpenAI Whisper + Indic-whisper fine-tunes |
| Piper TTS voices (1M + 1F) | 30MB | Piper community releases |
| LLM tokenizer extension | 5MB | Qwen2.5 tokenizer |
| Knowledge base (language-filtered) | 300MB | Wikipedia dumps, govt schemes |
| Form templates (translated) | 5MB | Curated |
| Intent training data (10 phrases × 20 intents) | 200KB | Native-speaker generated |
| UI strings (`.arb`) | 100KB | Steward-reviewed |
| Voice cues (localized UI sounds) | 2MB | Custom recorded |
| Default system prompts (translated) | 50KB | Native-speaker reviewed |

## Delivery

- **First launch**: user picks one language → that pack downloads.
- **More languages**: Settings → Languages → install on demand.
- **No internet at first launch?** A tiny English pack (~50MB) is embedded
  in the APK so the app is immediately usable; the real language pack
  downloads later.
- **Updates**: versioned, weekly checks, **always opt-in** (we ask
  permission before downloading).
- **Integrity**: packs are tarballs, GPG-signed, verified before install;
  transport is TLS 1.3.
- **Hosting**: Cloudflare R2 + Backblaze B2 (free egress) — static files only.

## Pack manifest (proposal)

```json
{
  "language": "ta",
  "version": "1.0.0",
  "min_app_version": "1.0.0",
  "models": {
    "stt": "whisper-tiny-ta-q5.bin",
    "tts": ["ta-IN-female.onnx", "ta-IN-male.onnx"]
  },
  "knowledge": {
    "kb": "kb-ta.sqlite",
    "embeddings": "kb-ta-embeddings.bin"
  },
  "ui_strings": "app_ta.arb",
  "prompts": "prompts-ta.tar.zst",
  "sha256": "…",
  "signature": "…"
}
```

## Build pipeline (planned, `models/` + `knowledge/`)

```bash
./models/download_models.sh ta
python ./models/quantize_models.py ta
python ./knowledge/build_kb.py --language ta
python ./knowledge/build_embeddings.py --language ta
./scripts/release_language_pack.sh ta 1.0.0   # assembles + signs + uploads
```

## Stewardship

A pack cannot ship until its **language steward** (native speaker) has
reviewed: UI strings, system prompts, TTS voice naturalness, and STT
accuracy on 50 real utterances. No machine translation ships unreviewed.
