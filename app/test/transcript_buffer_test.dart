import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/data/services/voice/stt_service.dart';

void main() {
  group('TranscriptBuffer partial merging', () {
    test('a re-decoding of the same audio replaces the hypothesis', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      buffer.addPartial('வணக்கம்');
      expect(buffer.draft, 'வணக்கம்');
      buffer.addPartial('வணக்கம், எப்படி');
      expect(buffer.draft, 'வணக்கம், எப்படி');
    });

    test('a new phrase continues the utterance', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      buffer.addPartial('வணக்கம், எப்படி');
      buffer.addPartial('இருக்கீங்களா');
      expect(buffer.draft, 'வணக்கம், எப்படி இருக்கீங்களா');
    });

    test('finals commit and later partials build on them', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      buffer.addPartial('Hello');
      buffer.addFinal('Hello world');
      expect(buffer.draft, 'Hello world');
      buffer.addPartial('again');
      expect(buffer.draft, 'Hello world again');
    });

    test('empty segments change nothing', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      buffer.addPartial('stay');
      buffer.addPartial('  ');
      buffer.addFinal('');
      expect(buffer.draft, 'stay');
    });
  });

  group('TranscriptBuffer finalization', () {
    test('silence beyond the threshold finalizes with reason pause', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      buffer.addPartial('one two');

      expect(
        buffer.notifySilence(const Duration(milliseconds: 899)),
        isNull,
      );
      final TranscriptFinal? finalSegment =
          buffer.notifySilence(const Duration(milliseconds: 900));
      expect(finalSegment, isNotNull);
      expect(finalSegment!.text, 'one two');
      expect(finalSegment.reason, TranscriptEndReason.pause);

      // The buffer is clean for the next utterance.
      expect(buffer.draft, '');
      expect(buffer.isActive, isFalse);
      expect(buffer.notifySilence(const Duration(seconds: 5)), isNull);
    });

    test('silence with nothing heard never finalizes', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      buffer.notifySpeech();
      expect(buffer.notifySilence(const Duration(seconds: 5)), isNull);
    });

    test('the 30 s utterance cap finalizes with reason maxLength', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      buffer.notifySpeech();
      buffer.addPartial('a long story');

      expect(buffer.advanceBy(const Duration(seconds: 29)), isNull);
      final TranscriptFinal? finalSegment =
          buffer.advanceBy(const Duration(seconds: 2));
      expect(finalSegment, isNotNull);
      expect(finalSegment!.text, 'a long story');
      expect(finalSegment.reason, TranscriptEndReason.maxLength);
      expect(buffer.draft, '');
    });

    test('the cap does not run while nothing is active', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      expect(buffer.advanceBy(const Duration(minutes: 2)), isNull);
    });

    test('manual finalize returns the draft exactly once', () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      buffer.addFinal('first part');
      buffer.addPartial('second part');

      final TranscriptFinal? once = buffer.finalize();
      expect(once, isNotNull);
      expect(once!.text, 'first part second part');
      expect(once.reason, TranscriptEndReason.manual);
      expect(buffer.finalize(), isNull);
    });

    test('manual finalize of an empty utterance is a null, not an error',
        () {
      final TranscriptBuffer buffer = TranscriptBuffer();
      expect(buffer.finalize(), isNull);
    });
  });

  group('ScriptLanguageDetector', () {
    test('each supported script maps to its language', () {
      const ScriptLanguageDetector detector = ScriptLanguageDetector();
      expect(detector.detect('வணக்கம், எப்படி இருக்கீங்களா'), 'ta');
      expect(detector.detect('नमस्ते, आप कैसे हैं'), 'hi');
      expect(detector.detect('বাংলা ভাষা'), 'bn');
      expect(detector.detect('ಕನ್ನಡ ಭಾಷೆ'), 'kn');
      expect(detector.detect('తెలుగు భాష'), 'te');
      expect(detector.detect('Hello, how are you'), 'en');
    });

    test('Devanagari defaults to hi and is configurable', () {
      expect(const ScriptLanguageDetector().detect('नमस्ते'), 'hi');
      expect(
        const ScriptLanguageDetector(devanagariLanguage: 'mr')
            .detect('नमस्कार'),
        'mr',
      );
    });

    test('mixed text resolves to the majority script', () {
      const ScriptLanguageDetector detector = ScriptLanguageDetector();
      expect(detector.detect('வணக்கம் hello நல்வரவு'), 'ta');
      expect(detector.detect('hello வணக்கம்'), 'ta');
      expect(detector.detect('ok வணக்கம் yes நல்வரவு maybe'), 'ta');
    });

    test('no known script falls back to the pinned default', () {
      expect(
        const ScriptLanguageDetector(fallbackLanguage: 'ta').detect('你好'),
        'ta',
      );
      // Digits and punctuation carry no script signal.
      expect(const ScriptLanguageDetector().detect('123 ?!'), 'ta');
      expect(const ScriptLanguageDetector().detect(''), 'ta');
    });
  });
}
