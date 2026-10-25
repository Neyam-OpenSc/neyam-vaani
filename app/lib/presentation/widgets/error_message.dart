/// The kind error message (TENDER_UX_PRINCIPLES.md: "All errors are kind").
///
/// One plain sentence in the user's language, a quiet icon, an optional
/// "try again" — never an error code, never alarming colors, never a
/// raw message key on a user's screen.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';

/// A calm error: quiet icon, one sentence, optional retry button.
class ErrorMessage extends StatelessWidget {
  const ErrorMessage({
    super.key,
    required this.userMessageKey,
    this.langCode = 'en',
    this.retryLabelKey = 'tryAgain',
    this.onRetry,
  });

  /// Message key of the kind sentence, e.g. 'couldNotHear' or
  /// 'actionFailed' (see [failureToMessageKey]).
  final String userMessageKey;

  /// Language the message resolves in; unknown codes fall back to
  /// English inside [AppStrings.of].
  final String langCode;

  /// Message key of the retry button label.
  final String retryLabelKey;

  /// Called when the user taps retry. Omit to render no button.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = AppStrings.of(langCode);
    final ThemeData theme = Theme.of(context);
    final String message = strings.resolve(userMessageKey);
    final VoidCallback? retry = onRetry;

    return Semantics(
      liveRegion: true,
      label: message,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: 24,
            // Quiet outline tone — errors inform, they never alarm.
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurface),
          ),
          if (retry != null)
            TextButton(
              onPressed: retry,
              child: Text(strings.resolve(retryLabelKey)),
            ),
        ],
      ),
    );
  }
}

/// Maps a failure-kind word — `FailureKind.name` from
/// `core/errors/failures.dart`, e.g. `'modelLoad'` — to the message key
/// the user hears.
///
/// Deliberately tiny and in one place, so the whole app says the same
/// kind sentence for the same failure:
///
/// - `nativeLibrary`, `modelLoad`, `memoryPressure`, `timeout` →
///   `actionFailed` ("I couldn't do that. Can we try again?").
/// - anything else, including `unknown` → `iDontKnow` — honest
///   uncertainty beats a confident guess (TENDER_UX_PRINCIPLES.md).
String failureToMessageKey(String failureKind) {
  switch (failureKind) {
    case 'nativeLibrary':
    case 'modelLoad':
    case 'memoryPressure':
    case 'timeout':
      return 'actionFailed';
    default:
      return 'iDontKnow';
  }
}
