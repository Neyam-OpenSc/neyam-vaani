# llama_bridge — On-device LLM

Plain-C FFI bridge between Dart (`dart:ffi`) and
[llama.cpp](https://github.com/ggml-org/llama.cpp), running quantized GGUF
models — **Qwen2.5-1.5B/3B-Instruct Q4** by default — fully offline on the
device CPU. One shared library: **`libnv_llama_bridge.so`**. No Java, no JNI.

Consumed only through `app/lib/data/services/` (see `docs/project-structure.md`).

## What it does

- Loads a GGUF model from a **downloaded language pack** (never bundled —
  see `docs/language-pack-spec.md`), CPU-only, with a 4096-token context by
  default.
- `nv_llama_generate(system, user, cb)` is **asynchronous**: tokens stream to
  Dart on a worker thread, one `is_final=true` callback closes every answer.
  The prompt is formatted as **ChatML** (Qwen2.5-Instruct's native template);
  decoding is **greedy** for deterministic on-device answers.
- `nv_llama_stop()` aborts promptly via llama.cpp's `abort_callback` — the
  final callback carries whatever was generated so far (barge-in support).
- **Low-RAM mode** (`low_ram=true` on 2 GB devices): weights are mmap'd
  without pinning, batches and threads are reduced, and the KV cache is
  quantized to q8_0 (halves its footprint). `nv_llama_unload()` /
  `nv_llama_reload()` implement the swap strategy from `docs/architecture.md`
  — the orchestrator unloads the LLM around STT/TTS spikes instead of
  letting the phone OOM.
- `nv_llama_tokens_per_second()` exposes generation speed; prompts that
  don't fit the context fail synchronously with `NV_LLAMA_ERR_CTX_OVERFLOW`.
- The bridge is **stateless between turns** (KV cache cleared after each
  answer); conversation history is managed by the Dart context manager
  (last 5 turns, per the architecture doc).

## Exact C surface (see `llama_bridge.h` for the full contract)

```c
typedef void (*nv_llama_token_cb)(const char* piece, const char* full,
                                  int32_t n_tokens, bool is_final);

int    nv_llama_init(const char* gguf_path, int32_t ctx_tokens, bool low_ram);
                                             // ctx_tokens=0 → 4096
int    nv_llama_is_loaded(void);              // 1/0
int    nv_llama_reload(void);                 // after unload(); idempotent
int    nv_llama_generate(const char* system, const char* user, nv_llama_token_cb cb);
int    nv_llama_stop(void);
int    nv_llama_is_generating(void);
int    nv_llama_unload(void);                 // memory-pressure primitive
float  nv_llama_tokens_per_second(void);      // last generation, or -1
size_t nv_llama_ram_bytes(void);              // GGUF bytes (weights)
size_t nv_llama_process_peak_rss(void);       // /proc VmHWM
int    nv_llama_last_status(void);
int    nv_llama_last_full_text(char* out, int out_len);
void   nv_llama_free(void);
```

All functions return `NV_LLAMA_OK (0)` or a negative `NV_LLAMA_ERR_*`.

## Dart/FFI integration notes

- Symbols are prefixed `nv_llama_` — llama.cpp exports its own C API under
  `llama_*` (including `llama_free`), which would collide.
- Register the token callback as a `NativeCallable.listener`. `piece` is a
  **UTF-8 byte fragment**: concatenate the bytes and decode on the Dart
  side (a token may end mid-grapheme — do not render pieces individually).
  `full` is a convenience copy of the answer so far, valid only during the
  call.
- Exactly one `is_final=true` per `generate` call — also on stop, context
  error and internal failure. Use it to flip UI state.
- One generation at a time; `NV_LLAMA_ERR_BUSY` means "call stop() or wait
  for is_final".
- `init` can take tens of seconds on low-end hardware — call it from a
  background isolate and show the "thinking" state.
- Suggested orchestration on 2 GB devices: after each answer completes,
  `nv_llama_unload()` before the next mic capture; `nv_llama_reload()` when
  the intent classifier needs the LLM.

## Building

### Android (primary target: arm64-v8a + armeabi-v7a)

```groovy
// app/android/app/build.gradle
android {
    defaultConfig {
        externalNativeBuild { cmake { arguments "-DANDROID_STL=c++_shared" } }
        ndk { abiFilters 'arm64-v8a', 'armeabi-v7a' }
    }
    externalNativeBuild { cmake {
        path file('../../../native/llama_bridge/CMakeLists.txt')
        version '3.22.1'
    } }
}
```

- llama.cpp is fetched at configure time (`FetchContent`). The default tag
  (`NV_LLAMA_CPP_TAG`) is a **pin** — bump it deliberately: this bridge uses
  the sampler-chain API, `llama_perf_context`, `llama_memory_seq_rm` and
  `LLAMA_LOAD_MODE_*`; older llama.cpp versions do not have these.
- `LLAMA_CURL=OFF` is forced: the runtime must never gain network
  capability (`PRIVACY_CHARTER.md`).
- OpenMP is disabled (NDK r26+ has no OpenMP runtime); threads are used.
- Linked with `-Wl,-z,max-page-size=16384` for Android 15+ 16 KB pages.

### Host (dev machines)

```bash
cmake -S native/llama_bridge -B build/llama
cmake --build build/llama -j
```

## Memory budget

Budget math for the two tiers from `docs/architecture.md` (4096-token
context, Qwen2.5-Instruct):

| Configuration | Weights (GGUF Q4) | KV cache (f16 / q8_0 in low_ram) | Peak RSS target |
|---|---|---|---|
| Qwen2.5-1.5B (2 GB devices) | ~1.0 GB | ~130 MB / ~65 MB | ≤ 1.4 GB |
| Qwen2.5-3B (4 GB+ devices) | ~1.8 GB | ~260 MB / ~130 MB | ≤ 2.5 GB |

The 3B model never co-resides with STT+TTS on a 2 GB phone — that is what
`unload()`/`reload()` are for. `nv_llama_ram_bytes()` reports the weights;
`nv_llama_process_peak_rss()` reports process VmHWM for the orchestrator's
load/unload decisions.

## Where models come from

Never bundled, never fetched by this library. The GGUF arrives inside a
language pack (opt-in download, TLS 1.3, GPG-signed, verified before
install — `docs/language-pack-spec.md`). Device-tier auto-selection (1.5B on
2 GB, 3B on 4 GB+) happens in the Dart layer, which then passes the chosen
GGUF's absolute path to `nv_llama_init`.

No network I/O, no telemetry, no disk writes — answers live in RAM and are
persisted (if at all) only by the encrypted SQLite layer on the Dart side.
