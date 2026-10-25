/// Intent classification over the seed training data.
///
/// Pure, offline, fast: normalized token overlap with IDF weighting
/// across the JSONL phrases in app/assets/training_data/intents/
/// (one file per intent id, >= 12 natural phrases each, mixed languages).
/// No ONNX, no native code — this must run in under ~200ms on a
/// low-end phone and inside plain unit tests.
///
/// Scoring per example, best example wins per intent:
/// - exact normalized match                -> 1.0
/// - every example token present (subset)  -> 0.85 (strong containment)
/// - otherwise IDF-weighted Jaccard        -> < 1.0
///
/// A confidence below [llmFallbackThreshold] is not an error: the caller
/// (OrchestrateUserRequest) escalates to the LLM meta-classifier. The
/// escalation itself never happens inside this class — the classifier
/// stays synchronous and deterministic.
///
/// Note for wiring: the JSONL assets are read by the app layer and handed
/// to [IntentClassifier.fromJsonl] as raw lines; this file does no I/O.
library;

import 'dart:convert' show jsonDecode;
import 'dart:math' show log;

import '../../../domain/entities/intent.dart';
import '../../../domain/usecases/orchestrate_user_request.dart'
    show IntentClassifying;

/// One training phrase from a JSONL file.
class IntentTrainingPhrase {
  const IntentTrainingPhrase({required this.text, required this.lang});

  /// The utterance, in its native script.
  final String text;

  /// Language code ('ta', 'hi', 'bn', 'kn', 'te', 'mr', 'bho', 'mai', 'en').
  final String lang;

  /// Parses one JSONL line: `{"text": "...", "lang": "ta"}`.
  ///
  /// Throws [FormatException] on invalid JSON or missing/empty fields.
  factory IntentTrainingPhrase.fromJsonLine(String line) {
    final Object? decoded = jsonDecode(line);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSONL line must be a JSON object');
    }
    final Object? text = decoded['text'];
    final Object? lang = decoded['lang'];
    if (text is! String || text.trim().isEmpty) {
      throw const FormatException(
        'JSONL line must have a non-empty string field "text"',
      );
    }
    if (lang is! String || lang.trim().isEmpty) {
      throw const FormatException(
        'JSONL line must have a non-empty string field "lang"',
      );
    }
    return IntentTrainingPhrase(text: text, lang: lang);
  }

  /// Like [fromJsonLine] but returns `null` instead of throwing.
  static IntentTrainingPhrase? tryFromJsonLine(String line) {
    try {
      return IntentTrainingPhrase.fromJsonLine(line);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'IntentTrainingPhrase($lang: $text)';
}

/// The classifier's verdict: best intent, confidence, and the full score
/// table for debugging (on-device only).
class IntentClassification extends IntentPrediction {
  const IntentClassification({
    required super.intent,
    required super.confidence,
    this.scores = const <VaaniIntent, double>{},
  });

  /// Per-intent best example score. Never leaves the device.
  final Map<VaaniIntent, double> scores;

  /// True when the orchestrator should ask the LLM to re-decide.
  bool get needsLlmFallback => confidence < IntentClassifier.llmFallbackThreshold;

  @override
  String toString() =>
      'IntentClassification(${intent.id}, ${(confidence * 100).toStringAsFixed(0)}%)';
}

/// Token-overlap + IDF classifier over the seed phrases.
class IntentClassifier implements IntentClassifying {
  /// Below this confidence the turn escalates to LLM meta-classification
  /// (docs/architecture.md, step 4).
  static const double llmFallbackThreshold = 0.6;

  /// Score for "every training token appears in the utterance".
  static const double _containmentConfidence = 0.85;

  IntentClassifier(Map<VaaniIntent, List<IntentTrainingPhrase>> trainingData)
      : _examples = <VaaniIntent, List<_TrainingExample>>{
          for (final MapEntry<VaaniIntent, List<IntentTrainingPhrase>> entry
              in trainingData.entries)
            if (entry.value.isNotEmpty)
              entry.key: <_TrainingExample>[
                for (final IntentTrainingPhrase phrase in entry.value)
                  _TrainingExample(phrase.text),
              ],
        } {
    _buildStatistics();
  }

  /// Builds a classifier from raw JSONL lines keyed by intent id.
  /// Blank and invalid lines are skipped; unknown intent ids are ignored.
  factory IntentClassifier.fromJsonl(Map<String, List<String>> jsonlByIntentId) {
    final Map<VaaniIntent, List<IntentTrainingPhrase>> data =
        <VaaniIntent, List<IntentTrainingPhrase>>{};
    for (final MapEntry<String, List<String>> entry
        in jsonlByIntentId.entries) {
      final VaaniIntent? intent = VaaniIntent.fromId(entry.key);
      if (intent == null) {
        continue;
      }
      final List<IntentTrainingPhrase> phrases = <IntentTrainingPhrase>[];
      for (final String line in entry.value) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        final IntentTrainingPhrase? phrase =
            IntentTrainingPhrase.tryFromJsonLine(trimmed);
        if (phrase != null) {
          phrases.add(phrase);
        }
      }
      data[intent] = phrases;
    }
    return IntentClassifier(data);
  }

  final Map<VaaniIntent, List<_TrainingExample>> _examples;

  late final Map<String, double> _idf;
  late final int _exampleCount;
  late final double _maxIdf;

  /// Total number of training phrases absorbed.
  int get phraseCount => _exampleCount;

  /// Number of training phrases per intent (for corpus health checks).
  Map<VaaniIntent, int> get phraseCounts => <VaaniIntent, int>{
        for (final MapEntry<VaaniIntent, List<_TrainingExample>> entry
            in _examples.entries)
          entry.key: entry.value.length,
      };

  void _buildStatistics() {
    final Map<String, int> documentFrequency = <String, int>{};
    int count = 0;
    for (final List<_TrainingExample> examples in _examples.values) {
      for (final _TrainingExample example in examples) {
        count += 1;
        for (final String token in example.tokens) {
          documentFrequency[token] = (documentFrequency[token] ?? 0) + 1;
        }
      }
    }
    _exampleCount = count;
    _idf = <String, double>{
      for (final MapEntry<String, int> entry in documentFrequency.entries)
        entry.key: log(1 + count / entry.value),
    };
    // Unseen tokens are treated as maximally rare.
    _maxIdf = count == 0 ? 0 : log(1 + count);
  }

  double _weight(String token) => _idf[token] ?? _maxIdf;

  @override
  IntentClassification classify(String transcript) {
    final Set<String> tokens = _tokenize(transcript).toSet();
    if (tokens.isEmpty || _examples.isEmpty) {
      return const IntentClassification(
        intent: VaaniIntent.answerQuestion,
        confidence: 0,
      );
    }
    final String normalized = tokens.join(' ');

    final Map<VaaniIntent, double> scores = <VaaniIntent, double>{};
    VaaniIntent bestIntent = VaaniIntent.answerQuestion;
    double best = 0;
    for (final MapEntry<VaaniIntent, List<_TrainingExample>> entry
        in _examples.entries) {
      double intentScore = 0;
      for (final _TrainingExample example in entry.value) {
        final double score = _score(tokens, normalized, example);
        if (score > intentScore) {
          intentScore = score;
        }
      }
      scores[entry.key] = intentScore;
      if (intentScore > best) {
        best = intentScore;
        bestIntent = entry.key;
      }
    }
    return IntentClassification(
      intent: bestIntent,
      confidence: best.clamp(0.0, 1.0).toDouble(),
      scores: scores,
    );
  }

  double _score(
    Set<String> tokens,
    String normalizedTranscript,
    _TrainingExample example,
  ) {
    if (example.tokens.isEmpty) {
      return 0;
    }
    if (example.normalized == normalizedTranscript) {
      return 1;
    }
    double intersection = 0;
    double exampleMass = 0;
    for (final String token in example.tokens) {
      final double weight = _weight(token);
      exampleMass += weight;
      if (tokens.contains(token)) {
        intersection += weight;
      }
    }
    if (exampleMass == 0) {
      return 0;
    }
    if (intersection == exampleMass) {
      // The utterance fully contains this training phrase.
      return _containmentConfidence;
    }
    double union = exampleMass;
    for (final String token in tokens) {
      if (!example.tokens.contains(token)) {
        union += _weight(token);
      }
    }
    return union == 0 ? 0 : intersection / union;
  }
}

class _TrainingExample {
  _TrainingExample(String rawText)
      : normalized = _tokenize(rawText).join(' '),
        tokens = _tokenize(rawText).toSet();

  final String normalized;
  final Set<String> tokens;
}

// Anything that is not [ASCII alphanumeric] or a letter in one of the nine
// supported scripts acts as a token separator.
final RegExp _separator = RegExp(
  r'[^0-9a-z\u0900-\u097F\u0980-\u09FF\u0B80-\u0BFF\u0C00-\u0C7F\u0C80-\u0CFF]+',
);

/// Function words with no intent signal, across the supported languages.
/// Kept deliberately small — IDF down-weights the rest anyway.
const Set<String> _stopwords = <String>{
  'a', 'an', 'the', 'is', 'are', 'am', 'do', 'does', 'did', 'i', 'me', 'my',
  'you', 'your', 'please', 'kindly', 'can', 'could', 'would', 'will', 'to',
  'of', 'and', 'for', 'in', 'on', 'at', 'vaani',
  'என்', 'நான்', 'ஒரு', 'எனக்கு',
  'मुझे', 'मेरा', 'मेरी', 'मेरे', 'एक', 'है', 'हैं', 'को', 'का', 'की',
  'నా', 'నాకు', 'ఒక',
  'ನನ್ನ', 'ಒಂದು',
  'আমার', 'আমি', 'একটি', 'একটা',
};

/// Lowercase, drop ZW characters (ZWSP splits, ZWNJ joins), split on
/// separators, remove stopwords.
List<String> _tokenize(String text) {
  final String cleaned = text
      .toLowerCase()
      .replaceAll('\u200B', ' ')
      .replaceAll('\u200C', '');
  return cleaned
      .split(_separator)
      .where((String token) =>
          token.isNotEmpty && !_stopwords.contains(token))
      .toList();
}
