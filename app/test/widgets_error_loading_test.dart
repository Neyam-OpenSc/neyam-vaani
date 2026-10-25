import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/l10n/app_strings.dart';
import 'package:neyam_vaani/presentation/widgets/error_message.dart';
import 'package:neyam_vaani/presentation/widgets/loading_states.dart';

void main() {
  group('ErrorMessage', () {
    testWidgets('unknown key falls back to English; retry invokes callback',
        (WidgetTester tester) async {
      bool retried = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ErrorMessage(
                userMessageKey: 'no.such.key',
                langCode: 'ta',
                onRetry: () {
                  retried = true;
                },
              ),
            ),
          ),
        ),
      );

      // Unknown key -> the calm English fallback sentence. Never blank,
      // never a raw key on the user's screen.
      expect(find.text(AppStrings.of('en').actionFailed), findsOneWidget);

      final Finder retry = find.byType(TextButton);
      expect(retry, findsOneWidget);
      expect(find.text(AppStrings.of('ta').tryAgain), findsOneWidget);

      await tester.tap(retry);
      expect(retried, isTrue);
    });

    testWidgets('renders the localized message without a retry button',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: ErrorMessage(
                userMessageKey: 'couldNotHear',
                langCode: 'ta',
              ),
            ),
          ),
        ),
      );

      expect(find.text(AppStrings.of('ta').couldNotHear), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('loading states', () {
    testWidgets('ThinkingLabel renders the localized thinking string',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: ThinkingLabel(langCode: 'ta'))),
        ),
      );

      expect(find.text(AppStrings.of('ta').thinking), findsOneWidget);
    });

    testWidgets('ListeningIndicator renders static and labeled when the OS '
        'asks for reduced motion', (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      const bool reduceMotion = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: Center(child: ListeningIndicator(langCode: 'ta')),
            ),
          ),
        ),
      );

      expect(find.byType(ListeningIndicator), findsOneWidget);
      expect(
        find.bySemanticsLabel(AppStrings.of('ta').listening),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('SpeakingIndicator renders static and labeled under '
        'disableAnimations', (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      const bool reduceMotion = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(disableAnimations: reduceMotion),
              child: Center(child: SpeakingIndicator(langCode: 'hi')),
            ),
          ),
        ),
      );

      expect(find.byType(SpeakingIndicator), findsOneWidget);
      expect(
        find.bySemanticsLabel(AppStrings.of('hi').speaking),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });
}
