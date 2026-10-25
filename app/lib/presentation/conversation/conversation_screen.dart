import 'package:flutter/material.dart';

/// Conversation screen placeholder.
///
/// Phase 1 (voice input): streaming transcription display.
/// Phase 2 (voice output): spoken replies with instant interruption.
/// Phase 3 (LLM): streamed token display.
class ConversationScreen extends StatelessWidget {
  const ConversationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vaani')), // TODO(l10n)
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'The conversation screen arrives in Phase 1 — '
            'when you speak, what Vaani heard and said will appear here.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
