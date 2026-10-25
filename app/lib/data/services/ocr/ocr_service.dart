/// On-device OCR (Tesseract via a platform channel) with a
/// never-guess-handwriting confidence policy, plus a rule-based page
/// classifier used by the read-document flow.
///
/// Privacy (PRIVACY_CHARTER.md): image bytes exist in RAM only, are
/// passed straight to the on-device engine, and are never persisted or
/// uploaded by this code. Saving a document is a separate, explicit user
/// action elsewhere.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// Outcome of one recognition pass.
class OcrResult {
  /// Creates a full result.
  const OcrResult({
    required this.text,
    required this.confidence,
    required this.engine,
    this.needsRetype = false,
  });

  /// Creates the "please retype" result for low-confidence (typically
  /// handwritten or blurry) input.
  ///
  /// Per the charter: below [OcrService.kRetypeConfidenceFloor] Vaani
  /// must admit it cannot read the text and ask the user to retype or
  /// have someone read it aloud — never guess.
  const OcrResult.needsRetype({this.engine = 'tesseract'})
      : text = '',
        confidence = 0.0,
        needsRetype = true;

  /// Recognized text (empty when [needsRetype] is true).
  final String text;

  /// Engine confidence in [0, 1].
  final double confidence;

  /// Engine identifier, e.g. `tesseract`.
  final String engine;

  /// True when confidence was too low to trust the text.
  final bool needsRetype;
}

/// Honest failure of the OCR pipeline (engine missing, native error…).
class OcrException implements Exception {
  /// Creates an exception.
  const OcrException(this.message, {this.kind = 'ocr_failed'});

  /// Human-readable explanation (to be localized, never spoken as-is).
  final String message;

  /// Machine kind: `ocr_unavailable`, `ocr_failed`, …
  final String kind;

  @override
  String toString() => 'OcrException($kind): $message';
}

/// Recognizes text in document photos on-device.
///
/// Talks to the native Tesseract wrapper over the `neyam_vaani/ocr`
/// method channel (Android implementation lands with `native/`, Phase 7;
/// until then calls fail with [OcrException] kind `ocr_unavailable`,
/// which the UI shows honestly rather than pretending).
class OcrService {
  /// Creates a service. [channel] is injectable for tests.
  OcrService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('neyam_vaani/ocr');

  /// Below this confidence (0.70) OCR results are discarded and the user
  /// is asked to retype — handwritten text is never guessed.
  static const double kRetypeConfidenceFloor = 0.70;

  final MethodChannel _channel;

  /// Runs OCR on [imageBytes] (RAM only; never stored, never uploaded).
  Future<OcrResult> recognize(Uint8List imageBytes) async {
    final Map<String, Object?> arguments = <String, Object?>{'bytes': imageBytes};
    Map<Object?, Object?> raw;
    try {
      raw = await _channel.invokeMapMethod<Object?, Object?>('recognize', arguments)
          ?? const <Object?, Object?>{};
    } on MissingPluginException {
      throw const OcrException(
        'Document scanning is not available on this device yet.',
        kind: 'ocr_unavailable',
      );
    } on PlatformException catch (error) {
      throw OcrException(
        error.message ?? 'The document could not be read.',
        kind: error.code,
      );
    }

    final String text = (raw['text'] as String? ?? '').trim();
    final double confidence =
        (raw['confidence'] as num?)?.toDouble() ?? 0.0;
    final String engine = raw['engine'] as String? ?? 'tesseract';

    if (confidence < kRetypeConfidenceFloor) {
      return OcrResult.needsRetype(engine: engine);
    }
    return OcrResult(text: text, confidence: confidence, engine: engine);
  }
}

/// What kind of page the OCR text looks like.
enum PageType {
  /// Medicine strip/label: dosage lines, mg/ml, "twice daily".
  medicineLabel,

  /// Correspondence: greetings, subject lines, sign-offs.
  letter,

  /// Application/form: field labels, signature box.
  form,

  /// Nothing matched confidently.
  unknown,
}

/// Keyword-hit classifier over OCR text (en/hi/ta in Phase 7 scope).
///
/// Deliberately rule-based and auditable: the read-document flow uses it
/// only to choose how to present a page (e.g. medicine labels get the
/// "ask a doctor" framing), never to answer questions about the content.
class RuleBasedPageClassifier {
  /// Creates a classifier (stateless; const).
  const RuleBasedPageClassifier();

  static const Map<PageType, List<String>> _keywords =
      <PageType, List<String>>{
    PageType.medicineLabel: <String>[
      'mg', 'ml', 'tablet', 'tablets', 'capsule', 'capsules', 'syrup',
      'dosage', 'dose', 'twice daily', 'three times', 'before food',
      'after food', 'prescription', 'expiry',
      // Hindi
      'खुराक', 'गोली', 'गोलियां', 'कैप्सूल', 'मिलीग्राम', 'दिन में दो बार',
      'भोजन से पहले', 'भोजन के बाद',
      // Tamil
      'மாத்திரை', 'காப்ஸுல்', 'மில்லி', 'டோஸ்', 'உணவுக்கு முன்', 'உணவுக்கு பின்',
    ],
    PageType.letter: <String>[
      'dear', 'sincerely', 'regards', 'respectfully',
      'to whom it may concern', 'subject:',
      // Hindi
      'प्रिय', 'सादर', 'भवदीय', 'सेवा में', 'विषय',
      // Tamil
      'அன்புடன்', 'தங்கள்', 'பொருள்',
    ],
    PageType.form: <String>[
      'application', 'form', 'full name', 'date of birth', 'address',
      'signature', 'applicant', 'declaration',
      // Hindi
      'आवेदन', 'प्रारूप', 'नाम', 'पता', 'हस्ताक्षर', 'जन्म तिथि', 'आवेदक',
      // Tamil
      'விண்ணப்பம்', 'பெயர்', 'முகவரி', 'கையொப்பம்', 'பிறந்த தேதி',
    ],
  };

  /// Tie-break order when several types hit equally often. Medicine
  /// labels come first because misreading one is the most harmful.
  static const List<PageType> _priority = <PageType>[
    PageType.medicineLabel,
    PageType.letter,
    PageType.form,
  ];

  /// Classifies [text] by counting keyword hits (case-insensitive).
  PageType classify(String text) {
    final String lowered = text.toLowerCase();
    final Map<PageType, int> hits = <PageType, int>{};
    for (final MapEntry<PageType, List<String>> entry in _keywords.entries) {
      int count = 0;
      for (final String keyword in entry.value) {
        if (lowered.contains(keyword)) {
          count++;
        }
      }
      if (count > 0) {
        hits[entry.key] = count;
      }
    }
    if (hits.isEmpty) {
      return PageType.unknown;
    }
    int best = -1;
    PageType result = PageType.unknown;
    for (final PageType type in _priority) {
      final int count = hits[type] ?? 0;
      if (count > best) {
        best = count;
        result = type;
      }
    }
    return result;
  }
}
