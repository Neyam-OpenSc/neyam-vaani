// whisper_bridge.cpp — STT bridge between Dart (FFI) and whisper.cpp.
//
// Architecture:
//
//   Dart audio thread            bridge worker thread
//   ─────────────────            ─────────────────────
//   nv_whisper_feed_pcm_*  ───►  PCM ring buffer ───► sliding-window decode
//   nv_whisper_flush_final ───►  full-buffer decode ───► nv_whisper_transcript_cb
//
// Partials are decoded from an internal thread over the last ~10 s of audio
// each time ~1.2 s of new samples arrive; flush_final decodes the whole
// buffered utterance, emits is_final=true, and resets. The whisper context is
// only ever touched from one thread at a time (decode_mutex).
//
// Privacy: audio lives in RAM only, is never written to disk, and is dropped
// on reset/flush/free (PRIVACY_CHARTER.md).
//
// No exception crosses the FFI boundary: every exported function is wrapped
// in try/catch and maps failures to NV_WHISPER_ERR_* codes.

#include "whisper_bridge.h"

#include "whisper.h"

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
#define NV_LOG(...) __android_log_print(ANDROID_LOG_INFO, "nv-whisper", __VA_ARGS__)
#else
#define NV_LOG(...) fprintf(stderr, "[nv-whisper] " __VA_ARGS__), fprintf(stderr, "\n")
#endif

namespace {

// ---------------------------------------------------------------------------
// Tunables (see README for the reasoning behind each).
// ---------------------------------------------------------------------------
constexpr int    kSampleRate            = 16000;
constexpr int    kThreadsMin            = 2;
constexpr int    kThreadsMax            = 4;
constexpr size_t kPartialIntervalMs     = 1200; // new audio needed per partial
constexpr size_t kPartialWindowMs       = 10000; // partial decode window
constexpr size_t kMaxBufferMs           = 30000; // utterance hard cap
constexpr size_t kMinBufferMs           = 10000; // even under RAM pressure
constexpr size_t kFixedOverheadBytes    = 64u << 20;  // whisper state + scratch estimate
constexpr int    kFlushWatchdogMs       = 30000;

constexpr size_t ms_to_samples(size_t ms) { return (kSampleRate * ms) / 1000; }

// ---------------------------------------------------------------------------
// State (single instance; one utterance stream per process is the product
// model — push-to-talk, one mic).
// ---------------------------------------------------------------------------
struct WhisperState {
    std::mutex api_mutex;            // lifecycle calls (init/free)
    std::mutex buf_mutex;            // guards pcm/unprocessed/final flags
    std::mutex decode_mutex;         // only one whisper_full at a time
    std::condition_variable work_cv;   // wakes the worker
    std::condition_variable final_cv;  // flush_final waiters

    whisper_context* ctx = nullptr;  // owned; freed with whisper_free()
    std::string model_path;
    std::string lang = "en";         // ISO code or "auto"
    size_t model_bytes = 0;          // file size, our RAM accounting base

    std::atomic<bool> ready{false};
    std::atomic<bool> stopping{false};
    std::atomic<bool> cancel_decode{false};
    std::atomic<int>  decode_threads{kThreadsMin};

    nv_whisper_transcript_cb cb = nullptr;

    std::vector<float> pcm;          // 16 kHz mono, oldest first
    size_t unprocessed = 0;          // samples not yet covered by a partial
    size_t max_buffer_samples = ms_to_samples(kMaxBufferMs);

    bool final_requested = false;
    bool final_done      = false;

    size_t mem_budget = size_t{320} << 20;
    size_t peak_ram   = 0;

    std::thread worker;

    size_t current_ram_bytes_locked() const {
        // Model file is mmapped/read into whisper's context; the state and
        // compute scratch are estimated conservatively by kFixedOverheadBytes.
        return model_bytes + kFixedOverheadBytes + pcm.capacity() * sizeof(float);
    }
};

WhisperState g;  // guarded by api_mutex / buf_mutex; trivially destructible parts only

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

size_t file_size_bytes(const char* path) {
    std::FILE* f = std::fopen(path, "rb");
    if (!f) return 0;
    std::fseek(f, 0, SEEK_END);
    long size = std::ftell(f);
    std::fclose(f);
    return size > 0 ? static_cast<size_t>(size) : 0;
}

size_t read_process_peak_rss() {
    // /proc/self/status → "VmHWM:  123456 kB" (Linux/Android only).
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

void update_peak_locked() {
    g.peak_ram = std::max(g.peak_ram, g.current_ram_bytes_locked());
}

void deliver(nv_whisper_transcript_cb cb, const std::string& text, bool is_final,
             const std::string& lang) {
    if (!cb) return;
    // Contract: text/lang are copied by the callee immediately (NativeCallable
    // copies into a message; they are only valid for the duration of the call).
    cb(text.c_str(), is_final, lang.c_str());
}

// Runs whisper_full over `samples`. Called with decode_mutex held by caller.
int decode_locked(const float* samples, int n_samples, bool is_final_request,
                  std::string* out_text, std::string* out_lang) {
    *out_text = "";
    *out_lang = g.lang;

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads        = g.decode_threads.load();
    params.translate        = false;
    params.print_progress   = false;
    params.print_realtime   = false;
    params.print_special    = false;
    params.print_timestamps = false;
    params.no_timestamps    = true;   // we only want text
    params.no_context       = true;   // each window is decoded independently
    params.single_segment   = false;
    params.suppress_blank   = true;
    params.suppress_nst     = true;
    params.temperature      = 0.0f;   // deterministic partials on tiny models
    params.greedy.best_of   = 1;

    const bool auto_lang = (g.lang == "auto");
    params.detect_language = auto_lang || is_final_request; // report best guess on finals
    params.language        = auto_lang ? "auto" : g.lang.c_str();

    params.abort_callback = [](void* user_data) -> bool {
        return static_cast<WhisperState*>(user_data)->cancel_decode.load();
    };
    params.abort_callback_user_data = &g;

    const int rc = whisper_full(g.ctx, params, samples, n_samples);
    if (rc != 0) {
        return g.cancel_decode.load() ? NV_WHISPER_ERR_CANCELLED : NV_WHISPER_ERR_INTERNAL;
    }

    if (auto_lang) {
        const int lang_id = whisper_full_lang_id(g.ctx);
        const char* lang_str = (lang_id >= 0) ? whisper_lang_str(lang_id) : nullptr;
        *out_lang = lang_str ? lang_str : "auto";
    }

    const int n_segments = whisper_full_n_segments(g.ctx);
    for (int i = 0; i < n_segments; ++i) {
        const char* seg = whisper_full_get_segment_text(g.ctx, i);
        if (seg) *out_text += seg;
    }
    // Trim the usual leading space whisper emits; drop trailing whitespace.
    size_t b = out_text->find_first_not_of(" \t\r\n");
    size_t e = out_text->find_last_not_of(" \t\r\n");
    *out_text = (b == std::string::npos) ? std::string() : out_text->substr(b, e - b + 1);
    return NV_WHISPER_OK;
}

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------

void worker_loop() {
    const size_t stride = ms_to_samples(kPartialIntervalMs);
    const size_t window = ms_to_samples(kPartialWindowMs);

    while (true) {
        std::unique_lock<std::mutex> lk(g.buf_mutex);
        g.work_cv.wait(lk, [&] {
            return g.stopping.load() || g.final_requested || g.unprocessed >= stride;
        });
        if (g.stopping.load()) return;

        const bool want_final = g.final_requested;
        const size_t pending_at_start = g.unprocessed;

        // Snapshot the audio to decode (last `window` for partials, all for final).
        std::vector<float> snap;
        if (want_final) {
            snap.assign(g.pcm.begin(), g.pcm.end());
        } else if (g.pcm.size() > window) {
            snap.assign(g.pcm.end() - static_cast<long>(window), g.pcm.end());
        } else {
            snap.assign(g.pcm.begin(), g.pcm.end());
        }
        lk.unlock();

        std::string text, lang;
        int rc = NV_WHISPER_OK;
        if (!snap.empty()) {
            std::lock_guard<std::mutex> decode_lk(g.decode_mutex);
            rc = decode_locked(snap.data(), static_cast<int>(snap.size()),
                               want_final, &text, &lang);
        } else {
            lang = g.lang;  // empty final: utterance ended with no audio
        }
        snap.clear();
        snap.shrink_to_fit();

        // Deliver outside every lock. Even a failed decode closes the
        // utterance with an (empty) final so the Dart state machine advances.
        deliver(g.cb, text, want_final, rc == NV_WHISPER_OK ? lang : g.lang);

        lk.lock();
        // Account only for the samples this decode covered; anything fed
        // while we were decoding keeps its "unprocessed" credit so the next
        // partial is not delayed by a full stride.
        g.unprocessed = (g.unprocessed > pending_at_start)
                            ? g.unprocessed - pending_at_start
                            : 0;
        if (want_final) {
            g.pcm.clear();
            g.pcm.shrink_to_fit();
            g.final_requested = false;
            g.final_done = true;
            update_peak_locked();
            g.final_cv.notify_all();
        }
        lk.unlock();
    }
}

// Called with api_mutex held. Must NOT hold buf_mutex while joining the
// worker: the worker re-acquires buf_mutex to return from its cv wait, so
// joining under it would deadlock.
void teardown_locked() {
    {
        std::lock_guard<std::mutex> lk(g.buf_mutex);
        g.stopping.store(true);
        g.cancel_decode.store(true);
        g.final_requested = false;
    }
    g.work_cv.notify_all();
    g.final_cv.notify_all();
    if (g.worker.joinable()) g.worker.join();

    if (g.ctx) {
        whisper_free(g.ctx);  // upstream C API — our export is nv_whisper_free
        g.ctx = nullptr;
    }
    {
        std::lock_guard<std::mutex> lk(g.buf_mutex);
        g.pcm.clear();
        g.pcm.shrink_to_fit();
        g.unprocessed = 0;
        g.final_done = false;
        g.cb = nullptr;
        g.model_path.clear();
        g.model_bytes = 0;
        g.ready.store(false);
        g.stopping.store(false);
        g.cancel_decode.store(false);
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// Exported FFI surface
// ---------------------------------------------------------------------------

extern "C" {

NV_EXPORT int nv_whisper_init(const char* model_path, const char* lang) {
    try {
        if (!model_path || !lang || !lang[0]) return NV_WHISPER_ERR_INVALID_ARG;

        std::lock_guard<std::mutex> api_lk(g.api_mutex);
        teardown_locked();  // re-init is allowed; previous model is released first

        const size_t fsize = file_size_bytes(model_path);
        if (fsize == 0) return NV_WHISPER_ERR_MODEL_LOAD;
        if (fsize + kFixedOverheadBytes > g.mem_budget) {
            NV_LOG("model (%zu bytes) exceeds RAM budget (%zu bytes)", fsize, g.mem_budget);
            return NV_WHISPER_ERR_MEM_BUDGET;
        }

        // Language must be known to whisper.cpp. Note for bho/mai packs:
        // whisper.cpp has no Bhojpuri/Maithili codes; those fine-tuned packs
        // declare the whisper-recognized code their fine-tune targets
        // (typically "hi") in the language-pack manifest, and Dart passes
        // that code here. "auto" defers detection to decode time.
        const bool auto_lang = (std::strcmp(lang, "auto") == 0);
        if (!auto_lang && whisper_lang_id(lang) < 0) {
            NV_LOG("unsupported language code: %s", lang);
            return NV_WHISPER_ERR_INVALID_ARG;
        }

        whisper_context_params cparams = whisper_context_default_params();
        cparams.use_gpu    = false;  // $200 phones: CPU-only inference
        cparams.flash_attn = false;  // not guaranteed on ARMv8-A cores

        whisper_context* ctx = whisper_init_from_file_with_params(model_path, cparams);
        if (!ctx) return NV_WHISPER_ERR_MODEL_LOAD;

        g.ctx         = ctx;
        g.lang        = lang;
        g.model_path  = model_path;
        g.model_bytes = fsize;

        // Audio headroom under the memory budget, clamped to [10 s, 30 s].
        const size_t headroom =
            (g.mem_budget > fsize + kFixedOverheadBytes)
                ? g.mem_budget - fsize - kFixedOverheadBytes
                : 0;
        size_t cap = headroom / sizeof(float);
        cap = std::min(cap, ms_to_samples(kMaxBufferMs));
        cap = std::max(cap, ms_to_samples(kMinBufferMs));
        g.max_buffer_samples = cap;

        g.peak_ram = g.current_ram_bytes_locked();
        g.unprocessed = 0;
        g.final_requested = false;
        g.final_done = false;
        g.cancel_decode.store(false);
        g.stopping.store(false);

        unsigned hw = std::thread::hardware_concurrency();
        g.decode_threads.store(static_cast<int>(
            std::min<unsigned>(std::max<unsigned>(hw, kThreadsMin), kThreadsMax)));

        g.worker = std::thread(worker_loop);
        g.ready.store(true);
        NV_LOG("loaded %s (%zu bytes), lang=%s", model_path, fsize, lang);
        return NV_WHISPER_OK;
    } catch (const std::exception& e) {
        NV_LOG("init exception: %s", e.what());
        return NV_WHISPER_ERR_INTERNAL;
    } catch (...) {
        return NV_WHISPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_whisper_set_transcript_callback(nv_whisper_transcript_cb cb) {
    try {
        std::lock_guard<std::mutex> lk(g.buf_mutex);
        g.cb = cb;
        return NV_WHISPER_OK;
    } catch (...) {
        return NV_WHISPER_ERR_INTERNAL;
    }
}

NV_EXPORT void nv_whisper_set_memory_budget(size_t max_bytes) {
    std::lock_guard<std::mutex> api_lk(g.api_mutex);
    std::lock_guard<std::mutex> buf_lk(g.buf_mutex);
    g.mem_budget = max_bytes;
    if (max_bytes == 0) {  // unlimited: fall back to the 30 s utterance cap
        g.max_buffer_samples = ms_to_samples(kMaxBufferMs);
    } else if (g.model_bytes > 0) {
        const size_t headroom =
            (max_bytes > g.model_bytes + kFixedOverheadBytes)
                ? max_bytes - g.model_bytes - kFixedOverheadBytes
                : 0;
        size_t cap = std::min(headroom / sizeof(float), ms_to_samples(kMaxBufferMs));
        g.max_buffer_samples = std::max(cap, ms_to_samples(kMinBufferMs));
    }
}

NV_EXPORT int nv_whisper_feed_pcm_i16(const int16_t* samples, int32_t n_samples) {
    try {
        if (!samples || n_samples <= 0) return NV_WHISPER_ERR_INVALID_ARG;
        if (!g.ready.load()) return NV_WHISPER_ERR_NOT_INIT;

        std::lock_guard<std::mutex> lk(g.buf_mutex);
        if (static_cast<size_t>(n_samples) > g.max_buffer_samples) {
            return NV_WHISPER_ERR_MEM_BUDGET;
        }
        const size_t keep_from =
            (g.pcm.size() + static_cast<size_t>(n_samples) > g.max_buffer_samples)
                ? g.pcm.size() + static_cast<size_t>(n_samples) - g.max_buffer_samples
                : 0;
        if (keep_from > 0) {
            g.pcm.erase(g.pcm.begin(), g.pcm.begin() + static_cast<long>(keep_from));
        }
        g.pcm.reserve(g.max_buffer_samples);
        for (int32_t i = 0; i < n_samples; ++i) {
            g.pcm.push_back(static_cast<float>(samples[i]) / 32768.0f);
        }
        g.unprocessed += static_cast<size_t>(n_samples);
        update_peak_locked();
        g.work_cv.notify_one();
        return NV_WHISPER_OK;
    } catch (const std::bad_alloc&) {
        return NV_WHISPER_ERR_OOM;
    } catch (...) {
        return NV_WHISPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_whisper_feed_pcm_f32(const float* samples, int32_t n_samples) {
    try {
        if (!samples || n_samples <= 0) return NV_WHISPER_ERR_INVALID_ARG;
        if (!g.ready.load()) return NV_WHISPER_ERR_NOT_INIT;

        std::lock_guard<std::mutex> lk(g.buf_mutex);
        if (static_cast<size_t>(n_samples) > g.max_buffer_samples) {
            return NV_WHISPER_ERR_MEM_BUDGET;
        }
        const size_t keep_from =
            (g.pcm.size() + static_cast<size_t>(n_samples) > g.max_buffer_samples)
                ? g.pcm.size() + static_cast<size_t>(n_samples) - g.max_buffer_samples
                : 0;
        if (keep_from > 0) {
            g.pcm.erase(g.pcm.begin(), g.pcm.begin() + static_cast<long>(keep_from));
        }
        g.pcm.reserve(g.max_buffer_samples);
        g.pcm.insert(g.pcm.end(), samples, samples + n_samples);
        g.unprocessed += static_cast<size_t>(n_samples);
        update_peak_locked();
        g.work_cv.notify_one();
        return NV_WHISPER_OK;
    } catch (const std::bad_alloc&) {
        return NV_WHISPER_ERR_OOM;
    } catch (...) {
        return NV_WHISPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_whisper_flush_final(void) {
    try {
        if (!g.ready.load()) return NV_WHISPER_ERR_NOT_INIT;

        std::unique_lock<std::mutex> lk(g.buf_mutex);
        g.final_requested = true;
        g.final_done = false;
        g.work_cv.notify_all();

        const bool done = g.final_cv.wait_for(
            lk, std::chrono::milliseconds(kFlushWatchdogMs), [] { return g.final_done; });
        return done ? NV_WHISPER_OK : NV_WHISPER_ERR_TIMEOUT;
    } catch (...) {
        return NV_WHISPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_whisper_detect_language(char* out_lang, int out_len) {
    try {
        if (!out_lang || out_len <= 0) return NV_WHISPER_ERR_INVALID_ARG;
        out_lang[0] = '\0';
        if (!g.ready.load()) return NV_WHISPER_ERR_NOT_INIT;

        std::vector<float> snap;
        {
            std::lock_guard<std::mutex> lk(g.buf_mutex);
            if (g.pcm.size() < ms_to_samples(1000)) return NV_WHISPER_ERR_INVALID_ARG;
            snap.assign(g.pcm.begin(), g.pcm.end());
        }

        // English-only models cannot detect language; whisper_full reports
        // that as a generic failure which we surface as ERR_UNSUPPORTED.
        std::string text, lang;
        std::string configured = g.lang;
        {
            std::lock_guard<std::mutex> decode_lk(g.decode_mutex);
            std::lock_guard<std::mutex> lk(g.buf_mutex);
            g.lang = "auto";  // decode_locked reports the detected language
            const int rc = decode_locked(snap.data(), static_cast<int>(snap.size()),
                                         /*is_final_request=*/true, &text, &lang);
            g.lang = configured;  // restore the configured decode language
            if (rc != NV_WHISPER_OK) return rc == NV_WHISPER_ERR_INTERNAL
                                              ? NV_WHISPER_ERR_UNSUPPORTED
                                              : rc;
        }
        std::snprintf(out_lang, static_cast<size_t>(out_len), "%s", lang.c_str());
        return NV_WHISPER_OK;
    } catch (...) {
        return NV_WHISPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_whisper_reset(void) {
    try {
        if (!g.ready.load()) return NV_WHISPER_ERR_NOT_INIT;
        std::lock_guard<std::mutex> lk(g.buf_mutex);
        g.pcm.clear();
        g.unprocessed = 0;
        return NV_WHISPER_OK;
    } catch (...) {
        return NV_WHISPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_whisper_sample_rate(void) {
    return kSampleRate;
}

NV_EXPORT size_t nv_whisper_current_ram_bytes(void) {
    std::lock_guard<std::mutex> lk(g.buf_mutex);
    return g.current_ram_bytes_locked();
}

NV_EXPORT size_t nv_whisper_peak_ram_bytes(void) {
    std::lock_guard<std::mutex> lk(g.buf_mutex);
    update_peak_locked();
    return g.peak_ram;
}

NV_EXPORT size_t nv_whisper_process_peak_rss(void) {
    return read_process_peak_rss();
}

NV_EXPORT void nv_whisper_free(void) {
    try {
        std::lock_guard<std::mutex> api_lk(g.api_mutex);
        teardown_locked();  // manages buf_mutex itself
    } catch (...) {
        // Free must never throw across FFI; state is already torn down above.
    }
}

NV_EXPORT const char* nv_whisper_version(void) {
    return "whisper_bridge 1.0.0 (whisper.cpp v1.7.5)";
}

}  // extern "C"
