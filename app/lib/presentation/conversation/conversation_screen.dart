import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_strings.dart';
import '../providers.dart';

/// The conversation: what the user said, what Vaani answered, and what
/// Vaani is doing right now.
///
/// Tender UX: honest visuals (always show what was heard, for users with
/// partial hearing), honest states ("I'm thinking…" — no fake spinners),
/// a way out at every step, and typing as an equal to speaking.
class ConversationScreen extends ConsumerStatefulWidget {
  const ConversationScreen({super.key});

  @override
  ConsumerState<ConversationScreen> createState() =>
      _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final String text = _input.text.trim();
    if (text.isEmpty) {
      return;
    }
    _input.clear();
    unawaited(ref.read(voiceSessionProvider.notifier).ask(text));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        unawaited(_scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final VoiceSessionState session = ref.watch(voiceSessionProvider);
    final List<ChatTurn> turns = ref.watch(conversationProvider);
    final AppStrings strings =
        AppStrings.of(ref.watch(selectedLanguageProvider));
    ref.listen<List<ChatTurn>>(conversationProvider, (_, __) => _scrollToEnd());
    ref.listen<VoiceSessionState>(voiceSessionProvider, (_, __) => _scrollToEnd());

    return Scaffold(
      appBar: AppBar(title: Text(strings.appName)),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: turns.isEmpty && session is VoiceSessionIdle
                  ? _EmptyState(text: strings.tapAndSpeak)
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      children: <Widget>[
                        for (final ChatTurn turn in turns) _Bubble(turn: turn),
                        if (session case VoiceSessionListening(:final String partial)
                            when partial.isNotEmpty)
                          _Bubble(turn: ChatTurn.user(partial), draft: true),
                        if (session case VoiceSessionTranscribing(:final String partial)
                            when partial.isNotEmpty)
                          _Bubble(turn: ChatTurn.user(partial), draft: true),
                      ],
                    ),
            ),
            _StatusLine(session: session, strings: strings),
            _InputBar(
              controller: _input,
              session: session,
              strings: strings,
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }
}

/// Kind empty state (TENDER_UX_PRINCIPLES.md: all states are kind).
final class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
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
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// One message. The user's words sit on the right, Vaani's on the left;
/// [draft] marks a live, not-yet-final transcript.
final class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn, this.draft = false});

  final ChatTurn turn;
  final bool draft;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool mine = turn.fromUser;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: mine ? colors.primaryContainer : colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            turn.text,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: mine
                      ? colors.onPrimaryContainer
                      : colors.onSurfaceVariant,
                  fontStyle: draft ? FontStyle.italic : FontStyle.normal,
                  height: 1.4,
                ),
          ),
        ),
      ),
    );
  }
}

/// What Vaani is doing right now, with a way out of it.
final class _StatusLine extends ConsumerWidget {
  const _StatusLine({required this.session, required this.strings});

  final VoiceSessionState session;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VoiceSessionNotifier notifier =
        ref.read(voiceSessionProvider.notifier);
    final (String? status, VoidCallback? onStop) = switch (session) {
      VoiceSessionIdle() => (null, null),
      VoiceSessionListening() => (strings.listening, null),
      VoiceSessionTranscribing() => (strings.transcribing, null),
      VoiceSessionThinking() => (
          strings.thinking,
          () => unawaited(notifier.endSession()),
        ),
      VoiceSessionSpeaking() => (
          strings.speaking,
          () => unawaited(notifier.stopSpeaking()),
        ),
    };
    if (status == null) {
      return const SizedBox.shrink();
    }
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                status,
                style: theme.textTheme.bodyLarge
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ),
          if (onStop != null)
            TextButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Stop'), // TODO(l10n)
            ),
        ],
      ),
    );
  }
}

/// Type or talk: a text field, a send button and the microphone.
final class _InputBar extends ConsumerWidget {
  const _InputBar({
    required this.controller,
    required this.session,
    required this.strings,
    required this.onSend,
  });

  final TextEditingController controller;
  final VoiceSessionState session;
  final AppStrings strings;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool listening = session is VoiceSessionListening ||
        session is VoiceSessionTranscribing;
    final VoiceSessionNotifier notifier =
        ref.read(voiceSessionProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              style: Theme.of(context).textTheme.titleMedium,
              decoration: InputDecoration(
                hintText: strings.typeHere,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            iconSize: 28,
            tooltip: strings.send,
            onPressed: onSend,
            icon: const Icon(Icons.send_rounded),
          ),
          const SizedBox(width: 4),
          Semantics(
            button: true,
            label: listening ? 'Stop listening' : 'Start listening', // TODO(l10n)
            child: IconButton.filled(
              iconSize: 32,
              tooltip: listening ? 'Stop listening' : 'Start listening', // TODO(l10n)
              onPressed: () => unawaited(
                listening ? notifier.stopListening() : notifier.startListening(),
              ),
              icon: Icon(listening ? Icons.stop_rounded : Icons.mic),
            ),
          ),
        ],
      ),
    );
  }
}
