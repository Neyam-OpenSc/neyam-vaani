import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/constants.dart';
import 'presentation/conversation/conversation_screen.dart';
import 'presentation/home/home_screen.dart';
import 'presentation/settings/settings_screen.dart';

final GoRouter _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/conversation',
      builder: (context, state) => const ConversationScreen(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
  ],
);

/// Vaani's look: warm terracotta, calm surfaces, generous type.
/// The same palette as the project website (see website/style.css).
class VaaniApp extends StatelessWidget {
  const VaaniApp({super.key});

  static const Color _seed = Color(0xFF9C4118);

  /// Indian scripts render from the platform's Noto fonts; the fallback
  /// keeps mixed-script replies (Tamil + digits, Devanagari + Latin) tidy.
  static const List<String> _scriptFonts = <String>[
    'Noto Sans Devanagari',
    'Noto Sans Tamil',
    'Noto Sans Bengali',
    'Noto Sans Kannada',
    'Noto Sans Telugu',
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: _seed,
      fontFamilyFallback: _scriptFonts,
    );
    return MaterialApp.router(
      title: kAppName,
      theme: base.copyWith(
        visualDensity: VisualDensity.comfortable,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: ZoomPageTransitionsBuilder(),
          },
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: _seed,
        brightness: Brightness.dark,
        fontFamilyFallback: _scriptFonts,
      ),
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
  }
}
