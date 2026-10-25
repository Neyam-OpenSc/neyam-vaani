// piper_bridge.h — plain-C FFI surface for Neyam Vaani's TTS bridge.
//
// This is NOT Java JNI. Every function below is `extern "C"`, looked up by
// name from Dart via `DynamicLibrary.open('libnv_piper_bridge.so')`.
// Synthesized audio is pushed in chunks through `nv_piper_pcm_cb`, invoked
// from an internal worker thread.
//
// Symbols are prefixed `nv_piper_` to avoid any collision with upstream
// libraries.
//
// Threading contract for the Dart side:
//   * `nv_piper_speak` returns immediately (0 = accepted); audio arrives on
//     the worker thread via the callback. Register it as a
//     `NativeCallable.listener` and copy samples out before returning.
//   * `nv_piper_stop` is safe to call from any thread, including from inside
//     another bridge's callback. After it returns, no further PCM is
//     delivered for the current utterance (see README for latency notes).
//   * All calls returning `int` return 0 on success and a negative
//     NV_PIPER_ERR_* code on failure. No C++ exception crosses this boundary.
//
// Privacy: text and synthesized audio exist in RAM only. This bridge never
// touches the network or the filesystem beyond reading the voice models.

#ifndef NV_PIPER_BRIDGE_H
#define NV_PIPER_BRIDGE_H

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

#define NV_PIPER_OK                0
#define NV_PIPER_ERR_NOT_INIT     (-1)  // no voice loaded / init failed
#define NV_PIPER_ERR_INVALID_ARG  (-2)  // null pointer / empty text / bad speed
#define NV_PIPER_ERR_VOICE_LOAD   (-3)  // .onnx or .onnx.json missing/corrupt
#define NV_PIPER_ERR_OOM          (-4)
#define NV_PIPER_ERR_BUSY         (-5)  // already speaking (call nv_piper_stop first)
#define NV_PIPER_ERR_ESPEAK       (-6)  // espeak-ng-data directory not found
#define NV_PIPER_ERR_INTERNAL     (-7)  // unexpected C++ exception / synth failure
#define NV_PIPER_ERR_STOPPED      (-8)  // synthesis interrupted by nv_piper_stop

// ---- callback --------------------------------------------------------------

// 16-bit mono PCM chunks of the utterance in progress.
//   samples  : interleaved-free mono s16le; NEVER null for a data chunk.
//   n_samples: number of int16 values in this chunk.
//   is_final : true exactly once when the utterance is finished — delivered
//              as (samples=NULL, n_samples=0). Also used alone to signal
//              early stop (nv_piper_stop) so the player can flush.
// The buffer is only valid for the duration of the call: copy it (e.g. into
// a stream feeding an audio track) before returning.
typedef void (*nv_piper_pcm_cb)(const int16_t* samples, int32_t n_samples, bool is_final);

// ---- lifecycle -------------------------------------------------------------

// Load the primary (index 0) Piper voice.
//   voice_path: absolute path to the .onnx model from a downloaded language
//               pack. Its JSON config must sit next to it as
//               `<voice_path>.json` (standard Piper layout).
// The espeak-ng-data directory must exist in the pack at
//   <voice_dir>/espeak-ng-data, <voice_dir>/../espeak-ng-data, or
//   <voice_dir>/../../espeak-ng-data
// (first match wins). Fails with NV_PIPER_ERR_ESPEAK if none is found.
NV_EXPORT int nv_piper_init(const char* voice_path);

// Load a second voice (index 1) — e.g. the male counterpart in a language
// pack that ships 1 female + 1 male voice. Returns NV_PIPER_OK, or
// NV_PIPER_ERR_BUSY if voice slot 1 is already taken (call nv_piper_free
// and re-init to replace voices).
NV_EXPORT int nv_piper_add_voice(const char* voice_path);

// Switch the active voice (0 or 1) for subsequent nv_piper_speak calls.
// Takes effect at the next utterance, never mid-utterance.
// Returns the previous active index, or a negative error.
NV_EXPORT int nv_piper_select_voice(int voice_index);

// Number of loaded voices (0, 1 or 2).
NV_EXPORT int nv_piper_voice_count(void);

// Sample rate of the ACTIVE voice in Hz (Piper voices are 16000 or 22050) —
// the Dart audio player must be configured per voice. Returns -1 with no
// voice loaded.
NV_EXPORT int nv_piper_sample_rate(void);

// ---- speaking --------------------------------------------------------------

// Speak `text` at the given speed (1.0 = voice default; 0.5 half, 2.0 twice;
// clamped to [0.5, 2.0]). Returns immediately:
//   NV_PIPER_OK        — accepted; chunks will arrive on the callback
//   NV_PIPER_ERR_BUSY  — an utterance is still in flight; stop first
// Text is split into sentences (Latin punctuation plus the Devanagari danda
// '।' / '॥') so that stop() can take effect between chunks quickly.
NV_EXPORT int nv_piper_speak(const char* text, float speed, nv_piper_pcm_cb cb);

// Cancel the current utterance. No further PCM chunks are delivered after
// this returns (the is_final marker is emitted). ONNX inference already in
// flight for the current sentence finishes server-side (worst case a few
// hundred ms of wasted CPU) but its audio is discarded.
NV_EXPORT int nv_piper_stop(void);

// 1 while an utterance is being synthesized/delivered, else 0.
NV_EXPORT int nv_piper_is_speaking(void);

// Best-effort RAM accounting for this bridge (loaded voice models +
// synthesis buffers). See whisper_bridge for the process-wide RSS helper.
NV_EXPORT size_t nv_piper_current_ram_bytes(void);

// Unload voices, stop the worker, terminate espeak-ng. Idempotent.
NV_EXPORT void nv_piper_free(void);

// "piper_bridge 1.0.0 (piper 2023.11.14-2)" — for logs/diagnostics.
NV_EXPORT const char* nv_piper_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // NV_PIPER_BRIDGE_H
