import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../data/services/voice/audio_capture_service.dart';
import '../data/services/voice/stt_service.dart';
import '../data/services/voice/tts_service.dart';

/// The language the user has chosen for voice and UI.
///
/// Phase 1 replaces the default with on-device language detection
/// (see docs/architecture.md, voice input pipeline).
final StateProvider<String> selectedLanguageProvider =
    StateProvider<String>((ref) => kDefaultLanguage);

// ---------------------------------------------------------------------------
// Voice services (Phase 1 skeleton; see docs/architecture.md)
//
// None of these constructors touch platform channels — the MethodChannel is
// only used when a session actually starts, so tests and CI stay clean.
// ---------------------------------------------------------------------------

/// Microphone capture behind the STT pipeline.
final Provider<MethodChannelAudioCapture> audioCaptureProvider =
    Provider<MethodChannelAudioCapture>((ref) {
  final MethodChannelAudioCapture capture = MethodChannelAudioCapture();
  ref.onDispose(capture.dispose);
  return capture;
});

/// Speech-to-text: capture -> VAD -> whisper bridge -> transcript events.
final Provider<SttService> sttServiceProvider = Provider<SttService>((ref) {
  final SttService service =
      SttService(audioCapture: ref.watch(audioCaptureProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// Text-to-speech: piper bridge -> PCM chunks -> (Phase 2) audio out.
final Provider<TtsService> ttsServiceProvider = Provider<TtsService>((ref) {
  final TtsService service = TtsService();
  ref.onDispose(service.dispose);
  return service;
});

// ---------------------------------------------------------------------------
// Voice session state
// ---------------------------------------------------------------------------

/// Where one voice turn is. Calm, honest, exhaustive:
/// idle -> listening -> transcribing -> thinking -> speaking -> idle.
/// (TENDER_UX_PRINCIPLES.md: no fake states, no fake delays.)
sealed class VoiceSessionState {
  const VoiceSessionState();
}

/// Nothing is happening; the microphone is off.
final class VoiceSessionIdle extends VoiceSessionState {
  const VoiceSessionIdle();
}

/// The microphone is open; [partial] is what Vaani has heard so far.
final class VoiceSessionListening extends VoiceSessionState {
  const VoiceSessionListening({this.partial = ''});

  /// Live transcript hypothesis; empty until the first partial arrives.
  final String partial;
}

/// The user stopped or paused; the final transcript is being settled.
final class VoiceSessionTranscribing extends VoiceSessionState {
  const VoiceSessionTranscribing({this.partial = ''});

  /// The last partial, kept on screen while the final settles.
  final String partial;
}

/// Vaani heard the user and is waiting for the answer (Phase 3 wires the
/// on-device LLM behind this state).
final class VoiceSessionThinking extends VoiceSessionState {
  const VoiceSessionThinking({required this.heard});

  /// The finalized transcript of what the user said.
  final String heard;
}

/// Vaani is speaking [text] aloud. Always interruptible.
final class VoiceSessionSpeaking extends VoiceSessionState {
  const VoiceSessionSpeaking({required this.text});

  /// The text being spoken.
  final String text;
}

/// Drives [voiceSessionProvider]: one spoken question at a time, from
/// microphone to final transcript. Future phases extend the same machine.
class VoiceSessionNotifier extends Notifier<VoiceSessionState> {
  StreamSubscription<TranscriptEvent>? _transcriptSubscription;
  String _lastPartial = '';

  @override
  VoiceSessionState build() {
    ref.onDispose(_cancelTranscriptSubscription);
    return const VoiceSessionIdle();
  }

  /// Opens the session: capture -> VAD -> STT (docs/architecture.md).
  /// Kindly returns to [VoiceSessionIdle] when the microphone permission
  /// was denied — nothing was started, nothing nags.
  Future<void> startListening() async {
    if (state is VoiceSessionListening || state is VoiceSessionTranscribing) {
      return;
    }
    state = const VoiceSessionListening();
    _lastPartial = '';
    final SttService stt = ref.read(sttServiceProvider);
    _cancelTranscriptSubscription();
    _transcriptSubscription = stt.transcripts.listen(_onTranscript);
    final bool granted =
        await stt.start(language: ref.read(selectedLanguageProvider));
    if (!granted) {
      _cancelTranscriptSubscription();
      state = const VoiceSessionIdle();
    }
  }

  /// Stops listening and transcribes whatever was said. Ends in
  /// [VoiceSessionThinking] when something was heard, back to
  /// [VoiceSessionIdle] when nothing was.
  Future<void> stopListening() async {
    if (state is! VoiceSessionListening) {
      return;
    }
    state = VoiceSessionTranscribing(partial: _lastPartial);
    final TranscriptEvent? finalEvent = await _stopStt();
    if (finalEvent != null) {
      state = VoiceSessionThinking(heard: finalEvent.text);
    } else {
      state = const VoiceSessionIdle();
    }
  }

  /// Interrupts spoken output immediately. Always a way out.
  Future<void> stopSpeaking() async {
    ref.read(ttsServiceProvider).stop();
    if (state is VoiceSessionSpeaking) {
      state = const VoiceSessionIdle();
    }
  }

  /// Ends the whole session from any state: mic off, speech off, idle.
  Future<void> endSession() async {
    if (state is VoiceSessionListening) {
      await stopListening();
    }
    ref.read(ttsServiceProvider).stop();
    state = const VoiceSessionIdle();
  }

  Future<TranscriptEvent?> _stopStt() async {
    final SttService stt = ref.read(sttServiceProvider);
    final TranscriptEvent? finalEvent = await stt.stop();
    _cancelTranscriptSubscription();
    return finalEvent;
  }

  void _onTranscript(TranscriptEvent event) {
    if (event.isFinal) {
      if (state is! VoiceSessionListening) {
        return; // A stop is already in flight.
      }
      state = VoiceSessionTranscribing(partial: event.text);
      unawaited(_finishUtterance(event));
    } else {
      _lastPartial = event.text;
      if (state is VoiceSessionListening) {
        state = VoiceSessionListening(partial: event.text);
      }
    }
  }

  Future<void> _finishUtterance(TranscriptEvent event) async {
    final TranscriptEvent? flushed = await _stopStt();
    state = VoiceSessionThinking(heard: flushed?.text ?? event.text);
    // TODO(Phase 3): stream the on-device LLM reply here, then hand it to
    // voice output —
    //
    //   state = VoiceSessionSpeaking(text: reply);
    //   unawaited(ref
    //       .read(ttsServiceProvider)
    //       .speak(reply, language: ref.read(selectedLanguageProvider)));
    //
    // Until the LLM lands, Vaani honestly stays in "thinking" with a way
    // out (endSession), rather than pretending to answer.
  }

  void _cancelTranscriptSubscription() {
    final StreamSubscription<TranscriptEvent>? subscription =
        _transcriptSubscription;
    _transcriptSubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
  }
}

/// The one voice session of the app, watched by home and conversation.
final NotifierProvider<VoiceSessionNotifier, VoiceSessionState>
    voiceSessionProvider =
    NotifierProvider<VoiceSessionNotifier, VoiceSessionState>(
  VoiceSessionNotifier.new,
);
