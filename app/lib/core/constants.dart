/// Core constants for Neyam Vaani.
library;

/// App display name.
const String kAppName = 'Neyam Vaani';

/// BCP-47-ish codes of the languages v1 supports, in priority order.
///
/// English is last on purpose: it is a secondary language, never the
/// default (see TENDER_UX_PRINCIPLES.md).
const List<String> kSupportedLanguages = [
  'ta', // Tamil
  'hi', // Hindi
  'bn', // Bengali
  'kn', // Kannada
  'te', // Telugu
  'mr', // Marathi
  'bho', // Bhojpuri
  'mai', // Maithili
  'en', // English (secondary)
];

/// Endonym for each language code, shown in the language picker.
const Map<String, String> kLanguageEndonyms = {
  'ta': 'தமிழ்',
  'hi': 'हिन्दी',
  'bn': 'বাংলা',
  'kn': 'ಕನ್ನಡ',
  'te': 'తెలుగు',
  'mr': 'मराठी',
  'bho': 'भोजपुरी',
  'mai': 'मैथिली',
  'en': 'English',
};

/// Default language until the user chooses one on first launch.
const String kDefaultLanguage = 'ta';
