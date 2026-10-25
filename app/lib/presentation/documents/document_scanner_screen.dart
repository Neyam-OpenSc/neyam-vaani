/// Document scanner screen: point, scan, hear.
///
/// Tender UX (TENDER_UX_PRINCIPLES.md): one calm flow — Scan document →
/// reading… → text ready → Read aloud → a plain-language explanation.
/// No feeds, no modes, no jargon. Every state is spoken/labelled for
/// screen-reader users.
///
/// Privacy (PRIVACY_CHARTER.md): photos exist in RAM only and are never
/// saved or uploaded — said out loud on the screen itself. Saving is a
/// separate, explicit user action that does not exist yet.
///
/// Phase 7 wiring: the "Scan document" button runs the real
/// [ReadDocument] use case with placeholder sample bytes until the
/// native camera + Tesseract pipeline lands (`native/`); until then the
/// honest "not available on this device yet" state is shown rather than
/// a fake demo of pretend text.
library;

import 'dart:async' show unawaited;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';

import '../../data/services/ocr/ocr_service.dart';
import '../../domain/usecases/read_document.dart';

/// Where the scan flow is.
enum _ScanPhase {
  /// Nothing scanned yet.
  idle,

  /// OCR is running.
  scanning,

  /// Text is ready to be read aloud.
  ready,

  /// Confidence was too low; ask the user to retype or dictate.
  needsRetype,

  /// The engine failed or is absent.
  failed,
}

/// Scan a paper document and have Vaani read it aloud.
class DocumentScannerScreen extends StatefulWidget {
  /// Creates the screen.
  ///
  /// [reader] overrides the OCR-backed use case (tests). [onReadAloud]
  /// is the TTS callback — a placeholder no-op until Piper lands in
  /// Phase 2. [sampleBytes] stands in for the camera capture until the
  /// native camera integration (Phase 7).
  const DocumentScannerScreen({
    super.key,
    ReadDocument? reader,
    this.onReadAloud,
    this.sampleBytes,
  }) : _reader = reader;

  final ReadDocument? _reader;
  final void Function(String text)? onReadAloud;
  final Uint8List? sampleBytes;

  @override
  State<DocumentScannerScreen> createState() => _DocumentScannerScreenState();
}

class _DocumentScannerScreenState extends State<DocumentScannerScreen> {
  // Placeholder for the camera frame: a PNG signature header. Replaced
  // by the real capture in Phase 7 (see class docs).
  static final Uint8List _defaultSampleBytes =
      Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  _ScanPhase _phase = _ScanPhase.idle;
  ReadDocumentResult? _result;
  String? _failure;

  ReadDocument? _reader;

  @override
  void initState() {
    super.initState();
    _reader = widget._reader ?? ReadDocument(OcrService());
  }

  Future<void> _scan() async {
    setState(() {
      _phase = _ScanPhase.scanning;
      _failure = null;
    });
    try {
      final ReadDocumentResult result =
          await _reader!(widget.sampleBytes ?? _defaultSampleBytes);
      if (!mounted) {
        return;
      }
      setState(() {
        _result = result;
        _phase = result.needsRetype ? _ScanPhase.needsRetype : _ScanPhase.ready;
      });
    } on OcrException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _phase = _ScanPhase.failed;
        _failure = error.kind == 'ocr_unavailable'
            ? 'Document scanning is not available on this device yet.'
            : 'The document could not be read. Please try again in better light.';
      });
    }
  }

  void _readAloud() {
    final ReadDocumentResult? result = _result;
    if (result == null || result.text.isEmpty) {
      return;
    }
    widget.onReadAloud?.call(result.text); // No-op placeholder by default.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Reading aloud… (voice arrives in Phase 2)'), // TODO(l10n)
      ),
    );
  }

  String get _typeLabel => switch (_result?.type) {
        PageType.medicineLabel => 'Medicine label', // TODO(l10n)
        PageType.letter => 'Letter', // TODO(l10n)
        PageType.form => 'Form', // TODO(l10n)
        PageType.unknown || null => 'Document', // TODO(l10n)
      };

  String get _explanation => switch (_result?.type) {
        PageType.medicineLabel =>
          'This looks like a medicine label. Listen to the dosage lines '
              'carefully. This is not medical advice — ask a doctor or '
              'pharmacist.', // TODO(l10n)
        PageType.letter =>
          'This looks like a letter. Vaani can read it aloud, or explain '
              'any sentence you point at.', // TODO(l10n)
        PageType.form =>
          'This looks like a form. Vaani can help you fill it by voice, '
              'one question at a time.', // TODO(l10n)
        PageType.unknown || null =>
          'Here is what Vaani could read.', // TODO(l10n)
      };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Read a document')), // TODO(l10n)
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              label: 'Scan a document with the camera', // TODO(l10n)
              button: true,
              child: FilledButton.icon(
                onPressed: _phase == _ScanPhase.scanning ? null : () => unawaited(_scan()),
                icon: const Icon(Icons.document_scanner),
                label: const Text('Scan document'), // TODO(l10n)
              ),
            ),
            const SizedBox(height: 24),
            _buildStatus(theme),
            const SizedBox(height: 32),
            // Said plainly, because it is a promise (PRIVACY_CHARTER.md).
            Semantics(
              label: 'Photos are not saved. Nothing leaves your phone.', // TODO(l10n)
              child: Text(
                'Photos are not saved. Nothing leaves your phone.', // TODO(l10n)
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(ThemeData theme) {
    switch (_phase) {
      case _ScanPhase.idle:
        return const _CalmMessage(
          icon: Icons.photo_camera_outlined,
          message: 'Hold the paper flat and tap Scan.', // TODO(l10n)
        );
      case _ScanPhase.scanning:
        return const _CalmMessage(
          icon: Icons.hourglass_top,
          message: 'Reading…', // TODO(l10n)
        );
      case _ScanPhase.failed:
        return _CalmMessage(
          icon: Icons.error_outline,
          message: _failure ?? 'The document could not be read.', // TODO(l10n)
        );
      case _ScanPhase.needsRetype:
        return const _CalmMessage(
          icon: Icons.edit_outlined,
          // Charter: never guess handwriting — ask for the words instead.
          message: 'This writing is hard for Vaani to read. Please type it, '
              'or ask someone to read it to you.', // TODO(l10n)
        );
      case _ScanPhase.ready:
        return _buildReadyCard(theme);
    }
  }

  Widget _buildReadyCard(ThemeData theme) {
    final ReadDocumentResult result = _result!;
    return Semantics(
      label: 'Document text is ready', // TODO(l10n)
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(_typeLabel, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                result.text,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              Text(
                _explanation,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Semantics(
                label: 'Read this document aloud', // TODO(l10n)
                button: true,
                child: OutlinedButton.icon(
                  onPressed: _readAloud,
                  icon: const Icon(Icons.volume_up),
                  label: const Text('Read aloud'), // TODO(l10n)
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One icon + one sentence, centered and calm. No spinners, no badges.
class _CalmMessage extends StatelessWidget {
  const _CalmMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: <Widget>[
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
