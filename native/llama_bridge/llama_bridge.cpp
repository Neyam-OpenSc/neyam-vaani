// llama_bridge.cpp — on-device LLM bridge between Dart (FFI) and llama.cpp.
//
// Architecture:
//
//   Dart (background isolate)        bridge worker thread
//   ────────────────────────         ─────────────────────
//   nv_llama_generate ──────────►    tokenize+validate (sync), then:
//                                    ChatML prompt decode
//                                    token loop ───► nv_llama_token_cb
//   nv_llama_stop ─────────────►     abort_callback → final cb with partial
//   nv_llama_unload ───────────►     free model+ctx (reload() can restore)
//
// Conversation memory is owned by the Dart layer (the context manager keeps
// the last 5 turns, per docs/architecture.md): this bridge is stateless
// between generate() calls — the KV cache is cleared after every answer.
// This keeps a turn cheap and makes unload/reload under memory pressure a
// clean operation.
//
// No exception crosses the FFI boundary: every exported function is wrapped
// in try/catch and maps failures to NV_LLAMA_ERR_* codes.

#include "llama_bridge.h"

#include "llama.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef __ANDROID__
#include <android/log.h>
#define NV_LOG(...) __android_log_print(ANDROID_LOG_INFO, "nv-llama", __VA_ARGS__)
#else
#define NV_LOG(...) fprintf(stderr, "[nv-llama] " __VA_ARGS__), fprintf(stderr, "\n")
#endif

namespace {

constexpr int32_t kDefaultCtxTokens = 4096;
constexpr int32_t kMinCtxTokens     = 512;
constexpr int32_t kMaxCtxTokens     = 16384;
constexpr int32_t kMinFreeTokens    = 16;   // prompt must leave at least this
constexpr int32_t kMaxNewTokens     = 512;  // per-answer cap
constexpr size_t  kMaxPromptBytes   = 96u << 10;

size_t read_process_peak_rss() {
    std::FILE* f = std::fopen("/proc/self/status", "r");
    if (!f) return 0;
    char line[256];
    size_t peak = 0;
    while (std::fgets(line, sizeof(line), f)) {
        if (std::strncmp(line, "VmHWM:", 6) == 0) {
            long kb = std::strtol(line + 6, nullptr, 10);
            if (kb > 0) peak = static_cast<size_t>(kb) * 1024;
            break;
        }
    }
    std::fclose(f);
    return peak;
}

struct GenerateTask {
    std::vector<llama_token> prompt_tokens;  // full ChatML prompt, pre-validated
    nv_llama_token_cb cb = nullptr;
};

struct LlamaState {
    std::mutex api_mutex;             // lifecycle + task submission
    std::mutex data_mutex;            // guards last_full/last_status/tps/paths
    std::condition_variable task_cv;  // wakes the worker
    std::condition_variable idle_cv;  // unload waits for !generating

    llama_model*   model = nullptr;
    llama_context* ctx    = nullptr;
    llama_sampler* sampler = nullptr;
    const llama_vocab* vocab = nullptr;
    std::string model_path;           // remembered for reload()
    int32_t     ctx_tokens = kDefaultCtxTokens;
    bool        low_ram = false;
    size_t      model_bytes = 0;

    std::thread worker;
    std::atomic<bool> stopping{false};
    std::atomic<bool> stop_gen{false};
    std::atomic<bool> generating{false};

    bool has_task = false;
    GenerateTask pending;

    std::string last_full;
    std::atomic<int> last_status{NV_LLAMA_OK};
    float last_tps = -1.0f;
};

LlamaState g;
std::once_flag g_backend_once;

void backend_init_once() {
    std::call_once(g_backend_once, [] { llama_backend_init(); });
}

// ChatML — Qwen2.5-Instruct's native template. Kept literal so the bridge
// has no template-engine dependency; other GGUF models that speak ChatML
// work unchanged. The prompt library lives in app/assets/prompts/.
std::string build_chatml(const std::string& system, const std::string& user) {
    std::string prompt;
    prompt.reserve(system.size() + user.size() + 64);
    if (!system.empty()) {
        prompt += "<|im_start|>system\n" + system + "<|im_end|>\n";
    }
    prompt += "<|im_start|>user\n" + user + "<|im_end|>\n";
    prompt += "<|im_start|>assistant\n";
    return prompt;
}

// Tokenize into `out`; returns NV_LLAMA_OK or a negative error.
int tokenize_prompt(const std::string& text, std::vector<llama_token>* out) {
    constexpr int kEstimate = 4;  // bytes/token is a safe first guess
    out->resize(std::max<size_t>(text.size() / kEstimate, 32) + 16);
    int32_t n = llama_tokenize(g.vocab, text.data(), static_cast<int32_t>(text.size()),
                               out->data(), static_cast<int32_t>(out->size()),
                               /*add_special=*/true, /*parse_special=*/true);
    if (n < 0) {  // needed size returned as -n
        out->resize(static_cast<size_t>(-n));
        n = llama_tokenize(g.vocab, text.data(), static_cast<int32_t>(text.size()),
                           out->data(), static_cast<int32_t>(out->size()),
                           /*add_special=*/true, /*parse_special=*/true);
    }
    if (n <= 0) return NV_LLAMA_ERR_INVALID_ARG;
    out->resize(static_cast<size_t>(n));
    return NV_LLAMA_OK;
}

// Runs on the worker with api_mutex NOT held; model/ctx/sampler are owned by
// the worker during generation (unload waits for `generating` to clear).
void run_generation(GenerateTask task) {
    nv_llama_token_cb cb = task.cb;

    g.stop_gen.store(false);
    g.generating.store(true);
    std::string full;                     // UTF-8 byte accumulation
    full.reserve(4096);
    int32_t n_generated = 0;
    int status = NV_LLAMA_OK;

    llama_perf_context_reset(g.ctx);
    llama_sampler_reset(g.sampler);

    // --- prompt processing -------------------------------------------------
    const int32_t n_batch = 512;
    bool aborted = false;
    for (size_t i = 0; i < task.prompt_tokens.size() && !aborted; i += n_batch) {
        const int32_t take = static_cast<int32_t>(
            std::min<size_t>(n_batch, task.prompt_tokens.size() - i));
        llama_batch batch = llama_batch_get_one(task.prompt_tokens.data() + i, take);
        if (llama_decode(g.ctx, batch) != 0) {
            aborted = true;  // abort_callback fired (or true decode failure)
        }
    }

    // --- token loop ---------------------------------------------------------
    const uint32_t n_ctx = llama_n_ctx(g.ctx);
    const int32_t max_new = static_cast<int32_t>(
        std::min<int64_t>(kMaxNewTokens,
                          static_cast<int64_t>(n_ctx) -
                              static_cast<int64_t>(task.prompt_tokens.size()) - 1));

    for (int32_t step = 0; step < max_new && !aborted; ++step) {
        if (g.stop_gen.load()) { aborted = true; break; }

        const llama_token token = llama_sampler_sample(g.sampler, g.ctx, /*idx=*/-1);
        if (llama_vocab_is_eog(g.vocab, token)) break;  // <|im_end|> for Qwen

        llama_sampler_accept(g.sampler, token);

        char piece[256];
        const int32_t piece_len =
            llama_token_to_piece(g.vocab, token, piece, sizeof(piece),
                                 /*lstrip=*/0, /*special=*/false);
        if (piece_len > 0 && piece_len <= static_cast<int32_t>(sizeof(piece))) {
            full.append(piece, static_cast<size_t>(piece_len));
        }
        ++n_generated;
        if (cb) cb(piece_len > 0 ? piece : "", full.c_str(), n_generated, false);

        llama_token feed = token;
        llama_batch batch = llama_batch_get_one(&feed, 1);
        if (llama_decode(g.ctx, batch) != 0) {
            aborted = true;  // stop_gen aborts mid-decode like this
        }
    }

    if (aborted && g.stop_gen.load()) status = NV_LLAMA_ERR_CANCELLED;
    else if (aborted) status = NV_LLAMA_ERR_INTERNAL;

    // --- perf + cleanup ------------------------------------------------------
    if (n_generated > 0) {
        const llama_perf_context_data perf = llama_perf_context(g.ctx);
        if (perf.t_eval_ms > 0.0) {
            g.last_tps = static_cast<float>(perf.n_eval) /
                         static_cast<float>(perf.t_eval_ms / 1000.0);
        }
    }

    // The bridge is stateless between turns: drop the KV cache so the next
    // generate() starts from a clean context (history is Dart's job).
    llama_memory_seq_rm(llama_get_memory(g.ctx), /*seq_id=*/0, /*p0=*/-1, /*p1=*/-1);

    g.generating.store(false);
    g.last_status.store(status);
    {
        // idle_cv waiters (unload) wait on data_mutex — notify under it.
        std::lock_guard<std::mutex> lk(g.data_mutex);
        g.last_full = full;
        g.idle_cv.notify_all();
    }

    if (cb) cb("", full.c_str(), n_generated, /*is_final=*/true);  // exactly one
}

void worker_loop() {
    while (true) {
        std::unique_lock<std::mutex> lk(g.api_mutex);
        g.task_cv.wait(lk, [&] { return g.stopping.load() || g.has_task; });
        if (g.stopping.load() && !g.has_task) return;

        GenerateTask task = std::move(g.pending);
        g.pending = GenerateTask{};
        g.has_task = false;
        lk.unlock();

        run_generation(std::move(task));
    }
}

// api_mutex held by callers.
int load_model_locked(const char* gguf_path, int32_t ctx_tokens, bool low_ram) {
    backend_init_once();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 0;  // CPU-only: $200 phones have no usable NPU path
    if (low_ram) {
        // Page the weights in/out (mmap, never mlock) so the OS can reclaim
        // them around STT/TTS spikes — see the swap strategy in
        // docs/architecture.md. Default mode stays AUTO.
        mparams.load_mode = LLAMA_LOAD_MODE_MMAP;
    }

    llama_model* model = llama_model_load_from_file(gguf_path, mparams);
    if (!model) return NV_LLAMA_ERR_MODEL_LOAD;

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = ctx_tokens;
    cparams.n_threads = low_ram ? 2 : static_cast<int>(std::min<unsigned>(
                                          std::thread::hardware_concurrency(), 4));
    cparams.n_threads_batch = cparams.n_threads;
    cparams.n_batch = low_ram ? 256 : 512;
    cparams.n_ubatch = low_ram ? 256 : 512;
    if (low_ram) {
        cparams.type_k = GGML_TYPE_Q8_0;  // halves the KV cache: 4096 ctx ×
        cparams.type_v = GGML_TYPE_Q8_0;  // ~28 layers fits 2 GB devices
    }
    cparams.abort_callback = [](void* user_data) -> bool {
        return static_cast<LlamaState*>(user_data)->stop_gen.load();
    };
    cparams.abort_callback_data = &g;

    llama_context* ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        llama_model_free(model);
        return NV_LLAMA_ERR_OOM;
    }

    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler* chain = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());  // deterministic

    g.model = model;
    g.ctx = ctx;
    g.sampler = chain;
    g.vocab = llama_model_get_vocab(model);
    g.model_path = gguf_path;
    g.ctx_tokens = ctx_tokens;
    g.low_ram = low_ram;

    std::FILE* f = std::fopen(gguf_path, "rb");
    if (f) {
        std::fseek(f, 0, SEEK_END);
        long sz = std::ftell(f);
        std::fclose(f);
        g.model_bytes = sz > 0 ? static_cast<size_t>(sz) : 0;
    }

    NV_LOG("loaded %s (ctx=%d, low_ram=%d, %zu bytes)", gguf_path, ctx_tokens,
           low_ram ? 1 : 0, g.model_bytes);
    return NV_LLAMA_OK;
}

// api_mutex held by callers. Waits for an in-flight generation, then frees
// the model. Keeps model_path/params for reload().
int unload_locked() {
    if (!g.model && !g.ctx) return NV_LLAMA_OK;

    if (g.generating.load()) {
        // Wait on data_mutex (NOT api_mutex — callers hold it and it is not
        // recursive); run_generation notifies idle_cv under data_mutex.
        g.stop_gen.store(true);
        std::unique_lock<std::mutex> lk(g.data_mutex);
        g.idle_cv.wait_for(lk, std::chrono::seconds(5),
                           [] { return !g.generating.load(); });
        g.stop_gen.store(false);
    }

    if (g.sampler) {
        llama_sampler_free(g.sampler);
        g.sampler = nullptr;
    }
    if (g.ctx) {
        llama_free(g.ctx);  // upstream C API — our export is nv_llama_free
        g.ctx = nullptr;
    }
    if (g.model) {
        llama_model_free(g.model);
        g.model = nullptr;
    }
    g.vocab = nullptr;
    g.model_bytes = 0;
    g.has_task = false;
    return NV_LLAMA_OK;
}

}  // namespace

// ---------------------------------------------------------------------------
// Exported FFI surface
// ---------------------------------------------------------------------------

extern "C" {

NV_EXPORT int nv_llama_init(const char* gguf_path, int32_t ctx_tokens, bool low_ram) {
    try {
        if (!gguf_path || !gguf_path[0]) return NV_LLAMA_ERR_INVALID_ARG;
        if (ctx_tokens == 0) ctx_tokens = kDefaultCtxTokens;
        if (ctx_tokens < kMinCtxTokens || ctx_tokens > kMaxCtxTokens) {
            return NV_LLAMA_ERR_INVALID_ARG;
        }

        std::lock_guard<std::mutex> lk(g.api_mutex);
        const int rc = unload_locked();  // re-init replaces a loaded model
        if (rc != NV_LLAMA_OK) return rc;

        const int lrc = load_model_locked(gguf_path, ctx_tokens, low_ram);
        if (lrc != NV_LLAMA_OK) return lrc;

        if (!g.worker.joinable()) {
            g.stopping.store(false);
            g.worker = std::thread(worker_loop);
        }
        return NV_LLAMA_OK;
    } catch (const std::bad_alloc&) {
        return NV_LLAMA_ERR_OOM;
    } catch (const std::exception& e) {
        NV_LOG("init exception: %s", e.what());
        return NV_LLAMA_ERR_INTERNAL;
    } catch (...) {
        return NV_LLAMA_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_llama_is_loaded(void) {
    return (g.model && g.ctx) ? 1 : 0;
}

NV_EXPORT int nv_llama_reload(void) {
    try {
        std::lock_guard<std::mutex> lk(g.api_mutex);
        if (g.model && g.ctx) return NV_LLAMA_OK;  // already loaded: idempotent
        if (g.model_path.empty()) return NV_LLAMA_ERR_UNLOADED;

        const int lrc = load_model_locked(g.model_path.c_str(), g.ctx_tokens, g.low_ram);
        if (lrc != NV_LLAMA_OK) return lrc;

        if (!g.worker.joinable()) {
            g.stopping.store(false);
            g.worker = std::thread(worker_loop);
        }
        return NV_LLAMA_OK;
    } catch (...) {
        return NV_LLAMA_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_llama_generate(const char* system, const char* user, nv_llama_token_cb cb) {
    try {
        if (!user || !user[0] || !cb) return NV_LLAMA_ERR_INVALID_ARG;

        std::lock_guard<std::mutex> lk(g.api_mutex);
        if (!g.model || !g.ctx || !g.vocab) return NV_LLAMA_ERR_NOT_INIT;
        if (g.generating.load() || g.has_task) return NV_LLAMA_ERR_BUSY;

        const std::string prompt = build_chatml(system ? system : "", user);
        if (prompt.size() > kMaxPromptBytes) return NV_LLAMA_ERR_INVALID_ARG;

        // Synchronous validation so overflow errors return from THIS call.
        GenerateTask task;
        task.cb = cb;
        int rc = tokenize_prompt(prompt, &task.prompt_tokens);
        if (rc != NV_LLAMA_OK) return rc;

        const uint32_t n_ctx = llama_n_ctx(g.ctx);
        if (task.prompt_tokens.size() + kMinFreeTokens > n_ctx) {
            NV_LOG("prompt (%zu tokens) overflows context (%u)", task.prompt_tokens.size(),
                   n_ctx);
            return NV_LLAMA_ERR_CTX_OVERFLOW;
        }

        g.pending = std::move(task);
        g.has_task = true;
        g.task_cv.notify_one();
        return NV_LLAMA_OK;
    } catch (const std::bad_alloc&) {
        return NV_LLAMA_ERR_OOM;
    } catch (...) {
        return NV_LLAMA_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_llama_stop(void) {
    try {
        g.stop_gen.store(true);  // abort_callback picks this up mid-decode
        return NV_LLAMA_OK;
    } catch (...) {
        return NV_LLAMA_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_llama_is_generating(void) {
    return (g.generating.load() || g.has_task) ? 1 : 0;
}

NV_EXPORT int nv_llama_unload(void) {
    try {
        std::lock_guard<std::mutex> lk(g.api_mutex);
        return unload_locked();  // model_path etc. kept for reload()
    } catch (...) {
        return NV_LLAMA_ERR_INTERNAL;
    }
}

NV_EXPORT float nv_llama_tokens_per_second(void) {
    return g.last_tps;
}

NV_EXPORT size_t nv_llama_ram_bytes(void) {
    std::lock_guard<std::mutex> lk(g.api_mutex);
    return g.model_bytes;
}

NV_EXPORT size_t nv_llama_process_peak_rss(void) {
    return read_process_peak_rss();
}

NV_EXPORT int nv_llama_last_status(void) {
    return g.last_status.load();
}

NV_EXPORT int nv_llama_last_full_text(char* out, int out_len) {
    try {
        if (!out || out_len <= 0) return NV_LLAMA_ERR_INVALID_ARG;
        std::lock_guard<std::mutex> lk(g.data_mutex);
        std::snprintf(out, static_cast<size_t>(out_len), "%s", g.last_full.c_str());
        return NV_LLAMA_OK;
    } catch (...) {
        return NV_LLAMA_ERR_INTERNAL;
    }
}

NV_EXPORT void nv_llama_free(void) {
    try {
        {
            std::lock_guard<std::mutex> lk(g.api_mutex);
            g.stopping.store(true);
            g.stop_gen.store(true);
            g.has_task = false;
            unload_locked();
        }
        g.task_cv.notify_all();
        if (g.worker.joinable()) g.worker.join();
        {
            std::lock_guard<std::mutex> lk(g.data_mutex);
            g.last_full.clear();
            g.last_tps = -1.0f;
            g.model_path.clear();
        }
        g.stopping.store(false);
    } catch (...) {
        // Free must never throw across FFI.
    }
}

NV_EXPORT const char* nv_llama_version(void) {
    return "llama_bridge 1.0.0 (llama.cpp, sampler-chain API)";
}

}  // extern "C"
