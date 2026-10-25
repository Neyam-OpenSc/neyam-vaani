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

class VaaniApp extends StatelessWidget {
  const VaaniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: kAppName,
      // Terracotta brand seed color; see assets/logo.png
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFC05621),
      ),
      routerConfig: _router,
    );
  }
}
