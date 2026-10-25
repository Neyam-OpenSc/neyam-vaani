// nllb_bridge.cpp — offline translation bridge (NLLB-200-distilled, M2M100
// architecture) written directly against the ggml C API.
//
// Why a hand-rolled runtime? Unlike whisper/piper/llama, NLLB has no
// canonical C/C++ engine that ships Android-friendly binaries. The bridge
// therefore implements the minimum viable M2M100 forward pass itself:
//
//   SentencePiece encode
//     → [src_lang_id] + tokens + [eos]
//     → encoder (post-LN transformer, learned positions, relu FFN)
//     → memory [d_model × src_len] cached in RAM
//     → greedy decode: prefix [eos, tgt_lang_id] + argmax steps
//     → SentencePiece decode
//
// Weight format (.nvbin), manifest (nllb.json) and langs.json are produced
// by the planned models/quantize_models.py converter — see README.md for
// the exact layout. Weights may be f32, f16, q8_0 or q4_0 per tensor; the
// recommended pack is q4_0 (~355 MB) per the memory budget in
// docs/architecture.md.
//
// The heavy work runs on a dedicated worker thread; nv_nllb_translate()
// blocks the FFI caller on a condition variable until the worker finishes.
// One translation at a time (NV_NLLB_ERR_BUSY otherwise). No exception
// crosses the FFI boundary: every exported function wraps its body in
// try/catch and maps failures to NV_NLLB_ERR_* codes.
//
// Known v1 simplifications (documented in README):
//   * No KV cache in the decoder — each step recomputes the prefix
//     (fine for ≤ 256 output tokens; the graph is small).
//   * Greedy decoding only (beam 1) — deterministic, cheapest on 2 GB RAM.
//   * No batching: one sentence at a time, exact lengths — so attention
//     needs only a causal mask for the decoder; there are no padding masks.

#include "nllb_bridge.h"

#include "ggml.h"
#include "sentencepiece_processor.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

#ifdef __ANDROID__
#include <android/log.h>
#define NV_LOG(...) __android_log_print(ANDROID_LOG_INFO, "nv-nllb", __VA_ARGS__)
#else
#define NV_LOG(...) fprintf(stderr, "[nv-nllb] " __VA_ARGS__), fprintf(stderr, "\n")
#endif

namespace {

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

constexpr int    kMaxInputTokens      = 192;
constexpr int    kMaxNewTokens        = 256;
constexpr size_t kDefaultScratchBytes = size_t{384} << 20;  // graph arena
constexpr size_t kGraphSlackBytes     = size_t{24} << 20;   // plan + metadata
constexpr float  kLnEps               = 1e-5f;              // M2M100 LN epsilon
constexpr uint32_t kNvbinMagic        = 0x4E564E31u;        // "NVN1"
constexpr uint32_t kNvbinVersion      = 1;

// App-facing short codes (app/lib/core/constants.dart) → NLLB-200 codes.
// Bhojpuri and Maithili ARE covered by NLLB-200 — one of the reasons the
// architecture picked it.
struct LangAlias { const char* short_code; const char* nllb_code; };
const LangAlias kLangAliases[] = {
    {"ta",  "tam_Taml"},
    {"hi",  "hin_Deva"},
    {"bn",  "ben_Beng"},
    {"kn",  "kan_Knda"},
    {"te",  "tel_Telu"},
    {"mr",  "mar_Deva"},
    {"bho", "bho_Deva"},
    {"mai", "mai_Deva"},
    {"en",  "eng_Latn"},
};
const char* canonical_lang(const std::string& code) {
    for (const auto& a : kLangAliases) {
        if (code == a.short_code) return a.nllb_code;
    }
    return nullptr;  // caller treats input as a full NLLB code
}

// ---------------------------------------------------------------------------
// Tiny flat-JSON parser (no external dependency; our config files are flat)
// ---------------------------------------------------------------------------

struct JsonVal {
    enum Kind { KIND_STR, KIND_NUM, KIND_BOOL, KIND_OTHER } kind = KIND_OTHER;
    std::string str;
    double num = 0;
    bool bool_val = false;
};

bool json_parse_flat(const std::string& doc, std::map<std::string, JsonVal>* out) {
    size_t i = 0;
    const auto skip_ws = [&] {
        while (i < doc.size() &&
               (doc[i] == ' ' || doc[i] == '\t' || doc[i] == '\r' || doc[i] == '\n')) {
            ++i;
        }
    };
    const auto parse_string = [&](std::string* s) {
        if (i >= doc.size() || doc[i] != '"') return false;
        ++i;
        s->clear();
        while (i < doc.size() && doc[i] != '"') {
            if (doc[i] == '\\' && i + 1 < doc.size()) ++i;  // keep escaped char raw
            s->push_back(doc[i]);
            ++i;
        }
        if (i >= doc.size()) return false;
        ++i;  // closing quote
        return true;
    };

    skip_ws();
    if (i >= doc.size() || doc[i] != '{') return false;
    ++i;
    skip_ws();
    if (i < doc.size() && doc[i] == '}') return true;

    while (true) {
        skip_ws();
        std::string key;
        if (!parse_string(&key)) return false;
        skip_ws();
        if (i >= doc.size() || doc[i] != ':') return false;
        ++i;
        skip_ws();

        JsonVal v;
        if (i < doc.size() && doc[i] == '"') {
            if (!parse_string(&v.str)) return false;
            v.kind = JsonVal::KIND_STR;
        } else if (doc.compare(i, 4, "true") == 0) {
            v.kind = JsonVal::KIND_BOOL;
            v.bool_val = true;
            i += 4;
        } else if (doc.compare(i, 5, "false") == 0) {
            v.kind = JsonVal::KIND_BOOL;
            v.bool_val = false;
            i += 5;
        } else if (i < doc.size() && (doc[i] == '-' || (doc[i] >= '0' && doc[i] <= '9'))) {
            char* end = nullptr;
            v.num = std::strtod(doc.c_str() + i, &end);
            if (end == doc.c_str() + i) return false;
            i = static_cast<size_t>(end - doc.c_str());
            v.kind = JsonVal::KIND_NUM;
        } else if (i < doc.size() && (doc[i] == '{' || doc[i] == '[')) {
            // Nested value: skip balanced and ignore (not used by our files).
            const char open = doc[i];
            const char close = (open == '{') ? '}' : ']';
            int depth = 0;
            bool started = false;
            while (i < doc.size()) {
                const char c = doc[i];
                if (c == open) { ++depth; started = true; }
                else if (c == close) { --depth; }
                ++i;
                if (started && depth == 0) break;
            }
            if (!started || depth != 0) return false;
            v.kind = JsonVal::KIND_OTHER;
        } else {
            return false;
        }
        (*out)[key] = v;

        skip_ws();
        if (i < doc.size() && doc[i] == ',') { ++i; continue; }
        if (i < doc.size() && doc[i] == '}') { ++i; return true; }
        return false;
    }
}

bool read_file(const std::string& path, std::string* out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    *out = ss.str();
    return true;
}

bool read_u32(std::istream& f, uint32_t* v) { return bool(f.read(reinterpret_cast<char*>(v), 4)); }
bool read_u64(std::istream& f, uint64_t* v) { return bool(f.read(reinterpret_cast<char*>(v), 8)); }

// ---------------------------------------------------------------------------
// Model configuration (nllb.json) and weight bundles
// ---------------------------------------------------------------------------

struct NllbConfig {
    int d_model = 1024;
    int n_heads = 16;
    int encoder_layers = 12;
    int decoder_layers = 12;
    int ffn_dim = 4096;
    int vocab_size = 256206;
    int max_positions = 1024;
    bool layer_norm_first = false;         // M2M100/NLLB: false (post-LN)
    bool share_input_output_embed = true;  // tied embeddings
    int pos_offset = 2;                    // fairseq padding_idx + 1
    int eos_id = 2;                        // "</s>"
    int unk_id = 3;                        // "<unk>"
    int pad_id = 1;                        // "<pad>"
    size_t scratch_bytes = kDefaultScratchBytes;  // optional manifest override
};

enum WeightTypeId : uint32_t {
    kTypeIdF32 = 0,
    kTypeIdF16 = 1,
    kTypeIdQ8_0 = 2,
    kTypeIdQ4_0 = 3,
};

enum ggml_type type_id_to_ggml(uint32_t id, bool* ok) {
    *ok = true;
    switch (id) {
        case kTypeIdF32:  return GGML_TYPE_F32;
        case kTypeIdF16:  return GGML_TYPE_F16;
        case kTypeIdQ8_0: return GGML_TYPE_Q8_0;
        case kTypeIdQ4_0: return GGML_TYPE_Q4_0;
        default: *ok = false; return GGML_TYPE_F32;
    }
}

struct AttnWeights {
    ggml_tensor *wq = nullptr, *bq = nullptr;
    ggml_tensor *wk = nullptr, *bk = nullptr;
    ggml_tensor *wv = nullptr, *bv = nullptr;
    ggml_tensor *wo = nullptr, *bo = nullptr;
};
struct LayerWeights {
    AttnWeights self;
    AttnWeights cross;                       // decoder only
    ggml_tensor *ln1w = nullptr, *ln1b = nullptr;
    ggml_tensor *ln2w = nullptr, *ln2b = nullptr;
    ggml_tensor *ln3w = nullptr, *ln3b = nullptr;  // decoder only
    ggml_tensor *fc1w = nullptr, *fc1b = nullptr;
    ggml_tensor *fc2w = nullptr, *fc2b = nullptr;
};

struct NllbModel {
    NllbConfig cfg;
    std::string dir;

    ggml_context* wctx = nullptr;             // owns every weight tensor
    std::map<std::string, ggml_tensor*> by_name;
    size_t weights_bytes = 0;

    ggml_tensor* enc_embed = nullptr;         // [d, vocab]
    ggml_tensor* enc_pos = nullptr;           // [d, max_positions + pos_offset]
    std::vector<LayerWeights> enc;
    ggml_tensor* enc_lnfw = nullptr;          // pre-LN variant only
    ggml_tensor* enc_lnfb = nullptr;
    ggml_tensor* dec_embed = nullptr;
    ggml_tensor* dec_pos = nullptr;
    std::vector<LayerWeights> dec;
    ggml_tensor* dec_lnfw = nullptr;          // pre-LN variant only
    ggml_tensor* dec_lnfb = nullptr;
    ggml_tensor* lm_head = nullptr;           // [d, vocab] (may == enc_embed)

    sentencepiece::SentencePieceProcessor spm;
    std::map<std::string, int> lang_ids;      // "tam_Taml" → token id

    ~NllbModel() {
        if (wctx) {
            ggml_free(wctx);
            wctx = nullptr;
        }
    }
};

ggml_tensor* find_named(NllbModel* m, const std::string& name) {
    auto it = m->by_name.find(name);
    return it == m->by_name.end() ? nullptr : it->second;
}

ggml_tensor* require_named(NllbModel* m, const std::string& name) {
    ggml_tensor* t = find_named(m, name);
    if (!t) NV_LOG("missing tensor in weights.nvbin: %s", name.c_str());
    return t;
}

// Dequantize row `row` of a (possibly quantized) 2d weight into dst
// (ne0 floats). Row layout: contiguous blocks along ne0; ne0 % blck == 0.
void dequant_row_into(const ggml_tensor* t, int64_t row, float* dst) {
    const int64_t ne0 = t->ne[0];
    const size_t blck = static_cast<size_t>(ggml_blck_size(t->type));
    const size_t row_bytes =
        static_cast<size_t>(ne0 / static_cast<int64_t>(blck)) * ggml_type_size(t->type);
    const uint8_t* rowp = static_cast<const uint8_t*>(t->data) +
                          static_cast<size_t>(row) * row_bytes;
    const int64_t nblocks = ne0 / static_cast<int64_t>(blck);

    switch (t->type) {
        case GGML_TYPE_F32:
            std::memcpy(dst, rowp, static_cast<size_t>(ne0) * sizeof(float));
            break;
        case GGML_TYPE_F16:
            for (int64_t i = 0; i < ne0; ++i) {
                dst[i] = ggml_fp16_to_fp32(
                    reinterpret_cast<const ggml_fp16_t*>(rowp)[i]);
            }
            break;
        case GGML_TYPE_Q8_0: {
            for (int64_t b = 0; b < nblocks; ++b) {
                const uint8_t* blk = rowp + static_cast<size_t>(b) * ggml_type_size(GGML_TYPE_Q8_0);
                const float d = ggml_fp16_to_fp32(
                    *reinterpret_cast<const ggml_fp16_t*>(blk));
                const int8_t* qs = reinterpret_cast<const int8_t*>(blk + 2);
                for (size_t k = 0; k < blck; ++k) {
                    dst[b * static_cast<int64_t>(blck) + static_cast<int64_t>(k)] =
                        d * static_cast<float>(qs[k]);
                }
            }
            break;
        }
        case GGML_TYPE_Q4_0: {
            for (int64_t b = 0; b < nblocks; ++b) {
                const uint8_t* blk = rowp + static_cast<size_t>(b) * ggml_type_size(GGML_TYPE_Q4_0);
                const float d = ggml_fp16_to_fp32(
                    *reinterpret_cast<const ggml_fp16_t*>(blk));
                const uint8_t* qs = blk + 2;  // 16 bytes → 32 nibbles
                for (size_t k = 0; k < blck / 2; ++k) {
                    const uint8_t byte = qs[k];
                    dst[b * static_cast<int64_t>(blck) + 2 * static_cast<int64_t>(k)] =
                        d * static_cast<float>(static_cast<int>(byte & 0x0F) - 8);
                    dst[b * static_cast<int64_t>(blck) + 2 * static_cast<int64_t>(k) + 1] =
                        d * static_cast<float>(static_cast<int>(byte >> 4) - 8);
                }
            }
            break;
        }
        default:
            std::memset(dst, 0, static_cast<size_t>(ne0) * sizeof(float));
            break;
    }
}

// ---------------------------------------------------------------------------
// Weight loading (weights.nvbin)
// ---------------------------------------------------------------------------
// Format (all little-endian):
//   u32 magic "NVN1" (0x4E564E31) | u32 version (1) | u32 n_tensors
//   per tensor:
//     u32 name_len | name bytes (no NUL)
//     u32 type_id (0 f32, 1 f16, 2 q8_0, 3 q4_0)
//     u32 ne0 | u32 ne1 | u32 ne2
//     u64 nbytes | raw tensor data (row-major, ne0 contiguous)

struct NvbinEntry {
    std::string name;
    uint32_t type_id = 0;
    uint32_t ne[3] = {1, 1, 1};
    uint64_t nbytes = 0;
    uint64_t data_offset = 0;
};

int load_weights(NllbModel* m, const std::string& path, std::string* err) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        *err = "cannot open " + path;
        return NV_NLLB_ERR_MODEL_LOAD;
    }

    uint32_t magic = 0, version = 0, n_tensors = 0;
    if (!read_u32(f, &magic) || !read_u32(f, &version) || !read_u32(f, &n_tensors) ||
        magic != kNvbinMagic || version != kNvbinVersion || n_tensors == 0) {
        *err = "bad nvbin header";
        return NV_NLLB_ERR_MODEL_LOAD;
    }

    // Pass 1: read the directory; size the ggml context exactly.
    std::vector<NvbinEntry> entries;
    entries.reserve(n_tensors);
    size_t total_data = 0;
    uint64_t off = 12;  // header size
    for (uint32_t i = 0; i < n_tensors; ++i) {
        NvbinEntry e;
        uint32_t name_len = 0;
        if (!read_u32(f, &name_len) || name_len == 0 || name_len > 128) {
            *err = "bad tensor name";
            return NV_NLLB_ERR_MODEL_LOAD;
        }
        e.name.resize(name_len);
        f.read(&e.name[0], static_cast<std::streamsize>(name_len));
        if (!f || !read_u32(f, &e.type_id) || !read_u32(f, &e.ne[0]) ||
            !read_u32(f, &e.ne[1]) || !read_u32(f, &e.ne[2]) || !read_u64(f, &e.nbytes)) {
            *err = "truncated entry header: " + e.name;
            return NV_NLLB_ERR_MODEL_LOAD;
        }
        bool type_ok = false;
        const enum ggml_type gt = type_id_to_ggml(e.type_id, &type_ok);
        if (!type_ok || e.ne[0] == 0 || e.ne[1] == 0 || e.ne[2] == 0) {
            *err = "bad tensor meta: " + e.name;
            return NV_NLLB_ERR_MODEL_LOAD;
        }
        const size_t blck = static_cast<size_t>(ggml_blck_size(gt));
        if (e.ne[0] % blck != 0) {
            *err = "ne0 not block-aligned (converter bug): " + e.name;
            return NV_NLLB_ERR_MODEL_LOAD;
        }
        const uint64_t expect =
            (static_cast<uint64_t>(e.ne[0] / blck) * ggml_type_size(gt)) * e.ne[1] * e.ne[2];
        if (e.nbytes != expect) {
            *err = "nbytes mismatch: " + e.name;
            return NV_NLLB_ERR_MODEL_LOAD;
        }
        off += 4 + name_len + 4 + 4 + 4 + 4 + 8 + e.nbytes;
        e.data_offset = off - e.nbytes;
        total_data += static_cast<size_t>(e.nbytes);
        entries.push_back(std::move(e));
        f.seekg(static_cast<std::streamsize>(e.nbytes), std::ios::cur);
        if (!f) {
            *err = "truncated tensor data";
            return NV_NLLB_ERR_MODEL_LOAD;
        }
    }

    const size_t overhead = ggml_tensor_overhead();
    const size_t ctx_size = total_data + (static_cast<size_t>(n_tensors) + 1) * overhead +
                            kGraphSlackBytes;
    ggml_init_params ip = {ctx_size, nullptr, false};
    m->wctx = ggml_init(ip);
    if (!m->wctx) {
        *err = "ggml_init failed";
        return NV_NLLB_ERR_OOM;
    }

    // Pass 2: allocate tensors and stream the data in.
    for (const NvbinEntry& e : entries) {
        bool ok = false;
        const enum ggml_type gt = type_id_to_ggml(e.type_id, &ok);
        ggml_tensor* t = nullptr;
        if (e.ne[2] != 1) {
            t = ggml_new_tensor_3d(m->wctx, gt, e.ne[0], e.ne[1], e.ne[2]);
        } else if (e.ne[1] != 1) {
            t = ggml_new_tensor_2d(m->wctx, gt, e.ne[0], e.ne[1]);
        } else {
            t = ggml_new_tensor_1d(m->wctx, gt, e.ne[0]);
        }
        if (!t) {
            *err = "tensor alloc failed: " + e.name;
            return NV_NLLB_ERR_OOM;
        }
        ggml_set_name(t, e.name.c_str());
        f.seekg(static_cast<std::streamoff>(e.data_offset), std::ios::beg);
        f.read(static_cast<char*>(t->data), static_cast<std::streamsize>(e.nbytes));
        if (!f) {
            *err = "short read: " + e.name;
            return NV_NLLB_ERR_MODEL_LOAD;
        }
        m->by_name[e.name] = t;
    }
    m->weights_bytes = total_data;
    return NV_NLLB_OK;
}

// Resolve the named layer bundles after the raw tensors are loaded.
int resolve_model(NllbModel* m, std::string* err) {
    const NllbConfig& c = m->cfg;

    m->enc_embed = require_named(m, "enc.embed_tokens");
    m->enc_pos = require_named(m, "enc.embed_positions");
    m->dec_embed = require_named(m, "dec.embed_tokens");
    m->dec_pos = require_named(m, "dec.embed_positions");
    if (!m->enc_embed || !m->enc_pos || !m->dec_embed || !m->dec_pos) {
        *err = "embeddings missing";
        return NV_NLLB_ERR_MODEL_LOAD;
    }
    if (m->enc_embed->ne[0] != c.d_model || m->enc_embed->ne[1] != c.vocab_size) {
        *err = "enc.embed_tokens shape mismatch (manifest vs weights)";
        return NV_NLLB_ERR_MODEL_LOAD;
    }

    m->lm_head = find_named(m, "lm_head");
    if (!m->lm_head && c.share_input_output_embed) {
        m->lm_head = m->enc_embed;  // tied embeddings (M2M100 default)
    }
    if (!m->lm_head) {
        *err = "lm_head missing and share_input_output_embed=false";
        return NV_NLLB_ERR_MODEL_LOAD;
    }

    m->enc.assign(static_cast<size_t>(c.encoder_layers), LayerWeights{});
    m->dec.assign(static_cast<size_t>(c.decoder_layers), LayerWeights{});
    char name[64];

    const auto need = [&](bool ok, const char* what) -> int {
        if (!ok) {
            *err = std::string(what) + " incomplete";
            return NV_NLLB_ERR_MODEL_LOAD;
        }
        return NV_NLLB_OK;
    };

    for (int i = 0; i < c.encoder_layers; ++i) {
        LayerWeights& L = m->enc[static_cast<size_t>(i)];
        std::snprintf(name, sizeof(name), "enc.%d.self_q.w", i); L.self.wq = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.self_q.b", i); L.self.bq = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.self_k.w", i); L.self.wk = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.self_k.b", i); L.self.bk = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.self_v.w", i); L.self.wv = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.self_v.b", i); L.self.bv = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.self_o.w", i); L.self.wo = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.self_o.b", i); L.self.bo = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.ln1.w", i);   L.ln1w = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.ln1.b", i);   L.ln1b = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.ln2.w", i);   L.ln2w = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.ln2.b", i);   L.ln2b = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.fc1.w", i);   L.fc1w = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.fc1.b", i);   L.fc1b = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.fc2.w", i);   L.fc2w = require_named(m, name);
        std::snprintf(name, sizeof(name), "enc.%d.fc2.b", i);   L.fc2b = require_named(m, name);
        if (int rc = need(L.self.wq && L.self.wk && L.self.wv && L.self.wo && L.ln1w &&
                          L.ln2w && L.fc1w && L.fc2w, "encoder layer");
            rc != NV_NLLB_OK) {
            return rc;
        }
    }
    for (int i = 0; i < c.decoder_layers; ++i) {
        LayerWeights& L = m->dec[static_cast<size_t>(i)];
        std::snprintf(name, sizeof(name), "dec.%d.self_q.w", i);  L.self.wq = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.self_q.b", i);  L.self.bq = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.self_k.w", i);  L.self.wk = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.self_k.b", i);  L.self.bk = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.self_v.w", i);  L.self.wv = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.self_v.b", i);  L.self.bv = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.self_o.w", i);  L.self.wo = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.self_o.b", i);  L.self.bo = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.cross_q.w", i); L.cross.wq = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.cross_q.b", i); L.cross.bq = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.cross_k.w", i); L.cross.wk = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.cross_k.b", i); L.cross.bk = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.cross_v.w", i); L.cross.wv = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.cross_v.b", i); L.cross.bv = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.cross_o.w", i); L.cross.wo = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.cross_o.b", i); L.cross.bo = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.ln1.w", i);     L.ln1w = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.ln1.b", i);     L.ln1b = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.ln2.w", i);     L.ln2w = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.ln2.b", i);     L.ln2b = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.ln3.w", i);     L.ln3w = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.ln3.b", i);     L.ln3b = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.fc1.w", i);     L.fc1w = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.fc1.b", i);     L.fc1b = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.fc2.w", i);     L.fc2w = require_named(m, name);
        std::snprintf(name, sizeof(name), "dec.%d.fc2.b", i);     L.fc2b = require_named(m, name);
        if (int rc = need(L.self.wq && L.self.wk && L.self.wv && L.self.wo && L.cross.wq &&
                          L.cross.wk && L.cross.wv && L.cross.wo && L.ln1w && L.ln2w &&
                          L.ln3w && L.fc1w && L.fc2w, "decoder layer");
            rc != NV_NLLB_OK) {
            return rc;
        }
    }
    if (c.layer_norm_first) {
        m->enc_lnfw = require_named(m, "enc.ln_f.w");
        m->enc_lnfb = require_named(m, "enc.ln_f.b");
        m->dec_lnfw = require_named(m, "dec.ln_f.w");
        m->dec_lnfb = require_named(m, "dec.ln_f.b");
        if (!m->enc_lnfw || !m->dec_lnfw) {
            *err = "layer_norm_first requires enc.ln_f/dec.ln_f";
            return NV_NLLB_ERR_MODEL_LOAD;
        }
    }
    return NV_NLLB_OK;
}

// ---------------------------------------------------------------------------
// Graph building blocks (CPU ggml, stable legacy API)
// ---------------------------------------------------------------------------
// Shape conventions (ggml: contraction over ne0):
//   activations x: [d, n] (n tokens as columns)
//   linear weights w: [d_in, d_out] (HF row-major blobs, verbatim)

ggml_tensor* g_layer_norm(struct ggml_context* ctx, ggml_tensor* x, ggml_tensor* w,
                          ggml_tensor* b) {
    ggml_tensor* n = ggml_norm(ctx, x, kLnEps);
    ggml_tensor* out = ggml_add(ctx, ggml_mul(ctx, n, ggml_repeat(ctx, w, n)),
                                ggml_repeat(ctx, b, n));
    return out;
}

ggml_tensor* g_linear(struct ggml_context* ctx, ggml_tensor* x, ggml_tensor* w,
                      ggml_tensor* b) {
    ggml_tensor* y = ggml_mul_mat(ctx, w, x);  // [d_out, n]
    if (b) y = ggml_add(ctx, y, ggml_repeat(ctx, b, y));
    return y;
}

// Multi-head attention, single sequence, exact length (⇒ no padding mask).
//   q_in: [d, n_q];  kv_in: [d, n_kv];  returns [d, n_q].
//   causal=true masks future positions (decoder self-attn).
//
// Tensor choreography (verified against ggml's contraction semantics):
//   Q,K: [d,n] → [hd, heads, n] → permute(0,2,1,3) → [hd, n, heads]
//   KQ = mul_mat(K, Q)                       → [n_kv, n_q, heads]
//   diag_mask_inf masks ne0(key) > ne1(query) — exactly causal attention.
//   V:  [hd, heads, n] → permute(1,0,2,3)    → [n_kv, hd, heads]
//   KQV = mul_mat(V, softmax(KQ))            → [hd, n_q, heads]
ggml_tensor* g_attention(struct ggml_context* ctx, ggml_tensor* q_in,
                         ggml_tensor* kv_in, const AttnWeights& w, int n_heads,
                         bool causal) {
    const int64_t d = q_in->ne[0];
    const int64_t n_q = q_in->ne[1];
    const int64_t n_kv = kv_in->ne[1];
    const int64_t hd = d / n_heads;

    ggml_tensor* Q = g_linear(ctx, q_in, w.wq, w.bq);   // [d, n_q]
    ggml_tensor* K = g_linear(ctx, kv_in, w.wk, w.bk);  // [d, n_kv]
    ggml_tensor* V = g_linear(ctx, kv_in, w.wv, w.bv);  // [d, n_kv]

    Q = ggml_permute(ctx, ggml_reshape_3d(ctx, Q, hd, n_heads, n_q), 0, 2, 1, 3);
    K = ggml_permute(ctx, ggml_reshape_3d(ctx, K, hd, n_heads, n_kv), 0, 2, 1, 3);
    V = ggml_permute(ctx, ggml_reshape_3d(ctx, V, hd, n_heads, n_kv), 1, 0, 2, 3);

    ggml_tensor* kq = ggml_mul_mat(ctx, K, Q);  // [n_kv, n_q, heads]
    kq = ggml_scale(ctx, kq, 1.0f / std::sqrt(static_cast<float>(hd)));
    if (causal) {
        kq = ggml_diag_mask_inf(ctx, kq, /*n_past=*/0);
    }
    kq = ggml_soft_max(ctx, kq);  // over ne0 = keys

    ggml_tensor* kv = ggml_mul_mat(ctx, V, kq);  // [hd, n_q, heads]
    kv = ggml_permute(ctx, kv, 0, 2, 1, 3);      // [hd, heads, n_q]
    // Permute breaks contiguity — copy into a fresh [d, n_q] tensor before
    // the output projection (the bert.cpp/gpt-2 ggml example pattern).
    kv = ggml_cpy(ctx, kv, ggml_new_tensor_2d(ctx, GGML_TYPE_F32, d, n_q));

    return g_linear(ctx, kv, w.wo, w.bo);
}

ggml_tensor* g_ffn(struct ggml_context* ctx, ggml_tensor* x, const LayerWeights& L) {
    ggml_tensor* h = g_linear(ctx, x, L.fc1w, L.fc1b);  // [ffn, n]
    h = ggml_relu(ctx, h);                              // M2M100 activation
    return g_linear(ctx, h, L.fc2w, L.fc2b);            // [d, n]
}

// Embedding lookup + learned positions, materialized into leaf tensors.
// Tables stay quantized; only the n needed rows are dequantized (a few
// hundred KB per step) to keep the RAM budget intact.
void fill_embeddings(struct ggml_context* ctx, ggml_tensor* table, ggml_tensor* pos_table,
                     const std::vector<int>& ids, int pos_offset, ggml_tensor** emb_out,
                     ggml_tensor** pos_out) {
    const int64_t d = table->ne[0];
    const int64_t n = static_cast<int64_t>(ids.size());
    ggml_tensor* emb = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, d, n);
    ggml_tensor* pos = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, d, n);
    float* edst = static_cast<float*>(emb->data);
    float* pdst = static_cast<float*>(pos->data);
    for (int64_t j = 0; j < n; ++j) {
        dequant_row_into(table, ids[static_cast<size_t>(j)], edst + j * d);
        dequant_row_into(pos_table, pos_offset + static_cast<int>(j), pdst + j * d);
    }
    *emb_out = emb;
    *pos_out = pos;
}

// ---------------------------------------------------------------------------
// Inference driver
// ---------------------------------------------------------------------------

struct TranslateResult {
    int status = NV_NLLB_OK;
    std::string text;
};

class Runner {
public:
    Runner(NllbModel* model, std::atomic<bool>* cancel, uint8_t* scratch,
           size_t scratch_size, int n_threads)
        : m_(model), cancel_(cancel), scratch_(scratch), scratch_size_(scratch_size),
          n_threads_(n_threads) {}

    // Encode `ids` → memory [d × n] (one column per token).
    int encode(const std::vector<int>& ids, std::vector<float>* mem) {
        const NllbConfig& c = m_->cfg;
        const int64_t n = static_cast<int64_t>(ids.size());
        const int64_t d = c.d_model;

        struct ggml_context* ctx = make_ctx();
        if (!ctx) return NV_NLLB_ERR_OOM;

        ggml_tensor *emb, *pos;
        fill_embeddings(ctx, m_->enc_embed, m_->enc_pos, ids, c.pos_offset, &emb, &pos);
        ggml_tensor* x = ggml_add(ctx, emb, pos);  // [d, n]

        for (const LayerWeights& L : m_->enc) {
            ggml_tensor* sub;
            if (c.layer_norm_first) {
                sub = g_attention(ctx, g_layer_norm(ctx, x, L.ln1w, L.ln1b), x, L.self,
                                  c.n_heads, /*causal=*/false);
                x = ggml_add(ctx, x, sub);
                sub = g_ffn(ctx, g_layer_norm(ctx, x, L.ln2w, L.ln2b), L);
                x = ggml_add(ctx, x, sub);
            } else {  // M2M100/NLLB default (post-LN)
                sub = g_attention(ctx, x, x, L.self, c.n_heads, /*causal=*/false);
                x = g_layer_norm(ctx, ggml_add(ctx, x, sub), L.ln1w, L.ln1b);
                sub = g_ffn(ctx, x, L);
                x = g_layer_norm(ctx, ggml_add(ctx, x, sub), L.ln2w, L.ln2b);
            }
        }
        if (c.layer_norm_first) {
            x = g_layer_norm(ctx, x, m_->enc_lnfw, m_->enc_lnfb);
        }

        int rc = compute(ctx, x);
        if (rc == NV_NLLB_OK) {
            const float* src = static_cast<const float*>(x->data);
            mem->assign(src, src + static_cast<size_t>(d * n));
        }
        ggml_free(ctx);
        return rc;
    }

    // One greedy decode step over the current prefix. Returns the argmax
    // token of the last position, or a negative error.
    int decode_step(const std::vector<int>& prefix, const std::vector<float>& mem,
                    int64_t mem_len) {
        const NllbConfig& c = m_->cfg;
        const int64_t n = static_cast<int64_t>(prefix.size());
        const int64_t d = c.d_model;

        struct ggml_context* ctx = make_ctx();
        if (!ctx) return NV_NLLB_ERR_OOM;

        ggml_tensor* mem_t = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, d, mem_len);
        std::memcpy(mem_t->data, mem.data(), sizeof(float) * mem.size());

        ggml_tensor *emb, *pos;
        fill_embeddings(ctx, m_->dec_embed, m_->dec_pos, prefix, c.pos_offset, &emb, &pos);
        ggml_tensor* x = ggml_add(ctx, emb, pos);  // [d, n]

        for (const LayerWeights& L : m_->dec) {
            ggml_tensor* sub;
            if (c.layer_norm_first) {
                sub = g_attention(ctx, g_layer_norm(ctx, x, L.ln1w, L.ln1b), x, L.self,
                                  c.n_heads, /*causal=*/true);
                x = ggml_add(ctx, x, sub);
                sub = g_attention(ctx, g_layer_norm(ctx, x, L.ln3w, L.ln3b), mem_t,
                                  L.cross, c.n_heads, /*causal=*/false);
                x = ggml_add(ctx, x, sub);
                sub = g_ffn(ctx, g_layer_norm(ctx, x, L.ln2w, L.ln2b), L);
                x = ggml_add(ctx, x, sub);
            } else {  // M2M100/NLLB default (post-LN)
                sub = g_attention(ctx, x, x, L.self, c.n_heads, /*causal=*/true);
                x = g_layer_norm(ctx, ggml_add(ctx, x, sub), L.ln1w, L.ln1b);
                sub = g_attention(ctx, x, mem_t, L.cross, c.n_heads, /*causal=*/false);
                x = g_layer_norm(ctx, ggml_add(ctx, x, sub), L.ln3w, L.ln3b);
                sub = g_ffn(ctx, x, L);
                x = g_layer_norm(ctx, ggml_add(ctx, x, sub), L.ln2w, L.ln2b);
            }
        }
        if (c.layer_norm_first) {
            x = g_layer_norm(ctx, x, m_->dec_lnfw, m_->dec_lnfb);
        }

        // lm_head only over the LAST position — full-vocab logits for the
        // whole prefix would waste hundreds of MB of scratch.
        ggml_tensor* h_last = ggml_view_2d(ctx, x, d, 1, x->nb[1],
                                           static_cast<size_t>(n - 1) * x->nb[1]);
        ggml_tensor* logits = ggml_mul_mat(ctx, m_->lm_head, h_last);  // [vocab, 1]

        int rc = compute(ctx, logits);
        int token = NV_NLLB_ERR_INTERNAL;
        if (rc == NV_NLLB_OK) {
            const float* lg = static_cast<const float*>(logits->data);
            const int64_t vocab = m_->lm_head->ne[1];
            int64_t best = 0;
            float best_v = lg[0];
            for (int64_t v = 1; v < vocab; ++v) {
                if (lg[v] > best_v) {
                    best_v = lg[v];
                    best = v;
                }
            }
            token = static_cast<int>(best);
        }
        ggml_free(ctx);
        return token;
    }

private:
    struct ggml_context* make_ctx() {
        ggml_init_params ip = {scratch_size_, scratch_, /*no_alloc=*/false};
        return ggml_init(ip);
    }

    int compute(struct ggml_context* ctx, ggml_tensor* out) {
        struct ggml_cgraph* gf = ggml_build_forward(ctx, out);
        ggml_graph_reset(gf);
        ggml_graph_compute_with_ctx(ctx, gf, n_threads_);
        // ggml aborts on internal errors rather than returning codes; the
        // token caps plus the fixed scratch arena keep the graph in bounds.
        return cancel_->load() ? NV_NLLB_ERR_CANCELLED : NV_NLLB_OK;
    }

    NllbModel* m_;
    std::atomic<bool>* cancel_;
    uint8_t* scratch_;
    size_t scratch_size_;
    int n_threads_;
};

// ---------------------------------------------------------------------------
// Bridge state: model + one-slot job queue + worker thread
// ---------------------------------------------------------------------------

// A request is waiter-owned: `result`/`done_flag` point into the FFI
// caller's stack, so a later caller can never clobber an earlier waiter's
// completion (each translate() blocks on ITS OWN flag).
struct JobRequest {
    std::string text;
    std::string src;
    std::string tgt;
    TranslateResult* result = nullptr;
    bool* done_flag = nullptr;
};

struct NllbState {
    std::mutex model_mutex;               // init/free vs. model access
    std::mutex job_mutex;                 // request slot
    std::condition_variable job_cv;       // wakes the worker
    std::condition_variable done_cv;      // wakes translate() waiters

    NllbModel* model = nullptr;           // null until init succeeds
    std::vector<uint8_t> scratch;         // graph arena (reserved at init)
    std::atomic<size_t> peak_ram{0};

    std::thread worker;
    std::atomic<bool> stopping{false};
    std::atomic<bool> cancel{false};

    bool has_job = false;
    JobRequest request;
};

NllbState g;

int worker_translate(NllbModel* m, const std::string& text, const std::string& src,
                     const std::string& tgt, TranslateResult* out) {
    const auto resolve = [&](const std::string& code, int* id) -> int {
        std::string c = code;
        if (const char* full = canonical_lang(c)) c = full;
        auto it = m->lang_ids.find(c);
        if (it == m->lang_ids.end()) return NV_NLLB_ERR_LANG;
        *id = it->second;
        return NV_NLLB_OK;
    };
    int src_id = -1, tgt_id = -1;
    int rc = resolve(src, &src_id);
    if (rc != NV_NLLB_OK) return rc;
    rc = resolve(tgt, &tgt_id);
    if (rc != NV_NLLB_OK) return rc;
    if (src_id == tgt_id) {  // no-op translation
        out->status = NV_NLLB_OK;
        out->text = text;
        return NV_NLLB_OK;
    }

    // Tokenize (SentencePiece applies NLLB normalization rules).
    std::vector<int> tokens;
    if (!m->spm.Encode(text, &tokens).ok()) return NV_NLLB_ERR_INTERNAL;
    if (static_cast<int>(tokens.size()) > kMaxInputTokens) return NV_NLLB_ERR_TOO_LONG;

    const int n_threads = static_cast<int>(
        std::min<unsigned>(std::max<unsigned>(std::thread::hardware_concurrency(), 1), 4));
    Runner runner(m, &g.cancel, g.scratch.data(), g.scratch.size(), n_threads);

    // Encoder input: [src_lang_id] + tokens + [eos]
    std::vector<int> enc_in;
    enc_in.reserve(tokens.size() + 2);
    enc_in.push_back(src_id);
    enc_in.insert(enc_in.end(), tokens.begin(), tokens.end());
    enc_in.push_back(m->cfg.eos_id);

    std::vector<float> mem;
    rc = runner.encode(enc_in, &mem);
    if (rc != NV_NLLB_OK) return rc;
    const int64_t mem_len = static_cast<int64_t>(enc_in.size());

    // Decoder: [eos, tgt_lang_id] prefix, greedy steps until eos/cap.
    std::vector<int> prefix{m->cfg.eos_id, tgt_id};
    prefix.reserve(static_cast<size_t>(kMaxNewTokens) + 2);
    for (int step = 0; step < kMaxNewTokens; ++step) {
        if (g.cancel.load()) return NV_NLLB_ERR_CANCELLED;
        const int next = runner.decode_step(prefix, mem, mem_len);
        if (next < 0) return next;
        if (next == m->cfg.eos_id) break;
        prefix.push_back(next);
    }

    // Detokenize the generated tokens (skip the [eos, tgt_lang] prefix).
    std::string output;
    if (prefix.size() > 2) {
        if (!m->spm.Decode(std::vector<int>(prefix.begin() + 2, prefix.end()), &output).ok()) {
            return NV_NLLB_ERR_INTERNAL;
        }
    }
    out->status = NV_NLLB_OK;
    out->text = std::move(output);
    return NV_NLLB_OK;
}

void worker_loop() {
    while (true) {
        std::unique_lock<std::mutex> lk(g.job_mutex);
        g.job_cv.wait(lk, [&] { return g.stopping.load() || g.has_job; });
        if (g.stopping.load() && !g.has_job) return;

        JobRequest req = std::move(g.request);
        g.request = JobRequest{};
        NllbModel* model = g.model;  // stable: free() joins us before freeing
        lk.unlock();

        TranslateResult result;
        if (model) {
            g.peak_ram = std::max(g.peak_ram.load(), model->weights_bytes + g.scratch.size());
            result.status = worker_translate(model, req.text, req.src, req.tgt, &result);
            if (result.status != NV_NLLB_OK) {
                NV_LOG("translate %s→%s failed: %d", req.src.c_str(), req.tgt.c_str(),
                       result.status);
            }
        } else {
            result.status = NV_NLLB_ERR_NOT_INIT;
        }

        lk.lock();
        if (req.result) *req.result = std::move(result);
        if (req.done_flag) *req.done_flag = true;
        g.has_job = false;
        g.done_cv.notify_all();
        // Loop: the next request overwrites the slot only after the previous
        // waiter's own flag was set, so no waiter can miss its completion.
    }
}

// model_mutex held by callers.
void teardown_locked() {
    g.stopping.store(true);
    g.cancel.store(true);
    g.job_cv.notify_all();
    g.done_cv.notify_all();
    if (g.worker.joinable()) g.worker.join();
    delete g.model;
    g.model = nullptr;
    std::vector<uint8_t>().swap(g.scratch);  // release the arena
    g.has_job = false;
    g.stopping.store(false);
    g.cancel.store(false);
    g.done_cv.notify_all();  // wake any translate() still parked post-join
}

// model_mutex held by the caller; returns a ready model or null (err set).
NllbModel* load_model_dir(const char* model_dir, std::string* err) {
    auto* m = new NllbModel();
    m->dir = model_dir;

    // --- manifest ----------------------------------------------------------
    std::string raw;
    if (!read_file(m->dir + "/nllb.json", &raw)) {
        *err = "nllb.json not found";
        delete m;
        return nullptr;
    }
    std::map<std::string, JsonVal> manifest;
    if (!json_parse_flat(raw, &manifest)) {
        *err = "nllb.json parse error";
        delete m;
        return nullptr;
    }
    const auto num = [&](const char* k, int dflt) {
        auto it = manifest.find(k);
        return (it != manifest.end() && it->second.kind == JsonVal::KIND_NUM)
                   ? static_cast<int>(it->second.num)
                   : dflt;
    };
    const auto boolean = [&](const char* k, bool dflt) {
        auto it = manifest.find(k);
        return (it != manifest.end() && it->second.kind == JsonVal::KIND_BOOL)
                   ? it->second.bool_val
                   : dflt;
    };
    m->cfg.d_model = num("d_model", 1024);
    m->cfg.n_heads = num("n_heads", 16);
    m->cfg.encoder_layers = num("encoder_layers", 12);
    m->cfg.decoder_layers = num("decoder_layers", 12);
    m->cfg.ffn_dim = num("ffn_dim", 4096);
    m->cfg.vocab_size = num("vocab_size", 256206);
    m->cfg.max_positions = num("max_positions", 1024);
    m->cfg.layer_norm_first = boolean("layer_norm_first", false);
    m->cfg.share_input_output_embed = boolean("share_input_output_embed", true);
    m->cfg.pos_offset = num("pos_offset", 2);
    m->cfg.eos_id = num("eos_id", 2);
    m->cfg.unk_id = num("unk_id", 3);
    m->cfg.pad_id = num("pad_id", 1);
    m->cfg.scratch_bytes = static_cast<size_t>(
                               num("graph_scratch_mb",
                                   static_cast<int>(kDefaultScratchBytes >> 20)))
                           << 20;

    // --- tokenizer -----------------------------------------------------------
    if (!m->spm.Load(m->dir + "/tokenizer.model").ok()) {
        *err = "tokenizer.model load failed";
        delete m;
        return nullptr;
    }

    // --- language ids ---------------------------------------------------------
    std::string langs_raw;
    if (read_file(m->dir + "/langs.json", &langs_raw)) {
        std::map<std::string, JsonVal> langs;
        if (json_parse_flat(langs_raw, &langs)) {
            for (const auto& kv : langs) {
                if (kv.second.kind == JsonVal::KIND_NUM) {
                    m->lang_ids[kv.first] = static_cast<int>(kv.second.num);
                }
            }
        }
    }
    if (m->lang_ids.empty()) {
        *err = "langs.json missing/empty";
        delete m;
        return nullptr;
    }

    // --- weights ----------------------------------------------------------------
    const int wrc = load_weights(m, m->dir + "/weights.nvbin", err);
    if (wrc != NV_NLLB_OK) {
        delete m;
        return nullptr;
    }
    const int rrc = resolve_model(m, err);
    if (rrc != NV_NLLB_OK) {
        delete m;
        return nullptr;
    }
    return m;
}

}  // namespace

// ---------------------------------------------------------------------------
// Exported FFI surface
// ---------------------------------------------------------------------------

extern "C" {

NV_EXPORT int nv_nllb_init(const char* model_dir) {
    try {
        if (!model_dir || !model_dir[0]) return NV_NLLB_ERR_INVALID_ARG;

        std::lock_guard<std::mutex> lk(g.model_mutex);
        teardown_locked();  // re-init replaces a loaded model

        std::string err;
        NllbModel* m = load_model_dir(model_dir, &err);
        if (!m) {
            NV_LOG("init failed: %s", err.c_str());
            return NV_NLLB_ERR_MODEL_LOAD;
        }

        g.scratch.resize(m->cfg.scratch_bytes);  // reserved, touched lazily
        g.peak_ram = m->weights_bytes;
        g.model = m;

        if (!g.worker.joinable()) {
            g.worker = std::thread(worker_loop);
        }
        NV_LOG("loaded nllb model from %s (%zu MB weights, %zu MB scratch)",
               model_dir, m->weights_bytes >> 20, g.scratch.size() >> 20);
        return NV_NLLB_OK;
    } catch (const std::bad_alloc&) {
        return NV_NLLB_ERR_OOM;
    } catch (const std::exception& e) {
        NV_LOG("init exception: %s", e.what());
        return NV_NLLB_ERR_INTERNAL;
    } catch (...) {
        return NV_NLLB_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_nllb_translate(const char* text, const char* src_lang,
                                const char* tgt_lang, char* out, int out_len) {
    try {
        if (!text || !src_lang || !tgt_lang || !out || out_len <= 0) {
            return NV_NLLB_ERR_INVALID_ARG;
        }
        out[0] = '\0';
        if (!g.model) return NV_NLLB_ERR_NOT_INIT;

        TranslateResult result;   // written by the worker under job_mutex
        bool done = false;

        {
            std::lock_guard<std::mutex> lk(g.job_mutex);
            if (g.has_job) return NV_NLLB_ERR_BUSY;

            g.request = JobRequest{};
            g.request.text = text;
            g.request.src = src_lang;
            g.request.tgt = tgt_lang;
            g.request.result = &result;
            g.request.done_flag = &done;
            g.has_job = true;
            g.cancel.store(false);
            g.job_cv.notify_one();
        }

        // Block until the worker finishes (bounded by the token caps), or
        // the bridge is torn down from another thread.
        std::unique_lock<std::mutex> lk(g.job_mutex);
        g.done_cv.wait(lk, [&] { return done || g.stopping.load(); });
        if (!done) return NV_NLLB_ERR_CANCELLED;

        const size_t copied =
            result.text.copy(out, static_cast<size_t>(out_len) - 1);
        out[copied] = '\0';
        return (copied < result.text.size()) ? NV_NLLB_ERR_TRUNCATED : result.status;
    } catch (const std::bad_alloc&) {
        return NV_NLLB_ERR_OOM;
    } catch (...) {
        return NV_NLLB_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_nllb_lang_supported(const char* code) {
    try {
        if (!code || !g.model) return 0;
        std::string c = code;
        if (const char* full = canonical_lang(c)) c = full;
        return g.model->lang_ids.count(c) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

NV_EXPORT int nv_nllb_max_input_tokens(void) {
    return kMaxInputTokens;
}

NV_EXPORT size_t nv_nllb_current_ram_bytes(void) {
    std::lock_guard<std::mutex> lk(g.model_mutex);
    if (!g.model) return 0;
    return g.model->weights_bytes + (g.has_job ? g.scratch.size() : 0);
}

NV_EXPORT size_t nv_nllb_peak_ram_bytes(void) {
    std::lock_guard<std::mutex> lk(g.model_mutex);
    return g.peak_ram.load();
}

NV_EXPORT void nv_nllb_free(void) {
    try {
        std::lock_guard<std::mutex> lk(g.model_mutex);
        teardown_locked();
    } catch (...) {
        // Free must never throw across FFI.
    }
}

NV_EXPORT const char* nv_nllb_version(void) {
    return "nllb_bridge 1.0.0 (ggml m2m100 runtime)";
}

}  // extern "C"
