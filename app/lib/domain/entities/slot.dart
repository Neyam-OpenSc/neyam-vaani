/// Slot values captured from a single utterance.
///
/// Slots are the bridge between what the user said and what the prompt
/// template or device action needs: recipient, time, tone, target
/// language... A [Slot] records *how* the value was obtained so later
/// turns (and the UI) can tell rules from guesses.
library;

/// How a slot value came to be.
enum SlotSource {
  /// Extracted by a deterministic rule (regex/keyword) in SlotExtractor.
  rule,

  /// Derived from the user's chosen language.
  language,

  /// Filled explicitly by the user (a later turn or the UI).
  user,

  /// Produced by the on-device LLM.
  llm,
}

/// Canonical slot names used across the intelligence layer.
///
/// These strings double as prompt placeholder keys (`{tone}`,
/// `{recipient_type}`, ...), so keep them in sync with the templates in
/// app/assets/prompts/.
abstract final class SlotNames {
  static const String recipient = 'recipient';
  static const String recipientType = 'recipient_type';
  static const String content = 'content';
  static const String time = 'time';
  static const String language = 'language';
  static const String sourceLanguage = 'source_language';
  static const String targetLanguage = 'target_language';
  static const String tone = 'tone';
  static const String expression = 'expression';
  static const String query = 'query';
  static const String locationType = 'location_type';
  static const String deviceAction = 'device_action';
}

/// One extracted value, e.g. `time = 2026-10-26T06:00`.
class Slot {
  const Slot({
    required this.name,
    required this.value,
    this.confidence = 1.0,
    this.source = SlotSource.rule,
  });

  /// One of [SlotNames] (or a feature-specific name).
  final String name;

  /// The extracted value, as a plain string.
  final String value;

  /// 0.0 to 1.0. Heuristic rules emit calibrated-ish values; treat
  /// anything below ~0.6 as "ask the user to confirm".
  final double confidence;

  /// Where the value came from.
  final SlotSource source;

  Slot copyWith({String? value, double? confidence, SlotSource? source}) {
    return Slot(
      name: name,
      value: value ?? this.value,
      confidence: confidence ?? this.confidence,
      source: source ?? this.source,
    );
  }

  /// Identity is name+value: the same fact from two paths is equal.
  @override
  bool operator ==(Object other) =>
      other is Slot && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);

  @override
  String toString() =>
      'Slot($name=$value @${(confidence * 100).toStringAsFixed(0)}%)';
}

/// An immutable set of slots for one turn, keyed by name.
class SlotSet {
  /// Builds a set from [slots]; a later slot with the same name wins.
  SlotSet(Iterable<Slot> slots)
      : _slots = <String, Slot>{
          for (final Slot slot in slots) slot.name: slot,
        };

  const SlotSet.empty() : _slots = const <String, Slot>{};

  final Map<String, Slot> _slots;

  bool get isEmpty => _slots.isEmpty;
  bool get isNotEmpty => _slots.isNotEmpty;
  int get length => _slots.length;

  /// The slots in this set (unmodifiable).
  List<Slot> get slots => List<Slot>.unmodifiable(_slots.values);

  /// Looks a slot up by name; `null` when absent.
  Slot? operator [](String name) => _slots[name];

  /// Returns a copy with [slot] added (replacing any same-named slot).
  SlotSet withSlot(Slot slot) => SlotSet(<Slot>[..._slots.values, slot]);

  // -- Typed getters for the common slots -------------------------------

  /// Who the request is for ("my boss", "amma", "மாமாவுக்கு").
  Slot? get recipient => this[SlotNames.recipient];

  /// Coarse recipient role the prompt templates understand
  /// (formal / family / friend / service).
  Slot? get recipientType => this[SlotNames.recipientType];

  /// The dictated body ("I will be late") or the text to process.
  Slot? get content => this[SlotNames.content];

  /// ISO-ish time from the utterance: `YYYY-MM-DD`, `HH:MM`, or
  /// `YYYY-MM-DDTHH:MM`.
  Slot? get time => this[SlotNames.time];

  /// The language a monolingual request refers to.
  Slot? get language => this[SlotNames.language];

  /// Translate: source language, when the user named one.
  Slot? get sourceLanguage => this[SlotNames.sourceLanguage];

  /// Translate/target output language.
  Slot? get targetLanguage => this[SlotNames.targetLanguage];

  /// formal / casual / apologetic / requesting / urgent.
  Slot? get tone => this[SlotNames.tone];

  /// Calculate: the normalized arithmetic expression ("25 * 48").
  Slot? get expression => this[SlotNames.expression];

  /// The raw question for Q&A-style intents.
  Slot? get query => this[SlotNames.query];

  /// findNearby: canonical place type (hospital, police, bank...).
  Slot? get locationType => this[SlotNames.locationType];

  /// Device toggle actions: on / off.
  Slot? get deviceAction => this[SlotNames.deviceAction];

  /// Name -> value mapping, ready for prompt substitution.
  Map<String, String> toValueMap() => <String, String>{
        for (final MapEntry<String, Slot> entry in _slots.entries)
          entry.key: entry.value.value,
      };

  @override
  bool operator ==(Object other) {
    if (other is! SlotSet) {
      return false;
    }
    if (other._slots.length != _slots.length) {
      return false;
    }
    for (final MapEntry<String, Slot> entry in _slots.entries) {
      if (other._slots[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(<String>[..._slots.keys]..sort());

  @override
  String toString() =>
      _slots.isEmpty ? 'SlotSet(empty)' : 'SlotSet(${_slots.keys.join(', ')})';
}
