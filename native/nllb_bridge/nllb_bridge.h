// nllb_bridge.h — plain-C FFI surface for Neyam Vaani's translation bridge.
//
// This is NOT Java JNI. Every function below is `extern "C"`, looked up by
// name from Dart via `DynamicLibrary.open('libnv_nllb_bridge.so')`.
//
// Unlike the other bridges this one is fully SYNCHRONOUS:
// `nv_nllb_translate` blocks until the translation is ready (translation is
// one bounded job — encode, greedy-decode, return — so no callback plumbing
// is warranted). The heavy work still runs on a dedicated internal thread;
// the FFI-calling thread sleeps until it finishes. Call it from a Dart
// background isolate (never the UI isolate: a sentence takes seconds on a
// $200 phone).
//
// Threading contract for the Dart side:
//   * Only ONE translation may run at a time; concurrent calls get
//     NV_NLLB_ERR_BUSY.
//   * All calls returning `int` return 0 on success and a negative
//     NV_NLLB_ERR_* code on failure. No C++ exception crosses this boundary.
//
// Language codes: the app-facing short codes from
// app/lib/core/constants.dart ("ta","hi","bn","kn","te","mr","bho","mai","en")
// and/or the full NLLB codes ("tam_Taml", "hin_Deva", …, "bho_Deva",
// "mai_Deva", "eng_Latn") are both accepted everywhere.
//
// Privacy: text exists in RAM only; this library performs zero network I/O
// (PRIVACY_CHARTER.md).

#ifndef NV_NLLB_BRIDGE_H
#define NV_NLLB_BRIDGE_H

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

#define NV_NLLB_OK                0
#define NV_NLLB_ERR_NOT_INIT     (-1)  // nv_nllb_init() not called / failed
#define NV_NLLB_ERR_INVALID_ARG  (-2)  // null pointers / empty text
#define NV_NLLB_ERR_MODEL_LOAD   (-3)  // manifest/weights/tokenizer missing or corrupt
#define NV_NLLB_ERR_OOM          (-4)
#define NV_NLLB_ERR_BUSY         (-5)  // a translation is already running
#define NV_NLLB_ERR_LANG         (-6)  // src/tgt language unknown or unsupported
#define NV_NLLB_ERR_TOO_LONG     (-7)  // input exceeds the token cap
#define NV_NLLB_ERR_TRUNCATED    (-8)  // output did not fit out_len (partial copy made)
#define NV_NLLB_ERR_CANCELLED    (-9)  // freed while a translation was running
#define NV_NLLB_ERR_INTERNAL     (-10) // unexpected C++ exception / inference failure

// ---- lifecycle -------------------------------------------------------------

// Load an NLLB translation model directory from a downloaded language pack:
//
//   <model_dir>/nllb.json        manifest (architecture dims, special ids)
//   <model_dir>/weights.nvbin    quantized weights (see README for format)
//   <model_dir>/tokenizer.model  SentencePiece model
//   <model_dir>/langs.json       NLLB language code -> token id
//
// Loading takes several seconds (weights are read into RAM); call from a
// background Dart isolate.
NV_EXPORT int nv_nllb_init(const char* model_dir);

// ---- translation -----------------------------------------------------------

// Translate `text` from src_lang to tgt_lang (short or full codes, see
// above). BLOCKS until done (its own thread does the work); the translated
// UTF-8 string is written to `out` NUL-terminated, at most out_len bytes
// including the NUL. Returns NV_NLLB_OK, or NV_NLLB_ERR_TRUNCATED when the
// result was cut to fit (partial copy still made), or a negative error
// (out is set to "" on failure).
//
// Caps enforced (see README): 192 input tokens, 256 output tokens.
NV_EXPORT int nv_nllb_translate(const char* text, const char* src_lang,
                                const char* tgt_lang, char* out, int out_len);

// 1 if `code` (short like "ta" or full like "tam_Taml") is resolvable with
// the loaded model, else 0. Use for UI gating ("translate this" only when
// both directions exist).
NV_EXPORT int nv_nllb_lang_supported(const char* code);

// ---- introspection ---------------------------------------------------------

// Input token cap (192) so the Dart side can pre-truncate / split text.
NV_EXPORT int nv_nllb_max_input_tokens(void);

// Best-effort RAM accounting: weights + scratch arena while a translation
// is running. peak = high-water mark. See README for the budget table.
NV_EXPORT size_t nv_nllb_current_ram_bytes(void);
NV_EXPORT size_t nv_nllb_peak_ram_bytes(void);

// Teardown: cancels a running translation, frees all model memory.
// Idempotent.
NV_EXPORT void nv_nllb_free(void);

// "nllb_bridge 1.0.0 (ggml m2m100 runtime)" — for logs/diagnostics.
NV_EXPORT const char* nv_nllb_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // NV_NLLB_BRIDGE_H
