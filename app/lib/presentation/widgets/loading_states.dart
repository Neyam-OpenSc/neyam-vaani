/// Calm loading states (TENDER_UX_PRINCIPLES.md: "All loading states are
/// honest" — and none of them flash).
///
/// Three widgets for the voice session's honest states: listening
/// (one softly pulsing dot), thinking (localized text, no spinner that
/// lies), speaking (three gently waving bars). All carry localized
/// semantics labels, all honor `MediaQuery.disableAnimations` by
/// rendering static — the OS "remove animations" setting is respected.
library;

import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';

/// A single softly pulsing dot while Vaani listens.
///
/// One slow breath (about 2.4s per cycle) — never a rapid flash, for
/// photosensitivity and calm alike.
class ListeningIndicator extends StatefulWidget {
  const ListeningIndicator({super.key, this.langCode = 'en'});

  /// Language of the accessibility label.
  final String langCode;

  @override
  State<ListeningIndicator> createState() => _ListeningIndicatorState();
}

class _ListeningIndicatorState extends State<ListeningIndicator>
    with SingleTickerProviderStateMixin {
  AnimationController? _pulse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool animationsDisabled =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (animationsDisabled) {
      _disposePulse();
      return;
    }
    _pulse ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      reverseDuration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  void _disposePulse() {
    _pulse?.dispose();
    _pulse = null;
  }

  @override
  void dispose() {
    _disposePulse();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(widget.langCode);
    final Color dotColor = Theme.of(context).colorScheme.primary;
    final AnimationController? pulse = _pulse;

    Widget dot = Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
    );
    if (pulse != null) {
      final Animation<double> scale = pulse
          .drive(const CurveTween(curve: Curves.easeInOut))
          .drive(const Tween<double>(begin: 1.0, end: 1.35));
      dot = ScaleTransition(scale: scale, child: dot);
    }

    return Semantics(
      label: strings.listening,
      liveRegion: true,
      child: SizedBox(width: 40, height: 40, child: Center(child: dot)),
    );
  }
}

/// The honest thinking state: localized "I'm thinking…" text — not a
/// spinner, not a fake delay (TENDER_UX_PRINCIPLES.md).
class ThinkingLabel extends StatelessWidget {
  const ThinkingLabel({super.key, this.langCode = 'en'});

  /// Language of the label.
  final String langCode;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(langCode);
    final ThemeData theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Text(
        strings.thinking,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyLarge
            ?.copyWith(color: theme.colorScheme.outline),
      ),
    );
  }
}

/// Three gently waving bars while Vaani speaks.
///
/// One slow, staggered wave (about 3.6s per cycle) with ease-in-out
/// heights — bar heights only, never opacity flicker, so nothing
/// approaches the three-flashes threshold (WCAG 2.3.1).
class SpeakingIndicator extends StatefulWidget {
  const SpeakingIndicator({super.key, this.langCode = 'en'});

  /// Language of the accessibility label.
  final String langCode;

  @override
  State<SpeakingIndicator> createState() => _SpeakingIndicatorState();
}

class _SpeakingIndicatorState extends State<SpeakingIndicator>
    with SingleTickerProviderStateMixin {
  static const List<double> _barHeights = <double>[14, 22, 18];
  static const double _barWidth = 6;
  static const double _maxHeight = 34;

  AnimationController? _wave;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool animationsDisabled =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (animationsDisabled) {
      _disposeWave();
      return;
    }
    _wave ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
      reverseDuration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  void _disposeWave() {
    _wave?.dispose();
    _wave = null;
  }

  @override
  void dispose() {
    _disposeWave();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(widget.langCode);
    final Color barColor = Theme.of(context).colorScheme.primary;
    final AnimationController? wave = _wave;

    return Semantics(
      label: strings.speaking,
      liveRegion: true,
      child: SizedBox(
        height: 40,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (int i = 0; i < _barHeights.length; i++)
              _bar(i, barColor, wave),
          ],
        ),
      ),
    );
  }

  Widget _bar(int index, Color color, AnimationController? wave) {
    final double baseHeight = _barHeights[index];

    Widget bar({
      required double height,
      EdgeInsetsGeometry margin = const EdgeInsets.symmetric(horizontal: 3),
    }) {
      return Container(
        width: _barWidth,
        height: height,
        margin: margin,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
      );
    }

    if (wave == null) {
      return bar(height: baseHeight); // Reduced motion: calm and static.
    }
    // Each bar rides a slightly later slice of the same slow wave.
    final Animation<double> phase = wave
        .drive(
          CurveTween(
            curve: Interval(
              0.15 * index,
              0.45 + 0.15 * index,
              curve: Curves.easeInOut,
            ),
          ),
        )
        .drive(Tween<double>(begin: baseHeight, end: _maxHeight));
    return AnimatedBuilder(
      animation: phase,
      builder: (BuildContext context, Widget? child) =>
          bar(height: lerpDouble(baseHeight, _maxHeight, phase.value)!),
    );
  }
}
