/// Use case: produce Vaani's answer for one user turn, using whatever is
/// actually installed on this phone.
///
/// Order of trust (TENDER_UX_PRINCIPLES.md: honest uncertainty beats a
/// guess):
///
///     greeting / date & time         (pure Dart, always available)
///       -> on-device LLM             (only when a model is loaded)
///       -> local knowledge base      (bundled sample KB / language pack)
///       -> "I don't know that yet"   (and what Vaani *can* help with)
///
/// Everything stays on-device (PRIVACY_CHARTER.md).
library;

import '../../core/result.dart';
import '../../data/services/voice/stt_service.dart' show ScriptLanguageDetector;
import '../../l10n/app_strings.dart';
import '../entities/intent.dart';
import 'answer_from_kb.dart';
import 'orchestrate_user_request.dart';

/// Answers one turn as a stream of the reply-so-far; the last value is
/// the complete reply. Never throws, never ends silently.
class ReplyToUser {
  ReplyToUser({
    required Future<IntentClassifying?> Function() loadClassifier,
    required this.slotExtractor,
    required this.promptBuilder,
    required this.llm,
    required this.isLlmReady,
    required this.answerFromKb,
    DateTime Function()? clock,
  })  : _loadClassifier = loadClassifier,
        _now = clock ?? DateTime.now;

  /// Below this the fast classifier's verdict is not trusted for the
  /// pure-Dart answers (date/time).
  static const double confidentEnough = 0.6;

  final Future<IntentClassifying?> Function() _loadClassifier;
  final SlotFilling slotExtractor;
  final PromptBuilding promptBuilder;
  final LlmGenerating llm;
  final bool Function() isLlmReady;
  final AnswerFromKb answerFromKb;
  final DateTime Function() _now;

  Future<IntentClassifying?>? _classifier;

  Stream<String> call(String text, String userLanguage) async* {
    final String question = text.trim();
    if (question.isEmpty) {
      return;
    }
    final AppStrings strings = AppStrings.of(userLanguage);

    if (isGreeting(question)) {
      yield strings.greetingReply;
      return;
    }

    final IntentClassifying? classifier = await (_classifier ??= _safeLoad());
    final IntentPrediction? prediction = classifier?.classify(question);
    if (prediction != null &&
        prediction.intent == VaaniIntent.dateTime &&
        prediction.confidence >= confidentEnough) {
      yield dateTimeReply(strings, _now());
      return;
    }

    if (classifier != null && isLlmReady()) {
      String streamed = '';
      await for (final String partial
          in _fromLlm(classifier, question, userLanguage)) {
        streamed = partial;
        if (partial.isNotEmpty) {
          yield partial;
        }
      }
      if (streamed.trim().isNotEmpty) {
        return;
      }
    }

    final String? fromKb = await _fromKnowledgeBase(question, userLanguage);
    yield fromKb ?? strings.noAnswerYet;
  }

  Future<IntentClassifying?> _safeLoad() async {
    try {
      return await _loadClassifier();
    } catch (_) {
      // No classifier: Vaani still answers from the knowledge base.
      return null;
    }
  }

  Stream<String> _fromLlm(
    IntentClassifying classifier,
    String question,
    String userLanguage,
  ) async* {
    final Result<OrchestrationPlan> plan = await OrchestrateUserRequest(
      classifier: classifier,
      slotExtractor: slotExtractor,
      promptBuilder: promptBuilder,
      llm: llm,
    )(OrchestrationRequest(transcript: question, userLanguage: userLanguage));
    if (plan case Ok<OrchestrationPlan>(:final OrchestrationPlan value)) {
      final StringBuffer reply = StringBuffer();
      await for (final LlmTokenEvent event in value.response) {
        switch (event) {
          case LlmTokenText(:final String text):
            reply.write(text);
            yield reply.toString();
          case LlmTokenFailed():
            // Fall back to the knowledge base instead of a half answer.
            yield '';
            return;
          case LlmTokenDone():
            break;
        }
      }
    }
  }

  Future<String?> _fromKnowledgeBase(String question, String userLanguage) async {
    // Search in the language the question is written in; the user's
    // chosen language decides which Devanagari language is meant.
    final String questionLanguage = ScriptLanguageDetector(
      devanagariLanguage: _devanagari.contains(userLanguage) ? userLanguage : 'hi',
      fallbackLanguage: userLanguage,
    ).detect(question);
    try {
      final KbAnswer answer = await answerFromKb(question, questionLanguage, k: 1);
      if (!answer.hasAnswer) {
        return null;
      }
      final KbPassage best = answer.passages.first;
      return '${best.title}\n${best.text}';
    } catch (_) {
      return null; // A broken KB must not break the turn.
    }
  }

  static const Set<String> _devanagari = <String>{'hi', 'mr', 'bho', 'mai'};

  /// Short hellos in every v1 language (and common romanizations).
  static const Set<String> _greetings = <String>{
    'hello', 'hi', 'hey', 'namaste', 'namaskar', 'namaskaram', 'vanakkam',
    'pranam', 'good morning', 'good evening',
    'வணக்கம்', 'नमस्ते', 'नमस्कार', 'प्रणाम', 'নমস্কার', 'প্রণাম',
    'ನಮಸ್ಕಾರ', 'నమస్కారం', 'నమస్తే',
  };

  /// Whether [text] is just a greeting ("vanakkam", "नमस्ते ji"...).
  static bool isGreeting(String text) {
    final String cleaned = text
        .toLowerCase()
        .replaceAll(RegExp(r'[.,!?।]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (_greetings.contains(cleaned)) {
      return true;
    }
    final List<String> words = cleaned.split(' ');
    return words.length <= 3 && _greetings.contains(words.first);
  }

  /// "Today is 26/10/2026. The time is 2:05 PM." in the user's language.
  static String dateTimeReply(AppStrings strings, DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    final int hour12 = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final String period = now.hour < 12 ? 'AM' : 'PM';
    return strings.dateTimeReply(
      date: '${two(now.day)}/${two(now.month)}/${now.year}',
      time: '$hour12:${two(now.minute)} $period',
    );
  }
}
