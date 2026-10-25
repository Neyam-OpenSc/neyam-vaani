import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/core/constants.dart';
import 'package:neyam_vaani/l10n/app_strings.dart';

void main() {
  group('table completeness', () {
    test('every supported language has a string table', () {
      for (final String code in kSupportedLanguages) {
        expect(
          AppStrings.table,
          contains(code),
          reason: '$code has no string table',
        );
        expect(AppStrings.table[code], isNotNull);
        expect(AppStrings.table[code], isNotEmpty);
      }
    });

    test('every non-English table has exactly the English key set', () {
      final Set<String> englishKeys = AppStrings.table['en']!.keys.toSet();
      expect(englishKeys, isNotEmpty);
      for (final MapEntry<String, Map<String, String>> entry
          in AppStrings.table.entries) {
        if (entry.key == 'en') {
          continue;
        }
        final Set<String> keys = entry.value.keys.toSet();
        expect(
          keys,
          equals(englishKeys),
          reason:
              '${entry.key} must carry the exact English key set — missing: '
              '${englishKeys.difference(keys).toList()} / extra: '
              '${keys.difference(englishKeys).toList()}',
        );
      }
    });

    test('every value in every table is non-empty', () {
      for (final MapEntry<String, Map<String, String>> entry
          in AppStrings.table.entries) {
        for (final MapEntry<String, String> pair in entry.value.entries) {
          expect(
            pair.value,
            isNotEmpty,
            reason: '${entry.key}.${pair.key} is empty — a grandmother '
                'must never see a blank screen',
          );
        }
      }
    });
  });

  group('spot checks (steward-owned exactness)', () {
    test('Tamil settings title is the Tamil-script string', () {
      expect(AppStrings.of('ta').settingsTitle, 'அமைப்புகள்');
    });

    test('Hindi app name is the Devanagari string', () {
      expect(AppStrings.of('hi').appName, 'नेयम वाणी');
    });
  });

  group('fallbacks', () {
    test('an unknown language code falls back to English', () {
      expect(AppStrings.of('xx').appName, 'Neyam Vaani');
      expect(AppStrings.of('zz-unknown').settingsTitle, 'Settings');
    });

    test('an unknown key resolves to the calm English fallback sentence',
        () {
      expect(
        AppStrings.of('ta').resolve('no.such.key'),
        AppStrings.of('en').actionFailed,
      );
    });
  });
}
