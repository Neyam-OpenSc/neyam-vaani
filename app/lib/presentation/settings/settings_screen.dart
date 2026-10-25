import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../providers.dart';

/// Settings: language first, because language is identity here.
/// Phase 7+ adds: voice speed, language packs, data controls.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String selected = ref.watch(selectedLanguageProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')), // TODO(l10n)
      body: ListView(
        children: [
          const ListTile(
            title: Text('Your language'), // TODO(l10n)
            subtitle: Text('Used for listening and speaking'), // TODO(l10n)
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
          const ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Clear conversation history'), // TODO(l10n)
            subtitle: Text('Deletes everything, immediately'), // TODO(l10n)
            enabled: false, // arrives with Phase 5 (storage layer)
          ),
        ],
      ),
    );
  }
}
