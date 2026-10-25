// piper_bridge.cpp — TTS bridge between Dart (FFI) and Piper.
//
// Architecture:
//
//   Dart (UI isolate)             bridge worker thread
//   ─────────────────             ─────────────────────
//   nv_piper_speak ──────────►    pending utterance
//                                 split into sentences (danda-aware)
//                                 piper::textToAudio per sentence
//   nv_piper_stop ──────────►     atomic stop flag ──► chunks dropped,
//                                 loop breaks at next sentence boundary
//
// Audio reaches Dart as 16-bit mono PCM chunks on the worker thread through
// nv_piper_pcm_cb; (samples=NULL, n=0, is_final=true) closes an utterance
// (whether it completed or was stopped).
//
// Two voices per language are supported (index 0 and 1 — e.g. female and
// male from the same language pack). Switching takes effect at the next
// utterance.
//
// No exception crosses the FFI boundary: every exported function is wrapped
// in try/catch and maps failures to NV_PIPER_ERR_* codes.

#include "piper_bridge.h"

#include "piper.hpp"  // upstream Piper C++ API (pinned 2023.11.14-2)

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef __ANDROID__
#include <android/log.h>
#define NV_LOG(...) __android_log_print(ANDROID_LOG_INFO, "nv-piper", __VA_ARGS__)
#else
#define NV_LOG(...) fprintf(stderr, "[nv-piper] " __VA_ARGS__), fprintf(stderr, "\n")
#endif

namespace {

namespace fs = std::filesystem;

constexpr int    kMaxVoices       = 2;
constexpr float  kSpeedMin        = 0.5f;
constexpr float  kSpeedMax        = 2.0f;
constexpr size_t kHardWrapBytes   = 240;  // unpunctuated text: cut here so
                                          // nv_piper_stop stays responsive

// Piper plays a chunk into `audioBuffer` and signals with a zero-arg
// callback; the buffer belongs to the caller for the duration of the call.
using PiperChunkSink = std::function<void(std::vector<int16_t>&)>;

struct Utterance {
    std::string text;
    float speed = 1.0f;
    nv_piper_pcm_cb cb = nullptr;
};

struct PiperState {
    std::mutex task_mutex;           // guards pending/active_voice/espeak_path
    std::condition_variable task_cv;

    piper::PiperConfig pconfig;      // espeak-ng handle lives here
    bool piper_initialized = false;

    std::unique_ptr<piper::Voice> voices[kMaxVoices];
    size_t voice_bytes[kMaxVoices] = {0, 0};  // onnx+json file sizes
    int active_voice = 0;

    std::thread worker;
    std::atomic<bool> stopping{false};
    std::atomic<bool> stop_speak{false};
    std::atomic<bool> speaking{false};
    std::atomic<int>  last_status{NV_PIPER_OK};

    bool has_task = false;
    Utterance pending;

    size_t current_ram_bytes() const {
        size_t total = 0;
        for (int i = 0; i < kMaxVoices; ++i) {
            if (voices[i]) total += voice_bytes[i] + (8u << 20);  // + session estimate
        }
        return total;
    }
};

PiperState g;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Find espeak-ng-data near the voice: the language pack ships it once while
// the two voices usually live one directory deeper (pack/tts/<voice>.onnx).
std::string find_espeak_data(const fs::path& voice_dir) {
    const fs::path candidates[] = {
        voice_dir / "espeak-ng-data",
        voice_dir.parent_path() / "espeak-ng-data",
        voice_dir.parent_path().parent_path() / "espeak-ng-data",
    };
    std::error_code ec;
    for (const auto& c : candidates) {
        if (fs::is_directory(c, ec)) return c.string();
    }
    return {};
}

size_t file_size_bytes(const fs::path& p) {
    std::error_code ec;
    const auto sz = fs::file_size(p, ec);
    return ec ? 0 : static_cast<size_t>(sz);
}

int load_voice_locked(const char* voice_path) {
    if (!voice_path || !voice_path[0]) return NV_PIPER_ERR_INVALID_ARG;

    const fs::path model(voice_path);
    const fs::path model_config(model.string() + ".json");  // standard Piper layout
    std::error_code ec;
    if (!fs::exists(model, ec) || !fs::exists(model_config, ec)) {
        NV_LOG("voice files missing: %s / %s", model.string().c_str(),
               model_config.string().c_str());
        return NV_PIPER_ERR_VOICE_LOAD;
    }

    if (!g.piper_initialized) {
        const std::string espeak = find_espeak_data(model.parent_path());
        if (espeak.empty()) {
            NV_LOG("espeak-ng-data not found near %s", voice_path);
            return NV_PIPER_ERR_ESPEAK;
        }
        g.pconfig.eSpeakDataPath = espeak;
        piper::initialize(g.pconfig);  // loads espeak-ng once per process
        g.piper_initialized = true;
        NV_LOG("piper initialized (espeak-ng-data: %s)", espeak.c_str());
    }

    int slot = -1;
    for (int i = 0; i < kMaxVoices; ++i) {
        if (!g.voices[i]) { slot = i; break; }
    }
    if (slot < 0) return NV_PIPER_ERR_BUSY;

    auto voice = std::make_unique<piper::Voice>();
    std::optional<piper::SpeakerId> speaker_id;  // nullopt: default speaker
    try {
        piper::loadVoice(g.pconfig, model.string(), model_config.string(),
                         *voice, speaker_id);
    } catch (const std::exception& e) {
        NV_LOG("loadVoice failed: %s", e.what());
        return NV_PIPER_ERR_VOICE_LOAD;
    }
    if (voice->phonemizeConfig.phonemeIdMap.empty()) {
        return NV_PIPER_ERR_VOICE_LOAD;  // config never parsed
    }

    g.voice_bytes[slot] = file_size_bytes(model) + file_size_bytes(model_config);
    g.voices[slot] = std::move(voice);
    NV_LOG("voice %d loaded from %s", slot, voice_path);
    return slot;  // 0 or 1: the slot it occupies
}

// Sentence splitting for stop() responsiveness. Understands Latin
// punctuation AND the Devanagari danda '।' (U+0964) / '॥' (U+0965) used by
// Hindi, Marathi, Bhojpuri and Maithili. Any run longer than kHardWrapBytes
// without punctuation is cut on the nearest UTF-8-safe space.
bool utf8_is_space(unsigned char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }
bool byte_is_continuation(unsigned char c) { return (c & 0xC0) == 0x80; }

std::vector<std::string> split_sentences(const std::string& text) {
    std::vector<std::string> out;
    std::string cur;
    const auto flush = [&] {
        if (!cur.empty()) {
            out.push_back(cur);
            cur.clear();
        }
    };

    size_t i = 0;
    while (i < text.size()) {
        const unsigned char c = static_cast<unsigned char>(text[i]);
        cur.push_back(text[i]);

        // Sentence enders: ASCII . ! ? ; \n — and Devanagari danda (3 bytes:
        // E0 A5 A4 / E0 A5 A5).
        bool boundary = false;
        if (c == '.' || c == '!' || c == '?' || c == ';' || c == '\n') {
            boundary = true;
        } else if (c == 0xE0 && i + 2 < text.size() &&
                   static_cast<unsigned char>(text[i + 1]) == 0xA5 &&
                   (static_cast<unsigned char>(text[i + 2]) == 0xA4 ||
                    static_cast<unsigned char>(text[i + 2]) == 0xA5)) {
            cur.push_back(text[i + 1]);
            cur.push_back(text[i + 2]);
            i += 2;
            boundary = true;
        }

        ++i;

        if (boundary) {
            // Swallow trailing spaces into this sentence.
            while (i < text.size() && utf8_is_space(static_cast<unsigned char>(text[i]))) {
                cur.push_back(text[i]);
                ++i;
            }
            flush();
        } else if (cur.size() >= kHardWrapBytes) {
            // Hard wrap at the last space, never mid-UTF-8-character.
            size_t cut = cur.find_last_of(' ');
            if (cut == std::string::npos || cut < kHardWrapBytes / 2) {
                // No usable space (e.g. long Indic run): cut on a UTF-8
                // lead byte boundary instead.
                cut = cur.size();
                while (cut > 0 && byte_is_continuation(static_cast<unsigned char>(cur[cut - 1]))) {
                    --cut;
                }
                if (cut == 0) cut = cur.size();
            }
            out.push_back(cur.substr(0, cut));
            cur.erase(0, cut);
        }
    }
    flush();
    return out;
}

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------

void worker_loop() {
    while (true) {
        std::unique_lock<std::mutex> lk(g.task_mutex);
        g.task_cv.wait(lk, [&] { return g.stopping.load() || g.has_task; });
        if (g.stopping.load()) return;

        Utterance u = std::move(g.pending);
        g.pending = Utterance{};
        g.has_task = false;
        piper::Voice* voice = g.voices[g.active_voice].get();  // stable until free()
        lk.unlock();

        if (!voice || !u.cb) {
            if (u.cb) u.cb(nullptr, 0, true);
            continue;
        }

        // speed > 1.0 ⇒ shorter audio ⇒ smaller lengthScale (Piper semantics).
        const float speed = std::min(std::max(u.speed, kSpeedMin), kSpeedMax);
        voice->synthesisConfig.lengthScale = 1.0f / speed;

        g.stop_speak.store(false);
        g.speaking.store(true);
        bool stopped = false;
        bool failed = false;

        for (const std::string& sentence : split_sentences(u.text)) {
            if (g.stop_speak.load() || g.stopping.load()) { stopped = true; break; }

            std::vector<int16_t> audio;
            piper::SynthesisResult result;
            const std::function<void()> chunk_ready = [&] {
                // Piper signals "audioBuffer holds a chunk; consume it".
                if (g.stop_speak.load() || g.stopping.load()) {
                    audio.clear();  // interrupted: drop the samples
                    return;
                }
                if (!audio.empty()) {
                    u.cb(audio.data(), static_cast<int32_t>(audio.size()), false);
                }
                audio.clear();
            };

            try {
                piper::textToAudio(g.pconfig, *voice, sentence, audio, result, chunk_ready);
            } catch (const std::exception& e) {
                NV_LOG("textToAudio failed: %s", e.what());
                failed = true;
                break;
            }
        }

        g.speaking.store(false);
        g.last_status.store(stopped ? NV_PIPER_ERR_STOPPED
                                    : (failed ? NV_PIPER_ERR_INTERNAL : NV_PIPER_OK));
        // Exactly one terminator per utterance, success or not.
        u.cb(nullptr, 0, true);
    }
}

}  // namespace

// ---------------------------------------------------------------------------
// Exported FFI surface
// ---------------------------------------------------------------------------

extern "C" {

NV_EXPORT int nv_piper_init(const char* voice_path) {
    try {
        std::lock_guard<std::mutex> lk(g.task_mutex);
        if (g.voices[0]) return NV_PIPER_ERR_BUSY;  // free() first to replace

        if (!g.worker.joinable()) {
            g.stopping.store(false);
            g.worker = std::thread(worker_loop);
        }
        const int rc = load_voice_locked(voice_path);
        if (rc < 0) return rc;
        g.active_voice = 0;
        return NV_PIPER_OK;
    } catch (const std::bad_alloc&) {
        return NV_PIPER_ERR_OOM;
    } catch (const std::exception& e) {
        NV_LOG("init exception: %s", e.what());
        return NV_PIPER_ERR_INTERNAL;
    } catch (...) {
        return NV_PIPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_piper_add_voice(const char* voice_path) {
    try {
        std::lock_guard<std::mutex> lk(g.task_mutex);
        if (!g.voices[0]) return NV_PIPER_ERR_NOT_INIT;  // init() first
        if (g.voices[1]) return NV_PIPER_ERR_BUSY;       // slot 1 taken
        const int rc = load_voice_locked(voice_path);
        return (rc == 1) ? NV_PIPER_OK : (rc < 0 ? rc : NV_PIPER_ERR_BUSY);
    } catch (...) {
        return NV_PIPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_piper_select_voice(int voice_index) {
    try {
        std::lock_guard<std::mutex> lk(g.task_mutex);
        if (voice_index < 0 || voice_index >= kMaxVoices) return NV_PIPER_ERR_INVALID_ARG;
        if (!g.voices[voice_index]) return NV_PIPER_ERR_NOT_INIT;
        const int previous = g.active_voice;
        g.active_voice = voice_index;  // takes effect at the next utterance
        return previous;
    } catch (...) {
        return NV_PIPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_piper_voice_count(void) {
    std::lock_guard<std::mutex> lk(g.task_mutex);
    int n = 0;
    for (int i = 0; i < kMaxVoices; ++i) n += g.voices[i] ? 1 : 0;
    return n;
}

NV_EXPORT int nv_piper_sample_rate(void) {
    std::lock_guard<std::mutex> lk(g.task_mutex);
    const piper::Voice* v = g.voices[g.active_voice].get();
    return v ? v->synthesisConfig.sampleRate : -1;
}

NV_EXPORT int nv_piper_speak(const char* text, float speed, nv_piper_pcm_cb cb) {
    try {
        if (!text || !text[0] || !cb) return NV_PIPER_ERR_INVALID_ARG;
        if (!(speed >= kSpeedMin && speed <= kSpeedMax)) return NV_PIPER_ERR_INVALID_ARG;

        std::lock_guard<std::mutex> lk(g.task_mutex);
        if (!g.voices[g.active_voice]) return NV_PIPER_ERR_NOT_INIT;
        if (g.has_task || g.speaking.load()) return NV_PIPER_ERR_BUSY;

        g.pending = Utterance{text, speed, cb};
        g.has_task = true;
        g.task_cv.notify_one();
        return NV_PIPER_OK;
    } catch (const std::bad_alloc&) {
        return NV_PIPER_ERR_OOM;
    } catch (...) {
        return NV_PIPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_piper_stop(void) {
    try {
        // No lock: must be callable from inside other bridges' callbacks.
        g.stop_speak.store(true);
        g.task_cv.notify_all();
        return NV_PIPER_OK;
    } catch (...) {
        return NV_PIPER_ERR_INTERNAL;
    }
}

NV_EXPORT int nv_piper_is_speaking(void) {
    return g.speaking.load() ? 1 : 0;
}

NV_EXPORT size_t nv_piper_current_ram_bytes(void) {
    std::lock_guard<std::mutex> lk(g.task_mutex);
    return g.current_ram_bytes();
}

NV_EXPORT void nv_piper_free(void) {
    try {
        {
            std::lock_guard<std::mutex> lk(g.task_mutex);
            g.stopping.store(true);
            g.stop_speak.store(true);
            g.has_task = false;
        }
        g.task_cv.notify_all();
        if (g.worker.joinable()) g.worker.join();  // in-flight sentence finishes

        {
            std::lock_guard<std::mutex> lk(g.task_mutex);
            for (int i = 0; i < kMaxVoices; ++i) {
                g.voices[i].reset();
                g.voice_bytes[i] = 0;
            }
            g.active_voice = 0;
            if (g.piper_initialized) {
                piper::terminate(g.pconfig);  // releases espeak-ng
                g.piper_initialized = false;
                g.pconfig = piper::PiperConfig{};
            }
            g.stopping.store(false);
        }
    } catch (...) {
        // Free must never throw across FFI.
    }
}

NV_EXPORT const char* nv_piper_version(void) {
    return "piper_bridge 1.0.0 (piper 2023.11.14-2)";
}

}  // extern "C"
