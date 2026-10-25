import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/data/services/translation/translation_service.dart';

void main() {
  // Constructed with no engine: on a dev machine/test runner there is no
  // libnllb_bridge.so, so the FFI probe fails and the service must fall
  // back to the dev-only offline dictionary — that graceful path is part
  // of what these tests pin.
  final TranslationService translator = TranslationService();

  group('OfflineDictionaryFallback via TranslationService (dev-only engine)', () {
    test('translates basic phrases ta -> en and ta -> hi', () async {
      final TranslationResult toEn = await translator.translate('வணக்கம்', 'ta', 'en');
      expect(toEn.ok, isTrue, reason: toEn.message ?? '');
      expect(toEn.text, 'hello');
      expect(toEn.engine, 'offline-dictionary');

      final TranslationResult toHi = await translator.translate('நன்றி', 'ta', 'hi');
      expect(toHi.ok, isTrue);
      expect(toHi.text, 'धन्यवाद');
      expect(toHi.engine, 'offline-dictionary');
    });

    test('translates basic phrases en -> ta and hi -> ta', () async {
      expect((await translator.translate('thank you', 'en', 'ta')).text, 'நன்றி');
      expect((await translator.translate('नमस्ते', 'hi', 'ta')).text, 'வணக்கம்');
    });

    test('unknown phrase is an honest failure, never a guess', () async {
      final TranslationResult result =
          await translator.translate('quantum entanglement of millets', 'en', 'ta');
      expect(result.ok, isFalse);
      expect(result.errorKind, TranslationErrorKind.phraseNotInOfflineDictionary);
      // No fabricated output ships to the user.
      expect(result.text, '');
    });

    test('unsupported language pair fails with the right kind', () async {
      final TranslationResult result = await translator.translate('hello', 'en', 'fr');
      expect(result.ok, isFalse);
      expect(result.errorKind, TranslationErrorKind.unsupportedLanguage);
    });

    test('empty input is rejected, same-language input is identity', () async {
      expect(
        (await translator.translate('   ', 'ta', 'en')).errorKind,
        TranslationErrorKind.invalidInput,
      );
      final TranslationResult same =
          await translator.translate('வணக்கம்', 'ta', 'ta');
      expect(same.ok, isTrue);
      expect(same.text, 'வணக்கம்');
      expect(same.engine, 'identity');
    });
  });

  group('in-memory translation cache', () {
    test('a repeat translation is served from cache, identical result',
        () async {
      translator.clearCache();
      expect(translator.cacheSize, 0);

      final TranslationResult first = await translator.translate('hello', 'en', 'ta');
      expect(translator.cacheSize, 1);
      expect(translator.cacheHits, 0);

      final TranslationResult second = await translator.translate('hello', 'en', 'ta');
      expect(translator.cacheHits, 1);
      // LRU hits return the very same result object — identical, not equal.
      expect(identical(first, second), isTrue);
      expect(second.text, first.text);
    });

    test('failures are cached too (same honest answer every time)', () async {
      translator.clearCache();
      final TranslationResult first =
          await translator.translate('not a known phrase', 'en', 'hi');
      final TranslationResult second =
          await translator.translate('not a known phrase', 'en', 'hi');
      expect(identical(first, second), isTrue);
      expect(second.ok, isFalse);
    });

    test('cache holds at most N translations (LRU eviction)', () async {
      final TranslationService small = TranslationService(cacheCapacity: 2);
      await small.translate('hello', 'en', 'ta');
      await small.translate('thank you', 'en', 'ta');
      expect(small.cacheSize, 2);
      await small.translate('water', 'en', 'ta');
      expect(small.cacheSize, 2);
      expect(small.cacheHits, 0);
      // 'hello' was evicted: this is a fresh (uncached) translation.
      await small.translate('hello', 'en', 'ta');
      expect(small.cacheHits, 0);
      expect(small.cacheSize, 2);
    });
  });
}
