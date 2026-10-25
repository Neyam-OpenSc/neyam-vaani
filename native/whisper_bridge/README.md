# whisper_bridge — Speech-to-Text (STT)

Plain-C FFI bridge between Dart (`dart:ffi`) and
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (pinned to `v1.7.5`).
One shared library: **`libnv_whisper_bridge.so`**. No Java, no JNI — Dart
calls `nv_*` symbols directly and receives results through a callback
function pointer.

Consumed only through `app/lib/data/services/` (see
`docs/project-structure.md` layer rules).

## What it does

- Loads a GGML-format Whisper model from a **downloaded language pack**
  (models are never bundled in the APK — see `docs/language-pack-spec.md`).
- Accepts streaming **16 kHz mono PCM**, `int16` or `float32`.
- Emits **partial transcriptions** on a callback roughly every 1.2 s of new
  audio (each partial is decoded from the last 10 s sliding window,
  temperature 0, greedy — deterministic hypotheses).
- `nv_whisper_flush_final()` decodes the full buffered utterance, emits one
  `is_final=true` callback, clears the buffer, and returns when done.
- **Language detection**: init with `lang="auto"` (multilingual models) and
  every callback reports the detected language, or call
  `nv_whisper_detect_language()` directly.
- **Hard memory budget**: init fails with `NV_WHISPER_ERR_MEM_BUDGET` if the
  model file would not fit; the PCM ring buffer is capped by the remaining
  headroom (10 s floor, 30 s ceiling). Peak-RAM queries below.
- Audio lives in RAM only and is never written to disk (`PRIVACY_CHARTER.md`).

## Exact C surface (see `whisper_bridge.h` for the full contract)

```c
typedef void (*nv_whisper_transcript_cb)(const char* text, bool is_final, const char* lang);

int    nv_whisper_init(const char* model_path, const char* lang); // lang: "ta"…"en" or "auto"
int    nv_whisper_set_transcript_callback(nv_whisper_transcript_cb cb);
void   nv_whisper_set_memory_budget(size_t max_bytes);            // default 320 MiB
int    nv_whisper_feed_pcm_i16(const int16_t* samples, int32_t n);
int    nv_whisper_feed_pcm_f32(const float* samples, int32_t n);
int    nv_whisper_flush_final(void);                              // blocking (<=30 s)
int    nv_whisper_detect_language(char* out_lang, int out_len);   // needs >=1 s audio
int    nv_whisper_reset(void);                                    // drop buffered audio
int    nv_whisper_sample_rate(void);                              // always 16000
size_t nv_whisper_current_ram_bytes(void);
size_t nv_whisper_peak_ram_bytes(void);
size_t nv_whisper_process_peak_rss(void);                         // /proc VmHWM
void   nv_whisper_free(void);
```

All functions return `NV_WHISPER_OK (0)` or a negative `NV_WHISPER_ERR_*`
(see header). No C++ exception ever crosses the boundary.

## Dart/FFI integration notes

- Register the callback as a `NativeCallable.listener` (it fires on the
  bridge's worker thread); marshal results to your isolate via `SendPort`.
  The `text`/`lang` pointers are only valid during the callback — copy them.
- Symbols are prefixed `nv_whisper_` **not** `whisper_`: libwhisper already
  exports a C API under `whisper_*` (e.g. its own `whisper_free`), and a
  colliding symbol here would silently bind to the wrong function at load
  time.
- Typical flow: `set_transcript_callback` → `init(pack.sttModel, lang)` →
  feed from the mic stream → on VAD end-of-speech call `flush_final()` →
  expect exactly one `is_final=true` (empty string if no audio) → `reset()`
  is implicit in flush; start feeding the next utterance after it.
- **Bhojpuri/Maithili packs**: whisper.cpp has no `bho`/`mai` codes. Those
  fine-tuned packs declare the whisper-recognized code their fine-tune
  targets (typically `hi`) in the pack manifest; Dart passes that code to
  `nv_whisper_init`. The manifest stays the source of truth.
- After `nv_whisper_free()` the callback registration is cleared; re-register
  after the next `init`.

## Building

### Android (primary target: arm64-v8a + armeabi-v7a)

Wire it into `app/android/app/build.gradle`:

```groovy
android {
    defaultConfig {
        externalNativeBuild { cmake { arguments "-DANDROID_STL=c++_shared" } }
        ndk { abiFilters 'arm64-v8a', 'armeabi-v7a' }
    }
    externalNativeBuild { cmake {
        path file('../../../native/whisper_bridge/CMakeLists.txt')
        version '3.22.1'
    } }
}
```

whisper.cpp is fetched at CMake configure time (FetchContent, `v1.7.5`) —
keep the pin deliberate; the bridge is written against that field set
(`abort_callback`, `whisper_init_from_file_with_params`, …).

- OpenMP is disabled (`GGML_OPENMP=OFF`) because NDK r26+ ships no OpenMP
  runtime; CPU threads are used instead (2–4, clamped to core count).
- The `.so` is linked with `-Wl,-z,max-page-size=16384` for Android 15+
  16 KB page devices.

### Host (smoke builds / dev)

```bash
cmake -S native/whisper_bridge -B build/whisper -DNV_WHISPER_CPP_TAG=v1.7.5
cmake --build build/whisper -j
```

## Memory budget

| Item | Bytes (approx.) |
|---|---|
| whisper-tiny q5 model file (pack) | 40–75 MB |
| Loaded model + whisper state + compute scratch (estimated) | file × ~2 |
| PCM ring buffer | ≤ budget headroom (10–30 s ⇒ 0.6–1.9 MB) |
| **Default hard budget** | **320 MiB** (`nv_whisper_set_memory_budget`) |

`current/peak_ram_bytes` reports bridge-owned accounting (model file size +
64 MiB fixed overhead estimate + PCM buffer). `process_peak_rss` reports the
process-wide VmHWM — the orchestrator should consult that before loading the
LLM, per the swap strategy in `docs/architecture.md`.

## Where models come from

Never bundled, never fetched by this library. Language packs
(`docs/language-pack-spec.md`) are downloaded by the Dart layer
(opt-in, TLS 1.3, GPG-signed, verified before install) and unpacked into
app-private storage. The pack manifest names the STT model, e.g.
`whisper-tiny-ta-q5.bin`; Dart passes its absolute path to
`nv_whisper_init`.

Voice recordings are never persisted by this bridge (RAM only), matching the
privacy charter's "Voice recordings: RAM only" guarantee.
