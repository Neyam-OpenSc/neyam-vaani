import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/home_screen.dart' show VoiceMicButton;
import '../providers.dart';

/// The conversation: what Vaani heard, what it is doing, what it said.
///
/// Tender UX: honest visuals (always show what was heard, for users with
/// partial hearing), honest states ("I'm thinking…" — no fake spinners),
/// and a way out at every step. No fake delays anywhere.
class ConversationScreen extends ConsumerWidget {
  const ConversationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VoiceSessionState session = ref.watch(voiceSessionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vaani'), // TODO(l10n)
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: const VoiceMicButton(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: switch (session) {
              VoiceSessionIdle() => const _EmptyState(
                  key: ValueKey<String>('idle'),
                ),
              VoiceSessionListening(:final partial) => _HeardPane(
                  key: const ValueKey<String>('listening'),
                  text: partial,
                  status: 'Listening…', // TODO(l10n)
                ),
              VoiceSessionTranscribing(:final partial) => _HeardPane(
                  key: const ValueKey<String>('transcribing'),
                  text: partial,
                  status: "I'm writing that down…", // TODO(l10n)
                ),
              VoiceSessionThinking(:final heard) => _ThinkingPane(
                  key: const ValueKey<String>('thinking'),
                  heard: heard,
                ),
              VoiceSessionSpeaking(:final text) => _SpeakingPane(
                  key: const ValueKey<String>('speaking'),
                  text: text,
                ),
            },
          ),
        ),
      ),
    );
  }
}

/// Kind empty state (TENDER_UX_PRINCIPLES.md: all states are kind).
final class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.mic_none_rounded,
            size: 56,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            'Tap the microphone and speak', // TODO(l10n)
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// What Vaani heard (live transcript hypothesis) plus an honest status.
final class _HeardPane extends StatelessWidget {
  const _HeardPane({super.key, required this.text, required this.status});

  final String text;
  final String status;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        // TODO(Phase 3): the streamed LLM reply renders here once the
        // orchestrator exists — grow it token by token under this same
        // layout; until then Vaani shows exactly what it heard, no more.
        Semantics(
          liveRegion: true,
          child: Text(
            status,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      ],
    );
  }
}

/// Transcript settled; waiting for the answer (Phase 3 wires the LLM).
final class _ThinkingPane extends ConsumerWidget {
  const _ThinkingPane({super.key, required this.heard});

  final String heard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Text(
                heard,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
            ),
          ),
        ),
        // Honest loading state: "I'm thinking…" — not a spinner that lies.
        Semantics(
          liveRegion: true,
          child: Text(
            "I'm thinking…", // TODO(l10n)
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
        const SizedBox(height: 16),
        // Tender UX: always offer a way out, even while thinking.
        TextButton(
          onPressed: () =>
              unawaited(ref.read(voiceSessionProvider.notifier).endSession()),
          child: const Text('Stop'), // TODO(l10n)
        ),
      ],
    );
  }
}

/// Vaani speaking; instantly interruptible.
final class _SpeakingPane extends ConsumerWidget {
  const _SpeakingPane({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: () => unawaited(
            ref.read(voiceSessionProvider.notifier).stopSpeaking(),
          ),
          icon: const Icon(Icons.stop_rounded),
          label: const Text('Stop'), // TODO(l10n)
        ),
      ],
    );
  }
}
