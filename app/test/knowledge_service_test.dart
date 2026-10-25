import 'dart:convert' show jsonEncode;
import 'dart:io' show File;

import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/data/services/knowledge/hybrid_search.dart';
import 'package:neyam_vaani/data/services/knowledge/knowledge_service.dart';

void main() {
  group('KnowledgeService with injected inline loader', () {
    test('loads entries, searches in the asked language, answers by id', () async {
      int loaderCalls = 0;
      final KnowledgeService kb = KnowledgeService(
        sourceLoader: () async {
          loaderCalls++;
          return jsonEncode(<String, Object>{
            'documents': <Map<String, Object>>[
              <String, Object>{
                'id': 'emergency-numbers-en',
                'title': 'Emergency numbers',
                'lang': 'en',
                'text': '112 - national emergency number. 100 - police. '
                    '108 - free ambulance.',
                'tags': <String>['emergency', 'helpline'],
              },
              <String, Object>{
                'id': 'emergency-numbers-ta',
                'title': 'அவசர உதவி எண்கள்',
                'lang': 'ta',
                'text': '112 - தேசிய அவசர உதவி எண். 108 - இலவச ஆம்புலன்ஸ்.',
                'tags': <String>['emergency', 'helpline'],
              },
              <String, Object>{
                'id': 'health-fever-en',
                'title': 'Fever - basic guide',
                'lang': 'en',
                'text': 'Drink water and rest. This is not medical advice - '
                    'consult a doctor.',
                'tags': <String>['health'],
              },
            ],
          });
        },
      );

      final List<SearchHit> en = await kb.search('emergency', 'en');
      expect(en, isNotEmpty);
      expect(en.first.entry.id, 'emergency-numbers-en');
      expect(en.first.entry.text, contains('112'));
      expect(en.first.entry.lang, 'en');

      final List<SearchHit> ta = await kb.search('அவசர உதவி', 'ta');
      expect(ta.first.entry.id, 'emergency-numbers-ta');
      expect(ta.first.entry.lang, 'ta');

      expect(kb.get('emergency-numbers-ta')?.title, 'அவசர உதவி எண்கள்');
      expect(kb.get('missing-id'), isNull);

      // The index is built exactly once, however often we search.
      await kb.search('emergency', 'en');
      expect(loaderCalls, 1);
      expect(kb.isLoaded, isTrue);
    });

    test('honest empty answer for questions with no match', () async {
      final KnowledgeService kb = KnowledgeService(
        sourceLoader: () async => jsonEncode(<String, Object>{
          'documents': <Map<String, Object>>[
            <String, Object>{
              'id': 'a',
              'title': 'Apples',
              'lang': 'en',
              'text': 'Apples grow on trees.',
              'tags': <String>[],
            },
          ],
        }),
      );
      expect(await kb.search('zzzzyyyyxxxx', 'en'), isEmpty);
    });

    test('corrupt knowledge base fails loudly, not silently', () {
      expect(() => parseKbJson('{"nope": 1}'), throwsFormatException);
      expect(() => parseKbJson('[{"id": "x"}]'), throwsFormatException);
    });
  });

  group('bundled sample_kb.json (app/assets/knowledge)', () {
    // `flutter test` runs from app/, so the asset is readable as a file.
    final File asset = File('assets/knowledge/sample_kb.json');

    test('has 12+ entries across ta/hi/en in the pipeline schema', () {
      final List<KbEntry> entries = parseKbJson(asset.readAsStringSync());
      expect(entries.length, greaterThanOrEqualTo(12));
      final Set<String> langs = entries.map((KbEntry e) => e.lang).toSet();
      expect(langs, containsAll(<String>['ta', 'hi', 'en']));
      // Ids are unique (they key the embedding packs).
      expect(
        entries.map((KbEntry e) => e.id).toSet().length,
        entries.length,
      );
    });

    test('search("emergency") finds the 112 entry in the right language',
        () async {
      final KnowledgeService kb = KnowledgeService(
        sourceLoader: asset.readAsString,
      );
      final List<SearchHit> enHits = await kb.search('emergency', 'en');
      expect(enHits.first.entry.id, 'emergency-numbers-en');
      expect(enHits.first.entry.text, contains('112'));

      final List<SearchHit> taHits = await kb.search('அவசர உதவி', 'ta');
      expect(taHits.first.entry.id, 'emergency-numbers-ta');
      expect(taHits.first.entry.text, contains('112'));
    });

    test('health entries carry the consult-a-doctor disclaimer', () {
      final List<KbEntry> entries = parseKbJson(asset.readAsStringSync());
      final List<KbEntry> health = entries
          .where((KbEntry e) => e.tags.contains('health') && e.tags.contains('guide'))
          .toList();
      expect(health.length, 3); // one per language
      for (final KbEntry entry in health) {
        expect(
          entry.text.toLowerCase(),
          anyOf(<Matcher>[
            contains('doctor'),
            contains('மருத்துவர'),
            contains('डॉक्टर'),
          ]),
          reason: 'health guidance must defer to a doctor: ${entry.id}',
        );
      }
    });
  });
}
