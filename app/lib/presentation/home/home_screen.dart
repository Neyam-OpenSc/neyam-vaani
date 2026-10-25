import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';

/// Home screen: one giant, unmistakable action — talk to Vaani.
///
/// Tender UX: no feeds, no cards, no engagement hooks. Just voice.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String language = ref.watch(selectedLanguageProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vaani'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings', // TODO(l10n): localize in Phase 1
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Talk to Vaani', // TODO(l10n)
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Language: $language', // TODO(l10n)
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 32),
            // Phase 1 wires this to the voice input pipeline
            // (whisper.cpp + Silero VAD). For now it opens the
            // conversation placeholder.
            FloatingActionButton.large(
              onPressed: () => context.go('/conversation'),
              child: const Icon(Icons.mic, size: 42),
            ),
            const SizedBox(height: 16),
            const Text(
              'Tap and speak', // TODO(l10n)
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
