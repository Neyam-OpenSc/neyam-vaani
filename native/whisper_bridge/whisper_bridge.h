// whisper_bridge.h — plain-C FFI surface for Neyam Vaani's STT bridge.
//
// This is NOT Java JNI. Every function below is `extern "C"`, looked up by
// name from Dart via `DynamicLibrary.open('libnv_whisper_bridge.so')`.
// Results arrive asynchronously through `nv_whisper_transcript_cb`, invoked
// from an internal worker thread (see the threading notes below).
//
// Symbols are prefixed `nv_whisper_` (not `whisper_`) because libwhisper
// already exports a C API under `whisper_*`; a bare `whisper_free` here would
// collide with `whisper_free(struct whisper_context*)` at link time.
//
// Threading contract for the Dart side:
//   * `nv_whisper_feed_pcm_*` is safe to call from the audio-capture thread.
//   * The transcript callback fires on the bridge's internal worker thread —
//     NOT the FFI-calling thread. Register it as a `NativeCallable.listener`
//     (isolates must be notified through a SendPort); do not touch Dart
//     objects directly from the callback.
//   * All calls that return `int` return 0 on success and a negative
//     NV_WHISPER_ERR_* code on failure. No C++ exception ever crosses this
//     boundary.
//
// Audio contract: 16 kHz, mono, interleaved-free (single channel).
// Voice recordings live in RAM only (PRIVACY_CHARTER.md) — this bridge
// never writes audio or transcripts to disk.

#ifndef NV_WHISPER_BRIDGE_H
#define NV_WHISPER_BRIDGE_H

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

#define NV_WHISPER_OK                0
#define NV_WHISPER_ERR_NOT_INIT     (-1)  // nv_whisper_init() not called / failed
#define NV_WHISPER_ERR_INVALID_ARG  (-2)  // null pointer, bad lang code, 0 samples
#define NV_WHISPER_ERR_MODEL_LOAD   (-3)  // model file missing / unreadable
#define NV_WHISPER_ERR_OOM          (-4)  // allocation failure
#define NV_WHISPER_ERR_BUSY         (-5)  // another operation holds the decoder
#define NV_WHISPER_ERR_CANCELLED    (-6)  // aborted by nv_whisper_free / decode abort
#define NV_WHISPER_ERR_MEM_BUDGET   (-7)  // model would exceed the RAM budget
#define NV_WHISPER_ERR_TIMEOUT      (-8)  // flush_final() gave up waiting for the worker
#define NV_WHISPER_ERR_UNSUPPORTED  (-9)  // e.g. detect_language on an English-only model
#define NV_WHISPER_ERR_INTERNAL     (-10) // unexpected C++ exception

// ---- callback --------------------------------------------------------------

// Called from the worker thread with the current hypothesis.
//   text     : UTF-8, never null (may be "" before enough audio arrived).
//   is_final : true exactly once per utterance, from nv_whisper_flush_final().
//   lang     : the language the result was decoded in ("ta", "hi", …); when
//              the bridge was initialized with lang="auto" this is the
//              detected language. Never null.
typedef void (*nv_whisper_transcript_cb)(const char* text, bool is_final, const char* lang);

// ---- lifecycle -------------------------------------------------------------

// Load a whisper.cpp GGML model (from a downloaded language pack — never
// bundled in the APK). `lang` is an ISO code from
// app/lib/core/constants.dart ("ta","hi","bn","kn","te","mr","bho","mai","en")
// or "auto" to detect per utterance (multilingual models only).
// Returns NV_WHISPER_OK or a negative error. Safe to call again after
// nv_whisper_free(). Fails with NV_WHISPER_ERR_MEM_BUDGET if the model file
// would not fit in the currently configured memory budget.
NV_EXPORT int nv_whisper_init(const char* model_path, const char* lang);

// Register (or replace, or clear with NULL) the transcript callback.
// May be called before or after nv_whisper_init().
NV_EXPORT int nv_whisper_set_transcript_callback(nv_whisper_transcript_cb cb);

// Hard memory cap, in bytes, enforced by this bridge:
//   * a model file larger than the budget fails nv_whisper_init() with
//     NV_WHISPER_ERR_MEM_BUDGET;
//   * the internal PCM ring buffer never exceeds the headroom the budget
//     leaves above the loaded model (oldest audio is dropped first).
// Default: 320 MiB (whisper-tiny/small packs fit; see README for budget math).
// Pass 0 for unlimited (not recommended on 2 GB devices).
NV_EXPORT void nv_whisper_set_memory_budget(size_t max_bytes);

// ---- audio input -----------------------------------------------------------

// Feed 16 kHz mono PCM. Both int16 and float (-1.0..1.0) forms are accepted.
// Partial hypotheses are emitted on the callback roughly every
// NV_WHISPER_PARTIAL_INTERVAL_MS of new audio (see README). Returns
// NV_WHISPER_ERR_MEM_BUDGET if the incoming chunk itself exceeds the cap.
NV_EXPORT int nv_whisper_feed_pcm_i16(const int16_t* samples, int32_t n_samples);
NV_EXPORT int nv_whisper_feed_pcm_f32(const float* samples, int32_t n_samples);

// Finalize the current utterance: runs a full decode over everything buffered,
// delivers one callback with is_final=true, clears the buffer, and returns
// only after the final result has been delivered (or a 30 s watchdog fired).
NV_EXPORT int nv_whisper_flush_final(void);

// Decode language of the buffered audio and copy an ISO code ("ta", …) into
// out_lang (NUL-terminated, at most out_len bytes including NUL).
// Requires a multilingual model and >= 1 s of audio.
NV_EXPORT int nv_whisper_detect_language(char* out_lang, int out_len);

// Drop buffered audio without decoding (e.g. after a VAD false trigger).
NV_EXPORT int nv_whisper_reset(void);

// ---- introspection ---------------------------------------------------------

// Expected input sample rate (16000). Lets the Dart side configure the
// recorder without hardcoding.
NV_EXPORT int nv_whisper_sample_rate(void);

// Best-effort RAM accounting:
//   nv_whisper_current_ram_bytes — bytes this bridge owns/allocated
//       (model file size + PCM buffer + fixed overhead estimate).
//   nv_whisper_peak_ram_bytes    — high-water mark of the above.
//   nv_whisper_process_peak_rss  — process-wide peak RSS (VmHWM from
//       /proc/self/status); useful when the orchestrator must decide whether
//       another model may be loaded (see docs/architecture.md swap strategy).
NV_EXPORT size_t nv_whisper_current_ram_bytes(void);
NV_EXPORT size_t nv_whisper_peak_ram_bytes(void);
NV_EXPORT size_t nv_whisper_process_peak_rss(void);

// Teardown: stops the worker, frees the model, zeroes buffers. Idempotent.
NV_EXPORT void nv_whisper_free(void);

// "whisper_bridge 1.0.0 (whisper.cpp <tag>)" — for logs/diagnostics.
NV_EXPORT const char* nv_whisper_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // NV_WHISPER_BRIDGE_H
