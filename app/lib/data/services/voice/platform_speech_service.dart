/// Android's own on-device speech recognizer and text-to-speech engine,
/// used while the whisper/piper bridges are not inside the APK.
///
/// PRIVACY_CHARTER.md: the Kotlin side only ever creates the ON-DEVICE
/// recognizer (Android 12+). When it is missing, [isRecognitionAvailable]
/// is false and the user types instead — audio never goes to a server.
///
/// Channels (implemented in android/.../MainActivity.kt):
/// - `neyam_vaani/speech`
///   - Dart -> platform: `isAvailable` -> bool, `requestPermission` ->
///     `'granted'` | `'denied'`, `start {language}` -> bool, `stop`, `cancel`
///   - platform -> Dart: `onPartial` (String), `onFinal` (String),
///     `onError` (int, android.speech.SpeechRecognizer.ERROR_*)
/// - `neyam_vaani/tts`
///   - `speak {text, language}` -> bool (completes when speech ends;
///     false when nothing could be spoken), `stop`
///
/// Every channel failure (desktop, tests, a missing engine) resolves to a
/// calm "unavailable" — never a crash.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'audio_capture_service.dart'
    show
        MicrophonePermission,
        MicrophonePermissionDenied,
        MicrophonePermissionGranted;

/// Something the platform recognizer reported.
sealed class PlatformSpeechEvent {
  const PlatformSpeechEvent();
}

/// Live hypothesis while the user is still speaking.
final class PlatformSpeechPartial extends PlatformSpeechEvent {
  const PlatformSpeechPartial(this.text);

  final String text;
}

/// The finished utterance (may be empty when nothing was understood).
final class PlatformSpeechFinal extends PlatformSpeechEvent {
  const PlatformSpeechFinal(this.text);

  final String text;
}

/// Recognition ended without a result.
final class PlatformSpeechError extends PlatformSpeechEvent {
  const PlatformSpeechError(this.code);

  /// `android.speech.SpeechRecognizer.ERROR_*`.
  final int code;

  /// Nothing (clear) was heard: ERROR_SPEECH_TIMEOUT / ERROR_NO_MATCH.
  bool get nothingHeard => code == 6 || code == 7;

  /// The microphone or the language model cannot be used right now:
  /// ERROR_INSUFFICIENT_PERMISSIONS, ERROR_LANGUAGE_NOT_SUPPORTED,
  /// ERROR_LANGUAGE_UNAVAILABLE.
  bool get voiceUnavailable => code == 9 || code == 12 || code == 13;
}

/// Maps Vaani's language codes to the BCP-47 tags Android expects.
/// Bhojpuri and Maithili have no Android voices yet; Hindi is the
/// closest Devanagari neighbour.
String platformLanguageTag(String language) {
  const Map<String, String> tags = <String, String>{
    'ta': 'ta-IN',
    'hi': 'hi-IN',
    'bn': 'bn-IN',
    'kn': 'kn-IN',
    'te': 'te-IN',
    'mr': 'mr-IN',
    'bho': 'hi-IN',
    'mai': 'hi-IN',
    'en': 'en-IN',
  };
  return tags[language] ?? 'en-IN';
}

/// Talks to the Android speech recognizer and TTS engine.
class PlatformSpeechService {
  PlatformSpeechService({
    MethodChannel? speechChannel,
    MethodChannel? ttsChannel,
  })  : _speech = speechChannel ?? const MethodChannel('neyam_vaani/speech'),
        _tts = ttsChannel ?? const MethodChannel('neyam_vaani/tts');

  final MethodChannel _speech;
  final MethodChannel _tts;
  final StreamController<PlatformSpeechEvent> _events =
      StreamController<PlatformSpeechEvent>.broadcast();
  bool _handlerBound = false;

  /// Recognizer events for the current listening session.
  Stream<PlatformSpeechEvent> get events => _events.stream;

  /// Whether the on-device recognizer exists on this phone.
  Future<bool> isRecognitionAvailable() async {
    try {
      return await _speech.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks for the microphone with the system dialog.
  Future<MicrophonePermission> requestPermission() async {
    try {
      final String? answer =
          await _speech.invokeMethod<String>('requestPermission');
      return answer == 'granted'
          ? const MicrophonePermissionGranted()
          : const MicrophonePermissionDenied();
    } catch (_) {
      return const MicrophonePermissionDenied();
    }
  }

  /// Starts listening in [language] (a Vaani code such as 'ta'). Returns
  /// false when nothing was started.
  Future<bool> startListening(String language) async {
    _bindHandler();
    try {
      return await _speech.invokeMethod<bool>(
            'start',
            <String, String>{'language': platformLanguageTag(language)},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Stops listening; the recognizer then delivers its final result.
  Future<void> stopListening() async {
    try {
      await _speech.invokeMethod<void>('stop');
    } catch (_) {
      // Nothing was listening.
    }
  }

  /// Abandons the current listening session without a result.
  Future<void> cancelListening() async {
    try {
      await _speech.invokeMethod<void>('cancel');
    } catch (_) {
      // Nothing was listening.
    }
  }

  /// Speaks [text] aloud; completes when speaking ends. Returns false when
  /// this phone has no usable voice for [language] — callers then simply
  /// show the text.
  Future<bool> speak(String text, String language) async {
    try {
      return await _tts.invokeMethod<bool>(
            'speak',
            <String, String>{
              'text': text,
              'language': platformLanguageTag(language),
            },
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Stops speaking immediately.
  Future<void> stopSpeaking() async {
    try {
      await _tts.invokeMethod<void>('stop');
    } catch (_) {
      // Nothing was speaking.
    }
  }

  /// Releases the event stream.
  void dispose() {
    unawaited(_events.close());
  }

  void _bindHandler() {
    if (_handlerBound) {
      return;
    }
    _handlerBound = true;
    _speech.setMethodCallHandler((MethodCall call) async {
      final PlatformSpeechEvent? event = switch (call.method) {
        'onPartial' => PlatformSpeechPartial('${call.arguments}'),
        'onFinal' => PlatformSpeechFinal('${call.arguments}'),
        'onError' => PlatformSpeechError(
            call.arguments is int ? call.arguments as int : -1,
          ),
        _ => null,
      };
      if (event != null && !_events.isClosed) {
        _events.add(event);
      }
      return null;
    });
  }
}
