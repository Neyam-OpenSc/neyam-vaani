import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants.dart';
import '../../l10n/app_strings.dart';
import '../providers.dart';

/// Home screen: one giant, unmistakable action — talk to Vaani.
///
/// Tender UX: no feeds, no cards, no engagement hooks. The breathing orb
/// carries the brand (the same mark as the website's voice visual); the
/// mic is the only loud element on the page.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final VoiceSessionState session = ref.watch(voiceSessionProvider);
    final bool listening = session is VoiceSessionListening ||
        session is VoiceSessionTranscribing;
    final ThemeData theme = Theme.of(context);
    final AppStrings strings =
        AppStrings.of(ref.watch(selectedLanguageProvider));
    final String language = ref.watch(selectedLanguageProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/logo.png',
                width: 34,
                height: 24,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 10),
            Text(strings.appName),
          ],
        ),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: strings.settingsTitle,
            onPressed: () => unawaited(context.push('/settings')),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const _VaaniOrb(active: false),
              const SizedBox(height: 28),
              Text(
                listening ? strings.listening : strings.talkToVaani,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(
                  listening
                      ? 'Tap the microphone when you are done.' // TODO(l10n)
                      : strings.tapAndSpeak,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
              const SizedBox(height: 20),
              // Your language, one tap away: language is identity here.
              ActionChip(
                avatar: const Icon(Icons.translate_rounded, size: 18),
                label: Text(
                  kLanguageEndonyms[language] ?? language,
                  style: theme.textTheme.titleSmall,
                ),
                tooltip: strings.yourLanguage,
                onPressed: () => unawaited(context.push('/settings')),
              ),
              const SizedBox(height: 24),
              // Typing is an equal way in, for phones without on-device voice.
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                onPressed: () => unawaited(context.push('/conversation')),
                icon: const Icon(Icons.keyboard_outlined),
                label: Text(strings.typeHere),
              ),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: const VoiceMicButton(),
    );
  }
}

/// The home screen's primary action: tap to talk (opens the
/// conversation), tap again to stop. Always carries a semantics label.
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
        elevation: active ? 6 : 3,
        tooltip: active ? 'Stop listening' : 'Start listening', // TODO(l10n)
        onPressed: () {
          final VoiceSessionNotifier notifier =
              ref.read(voiceSessionProvider.notifier);
          if (active) {
            unawaited(notifier.stopListening());
          } else {
            unawaited(notifier.startListening());
            unawaited(context.push('/conversation'));
          }
        },
        child: active
            ? const _CalmPulse(child: Icon(Icons.mic, size: 42))
            : const Icon(Icons.mic, size: 42),
      ),
    );
  }
}

/// Vaani's orb: a warm terracotta core with two slow ripples — the same
/// idea as the website's voice visual, quiet and unhurried. [active]
/// brightens the core and deepens the ripples while listening.
final class _VaaniOrb extends StatefulWidget {
  const _VaaniOrb({required this.active});

  final bool active;

  @override
  State<_VaaniOrb> createState() => _VaaniOrbState();
}

final class _VaaniOrbState extends State<_VaaniOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))
        ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool reducedMotion =
        MediaQuery.disableAnimationsOf(context);

    final Widget core = Container(
      width: 148,
      height: 148,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: <Color>[
            colors.primary.withValues(alpha: widget.active ? 1 : 0.92),
            colors.primary.withValues(alpha: 0.75),
          ],
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: colors.primary.withValues(alpha: 0.35),
            blurRadius: 34,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: const Icon(Icons.graphic_eq_rounded, size: 46, color: Colors.white),
    );

    if (reducedMotion) {
      return core;
    }

    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          for (final double delay in const <double>[0, 0.5])
            AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                final double t = (_controller.value + delay) % 1;
                return Container(
                  width: 148 + t * 64,
                  height: 148 + t * 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: colors.primary
                          .withValues(alpha: (1 - t) * 0.4),
                    ),
                  ),
                );
              },
            ),
          core,
        ],
      ),
    );
  }
}

/// A slow, gentle pulse — calm, never urgent (TENDER_UX_PRINCIPLES.md).
final class _CalmPulse extends StatefulWidget {
  const _CalmPulse({required this.child});

  final Widget child;

  @override
  State<_CalmPulse> createState() => _CalmPulseState();
}

final class _CalmPulseState extends State<_CalmPulse>
    with SingleTickerProviderStateMixin {
  static const Duration _period = Duration(milliseconds: 1600);

  late final AnimationController _controller =
      AnimationController(vsync: this, duration: _period)
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
