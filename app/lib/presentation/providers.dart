import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';

/// The language the user has chosen for voice and UI.
///
/// Phase 1 replaces the default with on-device language detection
/// (see docs/architecture.md, voice input pipeline).
final StateProvider<String> selectedLanguageProvider =
    StateProvider<String>((ref) => kDefaultLanguage);
