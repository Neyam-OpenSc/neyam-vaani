/// The v1 intent vocabulary.
///
/// These 20 intents are the entire v1 scope — everything else is out of
/// scope by decision (docs/use-cases.md, "Top 20 use cases"). The [id]
/// strings are stable: they name the training-data files
/// (app/assets/training_data/intents/<id>.jsonl) and appear verbatim in
/// the LLM meta-classification prompt. Never rename an id.
library;

/// Everything the assistant can be asked to do in v1.
enum VaaniIntent {
  /// Voice-search a question, get a spoken answer.
  answerQuestion('answer_question'),

  /// Dictate a WhatsApp/SMS message.
  draftMessage('draft_message'),

  /// Read aloud a document (PDF/photo of paper).
  readDocument('read_document'),

  /// Set a reminder / alarm.
  setReminder('set_reminder'),

  /// Make a call by voice.
  makeCall('make_call'),

  /// Calculate something (math, currency, units).
  calculate('calculate'),

  /// Translate between two vernacular languages.
  translate('translate'),

  /// Fill a form by voice (govt, school forms).
  fillForm('fill_form'),

  /// Ask about local market / commodity prices.
  marketPrice('market_price'),

  /// Get weather / news summary.
  weatherNews('weather_news'),

  /// Draft a formal letter (leave application, complaint).
  draftLetter('draft_letter'),

  /// Practice English conversation.
  practiceEnglish('practice_english'),

  /// Read a medicine label and explain dosage.
  explainMedicine('explain_medicine'),

  /// Schedule appointment (basic calendar).
  scheduleAppointment('schedule_appointment'),

  /// Convert voice to text and copy anywhere.
  copyText('copy_text'),

  /// Ask "how do I…" questions (cooking, repairs).
  howToQuestion('how_to_question'),

  /// Voice-controlled flashlight / torch.
  torchControl('torch_control'),

  /// Find a nearby hospital / police station / bank...
  findNearby('find_nearby'),

  /// Send location to family by voice.
  sendLocation('send_location'),

  /// Hear today's date / time / day in their language.
  dateTime('date_time');

  const VaaniIntent(this.id);

  /// Stable snake_case id from docs/use-cases.md. Also the JSONL training
  /// file name (without extension).
  final String id;

  static final Map<String, VaaniIntent> _byId = <String, VaaniIntent>{
    for (final VaaniIntent intent in VaaniIntent.values) intent.id: intent,
  };

  /// Looks an intent up by its snake_case id; `null` when unknown.
  static VaaniIntent? fromId(String id) => _byId[id];
}

/// Working display names for logs, tests and debug screens.
extension VaaniIntentDisplay on VaaniIntent {
  static const Map<VaaniIntent, String> _displayNames = <VaaniIntent, String>{
    VaaniIntent.answerQuestion: 'Answer a question',
    VaaniIntent.draftMessage: 'Draft a message',
    VaaniIntent.readDocument: 'Read a document aloud',
    VaaniIntent.setReminder: 'Set a reminder',
    VaaniIntent.makeCall: 'Make a call',
    VaaniIntent.calculate: 'Calculate',
    VaaniIntent.translate: 'Translate',
    VaaniIntent.fillForm: 'Fill a form',
    VaaniIntent.marketPrice: 'Check market price',
    VaaniIntent.weatherNews: 'Weather or news summary',
    VaaniIntent.draftLetter: 'Draft a formal letter',
    VaaniIntent.practiceEnglish: 'Practice English',
    VaaniIntent.explainMedicine: 'Explain a medicine label',
    VaaniIntent.scheduleAppointment: 'Schedule an appointment',
    VaaniIntent.copyText: 'Copy text',
    VaaniIntent.howToQuestion: 'How-to question',
    VaaniIntent.torchControl: 'Torch on or off',
    VaaniIntent.findNearby: 'Find a nearby place',
    VaaniIntent.sendLocation: 'Send location',
    VaaniIntent.dateTime: 'Date and time',
  };

  /// Short English working label. User-facing names come from l10n,
  /// keyed by intent id — never from this getter.
  String get displayName => _displayNames[this] ?? id;
}

/// A classifier verdict: the best intent plus how sure the classifier is.
///
/// This is the domain-level shape; the richer [IntentClassification]
/// returned by the data-layer classifier is a subtype of it.
class IntentPrediction {
  const IntentPrediction({required this.intent, this.confidence = 0});

  /// The best-guess intent. Always present — when [confidence] is low the
  /// orchestrator decides whether to escalate to the LLM fallback.
  final VaaniIntent intent;

  /// 0.0 to 1.0.
  final double confidence;

  @override
  String toString() =>
      'IntentPrediction(${intent.id}, ${(confidence * 100).toStringAsFixed(0)}%)';
}
