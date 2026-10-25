/// Raw microphone capture for the voice input pipeline.
///
/// PRIVACY_CHARTER.md: audio frames exist in RAM only — they are never
/// written to disk and never leave the device. There is no network code in
/// this file or anywhere it calls.
///
/// Three pieces live here:
/// - [AudioCapture] — the contract: 16 kHz mono 16-bit PCM frames.
/// - [MethodChannelAudioCapture] — talks to the Android side over
///   `neyam_vaani/audio` (the platform implementation arrives in Phase 1;
///   the Dart side is ready for it).
/// - [FakeAudioCapture] — pushable frames for tests and CI, no plugins.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Why Vaani needs the microphone, phrased for the user exactly as the
/// privacy charter's permission table words it ('To hear you'). TODO(l10n)
const String kMicrophonePermissionReason = 'To hear you';

/// Typed outcome of asking for the microphone permission.
sealed class MicrophonePermission {
  const MicrophonePermission();

  /// The one-sentence reason shown next to the request, in plain language.
  String get userReason => kMicrophonePermissionReason;
}

/// The user (or the OS) said yes; listening may start.
final class MicrophonePermissionGranted extends MicrophonePermission {
  const MicrophonePermissionGranted();
}

/// The user said no. Vaani accepts that calmly and does not nag.
final class MicrophonePermissionDenied extends MicrophonePermission {
  const MicrophonePermissionDenied();
}

/// Streams 16 kHz mono 16-bit PCM frames while started.
abstract interface class AudioCapture {
  /// Live frames. A broadcast stream; safe to listen before [start].
  Stream<Int16List> get frames;

  /// Asks for the microphone permission with a plain-language reason.
  Future<MicrophonePermission> requestPermission();

  /// Opens the microphone. Call after permission was granted.
  Future<void> start();

  /// Closes the microphone. Frames stop; RAM is dropped immediately.
  Future<void> stop();
}

// ---------------------------------------------------------------------------
// MethodChannel implementation (Android side arrives in Phase 1)
// ---------------------------------------------------------------------------

/// Platform-channel capture. Protocol the Android side must implement:
///
/// - Dart -> platform:
///   - `requestPermission` -> `'granted'` | `'denied'` (String)
///   - `start` (no result)
///   - `stop` (no result)
/// - platform -> Dart:
///   - `onFrame` with little-endian PCM16 bytes (`ByteData`/`Uint8List`)
final class MethodChannelAudioCapture implements AudioCapture {
  /// Creates a capture bound to [channelName].
  ///
  /// Constructing this touches no platform channels — only [requestPermission],
  /// [start] and [stop] do — so providers may build it eagerly.
  MethodChannelAudioCapture({String channel = channelName})
      : _channel = MethodChannel(channel);

  /// The channel name the Android implementation registers on.
  static const String channelName = 'neyam_vaani/audio';

  final MethodChannel _channel;
  final StreamController<Int16List> _frames =
      StreamController<Int16List>.broadcast();

  bool _started = false;
  bool _handlerBound = false;

  @override
  Stream<Int16List> get frames => _frames.stream;

  /// Whether [start] succeeded and [stop] has not run since.
  bool get isStarted => _started;

  @override
  Future<MicrophonePermission> requestPermission() async {
    try {
      final String? answer =
          await _channel.invokeMethod<String>('requestPermission');
      return answer == 'granted'
          ? const MicrophonePermissionGranted()
          : const MicrophonePermissionDenied();
    } catch (_) {
      // Any channel failure — platform side missing (desktop, CI), or the OS
      // refusing — resolves to a calm denial. Never a crash.
      return const MicrophonePermissionDenied();
    }
  }

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }
    if (!_handlerBound) {
      // A local registration, not a platform call.
      _channel.setMethodCallHandler(_onPlatformCall);
      _handlerBound = true;
    }
    await _channel.invokeMethod<void>('start');
    _started = true;
  }

  @override
  Future<void> stop() async {
    if (!_started) {
      return;
    }
    await _channel.invokeMethod<void>('stop');
    _started = false;
  }

  /// Releases the frames stream. Safe to call anytime.
  void dispose() {
    unawaited(_frames.close());
  }

  Future<dynamic> _onPlatformCall(MethodCall call) async {
    if (call.method == 'onFrame') {
      final dynamic args = call.arguments;
      if (args is ByteData) {
        _emit(_toInt16(args));
      } else if (args is Uint8List) {
        _emit(_toInt16(
          ByteData.view(args.buffer, args.offsetInBytes, args.lengthInBytes),
        ));
      }
    }
    return null;
  }

  void _emit(Int16List samples) {
    if (!_frames.isClosed && samples.isNotEmpty) {
      _frames.add(samples);
    }
  }

  static Int16List _toInt16(ByteData data) {
    final int count = data.lengthInBytes ~/ 2;
    final Int16List out = Int16List(count);
    for (int i = 0; i < count; i++) {
      out[i] = data.getInt16(i * 2, Endian.little);
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Test double
// ---------------------------------------------------------------------------

/// Pushable capture for tests: [pushFrame] injects PCM by hand; permission
/// is settable. No plugins, no platform channels — pure Dart.
final class FakeAudioCapture implements AudioCapture {
  /// Creates a capture whose permission starts as [permission].
  FakeAudioCapture({
    MicrophonePermission permission = const MicrophonePermissionGranted(),
  }) : _permission = permission;

  final StreamController<Int16List> _frames =
      StreamController<Int16List>.broadcast();

  MicrophonePermission _permission;

  /// Whether [start] was called more recently than [stop].
  bool started = false;

  @override
  Stream<Int16List> get frames => _frames.stream;

  /// Makes the next [requestPermission] succeed.
  void grantPermission() =>
      _permission = const MicrophonePermissionGranted();

  /// Makes the next [requestPermission] fail, as the user would.
  void denyPermission() => _permission = const MicrophonePermissionDenied();

  @override
  Future<MicrophonePermission> requestPermission() async => _permission;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  /// Injects one frame into [frames], as the microphone would.
  void pushFrame(Int16List frame) {
    if (!_frames.isClosed) {
      _frames.add(frame);
    }
  }

  /// Releases the frames stream.
  void dispose() {
    unawaited(_frames.close());
  }
}
