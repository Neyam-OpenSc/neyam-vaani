import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/data/services/voice/tts_service.dart';

Int16List _chunk(int fill) =>
    Int16List.fromList(<int>[fill, fill, fill, fill]);

/// Captures every chunk the service produces, with its is_final flag.
final class _RecordingSink implements PcmSink {
  final List<Int16List> chunks = <Int16List>[];
  final List<bool> finals = <bool>[];

  @override
  void write(Int16List chunk, {required bool isFinal}) {
    chunks.add(Int16List.fromList(chunk));
    finals.add(isFinal);
  }
}

/// Deterministic piper bridge: emits chunks on demand, records calls.
final class _FakePiperBridge implements PiperBridge {
  _FakePiperBridge({this.available = true});

  bool available;

  /// When true, speak() emits a partial and the final chunk immediately.
  /// When false, it emits the first chunk and waits for [finishSpeaking].
  bool autoFinish = true;

  /// When false, speak() emits nothing at all until [emitFirstChunk].
  bool emitFirstChunk = true;

  /// When true, speak() fails immediately with an ERR_BUSY-style code.
  bool failSpeak = false;

  bool stopWasCalled = false;
  int voiceCountValue = 1;
  int sampleRateValue = 22050;

  final List<String> spokenTexts = <String>[];
  final List<double> speeds = <double>[];
  PcmChunkHandler? pendingHandler;

  @override
  bool get isAvailable => available;

  @override
  bool ensureReady() => available;

  @override
  int get voiceCount => voiceCountValue;

  @override
  int get sampleRate => sampleRateValue;

  @override
  bool get isSpeaking => pendingHandler != null;

  @override
  int speak(String text, double speed, PcmChunkHandler onPcm) {
    if (!available) {
      return -1;
    }
    spokenTexts.add(text);
    speeds.add(speed);
    if (failSpeak) {
      return -16; // ERR_BUSY-style refusal.
    }
    if (!emitFirstChunk) {
      pendingHandler = onPcm;
      return 0;
    }
    onPcm(_chunk(1), false);
    if (autoFinish) {
      onPcm(_chunk(2), true);
      return 0;
    }
    pendingHandler = onPcm;
    return 0;
  }

  /// Delivers the first chunk for a held-open utterance.
  void emitFirstChunk() {
    pendingHandler?.call(_chunk(1), false);
  }

  /// Delivers the final chunk for a held-open utterance.
  void finishSpeaking() {
    final PcmChunkHandler? handler = pendingHandler;
    pendingHandler = null;
    handler?.call(_chunk(3), true);
  }

  @override
  void stop() {
    stopWasCalled = true;
    pendingHandler = null;
  }

  @override
  void dispose() {}
}

void main() {
  group('TtsService state machine', () {
    test('idle -> preparing -> speaking -> idle across one utterance',
        () async {
      final _FakePiperBridge bridge = _FakePiperBridge()
        ..autoFinish = false
        ..emitFirstChunk = false;
      final _RecordingSink sink = _RecordingSink();
      final TtsService tts = TtsService(bridge: bridge)..attachSink(sink);

      expect(tts.state, TtsState.idle);

      // Text accepted, no PCM yet: preparing, honestly.
      final Future<void> done = tts.speak('வணக்கம்');
      expect(tts.state, TtsState.preparing);
      expect(sink.chunks, isEmpty);

      // First PCM arrives: speaking.
      bridge.emitFirstChunk();
      expect(tts.state, TtsState.speaking);

      // Final chunk: back to idle, all chunks delivered in order.
      bridge.finishSpeaking();
      await done;
      expect(tts.state, TtsState.idle);
      expect(bridge.spokenTexts, <String>['வணக்கம்']);
      expect(sink.chunks, hasLength(2));
      expect(sink.finals, <bool>[false, true]);
    });

    test('a speak() the bridge refuses (ERR_BUSY) returns calmly to idle',
        () async {
      final _FakePiperBridge bridge = _FakePiperBridge()..failSpeak = true;
      final _RecordingSink sink = _RecordingSink();
      final TtsService tts = TtsService(bridge: bridge)..attachSink(sink);

      // Native is ready; the refusal happens at speak() time.
      expect(tts.spokenOutputAvailable, isTrue);

      final Future<void> done = tts.speak('busy');
      await done;

      expect(tts.state, TtsState.idle);
      expect(sink.chunks, isEmpty);
    });
  });

  group('TtsService.stop', () {
    test('stop() mid-speech resets to idle immediately and interrupts output',
        () async {
      final _FakePiperBridge bridge = _FakePiperBridge()..autoFinish = false;
      final _RecordingSink sink = _RecordingSink();
      final TtsService tts = TtsService(bridge: bridge)..attachSink(sink);

      final Future<void> done = tts.speak('Wait for me');
      expect(tts.state, TtsState.speaking);

      tts.stop();
      expect(tts.state, TtsState.idle);
      expect(bridge.stopWasCalled, isTrue);
      expect(bridge.pendingHandler, isNull);
      await done;

      // No final chunk was delivered after the stop: an honest interrupt.
      expect(sink.finals, <bool>[false]);
      expect(sink.chunks, hasLength(1));
    });

    test('a new speak() after stop() works (stop-before-speak ABI rule)',
        () async {
      final _FakePiperBridge bridge = _FakePiperBridge()..autoFinish = false;
      final TtsService tts = TtsService(bridge: bridge);

      final Future<void> first = tts.speak('first');
      tts.stop();
      await first;

      bridge.autoFinish = true;
      await tts.speak('second');
      expect(bridge.spokenTexts, <String>['first', 'second']);
      expect(tts.state, TtsState.idle);
    });
  });

  group('TtsService speed clamping', () {
    test('speed is clamped to 0.5..2.0 before reaching the bridge', () async {
      final _FakePiperBridge bridge = _FakePiperBridge();
      final TtsService tts = TtsService(bridge: bridge);

      expect(tts.clampSpeed(0.1), 0.5);
      expect(tts.clampSpeed(5.0), 2.0);
      expect(tts.clampSpeed(0.75), 0.75);

      await tts.speak('a', speed: 0.2);
      await tts.speak('b', speed: 3.9);
      await tts.speak('c', speed: 1.4);

      expect(bridge.speeds, <double>[0.5, 2.0, 1.4]);
    });
  });

  group('TtsService graceful degradation', () {
    test('a missing native bridge stays calm: no-op, no chunks, idle',
        () async {
      final _FakePiperBridge bridge = _FakePiperBridge(available: false);
      final _RecordingSink sink = _RecordingSink();
      final TtsService tts = TtsService(bridge: bridge)..attachSink(sink);

      expect(tts.spokenOutputAvailable, isFalse);

      await tts.speak('anything', speed: 1.0);

      expect(tts.state, TtsState.idle);
      expect(bridge.spokenTexts, isEmpty);
      expect(sink.chunks, isEmpty);
      expect(sink.finals, isEmpty);
    });

    test('spokenOutputAvailable is true once a voice is ready', () {
      final _FakePiperBridge bridge = _FakePiperBridge(available: true);
      final TtsService tts = TtsService(bridge: bridge);
      expect(tts.spokenOutputAvailable, isTrue);
    });

    test('empty text is a quiet no-op even when native is ready', () async {
      final _FakePiperBridge bridge = _FakePiperBridge();
      final TtsService tts = TtsService(bridge: bridge);
      await tts.speak('   ');
      expect(bridge.spokenTexts, isEmpty);
      expect(tts.state, TtsState.idle);
    });
  });
}
