import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/core/constants.dart';

void main() {
  group('supported languages', () {
    test('every language has an endonym', () {
      for (final String code in kSupportedLanguages) {
        expect(kLanguageEndonyms, contains(code));
        expect(kLanguageEndonyms[code], isNotEmpty);
      }
    });

    test('default language is valid and vernacular (not English)', () {
      expect(kSupportedLanguages, contains(kDefaultLanguage));
      expect(kDefaultLanguage, isNot('en'));
    });

    test('9 languages at parity are listed', () {
      expect(kSupportedLanguages.length, 9);
    });
  });
}
