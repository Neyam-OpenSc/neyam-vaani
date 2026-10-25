# piper_bridge — Text-to-Speech (TTS)

Plain-C FFI bridge between Dart (`dart:ffi`) and
[Piper](https://github.com/rhasspy/piper) (pinned to `2023.11.14-2` / 1.2.0),
which runs VITS voices on ONNX Runtime. One shared library:
**`libnv_piper_bridge.so`**. No Java, no JNI.

Consumed only through `app/lib/data/services/` (see `docs/project-structure.md`).

## What it does

- Loads up to **two voices per language** from a downloaded language pack
  (packs ship 1 female + 1 male `.onnx` + `.onnx.json`, plus one shared
  `espeak-ng-data/` directory).
- `nv_piper_speak(text, speed, cb)` returns immediately; **16-bit mono PCM**
  chunks stream to Dart on a worker thread. Sample rate is per-voice
  (Piper voices are 16 kHz or 22.05 kHz) — query `nv_piper_sample_rate()`.
- `nv_piper_stop()` cancels: audio delivery stops **immediately**; the
  sentence already inside ONNX Runtime finishes (discarded) — worst case a
  few hundred ms of wasted CPU. This is the "interruptible TTS" hook the
  architecture doc requires (user talks over the assistant → barge-in).
- Sentence splitting is **danda-aware** (`।` / `॥` for Hindi, Marathi,
  Bhojpuri, Maithili) with a hard 240-byte wrap so `stop()` latency stays
  bounded even on unpunctuated text.
- Speed control maps to Piper's `lengthScale` (2.0 = twice as fast).

## Exact C surface (see `piper_bridge.h` for the full contract)

```c
typedef void (*nv_piper_pcm_cb)(const int16_t* samples, int32_t n_samples, bool is_final);

int    nv_piper_init(const char* voice_path);            // .onnx; config must be "<path>.json"
int    nv_piper_add_voice(const char* voice_path);       // second voice (index 1)
int    nv_piper_select_voice(int voice_index);           // 0|1; returns previous index
int    nv_piper_voice_count(void);                       // 0..2
int    nv_piper_sample_rate(void);                       // active voice Hz, -1 if none
int    nv_piper_speak(const char* text, float speed, nv_piper_pcm_cb cb); // async
int    nv_piper_stop(void);                              // cancel current utterance
int    nv_piper_is_speaking(void);                        // 1/0
size_t nv_piper_current_ram_bytes(void);
void   nv_piper_free(void);
```

All functions return `NV_PIPER_OK (0)` or a negative `NV_PIPER_ERR_*`.
`nv_piper_speak` returns `NV_PIPER_ERR_BUSY` if an utterance is in flight —
call `nv_piper_stop()` first (the interrupt path) or wait for the
`is_final=true` marker.

## Dart/FFI integration notes

- Register `nv_piper_pcm_cb` as a `NativeCallable.listener`; copy the sample
  buffer into a stream feeding the audio track before returning. Exactly one
  `(NULL, 0, is_final=true)` is delivered per `nv_piper_speak` call — also
  when stopped early or on error. Treat it as the "utterance finished"
  event: it is what unblocks the next `speak()`.
- One utterance at a time (product model: the assistant speaks one turn).
  To interrupt: `nv_piper_stop()` → flush player → next `speak()` once
  `is_speaking()` is 0.
- Voice switch (`nv_piper_select_voice`) never applies mid-utterance.
- Pack layout expected by `init`:

```
<pack>/
  espeak-ng-data/          # shared by both voices
  tts/ta-IN-female.onnx
  tts/ta-IN-female.onnx.json
  tts/ta-IN-male.onnx      # optional, via nv_piper_add_voice
  tts/ta-IN-male.onnx.json
```

## Building

### Android (primary target: arm64-v8a + armeabi-v7a)

Piper's CMake downloads prebuilt ONNX Runtime for desktop hosts only —
under the NDK you must supply it:

1. Download the ONNX Runtime Android AAR from Maven:
   `com.microsoft.onnxruntime:onnxruntime-android` (CPU).
2. Unzip it once, e.g. `third_party/onnxruntime-android/` — it contains
   `headers/` and `jni/<abi>/libonnxruntime.so`.
3. Configure the module with `-DONNXRUNTIME_ROOT=<that directory>`.
4. Package `jni/<abi>/libonnxruntime.so` into the APK (e.g. `jniLibs/`).

```groovy
// app/android/app/build.gradle
android {
    defaultConfig {
        externalNativeBuild { cmake {
            arguments "-DANDROID_STL=c++_shared",
                      "-DONNXRUNTIME_ROOT=<repo>/third_party/onnxruntime-android"
        } }
        ndk { abiFilters 'arm64-v8a', 'armeabi-v7a' }
    }
    externalNativeBuild { cmake {
        path file('../../../native/piper_bridge/CMakeLists.txt')
        version '3.22.1'
    } }
}
```

Piper (and its espeak-ng phonemizer) is fetched at configure time via
FetchContent. The 16 KB page-size link flag is applied for Android 15+.

### Host (dev machines)

```bash
cmake -S native/piper_bridge -B build/piper
cmake --build build/piper -j
```

## Memory budget

| Item | Bytes (approx.) |
|---|---|
| 1 Piper voice (onnx + json) | 15–20 MB |
| Loaded voice session (ONNX Runtime arena) | ~3× file size |
| 2 voices per language (architecture doc) | ≤ 100 MB total |
| `nv_piper_current_ram_bytes` | file sizes + 8 MiB/voice estimate |

The orchestrator should unload TTS (`nv_piper_free`) before loading the 3B
LLM on 2 GB devices — see the swap strategy in `docs/architecture.md`.

## Where voices come from

Never bundled, never fetched by this library. Language packs
(`docs/language-pack-spec.md`) are downloaded by the Dart layer (opt-in,
TLS 1.3, GPG-signed) and unpacked into app-private storage; the pack
manifest names the two voices. Dart passes absolute paths to
`nv_piper_init` / `nv_piper_add_voice`.

Text and audio exist in RAM only; this bridge performs no network I/O
(`PRIVACY_CHARTER.md`).
