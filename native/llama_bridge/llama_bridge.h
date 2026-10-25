// llama_bridge.h — plain-C FFI surface for Neyam Vaani's on-device LLM bridge.
//
// This is NOT Java JNI. Every function below is `extern "C"`, looked up by
// name from Dart via `DynamicLibrary.open('libnv_llama_bridge.so')`.
// Generated tokens are streamed through `nv_llama_token_cb`, invoked from an
// internal worker thread.
//
// Symbols are prefixed `nv_llama_` because llama.cpp already exports a C API
// under `llama_*` (its own `llama_free` would collide with a bare `llama_free`
// here).
//
// Threading contract for the Dart side:
//   * `nv_llama_generate` returns immediately (0 = generation started);
//     tokens arrive on the worker thread via the callback. Register it as a
//     `NativeCallable.listener`; copy `piece`/`full` before returning.
//   * `nv_llama_stop` may be called from any thread and stops generation
//     promptly (the in-flight decode is aborted via llama.cpp's
//     abort_callback).
//   * All calls returning `int` return 0 on success and a negative
//     NV_LLAMA_ERR_* code on failure. No C++ exception crosses this boundary.
//
// Model policy: GGUF files arrive via downloadable language packs
// (docs/language-pack-spec.md) — never bundled in the APK, never downloaded
// by this library. Inference is CPU-only and fully offline.

#ifndef NV_LLAMA_BRIDGE_H
#define NV_LLAMA_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && !defined(__GNUC__)
#define NV_EXPORT __declspec(dllexport)
#else
#define NV_EXPORT __attribute__((visibility("default")))
#endif

// ---- error codes -----------------------------------------------------------

#define NV_LLAMA_OK                 0
#define NV_LLAMA_ERR_NOT_INIT      (-1)  // model not loaded / init failed
#define NV_LLAMA_ERR_INVALID_ARG   (-2)  // null pointer / bad ctx_tokens
#define NV_LLAMA_ERR_MODEL_LOAD    (-3)  // GGUF missing/corrupt/unsupported
#define NV_LLAMA_ERR_OOM           (-4)
#define NV_LLAMA_ERR_BUSY          (-5)  // a generation is already running
#define NV_LLAMA_ERR_CANCELLED     (-6)  // generation aborted by nv_llama_stop
#define NV_LLAMA_ERR_CTX_OVERFLOW  (-7)  // prompt does not fit the context
#define NV_LLAMA_ERR_UNLOADED      (-8)  // operation needs reload() first

// ---- callback --------------------------------------------------------------

// Streamed generation results.
//   piece    : UTF-8 fragment of the answer for THIS token (copy it; may
//              contain partial multibyte sequences — concatenate the bytes
//              and UTF-8-decode on the Dart side, do not print pieces raw).
//   full     : the complete answer so far (NUL-terminated convenience copy;
//              only valid for the duration of the call).
//   n_tokens : number of generated tokens so far (excluding prompt).
// The final callback of an answer arrives with is_final=true (see
// nv_llama_generate). Exactly one is_final per generate call.
typedef void (*nv_llama_token_cb)(const char* piece, const char* full, int32_t n_tokens,
                                  bool is_final);

// ---- lifecycle -------------------------------------------------------------

// Load a GGUF model and create a context.
//   gguf_path : absolute path (language pack download).
//   ctx_tokens: context window in tokens; pass 0 for the default 4096.
//   low_ram   : true on 2 GB devices — model is mmap'd without pinning,
//               batch sizes and threads are reduced, and the orchestrator
//               is expected to nv_llama_unload() around STT/TTS spikes
//               (see docs/architecture.md swap strategy).
// Model load may take tens of seconds on low-end hardware; call from a
// background Dart isolate.
NV_EXPORT int nv_llama_init(const char* gguf_path, int32_t ctx_tokens, bool low_ram);

// True while a model is loaded and a context exists (i.e. generate can run).
NV_EXPORT int nv_llama_is_loaded(void);

// Reload the last model with the same parameters after an unload.
// Used when the orchestrator swapped the LLM out for STT/TTS.
NV_EXPORT int nv_llama_reload(void);

// ---- generation ------------------------------------------------------------

// Generate an answer for `user` under `system`, streamed via `cb`.
//
// Prompt format: ChatML (Qwen2.5-Instruct's native template):
//   <|im_start|>system\n{system}<|im_end|>\n
//   <|im_start|>user\n{user}<|im_end|>\n
//   <|im_start|>assistant\n
// Pass NULL for system to use only the user turn. Decoding is greedy
// (deterministic — chosen deliberately for reproducible on-device answers).
//
// The call is asynchronous: it returns NV_LLAMA_OK as soon as the worker
// picks up the request, then invokes cb per token, finishing with one
// is_final=true callback. Output length is capped at 512 new tokens or the
// remaining context, whichever is smaller. Prompts that leave fewer than 16
// free tokens fail immediately with NV_LLAMA_ERR_CTX_OVERFLOW.
NV_EXPORT int nv_llama_generate(const char* system, const char* user, nv_llama_token_cb cb);

// Abort the running generation. The worker emits the final callback
// (is_final=true) with everything generated so far, and
// nv_llama_last_status() reports NV_LLAMA_ERR_CANCELLED.
NV_EXPORT int nv_llama_stop(void);

// 1 while a generation is running, else 0.
NV_EXPORT int nv_llama_is_generating(void);

// ---- memory pressure (low-RAM mode support) --------------------------------

// Free model + context immediately, remembering how to reload
// (nv_llama_reload). In-flight generation is cancelled first. This is the
// "model unloads under pressure" primitive the orchestrator calls before
// letting STT/TTS spikes allocate (docs/architecture.md).
NV_EXPORT int nv_llama_unload(void);

// ---- introspection ---------------------------------------------------------

// Tokens/sec of the most recent generation (prompt processing excluded),
// or -1 if none. Measured via llama.cpp perf counters over generated tokens.
NV_EXPORT float nv_llama_tokens_per_second(void);

// RAM accounting: GGUF file bytes (weights, mmap'd) while loaded; 0 when
// unloaded. Note the KV cache adds roughly ctx_tokens × 2 bytes/layer on
// top — see README for the full budget table.
NV_EXPORT size_t nv_llama_ram_bytes(void);

// Process-wide peak RSS (VmHWM from /proc/self/status); the orchestrator
// should consult this before loading additional models.
NV_EXPORT size_t nv_llama_process_peak_rss(void);

// Status of the last finished generation: NV_LLAMA_OK, or
// NV_LLAMA_ERR_CANCELLED / NV_LLAMA_ERR_INTERNAL.
NV_EXPORT int nv_llama_last_status(void);

// Copy the full text of the last finished generation into `out`
// (NUL-terminated, at most out_len bytes including NUL). Returns
// NV_LLAMA_OK or a negative error.
NV_EXPORT int nv_llama_last_full_text(char* out, int out_len);

// Teardown: cancels generation, frees model/context. Idempotent.
NV_EXPORT void nv_llama_free(void);

// "llama_bridge 1.0.0 (llama.cpp <tag>)" — for logs/diagnostics.
NV_EXPORT const char* nv_llama_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // NV_LLAMA_BRIDGE_H
