/// Text-to-speech over the piper native bridge.
///
/// The service produces synthesized 16-bit PCM chunks plus state — nothing
/// more. TODO(Phase 2): playback itself goes through a
/// `MethodChannel('neyam_vaani/audio_out')` sink implemented on Android;
/// until then (and in tests) an injectable [PcmSink] receives the chunks.
///
/// PRIVACY_CHARTER.md: the text handed to [TtsService.speak] and the PCM it
/// produces never leave the device. There is no network path here.
///
/// Expected C ABI of libnv_piper_bridge (all symbols optional at runtime —
/// a missing library degrades to a calm no-op with
/// `spokenOutputAvailable == false`):
///
/// ```c
/// typedef void (*nv_piper_pcm_cb)(
///     const int16_t* samples, int32_t n_samples, bool is_final);
/// int  nv_piper_init(const char* voice_path);      // config json next to it
/// int  nv_piper_add_voice(const char* voice_path); // second voice slot
/// int  nv_piper_select_voice(int voice_index);
/// int  nv_piper_voice_count(void);
/// int  nv_piper_sample_rate(void);
/// int  nv_piper_speak(const char* text, float speed, nv_piper_pcm_cb cb);
/// void nv_piper_stop(void);
/// int  nv_piper_is_speaking(void);
/// void nv_piper_free(void);
/// ```
///
/// Return codes follow C convention: 0 = success; nv_piper_speak returns
/// ERR_BUSY (nonzero) while already speaking, which is why [TtsService]
/// always stops before speaking again. The PCM callback fires on a native
/// worker thread and is registered with `NativeCallable.listener`; native
/// memory is copied before each delivery.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Lifecycle of the voice-output pipeline.
enum TtsState {
  /// Nothing is being spoken.
  idle,

  /// Text accepted, synthesis starting; no audio has arrived yet.
  preparing,

  /// PCM is flowing to the sink.
  speaking,
}

/// Receives synthesized 16-bit PCM chunks. [isFinal] marks the last chunk
/// of one utterance. Tests capture chunks with this; Phase 2 wires the
/// audio-out MethodChannel implementation of it.
abstract interface class PcmSink {
  /// Consumes one PCM chunk.
  void write(Int16List chunk, {required bool isFinal});
}

/// Handler the bridge calls with PCM; the data is already copied to Dart
/// memory and safe to keep.
typedef PcmChunkHandler = void Function(Int16List chunk, bool isFinal);

/// The piper native bridge, as the TTS service sees it. Injectable so tests
/// run without any native library.
abstract interface class PiperBridge {
  /// Whether the library is loadable and a voice path is configured.
  bool get isAvailable;

  /// Loads (once) the configured voice. Idempotent; returns success.
  bool ensureReady();

  /// Number of loaded voices (0 before a successful [ensureReady]).
  int get voiceCount;

  /// Output sample rate; 0 when unknown.
  int get sampleRate;

  /// Starts speaking [text] at [speed]; [onPcm] receives the chunks.
  /// Returns 0 on success, nonzero on failure/ERR_BUSY.
  int speak(String text, double speed, PcmChunkHandler onPcm);

  /// Interrupts the current synthesis immediately.
  void stop();

  /// Whether the native side is mid-synthesis.
  bool get isSpeaking;

  /// Frees the native voice data. Safe to call anytime.
  void dispose();
}

// ---------------------------------------------------------------------------
// FFI bindings
// ---------------------------------------------------------------------------

typedef _PPcmCbNative = Void Function(Pointer<Int16>, Int32, Bool);
typedef _PInitNative = Int32 Function(Pointer<Utf8>);
typedef _PInit = int Function(Pointer<Utf8>);
typedef _PAddVoiceNative = Int32 Function(Pointer<Utf8>);
typedef _PAddVoice = int Function(Pointer<Utf8>);
typedef _PSelectVoiceNative = Int32 Function(Int32);
typedef _PSelectVoice = int Function(int);
typedef _PVoiceCountNative = Int32 Function();
typedef _PVoiceCount = int Function();
typedef _PSampleRateNative = Int32 Function();
typedef _PSampleRate = int Function();
typedef _PSpeakNative = Int32 Function(
  Pointer<Utf8>,
  Float,
  Pointer<NativeFunction<_PPcmCbNative>>,
);
typedef _PSpeak = int Function(
  Pointer<Utf8>,
  double,
  Pointer<NativeFunction<_PPcmCbNative>>,
);
typedef _PStopNative = Void Function();
typedef _PStop = void Function();
typedef _PIsSpeakingNative = Int32 Function();
typedef _PIsSpeaking = int Function();
typedef _PFreeNative = Void Function();
typedef _PFree = void Function();

// ---------------------------------------------------------------------------
// FFI-backed bridge
// ---------------------------------------------------------------------------

/// Talks to libnv_piper_bridge over dart:ffi. A missing library is not an
/// error: [isAvailable] reports false and everything else degrades calmly.
final class FfiPiperBridge implements PiperBridge {
  /// Creates a bridge for [voicePath] (config json expected next to it) and
  /// an optional [additionalVoicePath] second voice slot.
  FfiPiperBridge({
    this.libraryName = defaultLibraryName,
    this.voicePath,
    this.additionalVoicePath,
  });

  /// Bridge library file name. Android: `libnv_piper_bridge.so`.
  static const String defaultLibraryName = 'libnv_piper_bridge.so';

  final String libraryName;
  final String? voicePath;
  final String? additionalVoicePath;

  DynamicLibrary? _lib;
  bool _openAttempted = false;
  bool _ready = false;
  bool _disposed = false;
  NativeCallable<NativeFunction<_PPcmCbNative>>? _pcmCallable;
  PcmChunkHandler? _handler;

  @override
  bool get isAvailable => voicePath != null && _libraryOrNull() != null;

  @override
  bool ensureReady() {
    if (_ready) {
      return true;
    }
    final DynamicLibrary? lib = _libraryOrNull();
    final String? path = voicePath;
    if (lib == null || path == null || _disposed) {
      return false;
    }
    NativeCallable<NativeFunction<_PPcmCbNative>>? callable;
    try {
      callable = NativeCallable<NativeFunction<_PPcmCbNative>>.listener(
        _onPcm,
      );
      final Pointer<Utf8> pathPtr = path.toNativeUtf8(allocator: calloc);
      try {
        if (lib
                .lookupFunction<_PInitNative, _PInit>('nv_piper_init')(
              pathPtr,
            ) !=
            0) {
          callable.close();
          return false;
        }
      } finally {
        calloc.free(pathPtr);
      }
      final String? second = additionalVoicePath;
      if (second != null) {
        final Pointer<Utf8> secondPtr = second.toNativeUtf8(allocator: calloc);
        try {
          lib
              .lookupFunction<_PAddVoiceNative, _PAddVoice>('nv_piper_add_voice')
              (secondPtr);
        } finally {
          calloc.free(secondPtr);
        }
      }
      lib
          .lookupFunction<_PSelectVoiceNative, _PSelectVoice>(
              'nv_piper_select_voice')(0);
      _pcmCallable = callable;
      _ready = true;
      return true;
    } catch (_) {
      callable?.close();
      return false;
    }
  }

  @override
  int get voiceCount {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null || !_ready) {
      return 0;
    }
    try {
      return lib
          .lookupFunction<_PVoiceCountNative, _PVoiceCount>(
              'nv_piper_voice_count')();
    } catch (_) {
      return 0;
    }
  }

  @override
  int get sampleRate {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return 0;
    }
    try {
      return lib
          .lookupFunction<_PSampleRateNative, _PSampleRate>(
              'nv_piper_sample_rate')();
    } catch (_) {
      return 0;
    }
  }

  @override
  bool get isSpeaking {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null || !_ready) {
      return false;
    }
    try {
      return lib
              .lookupFunction<_PIsSpeakingNative, _PIsSpeaking>(
                  'nv_piper_is_speaking')() !=
          0;
    } catch (_) {
      return false;
    }
  }

  @override
  int speak(String text, double speed, PcmChunkHandler onPcm) {
    final DynamicLibrary? lib = _libraryOrNull();
    final NativeCallable<NativeFunction<_PPcmCbNative>>? callable =
        _pcmCallable;
    if (lib == null || !_ready || callable == null || _disposed) {
      return -1;
    }
    if (_handler != null) {
      // ERR_BUSY per the ABI: stop() must be called before speak().
      return -16;
    }
    _handler = onPcm;
    final Pointer<Utf8> textPtr = text.toNativeUtf8(allocator: calloc);
    try {
      // The bridge copies the string before returning; generation continues
      // on a native worker thread (native team owns that guarantee).
      final int rc = lib
          .lookupFunction<_PSpeakNative, _PSpeak>('nv_piper_speak')(
        textPtr,
        speed,
        callable.nativeFunction,
      );
      if (rc != 0) {
        _handler = null;
      }
      return rc;
    } catch (_) {
      _handler = null;
      return -1;
    } finally {
      calloc.free(textPtr);
    }
  }

  @override
  void stop() {
    // Drop the handler first so late native deliveries are ignored.
    _handler = null;
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null || !_ready) {
      return;
    }
    try {
      lib.lookupFunction<_PStopNative, _PStop>('nv_piper_stop')();
    } catch (_) {
      // Best-effort.
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _handler = null;
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib != null && _ready) {
      try {
        lib.lookupFunction<_PFreeNative, _PFree>('nv_piper_free')();
      } catch (_) {
        // Best-effort.
      }
    }
    _ready = false;
    _pcmCallable?.close();
    _pcmCallable = null;
  }

  /// Invoked from the native worker thread via NativeCallable.listener —
  /// delivery happens on the Dart event loop; memory is copied out first.
  void _onPcm(Pointer<Int16> samples, int n, bool isFinal) {
    final PcmChunkHandler? handler = _handler;
    if (handler == null) {
      return;
    }
    if (n > 0) {
      final Int16List copy = Int16List(n);
      copy.setRange(0, n, samples.asTypedList(n));
      handler(copy, isFinal);
    } else if (isFinal) {
      handler(Int16List(0), true);
    }
    if (isFinal) {
      _handler = null;
    }
  }

  DynamicLibrary? _libraryOrNull() {
    if (_disposed) {
      return null;
    }
    final DynamicLibrary? cached = _lib;
    if (cached != null) {
      return cached;
    }
    if (_openAttempted) {
      return null;
    }
    _openAttempted = true;
    try {
      // A statically-linked bridge ships inside the app binary.
      final DynamicLibrary process = DynamicLibrary.process();
      if (process.providesSymbol('nv_piper_init')) {
        _lib = process;
        return process;
      }
    } catch (_) {
      // Process lookup unsupported here; try opening the file.
    }
    try {
      final DynamicLibrary opened = DynamicLibrary.open(libraryName);
      _lib = opened;
      return opened;
    } catch (_) {
      // Graceful degradation: no bridge on this device (tests, desktop).
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// TtsService
// ---------------------------------------------------------------------------

/// Voice output with honest states and instant interruption
/// (TENDER_UX_PRINCIPLES.md: interruption kills playback instantly).
///
/// ```dart
/// final TtsService tts = TtsService()..attachSink(mySink);
/// await tts.speak('வணக்கம்', language: 'ta', speed: 0.9);
/// tts.stop(); // from anywhere, immediately
/// ```
class TtsService {
  /// Creates a service; bridge and sink are injectable for tests.
  TtsService({
    PiperBridge? bridge,
    this.voicePath,
    this.additionalVoicePath,
  }) : _bridge =
            bridge ?? FfiPiperBridge(voicePath: voicePath, additionalVoicePath: additionalVoicePath);

  /// Slowest permitted speaking rate.
  static const double minSpeed = 0.5;

  /// Fastest permitted speaking rate.
  static const double maxSpeed = 2.0;

  static const double _cueSeconds = 0.1;
  static const int _cueFallbackSampleRate = 16000;
  static const double _cueFrequencyHz = 660;
  static const int _cueAmplitude = 1200; // ~ -28 dBFS: gentle, never sharp.

  /// Voice files, resolved by the Phase 5 language-pack manager.
  final String? voicePath;
  final String? additionalVoicePath;

  final PiperBridge _bridge;

  PcmSink? _sink;
  TtsState _state = TtsState.idle;
  bool _nativeReady = false;
  Completer<void>? _speaking;

  /// Current lifecycle state.
  TtsState get state => _state;

  /// Whether spoken output can happen on this device (library + voice).
  /// False on desktop/CI — callers show text-only replies, calmly.
  bool get spokenOutputAvailable => _ensureNative();

  /// Attaches the PCM output sink (tests inject one; Phase 2 wires the
  /// `neyam_vaani/audio_out` MethodChannel sink here).
  void attachSink(PcmSink sink) => _sink = sink;

  /// Detaches the current sink, if any.
  void detachSink() => _sink = null;

  /// Clamps a speaking rate into [minSpeed, maxSpeed].
  double clampSpeed(double speed) =>
      speed < minSpeed ? minSpeed : (speed > maxSpeed ? maxSpeed : speed);

  /// Pre-speak cue: a 100 ms soft tone so the user knows Vaani is about to
  /// talk. Placeholder design — Phase 2 UX polish replaces the waveform.
  void playPreSpeakCue() {
    if (_state != TtsState.idle) {
      return;
    }
    final int rate = _cueSampleRate();
    final int count = (rate * _cueSeconds).round();
    if (count <= 0) {
      return;
    }
    final Int16List cue = Int16List(count);
    for (int i = 0; i < count; i++) {
      final double fade = math.sin(math.pi * i / count); // in and out
      final double tone = math.sin(2 * math.pi * _cueFrequencyHz * i / rate);
      cue[i] = (_cueAmplitude * fade * tone).round();
    }
    _sink?.write(cue, isFinal: true);
  }

  /// Speaks [text]. Speed is clamped to 0.5–2.0; [language] selects the
  /// voice once language packs install voices (Phase 5). Completes when the
  /// utterance finishes (or is stopped). A missing native bridge is a calm
  /// no-op straight back to idle.
  Future<void> speak(String text, {String? language, double speed = 1.0}) async {
    if (text.trim().isEmpty) {
      return;
    }
    // ABI contract: stop() must precede the next speak() (ERR_BUSY).
    if (_state != TtsState.idle) {
      stop();
    }
    if (!_ensureNative()) {
      // Calm degradation: no spoken output on this device.
      _state = TtsState.idle;
      return;
    }
    final double clamped = clampSpeed(speed);
    _state = TtsState.preparing;
    final Completer<void> done = Completer<void>();
    _speaking = done;
    // TODO(Phase 5): map [language] to a loaded voice index with
    // nv_piper_select_voice when language packs manage voices.
    final int rc = _bridge.speak(text, clamped, _onPcm);
    if (rc != 0) {
      _finishSpeaking();
      return;
    }
    return done.future;
  }

  /// Interrupts immediately: state returns to idle and the pending speak()
  /// future completes. Safe to call from any state.
  void stop() {
    _bridge.stop();
    _finishSpeaking();
  }

  /// Releases native voice data. Safe to call anytime.
  void dispose() {
    stop();
    _bridge.dispose();
  }

  // -------------------------------------------------------------------------

  void _onPcm(Int16List chunk, bool isFinal) {
    if (_state == TtsState.preparing) {
      _state = TtsState.speaking;
    }
    _sink?.write(chunk, isFinal: isFinal);
    if (isFinal) {
      _finishSpeaking();
    }
  }

  void _finishSpeaking() {
    if (_state != TtsState.idle) {
      _state = TtsState.idle;
    }
    final Completer<void>? done = _speaking;
    _speaking = null;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }

  bool _ensureNative() {
    if (_nativeReady) {
      return true;
    }
    if (!_bridge.isAvailable) {
      return false;
    }
    _nativeReady = _bridge.ensureReady();
    return _nativeReady;
  }

  int _cueSampleRate() {
    final int rate = _bridge.sampleRate;
    return rate > 0 ? rate : _cueFallbackSampleRate;
  }
}
