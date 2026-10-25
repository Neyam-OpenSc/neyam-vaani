import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';

/// Home screen: one giant, unmistakable action — talk to Vaani.
///
/// Tender UX: no feeds, no cards, no engagement hooks. Just voice, one
/// calm pulsing state, and a way to settings.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VoiceSessionState session = ref.watch(voiceSessionProvider);
    final bool listening = session is VoiceSessionListening ||
        session is VoiceSessionTranscribing;
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Vaani'), // TODO(l10n)
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings', // TODO(l10n)
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (listening) ...<Widget>[
              // Calm pulsing indicator: slow, quiet, never urgent.
              const _CalmPulse(
                child: Icon(Icons.graphic_eq_rounded, size: 28),
              ),
              const SizedBox(height: 16),
            ],
            Text(
              listening ? 'Listening…' : 'Talk to Vaani', // TODO(l10n)
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                listening
                    ? 'Tap the microphone when you are done.' // TODO(l10n)
                    : 'Tap the microphone and speak', // TODO(l10n)
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: const VoiceMicButton(),
    );
  }
}

/// The app's single primary action, shared with the conversation screen:
/// tap to talk, tap again to stop. Always carries a semantics label.
class VoiceMicButton extends ConsumerWidget {
  const VoiceMicButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VoiceSessionState session = ref.watch(voiceSessionProvider);
    final bool active = session is VoiceSessionListening ||
        session is VoiceSessionTranscribing;

    return Semantics(
      button: true,
      label: active ? 'Stop listening' : 'Start listening', // TODO(l10n)
      child: FloatingActionButton.large(
        tooltip: active ? 'Stop listening' : 'Start listening', // TODO(l10n)
        onPressed: () {
          final VoiceSessionNotifier notifier =
              ref.read(voiceSessionProvider.notifier);
          if (active) {
            unawaited(notifier.stopListening());
          } else {
            unawaited(notifier.startListening());
            context.go('/conversation');
          }
        },
        child: active
            ? const _CalmPulse(child: Icon(Icons.mic, size: 42))
            : const Icon(Icons.mic, size: 42),
      ),
    );
  }
}

/// A slow, gentle pulse — calm, never urgent (TENDER_UX_PRINCIPLES.md).
final class _CalmPulse extends StatefulWidget {
  const _CalmPulse({required this.child, this.duration = const Duration(milliseconds: 1600)});

  final Widget child;
  final Duration duration;

  @override
  State<_CalmPulse> createState() => _CalmPulseState();
}

final class _CalmPulseState extends State<_CalmPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration)
        ..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween<double>(begin: 0.88, end: 1.12).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
}
