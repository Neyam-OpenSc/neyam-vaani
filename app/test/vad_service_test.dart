import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/data/services/voice/vad_service.dart';

/// A frame of constant amplitude: RMS == amplitude, at 16 kHz each frame is
/// 320 samples = 20 ms.
Int16List _flat(int amplitude) {
  final Int16List frame = Int16List(320);
  for (int i = 0; i < frame.length; i++) {
    frame[i] = amplitude;
  }
  return frame;
}

const VadConfig _config = VadConfig(
  speechRmsThreshold: 700,
  silenceRmsThreshold: 350,
  minSpeechDuration: Duration(milliseconds: 60),
  minSilenceDuration: Duration(milliseconds: 200),
);

void main() {
  group('VadService over a frame stream', () {
    test('silence -> speech -> silence emits speechStart then speechEnd',
        () async {
      final StreamController<Int16List> frames = StreamController<Int16List>();
      final List<VadEvent> events = <VadEvent>[];
      final VadService vad = VadService(config: _config);
      final StreamSubscription<VadEvent> subscription =
          vad.bind(frames.stream).listen(events.add);

      // 100 ms of quiet room noise.
      for (int i = 0; i < 5; i++) {
        frames.add(_flat(50));
      }
      // 100 ms of speech (>= 60 ms minimum).
      for (int i = 0; i < 5; i++) {
        frames.add(_flat(8000));
      }
      // 240 ms of silence (>= 200 ms minimum).
      for (int i = 0; i < 12; i++) {
        frames.add(_flat(50));
      }

      await pumpEventQueue();
      await frames.close();
      await subscription.cancel();

      expect(events, hasLength(2));
      expect(events[0].kind, VadEventKind.speechStart);
      expect(events[1].kind, VadEventKind.speechEnd);
      expect(
        events[1].silenceDuration,
        greaterThanOrEqualTo(const Duration(milliseconds: 200)),
      );
    });

    test('hysteresis ignores short bursts (clicks, breath)', () async {
      final StreamController<Int16List> frames = StreamController<Int16List>();
      final List<VadEvent> events = <VadEvent>[];
      final VadService vad = VadService(config: _config);
      final StreamSubscription<VadEvent> subscription =
          vad.bind(frames.stream).listen(events.add);

      // A 40 ms burst — under the 60 ms speech minimum — then quiet.
      frames.add(_flat(8000));
      frames.add(_flat(8000));
      for (int i = 0; i < 12; i++) {
        frames.add(_flat(50));
      }
      // A longer burst that is still broken by one quiet frame: the run
      // resets each time, so it never sustains 60 ms.
      frames.add(_flat(8000));
      frames.add(_flat(50));
      frames.add(_flat(8000));
      frames.add(_flat(50));
      frames.add(_flat(8000));
      for (int i = 0; i < 12; i++) {
        frames.add(_flat(50));
      }

      await pumpEventQueue();
      await frames.close();
      await subscription.cancel();

      expect(events, isEmpty);
    });

    test('a brief quiet blip mid-speech does not end the utterance',
        () async {
      final StreamController<Int16List> frames = StreamController<Int16List>();
      final List<VadEvent> events = <VadEvent>[];
      final VadService vad = VadService(config: _config);
      final StreamSubscription<VadEvent> subscription =
          vad.bind(frames.stream).listen(events.add);

      // Sustained speech opens the gate.
      for (int i = 0; i < 5; i++) {
        frames.add(_flat(8000));
      }
      // 40 ms of quiet — under the 200 ms hangover — then speech resumes.
      frames.add(_flat(50));
      frames.add(_flat(50));
      for (int i = 0; i < 5; i++) {
        frames.add(_flat(8000));
      }
      // Now real silence: only one speechEnd, well after the blip.
      for (int i = 0; i < 12; i++) {
        frames.add(_flat(50));
      }

      await pumpEventQueue();
      await frames.close();
      await subscription.cancel();

      expect(events, hasLength(2));
      expect(events[0].kind, VadEventKind.speechStart);
      expect(events[1].kind, VadEventKind.speechEnd);
    });
  });

  group('VadService.process', () {
    test('speechEnd carries the exact accumulated silence', () {
      final VadService vad = VadService(config: _config);

      // Three speech frames: 40 ms is under the minimum, 60 ms opens.
      expect(vad.process(_flat(8000)), isNull);
      expect(vad.process(_flat(8000)), isNull);
      final VadEvent? start = vad.process(_flat(8000));
      expect(start, isNotNull);
      expect(start!.kind, VadEventKind.speechStart);
      expect(start.silenceDuration, Duration.zero);

      // Nine quiet frames = 180 ms: still open.
      for (int i = 0; i < 9; i++) {
        expect(vad.process(_flat(50)), isNull);
      }
      // Tenth quiet frame reaches 200 ms exactly: end, with the duration.
      final VadEvent? end = vad.process(_flat(50));
      expect(end, isNotNull);
      expect(end!.kind, VadEventKind.speechEnd);
      expect(end.silenceDuration, const Duration(milliseconds: 200));
      expect(vad.inSpeech, isFalse);
    });

    test('reset clears the detector for the next utterance', () {
      final VadService vad = VadService(config: _config);
      for (int i = 0; i < 3; i++) {
        vad.process(_flat(8000));
      }
      expect(vad.inSpeech, isTrue);
      vad.reset();
      expect(vad.inSpeech, isFalse);
      // A fresh 40 ms burst after reset is ignored again.
      expect(vad.process(_flat(8000)), isNull);
      expect(vad.process(_flat(8000)), isNull);
      expect(vad.inSpeech, isFalse);
    });
  });
}
