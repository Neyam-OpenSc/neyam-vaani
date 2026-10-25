import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/core/result.dart';
import 'package:neyam_vaani/data/services/llm/prompt_router.dart';
import 'package:neyam_vaani/domain/entities/intent.dart';
import 'package:neyam_vaani/domain/usecases/orchestrate_user_request.dart'
    show RoutedPrompt;

PromptRouter _routerWith(Map<String, String> templates) {
  return PromptRouter(
    assetLoader: (String path) {
      final String? template = templates[path];
      if (template == null) {
        throw StateError('missing asset: $path');
      }
      return Future<String>.value(template);
    },
    languageNames: const <String, String>{
      'ta': 'தமிழ்',
      'hi': 'हिन्दी',
      'en': 'English',
    },
  );
}

Directory? _locateAssetDir(String subDir) {
  // `flutter test` runs with cwd = the app package root; also tolerate a
  // cwd at the repository root for plain `dart test` runs.
  final List<String> candidates = <String>[
    '${Directory.current.path}/assets/$subDir',
    '${Directory.current.path}/app/assets/$subDir',
  ];
  for (final String path in candidates) {
    final Directory dir = Directory(path);
    if (dir.existsSync()) {
      return dir;
    }
  }
  return null;
}

void main() {
  group('renderTemplate', () {
    test('substitutes every provided placeholder', () {
      const String template =
          'Q: {question} lang: {user_language} tone: {tone}';
      final String rendered = PromptRouter.renderTemplate(
        template,
        const <String, String>{
          'question': '2+2?',
          'user_language': 'தமிழ்',
          'tone': 'formal',
        },
      );
      expect(rendered, 'Q: 2+2? lang: தமிழ் tone: formal');
    });

    test('leaves unknown placeholders untouched', () {
      const String template = '{ocr_text} in {user_language}';
      final String rendered = PromptRouter.renderTemplate(
        template,
        const <String, String>{'user_language': 'தமிழ்'},
      );
      expect(rendered, '{ocr_text} in தமிழ்');
    });
  });

  group('template mapping', () {
    final PromptRouter router = _routerWith(const <String, String>{});

    test('maps intents with dedicated prompt files', () {
      expect(
        router.templateFileFor(VaaniIntent.answerQuestion),
        'answer_question.txt',
      );
      expect(
        router.templateFileFor(VaaniIntent.howToQuestion),
        'answer_question.txt',
      );
      expect(
        router.templateFileFor(VaaniIntent.draftMessage),
        'draft_message.txt',
      );
      expect(
        router.templateFileFor(VaaniIntent.draftLetter),
        'draft_message.txt',
      );
      expect(
        router.templateFileFor(VaaniIntent.explainMedicine),
        'explain_medicine.txt',
      );
      expect(router.templateFileFor(VaaniIntent.fillForm), 'fill_form.txt');
      expect(router.templateFileFor(VaaniIntent.translate), 'translate.txt');
      expect(
        router.templateFileFor(VaaniIntent.readDocument),
        'simplify_text.txt',
      );
    });

    test('unmapped intents fall back to general_assistant', () {
      for (final VaaniIntent intent in <VaaniIntent>[
        VaaniIntent.torchControl,
        VaaniIntent.makeCall,
        VaaniIntent.setReminder,
        VaaniIntent.dateTime,
        VaaniIntent.marketPrice,
      ]) {
        expect(
          router.templateFileFor(intent),
          PromptRouter.fallbackPromptFile,
          reason: intent.id,
        );
        expect(router.hasDedicatedPrompt(intent), isFalse, reason: intent.id);
      }
      expect(router.hasDedicatedPrompt(VaaniIntent.answerQuestion), isTrue);
      expect(
        router.promptIdFor(VaaniIntent.torchControl),
        'general_assistant',
      );
    });
  });

  group('buildPrompt', () {
    test('renders defaults plus slot values', () async {
      final PromptRouter router = _routerWith(
        <String, String>{
          '${PromptRouter.promptAssetPrefix}answer_question.txt':
              'lang {user_language} q {question} tone {tone}',
        },
      );
      final Result<RoutedPrompt> result = await router.buildPrompt(
        intent: VaaniIntent.answerQuestion,
        userLanguage: 'ta',
        transcript: 'வானம் ஏன் நீல நிறம்',
        slotValues: const <String, String>{'tone': 'formal'},
      );
      final RoutedPrompt prompt = result.valueOrNull!;
      expect(prompt.promptId, 'answer_question');
      expect(prompt.isFallback, isFalse);
      expect(prompt.text, 'lang தமிழ் q வானம் ஏன் நீல நிறம் tone formal');
    });

    test('slot values override the transcript default for {text}', () async {
      final PromptRouter router = _routerWith(
        <String, String>{
          '${PromptRouter.promptAssetPrefix}translate.txt': 'Text: {text}',
        },
      );
      final Result<RoutedPrompt> result = await router.buildPrompt(
        intent: VaaniIntent.translate,
        userLanguage: 'en',
        transcript: 'translate this letter into bengali',
        slotValues: const <String, String>{'text': 'நன்றி'},
      );
      expect(result.valueOrNull!.text, 'Text: நன்றி');
    });

    test('missing dedicated template degrades to the fallback', () async {
      final PromptRouter router = _routerWith(
        <String, String>{
          '${PromptRouter.promptAssetPrefix}general_assistant.txt':
              'You said: {user_input} in {user_language}',
        },
      );
      final Result<RoutedPrompt> result = await router.buildPrompt(
        intent: VaaniIntent.answerQuestion, // dedicated template missing
        userLanguage: 'hi',
        transcript: 'भारत की राजधानी क्या है',
      );
      final RoutedPrompt prompt = result.valueOrNull!;
      expect(prompt.promptId, 'general_assistant');
      expect(prompt.isFallback, isTrue);
      expect(
        prompt.text,
        'You said: भारत की राजधानी क्या है in हिन्दी',
      );
    });

    test('returns Err when even the fallback cannot be loaded', () async {
      final PromptRouter router = _routerWith(const <String, String>{});
      final Result<RoutedPrompt> result = await router.buildPrompt(
        intent: VaaniIntent.torchControl,
        userLanguage: 'ta',
        transcript: 'டார்ச் ஆன் பண்ணு',
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull!.userMessageKey, 'failure_unknown');
    });

    test('unknown language code passes through as-is', () async {
      final PromptRouter router = _routerWith(
        <String, String>{
          '${PromptRouter.promptAssetPrefix}general_assistant.txt':
              'lang: {user_language}',
        },
      );
      final Result<RoutedPrompt> result = await router.buildPrompt(
        intent: VaaniIntent.copyText,
        userLanguage: 'xx',
        transcript: 'copy what I say',
      );
      expect(result.valueOrNull!.text, 'lang: xx');
    });
  });

  group('buildMetaClassificationPrompt', () {
    test('lists every candidate id and the transcript', () async {
      final PromptRouter router = _routerWith(const <String, String>{});
      final Result<RoutedPrompt> result =
          await router.buildMetaClassificationPrompt(
        transcript: 'நாளை காலை எழுப்பு',
        userLanguage: 'ta',
        candidates: VaaniIntent.values,
      );
      final RoutedPrompt prompt = result.valueOrNull!;
      expect(prompt.promptId, PromptRouter.metaPromptId);
      expect(prompt.isFallback, isFalse);
      expect(prompt.text, contains('தமிழ்'));
      expect(prompt.text, contains('நாளை காலை எழுப்பு'));
      for (final VaaniIntent intent in VaaniIntent.values) {
        expect(prompt.text, contains(intent.id), reason: intent.id);
      }
    });
  });

  group('prompt assets on disk', () {
    test('every referenced template exists in the repo', () {
      final Directory? dir = _locateAssetDir('prompts');
      expect(
        dir,
        isNotNull,
        reason:
            'assets/prompts not found relative to ${Directory.current.path}',
      );
      final Set<String> files = dir!
          .listSync()
          .whereType<File>()
          .map((File f) => f.uri.pathSegments.last)
          .toSet();
      final Set<String> referenced = <String>{
        ...PromptRouter.promptFiles.values,
        PromptRouter.fallbackPromptFile,
      };
      for (final String name in referenced) {
        expect(files, contains(name), reason: name);
      }
    });
  });
}
