import 'dart:io' show File;

import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/data/services/intent/slot_extractor.dart';
import 'package:neyam_vaani/data/services/knowledge/knowledge_service.dart';
import 'package:neyam_vaani/data/services/llm/llm_service.dart';
import 'package:neyam_vaani/data/services/llm/prompt_router.dart';
import 'package:neyam_vaani/domain/entities/intent.dart';
import 'package:neyam_vaani/domain/usecases/answer_from_kb.dart';
import 'package:neyam_vaani/domain/usecases/orchestrate_user_request.dart';
import 'package:neyam_vaani/domain/usecases/reply_to_user.dart';
import 'package:neyam_vaani/l10n/app_strings.dart';

/// Always answers with one fixed intent at full confidence.
class _FixedClassifier implements IntentClassifying {
  const _FixedClassifier(this.intent);

  final VaaniIntent intent;

  @override
  IntentPrediction classify(String transcript) =>
      IntentPrediction(intent: intent, confidence: 1);
}

ReplyToUser _reply({
  VaaniIntent intent = VaaniIntent.answerQuestion,
  bool llmReady = false,
  LlmGenerating? llm,
}) {
  final File kb = File('assets/knowledge/sample_kb.json');
  return ReplyToUser(
    loadClassifier: () async => _FixedClassifier(intent),
    slotExtractor: SlotExtractor(),
    promptBuilder: PromptRouter(
      assetLoader: (String path) async => 'Answer in {user_language}: {question}',
    ),
    llm: llm ?? DeterministicLlm(),
    isLlmReady: () => llmReady,
    answerFromKb: AnswerFromKb(KnowledgeService(sourceLoader: kb.readAsString)),
    clock: () => DateTime(2026, 10, 26, 14, 5),
  );
}

Future<String> _final(Stream<String> replies) async {
  String last = '';
  await for (final String reply in replies) {
    last = reply;
  }
  return last;
}

void main() {
  test('greetings get a friendly hello in the user\'s language', () async {
    expect(await _final(_reply()('vanakkam', 'ta')),
        AppStrings.of('ta').greetingReply);
    expect(await _final(_reply()('Hello!', 'en')),
        AppStrings.of('en').greetingReply);
  });

  test('date and time are answered on-device', () async {
    final String answer =
        await _final(_reply(intent: VaaniIntent.dateTime)('what time is it', 'en'));
    expect(answer, 'Today is 26/10/2026. The time is 2:05 PM.');
  });

  test('without a model, questions are answered from the knowledge base',
      () async {
    final String answer =
        await _final(_reply()('emergency number', 'en'));
    expect(answer, contains('112'));
  });

  test('the knowledge base is searched in the script of the question',
      () async {
    // Tamil chosen in settings, but the question is typed in English.
    final String answer = await _final(_reply()('emergency', 'ta'));
    expect(answer, contains('112'));
  });

  test('unknown questions get an honest answer, never silence', () async {
    expect(await _final(_reply()('zzzzyyyyxxxx', 'en')),
        AppStrings.of('en').noAnswerYet);
  });

  test('a loaded model streams its answer', () async {
    final DeterministicLlm llm = DeterministicLlm(
      cannedResponses: <String, String>{'capital': 'New Delhi.'},
    );
    final String answer = await _final(
      _reply(llmReady: true, llm: llm)('what is the capital of India', 'en'),
    );
    expect(answer, 'New Delhi.');
  });

  test('isGreeting ignores real questions that start with hello', () {
    expect(ReplyToUser.isGreeting('नमस्ते'), isTrue);
    expect(ReplyToUser.isGreeting('hello what is the emergency number'),
        isFalse);
  });
}
