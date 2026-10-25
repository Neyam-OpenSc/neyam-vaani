/// Speech-to-text: transcript buffering, script-based language detection,
/// and the whisper.cpp bridge wiring.
///
/// PRIVACY_CHARTER.md: audio and transcripts-in-flight live in RAM only and
/// never leave the device. There is no network path from this file.
///
/// Three pieces live here:
/// - [TranscriptBuffer] — pure Dart: merges partial transcripts and decides
///   when an utterance is finished (silence pause or 30 s cap).
/// - [ScriptLanguageDetector] — pure Dart: Unicode-block language guessing.
/// - [SttService] — wires an [AudioCapture] + [VadService] + the whisper
///   FFI bridge into one transcript event stream. When the native library
///   is missing (tests, CI, desktop) the service still exposes buffer-driven
///   transcript events and reports `nativeAvailable == false` — graceful,
///   never a crash.
///
/// Expected C ABI of libnv_whisper_bridge (all symbols optional at runtime —
/// a missing library degrades to buffer-only operation):
///
/// ```c
/// typedef void (*nv_whisper_transcript_cb)(
///     const char* text, bool is_final, const char* lang);
/// int    nv_whisper_init(const char* model_path, const char* lang);
/// int    nv_whisper_set_transcript_callback(nv_whisper_transcript_cb cb);
/// int    nv_whisper_feed_pcm_i16(const int16_t* samples, int32_t n);
/// int    nv_whisper_flush_final(void);   // blocking; run off the UI thread
/// int    nv_whisper_reset(void);
/// int    nv_whisper_sample_rate(void);   // 16000
/// void   nv_whisper_free(void);
/// ```
///
/// Return codes follow C convention: 0 = success. Callbacks fire on a
/// native worker thread, exactly one is_final = true per flush.
///
/// Callback strategy (documented choice): the transcript callback is
/// registered with `NativeCallable.listener`, which lets the native worker
/// thread invoke Dart safely — deliveries arrive on the Dart event loop and
/// native memory is copied before returning. `nv_whisper_flush_final`
/// blocks in C, so it runs on a background isolate via `Isolate.run`; the
/// race between the isolate reply and the listener delivery is resolved by
/// completing a [Completer] from the is_final callback and awaiting it with
/// a timeout.
///
/// nv_whisper_set_memory_budget / nv_whisper_current_ram_bytes /
/// nv_whisper_peak_ram_bytes / nv_whisper_detect_language are deliberately
/// not bound yet — they arrive with the Phase 5 memory manager and the
/// language-pack manager, which own those concerns.
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/constants.dart' show kDefaultLanguage;
import 'audio_capture_service.dart';
import 'vad_service.dart';

// ---------------------------------------------------------------------------
// Transcript events
// ---------------------------------------------------------------------------

/// One transcript hypothesis or result, as shown to the user.
final class TranscriptEvent {
  /// Creates an event; [language] is set on finals via script detection.
  const TranscriptEvent({
    required this.text,
    required this.isFinal,
    this.language,
  });

  /// The merged text so far (partials) or the finished utterance (finals).
  final String text;

  /// Whether this closes the utterance.
  final bool isFinal;

  /// Detected language code for finals; null for partials.
  final String? language;

  @override
  String toString() =>
      'TranscriptEvent(final: $isFinal, lang: $language, text: $text)';
}

/// Why an utterance ended.
enum TranscriptEndReason {
  /// The speaker paused (silence beyond the buffer's threshold).
  pause,

  /// The utterance hit the maximum length cap.
  maxLength,

  /// finalize() was called explicitly (user tap, session stop).
  manual,
}

/// A finished utterance.
final class TranscriptFinal {
  /// Creates a final segment with its [reason].
  const TranscriptFinal(this.text, this.reason);

  /// The utterance text, trimmed.
  final String text;

  /// Why the utterance ended.
  final TranscriptEndReason reason;
}

// ---------------------------------------------------------------------------
// TranscriptBuffer — pure Dart
// ---------------------------------------------------------------------------

/// Merges partial transcripts into one utterance and finalizes on a pause
/// (default 900 ms of silence) or the 30 s maximum utterance cap.
///
/// Merge rule: a new segment that starts with the current hypothesis
/// replaces it (a re-decoding of the same audio); otherwise it is appended
/// as a continuation (a following phrase). Partials stay uncommitted until
/// a final or a finalize() call.
class TranscriptBuffer {
  /// Creates a buffer; thresholds are injectable for tests.
  TranscriptBuffer({
    this.finalizeAfterSilence = const Duration(milliseconds: 900),
    this.maxUtterance = const Duration(seconds: 30),
  });

  /// Silence that closes an utterance. Pairs with the VAD's
  /// minSilenceDuration default (see vad_service.dart).
  final Duration finalizeAfterSilence;

  /// Hard cap on one utterance, however the silence gate behaves.
  final Duration maxUtterance;

  String _committed = '';
  String _partial = '';
  bool _speechActive = false;
  Duration _utteranceElapsed = Duration.zero;

  /// Current best text: committed finals plus the live partial.
  String get draft =>
      _committed.isEmpty ? _partial : (_partial.isEmpty ? _committed : '$_committed $_partial');

  /// Whether an utterance is open (speech seen, nothing finalized since).
  bool get isActive => _speechActive || _committed.isNotEmpty || _partial.isNotEmpty;

  /// Feeds a partial (non-final) transcript segment.
  void addPartial(String text) {
    _speechActive = true;
    _partial = _merge(_partial, text);
  }

  /// Feeds a final transcript segment for the current utterance.
  void addFinal(String text) {
    _speechActive = true;
    final String merged = _merge(_partial, text);
    _committed = _committed.isEmpty ? merged : '$_committed $merged';
    _partial = '';
  }

  /// Marks the start of user speech (from the VAD).
  void notifySpeech() {
    _speechActive = true;
  }

  /// Reports accumulated silence; finalizes the utterance when it exceeds
  /// [finalizeAfterSilence]. Returns null while the pause is too short or
  /// nothing was heard.
  TranscriptFinal? notifySilence(Duration silenceSoFar) {
    if (draft.isEmpty || silenceSoFar < finalizeAfterSilence) {
      return null;
    }
    return finalize(TranscriptEndReason.pause);
  }

  /// Advances the utterance clock (one audio frame's duration at a time);
  /// finalizes when the utterance exceeds [maxUtterance].
  TranscriptFinal? advanceBy(Duration delta) {
    if (!isActive) {
      return null;
    }
    _utteranceElapsed += delta;
    if (_utteranceElapsed >= maxUtterance && draft.isNotEmpty) {
      return finalize(TranscriptEndReason.maxLength);
    }
    return null;
  }

  /// Ends the utterance now, whatever it holds. Returns null when nothing
  /// was heard (the buffer still resets, ready for the next utterance).
  TranscriptFinal? finalize([
    TranscriptEndReason reason = TranscriptEndReason.manual,
  ]) {
    final String text = draft.trim();
    reset();
    if (text.isEmpty) {
      return null;
    }
    return TranscriptFinal(text, reason);
  }

  /// Clears everything; ready for the next utterance.
  void reset() {
    _committed = '';
    _partial = '';
    _speechActive = false;
    _utteranceElapsed = Duration.zero;
  }
}

String _merge(String current, String next) {
  final String c = current.trim();
  final String n = next.trim();
  if (c.isEmpty) {
    return n;
  }
  if (n.isEmpty) {
    return c;
  }
  // A re-decoding of the same audio replaces; a new phrase continues.
  if (n.toLowerCase().startsWith(c.toLowerCase())) {
    return n;
  }
  return '$c $n';
}

// ---------------------------------------------------------------------------
// ScriptLanguageDetector — pure Dart
// ---------------------------------------------------------------------------

/// Guesses a language code from the Unicode blocks in a string.
///
/// Devanagari covers hi/mr/bho/mai; the block maps to [devanagariLanguage]
/// (default 'hi') until the user's choice or the STT language id says
/// otherwise. Text with no recognized script falls back to
/// [fallbackLanguage] (the app default). Mixed text resolves to the
/// majority script.
class ScriptLanguageDetector {
  /// Creates a detector; both defaults are pinned constants so behavior is
  /// deterministic across the app.
  const ScriptLanguageDetector({
    this.devanagariLanguage = 'hi',
    this.fallbackLanguage = kDefaultLanguage,
  });

  /// Which of the Devanagari family this detector returns.
  final String devanagariLanguage;

  /// Returned when no known script is present.
  final String fallbackLanguage;

  /// Detects the majority script language of [text].
  String detect(String text) {
    final Map<String, int> counts = <String, int>{};
    for (final int rune in text.runes) {
      final String? language = _languageOfRune(rune);
      if (language != null) {
        counts[language] = (counts[language] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) {
      return fallbackLanguage;
    }
    String best = counts.keys.first;
    int bestCount = counts[best]!;
    for (final MapEntry<String, int> entry in counts.entries) {
      if (entry.value > bestCount) {
        best = entry.key;
        bestCount = entry.value;
      }
    }
    return best;
  }

  String? _languageOfRune(int rune) {
    // Tamil: 0B80–0BFF.
    if (rune >= 0x0B80 && rune <= 0x0BFF) {
      return 'ta';
    }
    // Devanagari: 0900–097F (hi, mr, bho, mai).
    if (rune >= 0x0900 && rune <= 0x097F) {
      return devanagariLanguage;
    }
    // Bengali: 0980–09FF.
    if (rune >= 0x0980 && rune <= 0x09FF) {
      return 'bn';
    }
    // Kannada: 0C80–0CFF.
    if (rune >= 0x0C80 && rune <= 0x0CFF) {
      return 'kn';
    }
    // Telugu: 0C00–0C7F.
    if (rune >= 0x0C00 && rune <= 0x0C7F) {
      return 'te';
    }
    // Basic Latin letters: English (secondary language).
    if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      return 'en';
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Whisper FFI bindings
// ---------------------------------------------------------------------------

typedef _WTranscriptCbNative = Void Function(
  Pointer<Utf8>,
  Bool,
  Pointer<Utf8>,
);
typedef _WInitNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _WInit = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _WSetCbNative = Int32 Function(
  Pointer<NativeFunction<_WTranscriptCbNative>>,
);
typedef _WSetCb = int Function(Pointer<NativeFunction<_WTranscriptCbNative>>);
typedef _WFeedNative = Int32 Function(Pointer<Int16>, Int32);
typedef _WFeed = int Function(Pointer<Int16>, int);
typedef _WFlushNative = Int32 Function();
typedef _WFlush = int Function();
typedef _WResetNative = Int32 Function();
typedef _WReset = int Function();
typedef _WSampleRateNative = Int32 Function();
typedef _WSampleRate = int Function();
typedef _WFreeNative = Void Function();
typedef _WFree = void Function();

String _readUtf8(Pointer<Utf8> pointer) {
  try {
    final Pointer<Uint8> bytes = pointer.cast<Uint8>();
    int length = 0;
    while (bytes[length] != 0 && length < 65536) {
      length++;
    }
    return utf8.decode(bytes.asTypedList(length), allowMalformed: true);
  } catch (_) {
    return '';
  }
}

// ---------------------------------------------------------------------------
// SttService
// ---------------------------------------------------------------------------

/// Capture -> VAD -> whisper bridge, exposed as one transcript stream.
///
/// Typical wiring (see presentation/providers.dart):
///
/// ```dart
/// final SttService stt = SttService();
/// stt.transcripts.listen(print);
/// final bool granted = await stt.start(language: 'ta');
/// final TranscriptEvent? finalEvent = await stt.stop();
/// ```
class SttService {
  /// Creates a service; every part is injectable for tests.
  SttService({
    AudioCapture? audioCapture,
    this.libraryName = defaultLibraryName,
    this.modelPath = defaultModelPath,
    this.flushTimeout = const Duration(seconds: 2),
    VadConfig? vadConfig,
  })  : _capture = audioCapture ?? MethodChannelAudioCapture(),
        _vad = VadService(config: vadConfig ?? const VadConfig()),
        _detector = const ScriptLanguageDetector();

  /// Bridge library file name. Android: `libnv_whisper_bridge.so`.
  static const String defaultLibraryName = 'libnv_whisper_bridge.so';

  /// Placeholder model path; the Phase 5 language-pack manager sets the
  /// real, per-language path.
  static const String defaultModelPath = 'models/whisper/ggml-base.bin';

  /// Used when the bridge is absent or reports nothing.
  static const int fallbackSampleRate = 16000;

  final String libraryName;
  final String modelPath;
  final Duration flushTimeout;

  final AudioCapture _capture;
  final VadService _vad;
  final ScriptLanguageDetector _detector;
  final TranscriptBuffer _buffer = TranscriptBuffer();
  final StreamController<TranscriptEvent> _transcripts =
      StreamController<TranscriptEvent>.broadcast();

  DynamicLibrary? _lib;
  bool _openAttempted = false;
  NativeCallable<NativeFunction<_WTranscriptCbNative>>? _transcriptCallable;
  bool _nativeReady = false;
  int _sampleRate = fallbackSampleRate;
  bool _listening = false;
  StreamSubscription<Int16List>? _frameSubscription;
  Completer<void>? _flushCompleter;
  Future<void> _flushChain = Future<void>.value();

  /// Transcript stream: partials as they firm up, one final per utterance.
  Stream<TranscriptEvent> get transcripts => _transcripts.stream;

  /// Whether the microphone session is open.
  bool get isListening => _listening;

  /// Whether the whisper bridge could be opened on this device. False on
  /// desktop/CI — the service keeps running on buffer logic alone.
  bool get nativeAvailable => _libraryOrNull() != null;

  // -------------------------------------------------------------------------
  // Session lifecycle
  // -------------------------------------------------------------------------

  /// Opens the microphone and starts transcribing. Requests permission
  /// first (typed result; the UI shows the plain-language reason). Returns
  /// false when permission was denied — nothing was started.
  Future<bool> start({String? language}) async {
    if (_listening) {
      return true;
    }
    final MicrophonePermission permission = await _capture.requestPermission();
    if (permission is! MicrophonePermissionGranted) {
      return false;
    }
    _nativeReady = _initNative(language ?? 'auto');
    _sampleRate = _querySampleRate();
    _buffer.reset();
    _vad.reset();
    _frameSubscription = _capture.frames.listen(_onFrame);
    await _capture.start();
    _listening = true;
    return true;
  }

  /// Closes the microphone, flushes the native decoder when there is
  /// anything pending, and finalizes the utterance. Returns the final
  /// transcript event (already emitted on [transcripts]), or null when
  /// nothing was heard.
  Future<TranscriptEvent?> stop() async {
    if (!_listening) {
      return null;
    }
    _listening = false;
    final StreamSubscription<Int16List>? subscription = _frameSubscription;
    _frameSubscription = null;
    await subscription?.cancel();
    if (_nativeReady && _buffer.draft.isNotEmpty) {
      await _flushNativeWithTimeout();
    }
    final TranscriptFinal? segment =
        _buffer.finalize(TranscriptEndReason.manual);
    _vad.reset();
    await _capture.stop();
    _resetNative();
    return segment == null ? null : _emitFinal(segment);
  }

  /// Test hook: feeds a transcript in as if the whisper bridge produced it.
  /// Lets CI exercise the event stream without the native library. Never
  /// call from production code.
  @visibleForTesting
  void debugInjectTranscript(String text, {required bool isFinal}) {
    if (isFinal) {
      _buffer.addFinal(text);
      final TranscriptFinal? segment =
          _buffer.finalize(TranscriptEndReason.manual);
      if (segment != null) {
        _emitFinal(segment);
      }
    } else {
      _buffer.addPartial(text);
      _addEvent(TranscriptEvent(text: _buffer.draft, isFinal: false));
    }
  }

  /// Releases everything: subscriptions, streams, native model, callback.
  void dispose() {
    _listening = false;
    final StreamSubscription<Int16List>? subscription = _frameSubscription;
    _frameSubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    final DynamicLibrary? lib = _lib;
    if (lib != null) {
      try {
        lib.lookupFunction<_WFreeNative, _WFree>('nv_whisper_free')();
      } catch (_) {
        // Best-effort teardown; the process may not own the library.
      }
    }
    _nativeReady = false;
    _transcriptCallable?.close();
    _transcriptCallable = null;
    unawaited(_transcripts.close());
  }

  // -------------------------------------------------------------------------
  // Frame plumbing
  // -------------------------------------------------------------------------

  void _onFrame(Int16List frame) {
    if (!_listening) {
      return;
    }
    final Duration frameDuration = _frameDurationOf(frame.length);

    final VadEvent? vadEvent = _vad.process(frame);
    if (vadEvent != null) {
      switch (vadEvent.kind) {
        case VadEventKind.speechStart:
          _buffer.notifySpeech();
        case VadEventKind.speechEnd:
          unawaited(_handleSpeechEnd(vadEvent.silenceDuration));
      }
    }

    final TranscriptFinal? capped = _buffer.advanceBy(frameDuration);
    if (capped != null) {
      _emitFinal(capped);
    }

    if (_nativeReady) {
      _feedNative(frame);
    }
  }

  Future<void> _handleSpeechEnd(Duration silence) async {
    // Flush first so the (more accurate) final decoding lands in the buffer
    // before the pause finalizes it — then the emitted final carries it.
    if (_nativeReady && _buffer.draft.isNotEmpty) {
      await _flushNativeWithTimeout();
    }
    final TranscriptFinal? segment = _buffer.notifySilence(silence);
    if (segment != null) {
      _emitFinal(segment);
    }
  }

  // -------------------------------------------------------------------------
  // Native bridge
  // -------------------------------------------------------------------------

  DynamicLibrary? _libraryOrNull() {
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
      if (process.providesSymbol('nv_whisper_init')) {
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

  bool _initNative(String language) {
    if (_nativeReady) {
      // TODO(Phase 5): re-init with the language-pack manager when the
      // selected language changes; today one model load per process.
      return true;
    }
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return false;
    }
    try {
      final Pointer<Utf8> modelPtr = modelPath.toNativeUtf8(allocator: calloc);
      final Pointer<Utf8> langPtr = language.toNativeUtf8(allocator: calloc);
      try {
        final int rc = lib
            .lookupFunction<_WInitNative, _WInit>('nv_whisper_init')(
          modelPtr,
          langPtr,
        );
        if (rc != 0) {
          return false;
        }
      } finally {
        calloc.free(modelPtr);
        calloc.free(langPtr);
      }
      final NativeCallable<NativeFunction<_WTranscriptCbNative>> callable =
          NativeCallable<NativeFunction<_WTranscriptCbNative>>.listener(
        _onNativeTranscript,
      );
      final int setRc = lib
          .lookupFunction<_WSetCbNative, _WSetCb>(
              'nv_whisper_set_transcript_callback')(callable.nativeFunction);
      if (setRc != 0) {
        callable.close();
        return false;
      }
      _transcriptCallable = callable;
      return true;
    } catch (_) {
      return false;
    }
  }

  int _querySampleRate() {
    final DynamicLibrary? lib = _lib;
    if (lib == null) {
      return fallbackSampleRate;
    }
    try {
      final int rate = lib
          .lookupFunction<_WSampleRateNative, _WSampleRate>(
              'nv_whisper_sample_rate')();
      return rate > 0 ? rate : fallbackSampleRate;
    } catch (_) {
      return fallbackSampleRate;
    }
  }

  void _feedNative(Int16List frame) {
    final DynamicLibrary? lib = _lib;
    if (lib == null || frame.isEmpty) {
      return;
    }
    final Pointer<Int16> samples = calloc<Int16>(frame.length);
    try {
      samples
          .asTypedList(frame.length)
          .setRange(0, frame.length, frame);
      lib.lookupFunction<_WFeedNative, _WFeed>('nv_whisper_feed_pcm_i16')(
        samples,
        frame.length,
      );
    } catch (_) {
      // Feeding is best-effort: a hiccup must never break listening.
    } finally {
      calloc.free(samples);
    }
  }

  /// Runs nv_whisper_flush_final on a background isolate (it blocks in C)
  /// and waits for the is_final callback, with a timeout so a silent native
  /// side can never wedge the pipeline.
  Future<void> _flushNativeWithTimeout() {
    final Future<void> mine = _flushChain.then((_) => _doFlushWithTimeout());
    _flushChain = mine.catchError((Object _) {});
    return mine;
  }

  Future<void> _doFlushWithTimeout() async {
    if (!_nativeReady) {
      return;
    }
    final Completer<void> waiter = Completer<void>();
    _flushCompleter = waiter;
    try {
      int rc = -1;
      try {
        rc = await _flushNative().timeout(flushTimeout, onTimeout: () => -1);
      } catch (_) {
        rc = -1;
      }
      if (rc == 0) {
        await waiter.future.timeout(flushTimeout, onTimeout: () {});
      }
      // Yield once so NativeCallable.listener deliveries queued during the
      // blocking flush land before we finalize.
      await Future<void>.delayed(Duration.zero);
    } finally {
      _flushCompleter = null;
    }
  }

  Future<int> _flushNative() {
    final String name = libraryName;
    return Isolate.run<int>(() {
      final DynamicLibrary lib = DynamicLibrary.open(name);
      return lib
          .lookupFunction<_WFlushNative, _WFlush>('nv_whisper_flush_final')();
    });
  }

  void _resetNative() {
    final DynamicLibrary? lib = _lib;
    if (lib == null || !_nativeReady) {
      return;
    }
    try {
      lib.lookupFunction<_WResetNative, _WReset>('nv_whisper_reset')();
    } catch (_) {
      // Best-effort.
    }
  }

  /// Invoked from the native worker thread via NativeCallable.listener —
  /// delivery happens on the Dart event loop. Copies all native memory
  /// before returning to it.
  void _onNativeTranscript(
    Pointer<Utf8> textPtr,
    bool isFinal,
    Pointer<Utf8> langPtr,
  ) {
    // langPtr is accepted for ABI completeness but not read yet: script
    // detection (Dart side) is cheaper and already multilingual.
    final String text = _readUtf8(textPtr);
    if (isFinal) {
      if (text.isNotEmpty) {
        _buffer.addFinal(text);
      }
      final Completer<void>? waiter = _flushCompleter;
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete();
      }
    } else if (text.isNotEmpty) {
      _buffer.addPartial(text);
      _addEvent(TranscriptEvent(text: _buffer.draft, isFinal: false));
    }
  }

  // -------------------------------------------------------------------------
  // Event emission
  // -------------------------------------------------------------------------

  TranscriptEvent _emitFinal(TranscriptFinal segment) {
    final TranscriptEvent event = TranscriptEvent(
      text: segment.text,
      isFinal: true,
      language: _detector.detect(segment.text),
    );
    _addEvent(event);
    return event;
  }

  void _addEvent(TranscriptEvent event) {
    if (!_transcripts.isClosed) {
      _transcripts.add(event);
    }
  }

  Duration _frameDurationOf(int samples) {
    final double micros =
        samples * Duration.microsecondsPerSecond / _sampleRate;
    return Duration(microseconds: micros.round());
  }
}
