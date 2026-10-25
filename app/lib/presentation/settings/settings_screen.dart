import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../l10n/app_strings.dart';
import '../providers.dart';

/// Settings: language first, because language is identity here.
/// Phase 7+ adds: voice speed, language packs, data controls.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String selected = ref.watch(selectedLanguageProvider);
    final AppStrings strings = AppStrings.of(selected);

    return Scaffold(
      appBar: AppBar(title: Text(strings.settingsTitle)),
      body: ListView(
        children: <Widget>[
          ListTile(
            title: Text(strings.yourLanguage),
            subtitle: Text(strings.languageSubtitle),
          ),
          for (final String code in kSupportedLanguages)
            ListTile(
              selected: selected == code,
              title: Text(kLanguageEndonyms[code] ?? code),
              trailing:
                  selected == code ? const Icon(Icons.check_rounded) : null,
              onTap: () {
                ref.read(selectedLanguageProvider.notifier).state = code;
              },
            ),
          const Divider(),
          // Tender UX: data controls are always 3 taps away, never buried.
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(strings.clearHistory),
            subtitle: Text(strings.clearHistoryDesc),
            enabled: false, // arrives with Phase 5 (storage layer)
          ),
        ],
      ),
    );
  }
}
