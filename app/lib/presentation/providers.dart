import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../data/services/intent/classifier_service.dart';
import '../data/services/intent/slot_extractor.dart';
import '../data/services/knowledge/knowledge_service.dart';
import '../data/services/llm/llm_service.dart';
import '../data/services/llm/prompt_router.dart';
import '../data/services/voice/audio_capture_service.dart';
import '../data/services/voice/platform_speech_service.dart';
import '../data/services/voice/stt_service.dart';
import '../data/services/voice/tts_service.dart';
import '../domain/entities/intent.dart';
import '../domain/usecases/answer_from_kb.dart';
import '../domain/usecases/orchestrate_user_request.dart'
    show IntentClassifying;
import '../domain/usecases/reply_to_user.dart';
import '../l10n/app_strings.dart';

/// The language the user has chosen for voice and UI.
///
/// Phase 1 replaces the default with on-device language detection
/// (see docs/architecture.md, voice input pipeline).
final StateProvider<String> selectedLanguageProvider =
    StateProvider<String>((ref) => kDefaultLanguage);

// ---------------------------------------------------------------------------
// Voice services (see docs/architecture.md)
//
// None of these constructors touch platform channels — channels are only
// used when a session actually starts, so tests and CI stay clean.
// ---------------------------------------------------------------------------

/// Microphone capture behind the whisper STT pipeline.
final Provider<MethodChannelAudioCapture> audioCaptureProvider =
    Provider<MethodChannelAudioCapture>((ref) {
  final MethodChannelAudioCapture capture = MethodChannelAudioCapture();
  ref.onDispose(capture.dispose);
  return capture;
});

/// Speech-to-text: capture -> VAD -> whisper bridge -> transcript events.
/// Used when the whisper bridge ships inside the APK.
final Provider<SttService> sttServiceProvider = Provider<SttService>((ref) {
  final SttService service =
      SttService(audioCapture: ref.watch(audioCaptureProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// Text-to-speech: piper bridge -> PCM chunks -> audio out.
final Provider<TtsService> ttsServiceProvider = Provider<TtsService>((ref) {
  final TtsService service = TtsService();
  ref.onDispose(service.dispose);
  return service;
});

/// Android's on-device recognizer and TTS engine: the voice loop until the
/// whisper/piper bridges are bundled.
final Provider<PlatformSpeechService> platformSpeechProvider =
    Provider<PlatformSpeechService>((ref) {
  final PlatformSpeechService service = PlatformSpeechService();
  ref.onDispose(service.dispose);
  return service;
});

// ---------------------------------------------------------------------------
// Understanding and answering
// ---------------------------------------------------------------------------

/// The on-device LLM. Stays `unavailable` until a model is loaded; Vaani
/// answers from the knowledge base meanwhile.
final Provider<FfiLlmService> llmServiceProvider =
    Provider<FfiLlmService>((ref) => FfiLlmService());

/// The local knowledge base (bundled sample until a language pack lands).
final Provider<KnowledgeService> knowledgeServiceProvider =
    Provider<KnowledgeService>((ref) => KnowledgeService());

/// Turns one question into Vaani's answer.
final Provider<ReplyToUser> replyToUserProvider =
    Provider<ReplyToUser>((ref) {
  final FfiLlmService llm = ref.watch(llmServiceProvider);
  return ReplyToUser(
    loadClassifier: _loadBundledClassifier,
    slotExtractor: SlotExtractor(),
    promptBuilder: PromptRouter(),
    llm: llm,
    isLlmReady: () => llm.state == LlmState.ready,
    answerFromKb: AnswerFromKb(ref.watch(knowledgeServiceProvider)),
  );
});

/// Builds the intent classifier from the JSONL seed phrases in the bundle.
Future<IntentClassifying?> _loadBundledClassifier() async {
  final Map<String, List<String>> jsonlByIntentId = <String, List<String>>{};
  for (final VaaniIntent intent in VaaniIntent.values) {
    try {
      final String raw = await rootBundle
          .loadString('assets/training_data/intents/${intent.id}.jsonl');
      jsonlByIntentId[intent.id] = raw.split('\n');
    } catch (_) {
      // A missing file only removes that one intent.
    }
  }
  return jsonlByIntentId.isEmpty
      ? null
      : IntentClassifier.fromJsonl(jsonlByIntentId);
}

// ---------------------------------------------------------------------------
// Conversation history (RAM only — PRIVACY_CHARTER.md)
// ---------------------------------------------------------------------------

/// One message on the conversation screen.
final class ChatTurn {
  const ChatTurn.user(this.text) : fromUser = true;

  const ChatTurn.vaani(this.text) : fromUser = false;

  /// True for what the user said or typed, false for Vaani's replies.
  final bool fromUser;

  final String text;
}

/// The turns of this session, oldest first.
class ConversationNotifier extends Notifier<List<ChatTurn>> {
  @override
  List<ChatTurn> build() => const <ChatTurn>[];

  void add(ChatTurn turn) => state = <ChatTurn>[...state, turn];

  /// Replaces the newest turn (used while a reply streams in).
  void replaceLast(ChatTurn turn) {
    if (state.isEmpty) {
      add(turn);
      return;
    }
    state = <ChatTurn>[...state.sublist(0, state.length - 1), turn];
  }

  void clear() => state = const <ChatTurn>[];
}

final NotifierProvider<ConversationNotifier, List<ChatTurn>>
    conversationProvider =
    NotifierProvider<ConversationNotifier, List<ChatTurn>>(
  ConversationNotifier.new,
);

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

/// Vaani heard the user and is working on the answer.
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

/// Drives [voiceSessionProvider]: listen (or read typed text), answer,
/// speak, back to idle. Every path ends in a visible reply or a kind
/// notice — never a silent dead end.
class VoiceSessionNotifier extends Notifier<VoiceSessionState> {
  /// How long to wait for the recognizer's final result after a stop.
  static const Duration _finalResultTimeout = Duration(seconds: 6);

  StreamSubscription<TranscriptEvent>? _transcriptSubscription;
  StreamSubscription<PlatformSpeechEvent>? _platformSubscription;
  String _lastPartial = '';
  bool _usingPlatformSpeech = false;

  /// Bumped by every new turn and every interruption; async work from an
  /// older turn checks it and drops its results.
  int _turn = 0;

  @override
  VoiceSessionState build() {
    ref.onDispose(() {
      _cancelTranscriptSubscription();
      _cancelPlatformSubscription();
    });
    return const VoiceSessionIdle();
  }

  AppStrings get _strings => AppStrings.of(ref.read(selectedLanguageProvider));

  /// Opens the microphone. When voice cannot work on this phone, says so
  /// kindly in the conversation and returns to idle — typing still works.
  Future<void> startListening() async {
    if (state is VoiceSessionListening || state is VoiceSessionTranscribing) {
      return;
    }
    _silenceOutput();
    final int turn = ++_turn;
    state = const VoiceSessionListening();
    _lastPartial = '';

    final SttService stt = ref.read(sttServiceProvider);
    if (stt.nativeAvailable) {
      _usingPlatformSpeech = false;
      _cancelTranscriptSubscription();
      _transcriptSubscription = stt.transcripts.listen(_onTranscript);
      final bool granted =
          await stt.start(language: ref.read(selectedLanguageProvider));
      if (!granted && turn == _turn) {
        _cancelTranscriptSubscription();
        _notice(_strings.voiceUnavailable);
      }
      return;
    }

    _usingPlatformSpeech = true;
    final PlatformSpeechService speech = ref.read(platformSpeechProvider);
    final bool ready = await speech.isRecognitionAvailable() &&
        await speech.requestPermission() is MicrophonePermissionGranted;
    if (turn != _turn) {
      return;
    }
    if (!ready) {
      _notice(_strings.voiceUnavailable);
      return;
    }
    _cancelPlatformSubscription();
    _platformSubscription = speech.events.listen(_onPlatformEvent);
    final bool started =
        await speech.startListening(ref.read(selectedLanguageProvider));
    if (!started && turn == _turn) {
      _cancelPlatformSubscription();
      _notice(_strings.voiceUnavailable);
    }
  }

  /// Stops listening and answers whatever was said.
  Future<void> stopListening() async {
    if (state is! VoiceSessionListening) {
      return;
    }
    state = VoiceSessionTranscribing(partial: _lastPartial);
    if (_usingPlatformSpeech) {
      final int turn = _turn;
      await ref.read(platformSpeechProvider).stopListening();
      // The recognizer answers with onFinal/onError; never wait forever.
      unawaited(Future<void>.delayed(_finalResultTimeout, () {
        if (turn == _turn && state is VoiceSessionTranscribing) {
          _cancelPlatformSubscription();
          unawaited(ref.read(platformSpeechProvider).cancelListening());
          _notice(_strings.couldNotHear);
        }
      }));
      return;
    }
    final TranscriptEvent? finalEvent = await _stopStt();
    if (finalEvent != null && finalEvent.text.trim().isNotEmpty) {
      await ask(finalEvent.text);
    } else {
      _notice(_strings.couldNotHear);
    }
  }

  /// Answers [text] (typed, or the final transcript): shows it, thinks,
  /// shows the reply, and speaks it when this phone has a voice.
  Future<void> ask(String text) async {
    final String question = text.trim();
    if (question.isEmpty) {
      return;
    }
    await _stopInput();
    _silenceOutput();
    final int turn = ++_turn;
    final ConversationNotifier chat = ref.read(conversationProvider.notifier);
    final String language = ref.read(selectedLanguageProvider);

    chat.add(ChatTurn.user(question));
    state = VoiceSessionThinking(heard: question);

    String reply = '';
    bool shown = false;
    try {
      await for (final String partial
          in ref.read(replyToUserProvider)(question, language)) {
        if (turn != _turn) {
          return;
        }
        reply = partial;
        if (shown) {
          chat.replaceLast(ChatTurn.vaani(reply));
        } else {
          chat.add(ChatTurn.vaani(reply));
          shown = true;
        }
      }
    } catch (_) {
      reply = '';
    }
    if (turn != _turn) {
      return;
    }
    if (reply.trim().isEmpty) {
      reply = _strings.iDontKnow;
      if (shown) {
        chat.replaceLast(ChatTurn.vaani(reply));
      } else {
        chat.add(ChatTurn.vaani(reply));
      }
    }

    state = VoiceSessionSpeaking(text: reply);
    await _speak(reply, language);
    if (turn == _turn && state is VoiceSessionSpeaking) {
      state = const VoiceSessionIdle();
    }
  }

  /// Interrupts spoken output immediately. Always a way out.
  Future<void> stopSpeaking() async {
    _turn++;
    _silenceOutput();
    if (state is VoiceSessionSpeaking) {
      state = const VoiceSessionIdle();
    }
  }

  /// Ends the whole session from any state: mic off, speech off, idle.
  Future<void> endSession() async {
    _turn++;
    await _stopInput();
    _silenceOutput();
    state = const VoiceSessionIdle();
  }

  // -------------------------------------------------------------------------

  Future<void> _speak(String text, String language) async {
    final TtsService tts = ref.read(ttsServiceProvider);
    if (tts.spokenOutputAvailable) {
      await tts.speak(text, language: language);
      return;
    }
    await ref.read(platformSpeechProvider).speak(text, language);
  }

  void _silenceOutput() {
    ref.read(ttsServiceProvider).stop();
    unawaited(ref.read(platformSpeechProvider).stopSpeaking());
  }

  /// Closes the microphone without answering anything.
  Future<void> _stopInput() async {
    if (_platformSubscription != null) {
      _cancelPlatformSubscription();
      await ref.read(platformSpeechProvider).cancelListening();
    }
    if (_transcriptSubscription != null) {
      await _stopStt();
    }
  }

  /// A kind, unspoken note from Vaani in the conversation; back to idle.
  void _notice(String text) {
    ref.read(conversationProvider.notifier).add(ChatTurn.vaani(text));
    state = const VoiceSessionIdle();
  }

  void _onPlatformEvent(PlatformSpeechEvent event) {
    switch (event) {
      case PlatformSpeechPartial(:final String text):
        _lastPartial = text;
        if (state is VoiceSessionListening) {
          state = VoiceSessionListening(partial: text);
        } else if (state is VoiceSessionTranscribing) {
          state = VoiceSessionTranscribing(partial: text);
        }
      case PlatformSpeechFinal(:final String text):
        _cancelPlatformSubscription();
        final String heard = text.trim().isEmpty ? _lastPartial : text;
        if (heard.trim().isEmpty) {
          _notice(_strings.couldNotHear);
        } else {
          unawaited(ask(heard));
        }
      case PlatformSpeechError(:final bool voiceUnavailable):
        _cancelPlatformSubscription();
        if (voiceUnavailable) {
          _notice(_strings.voiceUnavailable);
        } else if (_lastPartial.trim().isNotEmpty) {
          unawaited(ask(_lastPartial));
        } else {
          _notice(_strings.couldNotHear);
        }
    }
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
    await ask(flushed?.text ?? event.text);
  }

  void _cancelTranscriptSubscription() {
    final StreamSubscription<TranscriptEvent>? subscription =
        _transcriptSubscription;
    _transcriptSubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
  }

  void _cancelPlatformSubscription() {
    final StreamSubscription<PlatformSpeechEvent>? subscription =
        _platformSubscription;
    _platformSubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
  }
}

/// The one voice session of the app, watched by home and conversation.
final NotifierProvider<VoiceSessionNotifier, VoiceSessionState>
    voiceSessionProvider =
    NotifierProvider<VoiceSessionNotifier, VoiceSessionState>(
  VoiceSessionNotifier.new,
);
