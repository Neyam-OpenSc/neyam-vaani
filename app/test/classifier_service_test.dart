import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/core/constants.dart' show kSupportedLanguages;
import 'package:neyam_vaani/data/services/intent/classifier_service.dart';
import 'package:neyam_vaani/domain/entities/intent.dart';

IntentClassifier _inlineClassifier() {
  return IntentClassifier(
    <VaaniIntent, List<IntentTrainingPhrase>>{
      VaaniIntent.setReminder: const <IntentTrainingPhrase>[
        IntentTrainingPhrase(text: 'set a reminder', lang: 'en'),
        IntentTrainingPhrase(text: 'set an alarm', lang: 'en'),
        IntentTrainingPhrase(text: 'remind me to take medicine', lang: 'en'),
        IntentTrainingPhrase(text: 'कल सुबह 6 बजे अलार्म लगाओ', lang: 'hi'),
      ],
      VaaniIntent.makeCall: const <IntentTrainingPhrase>[
        IntentTrainingPhrase(text: 'call my son', lang: 'en'),
        IntentTrainingPhrase(text: 'phone the doctor', lang: 'en'),
        IntentTrainingPhrase(text: 'अम्मा को फोन करो', lang: 'hi'),
      ],
      VaaniIntent.answerQuestion: const <IntentTrainingPhrase>[
        IntentTrainingPhrase(text: 'what is the capital of India', lang: 'en'),
        IntentTrainingPhrase(text: 'why is the sky blue', lang: 'en'),
      ],
      VaaniIntent.calculate: const <IntentTrainingPhrase>[
        IntentTrainingPhrase(text: 'what is 12 times 10', lang: 'en'),
        IntentTrainingPhrase(text: 'calculate 25 plus 48', lang: 'en'),
      ],
    },
  );
}

Directory _requireTrainingDir() {
  // `flutter test` runs with cwd = the app package root; also tolerate a
  // cwd at the repository root for plain `dart test` runs. CI checks out
  // the full repo, so the files always exist.
  final List<String> candidates = <String>[
    '${Directory.current.path}/assets/training_data/intents',
    '${Directory.current.path}/app/assets/training_data/intents',
  ];
  for (final String path in candidates) {
    final Directory dir = Directory(path);
    if (dir.existsSync()) {
      return dir;
    }
  }
  fail(
    'assets/training_data/intents not found relative to '
    '${Directory.current.path}',
  );
}

Map<String, List<String>> _loadAllJsonl() {
  final Directory dir = _requireTrainingDir();
  final Map<String, List<String>> out = <String, List<String>>{};
  for (final FileSystemEntity entity in dir.listSync()) {
    if (entity is File && entity.path.endsWith('.jsonl')) {
      final String id = entity.uri.pathSegments.last.replaceFirst('.jsonl', '');
      out[id] = entity.readAsLinesSync();
    }
  }
  return out;
}

void main() {
  group('IntentClassifier with inline phrases', () {
    final IntentClassifier classifier = _inlineClassifier();

    test('exact normalized match scores 1.0', () {
      final IntentClassification result = classifier.classify('call my son');
      expect(result.intent, VaaniIntent.makeCall);
      expect(result.confidence, 1.0);
      expect(result.needsLlmFallback, isFalse);
    });

    test('stopwords and case do not affect exact matching', () {
      final IntentClassification result =
          classifier.classify('Vaani, please set an alarm!');
      expect(result.intent, VaaniIntent.setReminder);
      expect(result.confidence, 1.0);
    });

    test('utterance containing a training phrase classifies confidently',
        () {
      final IntentClassification result = classifier.classify(
        'vaani please set a reminder for my blood pressure tablet',
      );
      expect(result.intent, VaaniIntent.setReminder);
      expect(result.confidence, greaterThanOrEqualTo(0.6));
      expect(result.needsLlmFallback, isFalse);
    });

    test('unrelated utterance asks for the LLM fallback', () {
      final IntentClassification result =
          classifier.classify('my favourite colour is blue');
      expect(result.confidence, lessThan(IntentClassifier.llmFallbackThreshold));
      expect(result.needsLlmFallback, isTrue);
    });

    test('empty or punctuation-only utterance yields zero confidence', () {
      for (final String utterance in <String>['', '   ', '!!! ... ???']) {
        final IntentClassification result = classifier.classify(utterance);
        expect(result.confidence, 0.0, reason: '"$utterance"');
        expect(result.needsLlmFallback, isTrue, reason: '"$utterance"');
      }
    });

    test('classification is an IntentPrediction (the domain port shape)', () {
      final IntentPrediction prediction = classifier.classify('phone the doctor');
      expect(prediction.intent, VaaniIntent.makeCall);
      expect(prediction, isA<IntentClassification>());
    });

    test('scores cover every trained intent', () {
      final IntentClassification result = classifier.classify('set an alarm');
      expect(result.scores.keys, containsAll(<VaaniIntent>[
        VaaniIntent.setReminder,
        VaaniIntent.makeCall,
        VaaniIntent.answerQuestion,
        VaaniIntent.calculate,
      ]));
    });
  });

  group('IntentClassifier.fromJsonl', () {
    test('parses valid lines, skips blank and invalid ones', () {
      final IntentClassifier classifier = IntentClassifier.fromJsonl(
        <String, List<String>>{
          'make_call': <String>[
            '',
            '   ',
            '{"text": "call my son", "lang": "en"}',
            'not json at all',
            '{"text": "", "lang": "en"}',
            '{"lang": "en"}',
          ],
          'totally_unknown_intent': <String>[
            '{"text": "hello there", "lang": "en"}',
          ],
        },
      );
      expect(classifier.phraseCount, 1);
      expect(classifier.phraseCounts[VaaniIntent.makeCall], 1);
      expect(classifier.classify('call my son').confidence, 1.0);
    });

    test('IntentTrainingPhrase.fromJsonLine validates fields', () {
      expect(
        IntentTrainingPhrase.fromJsonLine('{"text": "hi", "lang": "en"}').lang,
        'en',
      );
      expect(
        IntentTrainingPhrase.tryFromJsonLine('{"text": "hi"}'),
        isNull,
      );
      expect(
        IntentTrainingPhrase.tryFromJsonLine('broken'),
        isNull,
      );
    });
  });

  group('training data on disk', () {
    test('exactly 20 files, one per intent id', () {
      final Map<String, List<String>> raw = _loadAllJsonl();
      final Set<String> fileIds = raw.keys.toSet();
      final Set<String> enumIds =
          VaaniIntent.values.map((VaaniIntent v) => v.id).toSet();
      expect(enumIds.length, 20);
      expect(fileIds, unorderedEquals(enumIds.toList()));
    });

    test('every file has at least 12 valid, multilingual lines', () {
      final Map<String, List<String>> raw = _loadAllJsonl();
      final Set<String> seenTexts = <String>{};
      final Set<String> languagesSeen = <String>{};
      for (final MapEntry<String, List<String>> entry in raw.entries) {
        final List<String> lines = entry.value
            .where((String line) => line.trim().isNotEmpty)
            .toList();
        expect(lines.length, greaterThanOrEqualTo(12),
            reason: '${entry.key}.jsonl');
        for (final String line in lines) {
          final IntentTrainingPhrase? phrase =
              IntentTrainingPhrase.tryFromJsonLine(line);
          expect(phrase, isNotNull, reason: '${entry.key}.jsonl: $line');
          expect(phrase!.text.trim(), isNotEmpty);
          expect(
            kSupportedLanguages,
            contains(phrase.lang),
            reason: '${entry.key}.jsonl: ${phrase.lang}',
          );
          expect(
            seenTexts.add(phrase.text),
            isTrue,
            reason: 'duplicate phrase across corpus: ${phrase.text}',
          );
          languagesSeen.add(phrase.lang);
        }
      }
      // The corpus must be genuinely multilingual, not English-only.
      expect(languagesSeen.length, greaterThanOrEqualTo(5));
    });

    test('classifier trained on the real corpus recognizes its phrases', () {
      final Map<String, List<String>> raw = _loadAllJsonl();
      final IntentClassifier classifier = IntentClassifier.fromJsonl(raw);
      expect(classifier.phraseCount, greaterThanOrEqualTo(20 * 12));
      for (final String id in <String>[
        'set_reminder',
        'translate',
        'torch_control',
        'date_time',
      ]) {
        final String line =
            raw[id]!.firstWhere((String l) => l.trim().isNotEmpty);
        final IntentTrainingPhrase phrase =
            IntentTrainingPhrase.fromJsonLine(line);
        final IntentClassification verdict = classifier.classify(phrase.text);
        expect(verdict.intent.id, id, reason: phrase.text);
        expect(verdict.confidence, greaterThan(0.999), reason: phrase.text);
      }
    });

    test('vocabulary-gap paraphrase: right intent, honestly flagged', () {
      final Map<String, List<String>> raw = _loadAllJsonl();
      final IntentClassifier classifier = IntentClassifier.fromJsonl(raw);
      final IntentClassification verdict =
          classifier.classify('please remind me to take my tablets');
      // Best intent is right, but "tablets" vs "medicine" leaves the
      // score under the threshold — exactly the case the architecture
      // hands to the LLM fallback instead of guessing confidently.
      expect(verdict.intent, VaaniIntent.setReminder);
      expect(verdict.confidence, lessThan(IntentClassifier.llmFallbackThreshold));
      expect(verdict.needsLlmFallback, isTrue);
    });
  });
}
