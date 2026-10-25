# nllb_bridge — Offline Translation (NLLB-200)

Plain-C FFI bridge between Dart (`dart:ffi`) and a compact **ggml-based
M2M100 runtime** for **NLLB-200-distilled-600M** (quantized). One shared
library: **`libnv_nllb_bridge.so`**. No Java, no JNI, no network — the
runtime contains zero network code by construction.

Consumed only through `app/lib/data/services/` (see `docs/project-structure.md`).

## What it does

- Loads a converted+quantized NLLB model directory from a **downloaded
  language pack** (never bundled — `docs/language-pack-spec.md`).
- `nv_nllb_translate(text, src, tgt, out, out_len)` — **blocking**, with the
  heavy work on a dedicated internal thread: SentencePiece encode → encoder
  (12 layers, post-LN, learned positions, relu FFN) → greedy decode →
  SentencePiece decode. One translation at a time (`NV_NLLB_ERR_BUSY`
  otherwise).
- Accepts both the app's short codes (`"ta"`, `"bho"`, …) and full NLLB
  codes (`"tam_Taml"`, `"bho_Deva"`, …). All 9 v1 languages are covered —
  NLLB-200 includes Bhojpuri (`bho_Deva`) and Maithili (`mai_Deva`).
- Same-language requests short-circuit (no inference).
- Caps: **192 input tokens, 256 output tokens** — query
  `nv_nllb_max_input_tokens()` and pre-split on the Dart side.

## Exact C surface (see `nllb_bridge.h` for the full contract)

```c
int    nv_nllb_init(const char* model_dir);
int    nv_nllb_translate(const char* text, const char* src_lang,
                         const char* tgt_lang, char* out, int out_len); // blocking
int    nv_nllb_lang_supported(const char* code);  // 1/0, for UI gating
int    nv_nllb_max_input_tokens(void);            // 192
size_t nv_nllb_current_ram_bytes(void);           // weights (+scratch while running)
size_t nv_nllb_peak_ram_bytes(void);
void   nv_nllb_free(void);
```

All functions return `NV_NLLB_OK (0)` or a negative `NV_NLLB_ERR_*`.
`NV_NLLB_ERR_TRUNCATED` still leaves a partial (NUL-terminated) copy in `out`.

## Dart/FFI integration notes

- `nv_nllb_translate` **blocks for seconds** — always call it from a
  background isolate (`Isolate.run`), never the UI isolate.
- Output buffer: pass a generous `malloc`'d `char` buffer (e.g. 8–16 KB for
  a 192-token input). It is written UTF-8, NUL-terminated, even on error
  paths.
- No callback: the result is the return of the blocking call. The
  "translation in progress" UI state is driven by the Dart isolate boundary.

## Model directory format (produced by `models/quantize_models.py`, planned)

```
<model_dir>/
  nllb.json          # flat-JSON manifest
  weights.nvbin      # tensors (see binary format below)
  tokenizer.model    # SentencePiece (from the HF NLLB tokenizer)
  langs.json         # { "tam_Taml": 256048, ... }  NLLB code → token id
```

`nllb.json` (defaults shown; all keys optional):

```json
{
  "d_model": 1024, "n_heads": 16,
  "encoder_layers": 12, "decoder_layers": 12, "ffn_dim": 4096,
  "vocab_size": 256206, "max_positions": 1024,
  "layer_norm_first": false, "share_input_output_embed": true,
  "pos_offset": 2, "eos_id": 2, "unk_id": 3, "pad_id": 1,
  "graph_scratch_mb": 384
}
```

`weights.nvbin` (little-endian): header `u32 magic "NVN1" | u32 version 1 |
u32 n_tensors`, then per tensor: `u32 name_len | name | u32 type_id (0 f32,
1 f16, 2 q8_0, 3 q4_0) | u32 ne0 | u32 ne1 | u32 ne2 | u64 nbytes | data`
(row-major, ne0 contiguous; ne0 must be a multiple of the quant block size).

Tensor names (HF M2M100 weights, HF row-major blobs copy verbatim — a
`[out, in]` HF linear weight is exactly ggml's `[in, out]`):

| Name | Shape | Notes |
|---|---|---|
| `enc.embed_tokens` | `[d, vocab]` | tied with `lm_head` by default |
| `enc.embed_positions` | `[d, max_positions+8]` | f32 |
| `enc.<i>.self_{q,k,v,o}.{w,b}` | `[d,d]` / `[d]` | i = 0..11 |
| `enc.<i>.ln{1,2}.{w,b}` | `[d]` | f32 |
| `enc.<i>.fc1.w` | `[ffn,d]`, `fc1.b` `[ffn]` | |
| `enc.<i>.fc2.w` | `[d,ffn]`, `fc2.b` `[d]` | |
| `dec.*` | mirror of `enc.*` plus `cross_{q,k,v,o}` and `ln3` | |
| `lm_head` | `[d, vocab]` | optional (else tied) |
| `enc.ln_f.*` / `dec.ln_f.*` | `[d]` | only if `layer_norm_first` |

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
        path file('../../../native/nllb_bridge/CMakeLists.txt')
        version '3.22.1'
    } }
}
```

Fetched at configure time: **ggml** (compute) and **sentencepiece v0.2.0**
(tokenizer). Pin `NV_GGML_TAG` to a concrete commit in CI — the bridge uses
ggml's stable legacy CPU graph API (`ggml_build_forward`,
`ggml_graph_compute_with_ctx`, `ggml_blck_size`, `ggml_tensor_overhead`),
which is maintained for compatibility but lives in a fast-moving repo.
OpenMP is disabled (NDK r26+); 1–4 CPU threads are used.

### Host (dev machines)

```bash
cmake -S native/nllb_bridge -B build/nllb
cmake --build build/nllb -j
```

## Memory budget

| Item | Bytes (approx.) |
|---|---|
| Weights q4_0 (recommended pack) | ~355 MB |
| Weights q8_0 (higher quality) | ~640 MB |
| Graph scratch arena (transient, during a translation) | 384 MB default |
| Encoder memory cache | ≤ 0.8 MB (192 tokens) |

Realistic peak ≈ weights + scratch ≈ **740 MB (q4_0)** — the architecture
doc's 500 MB target assumes a KV-cached decoder and shared workspace reuse,
both tracked as future work (`docs/architecture.md`, Phase 8). Until then,
treat translation as a *solo* activity: the orchestrator must unload the
LLM (`nv_llama_unload`) before translating on 2 GB devices. The scratch
arena is only touched while a translation runs
(`nv_nllb_current_ram_bytes` reflects that).

## Where models come from

Never bundled, never fetched by this library. The NLLB pack is converted
from HuggingFace `facebook/nllb-200-distilled-600M` by the planned
`models/quantize_models.py`, GPG-signed, and downloaded opt-in over TLS 1.3
(`docs/language-pack-spec.md`). Dart passes the unpacked directory's
absolute path to `nv_nllb_init`.

Text exists in RAM only; nothing is written to disk (`PRIVACY_CHARTER.md`).
