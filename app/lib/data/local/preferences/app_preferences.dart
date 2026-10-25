/// Key-value preferences, kept on the device.
///
/// Preferences are **not** secrets: the production implementation is
/// plain `SharedPreferences` (or an unencrypted table next to the
/// SQLCipher database). Anything sensitive — the database key, contacts,
/// transcripts — never goes through here (PRIVACY_CHARTER.md).
library;

import '../../../core/constants.dart' show kDefaultLanguage;

/// String/boolean preferences: the language pin, TTS pace, retention.
abstract class AppPreferences {
  /// Reads a string; `null` when the key was never set.
  Future<String?> getString(String key);

  /// Writes a string.
  Future<void> setString(String key, String value);

  /// Reads a boolean; `null` when the key was never set.
  Future<bool?> getBool(String key);

  /// Writes a boolean.
  Future<void> setBool(String key, bool value);
}

/// The well-known preference keys.
abstract final class AppPreferencesKeys {
  /// BCP-47 code of the language the user pinned (constants.dart codes).
  static const String pinnedLanguage = 'pinned_language';

  /// TTS speech rate as a decimal string ('0.9').
  static const String ttsSpeed = 'tts_speed';

  /// Conversation-history retention, in days, as a decimal string ('30').
  static const String retentionDays = 'retention_days';
}

/// Defaults for the well-known keys, mirroring the charters.
abstract final class AppPreferenceDefaults {
  /// The user has not chosen yet: Tamil, the first priority language.
  static const String pinnedLanguage = kDefaultLanguage;

  /// Slightly slower than default — the charter's voice pace (~0.9x).
  static const double ttsSpeed = 0.9;

  /// PRIVACY_CHARTER.md: history is user-deletable, 30 days by default.
  static const int retentionDays = 30;
}

/// Map-backed [AppPreferences] for tests and first runs.
class InMemoryAppPreferences implements AppPreferences {
  final Map<String, String> _strings = <String, String>{};
  final Map<String, bool> _bools = <String, bool>{};

  @override
  Future<String?> getString(String key) async => _strings[key];

  @override
  Future<void> setString(String key, String value) async {
    _strings[key] = value;
  }

  @override
  Future<bool?> getBool(String key) async => _bools[key];

  @override
  Future<void> setBool(String key, bool value) async {
    _bools[key] = value;
  }
}
