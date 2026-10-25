/// Voice activity detection over 16-bit PCM frames.
///
/// Pure Dart — no FFI, no plugins. An RMS-energy detector with hysteresis
/// and minimum speech/silence durations:
///
/// - Speech opens only when energy stays at or above [VadConfig.speechRmsThreshold]
///   for [VadConfig.minSpeechDuration] — short bursts (clicks, breath) are
///   ignored.
/// - Speech closes only when energy stays below [VadConfig.silenceRmsThreshold]
///   for [VadConfig.minSilenceDuration] — brief quiet blips mid-sentence do
///   not cut the user off.
/// - Between the two thresholds the current state holds (hysteresis band).
///
/// TODO(voice): Silero VAD via the native bridge is the planned upgrade
/// (docs/architecture.md). This class is the extension point — keep the
/// [VadEvent] contract identical when it lands, and keep this as the
/// fallback for low-tier devices.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// What the detector observed.
enum VadEventKind {
  /// Speech was just confirmed (after the minimum speech duration).
  speechStart,

  /// Speech just ended; carries the silence duration that closed it.
  speechEnd,
}

/// One VAD transition.
final class VadEvent {
  /// Creates an event of [kind]; only speechEnd carries a silence duration.
  const VadEvent({required this.kind, this.silenceDuration = Duration.zero});

  /// Which transition happened.
  final VadEventKind kind;

  /// The accumulated silence that ended speech (zero for speechStart).
  final Duration silenceDuration;

  @override
  String toString() =>
      'VadEvent(${kind.name}, silence: ${silenceDuration.inMilliseconds}ms)';
}

/// Tuning for [VadService]. Defaults assume 16 kHz mono 16-bit PCM, where
/// full scale is 32768: room noise sits well under an RMS of 350 and speech
/// comfortably over 700.
final class VadConfig {
  /// Creates a configuration with sensible low-end-phone defaults.
  const VadConfig({
    this.sampleRate = 16000,
    this.speechRmsThreshold = 700,
    this.silenceRmsThreshold = 350,
    this.minSpeechDuration = const Duration(milliseconds: 120),
    this.minSilenceDuration = const Duration(milliseconds: 900),
  });

  /// Expected capture rate; frames of other rates are measured against it.
  final int sampleRate;

  /// RMS (in 16-bit units) at or above which a frame counts as speech.
  final int speechRmsThreshold;

  /// RMS below which a frame counts as silence once speech is open.
  final int silenceRmsThreshold;

  /// Energy must persist this long before speechStart fires.
  final Duration minSpeechDuration;

  /// Quiet must persist this long before speechEnd fires. The default pairs
  /// with TranscriptBuffer's 900 ms pause threshold (stt_service.dart).
  final Duration minSilenceDuration;
}

/// Energy-gate voice activity detector over injected frame streams.
class VadService {
  /// Creates a detector with [config]; stateful across frames.
  VadService({VadConfig config = const VadConfig()}) : _config = config;

  final VadConfig _config;

  bool _inSpeech = false;
  Duration _speechRun = Duration.zero;
  Duration _silenceRun = Duration.zero;

  /// Whether speech is currently considered open.
  bool get inSpeech => _inSpeech;

  /// Feeds one frame; returns the transition it caused, if any.
  ///
  /// At most one event per frame: a frame is either speech or silence.
  VadEvent? process(Int16List frame) {
    final Duration frameDuration = _durationOf(frame.length);
    final double rms = _rms(frame);

    if (_inSpeech) {
      if (rms < _config.silenceRmsThreshold) {
        _silenceRun += frameDuration;
        if (_silenceRun >= _config.minSilenceDuration) {
          final Duration silence = _silenceRun;
          _inSpeech = false;
          _speechRun = Duration.zero;
          _silenceRun = Duration.zero;
          return VadEvent(
            kind: VadEventKind.speechEnd,
            silenceDuration: silence,
          );
        }
      } else {
        // Quiet ended within the hangover window (or we are in the
        // hysteresis band): keep the utterance open.
        _silenceRun = Duration.zero;
      }
      return null;
    }

    if (rms >= _config.speechRmsThreshold) {
      _speechRun += frameDuration;
      if (_speechRun >= _config.minSpeechDuration) {
        _inSpeech = true;
        _speechRun = Duration.zero;
        _silenceRun = Duration.zero;
        return const VadEvent(kind: VadEventKind.speechStart);
      }
    } else {
      // Energy did not persist: a short burst, not speech.
      _speechRun = Duration.zero;
    }
    return null;
  }

  /// Wires the detector over [frames], yielding transitions in order.
  ///
  /// The returned stream ends when [frames] ends. [VadService] stays
  /// stateful per instance — use one service per stream.
  Stream<VadEvent> bind(Stream<Int16List> frames) async* {
    await for (final Int16List frame in frames) {
      final VadEvent? event = process(frame);
      if (event != null) {
        yield event;
      }
    }
  }

  /// Clears all state; the next utterance starts from scratch.
  void reset() {
    _inSpeech = false;
    _speechRun = Duration.zero;
    _silenceRun = Duration.zero;
  }

  Duration _durationOf(int samples) {
    final double micros =
        samples * Duration.microsecondsPerSecond / _config.sampleRate;
    return Duration(microseconds: micros.round());
  }

  static double _rms(Int16List frame) {
    if (frame.isEmpty) {
      return 0;
    }
    int sum = 0;
    for (final int sample in frame) {
      sum += sample * sample;
    }
    return math.sqrt(sum / frame.length);
  }
}
