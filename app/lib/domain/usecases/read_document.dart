/// Use case: read a photographed document aloud.
///
/// Flow: image bytes -> OCR -> confidence policy -> page classification
/// -> structured result. The caller (document scanner screen, then the
/// LLM orchestrator in Phase 7) owns presentation and TTS; this use case
/// stays free of both.
library;

import 'dart:typed_data' show Uint8List;

import '../../data/services/ocr/ocr_service.dart';

/// Structured outcome of reading one document image.
class ReadDocumentResult {
  /// Creates a result.
  const ReadDocumentResult({
    required this.text,
    required this.type,
    required this.needsRetype,
    this.confidence,
  });

  /// Empty text; the OCR engine could not read the image confidently.
  factory ReadDocumentResult.retype(double confidence) => ReadDocumentResult(
        text: '',
        type: PageType.unknown,
        needsRetype: true,
        confidence: confidence,
      );

  /// Recognized text (empty when [needsRetype]).
  final String text;

  /// Rule-based page classification of the recognized text.
  final PageType type;

  /// True when the user should be asked to retype or dictate the text
  /// (charter: never guess handwriting).
  final bool needsRetype;

  /// OCR confidence in [0, 1], when known.
  final double? confidence;
}

/// Turns an image into a [ReadDocumentResult].
///
/// ```dart
/// final ReadDocument readDocument = ReadDocument(OcrService());
/// final ReadDocumentResult r = await readDocument(imageBytes);
/// if (r.needsRetype) { /* ask the user to retype */ }
/// ```
///
/// Note on layering: the use case depends directly on the concrete
/// [OcrService] (data layer) for now; when the native engines land, OCR
/// moves behind a domain port without changing this call signature.
class ReadDocument {
  /// Creates the use case. [classifier] is injectable for tests.
  const ReadDocument(
    this._ocr, {
    RuleBasedPageClassifier classifier = const RuleBasedPageClassifier(),
  }) : _classifier = classifier;

  final OcrService _ocr;
  final RuleBasedPageClassifier _classifier;

  /// Reads [imageBytes]. Image bytes stay in RAM (PRIVACY_CHARTER.md).
  Future<ReadDocumentResult> call(Uint8List imageBytes) async {
    final OcrResult ocr = await _ocr.recognize(imageBytes);
    if (ocr.needsRetype) {
      return ReadDocumentResult.retype(ocr.confidence);
    }
    return ReadDocumentResult(
      text: ocr.text,
      type: _classifier.classify(ocr.text),
      needsRetype: false,
      confidence: ocr.confidence,
    );
  }
}
