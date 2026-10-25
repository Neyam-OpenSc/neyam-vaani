/// Ports to the native side for device actions and permissions.
///
/// Two method channels:
/// - `neyam_vaani/actions` — perform an action (send SMS, dial, torch...).
/// - `neyam_vaani/permissions` — check/request a runtime permission.
///
/// Both return values, never throw across the boundary: a failed native
/// call becomes a [PlatformActionResult] carrying an errorCode, which
/// handlers map to a kind sentence. The Android implementations
/// land with the native integration; until then [MissingPluginException]
/// is reported honestly as errorCode `missingPlugin` rather than
/// pretended away.
library;

import 'package:flutter/services.dart';

import '../../../domain/entities/action_result.dart';

/// The result of one native action invocation.
class PlatformActionResult {
  const PlatformActionResult({
    required this.ok,
    this.data = const <String, Object?>{},
    this.errorCode,
  });

  /// Whether the native side succeeded.
  final bool ok;

  /// Optional data returned by the native side (never user-facing text —
  /// handlers turn outcomes into message keys).
  final Map<String, Object?> data;

  /// Machine-readable error code when [ok] is false (`missingPlugin`,
  /// `permissionDenied`, ...). Logs only, never spoken.
  final String? errorCode;

  @override
  String toString() =>
      ok ? 'PlatformActionResult(ok)' : 'PlatformActionResult($errorCode)';
}

/// The method names the native side implements on
/// `neyam_vaani/actions`. This catalog is the Kotlin-side contract.
abstract final class PlatformActionMethods {
  /// Send an SMS directly. Args: recipient, content.
  static const String smsSend = 'sms.send';

  /// Open the dialer placed on the number. Args: number.
  static const String callDial = 'call.dial';

  /// Set an alarm. Args: hour (0-23), minute (0-59), label.
  static const String alarmSet = 'alarm.set';

  /// Copy text to the clipboard. Args: text.
  static const String clipboardCopy = 'clipboard.copy';

  /// Open another app. Args: package.
  static const String appOpen = 'app.open';

  /// Turn the torch on or off. Args: on (bool).
  static const String torchSet = 'torch.set';

  /// Hand a message to WhatsApp. Args: recipient, content.
  static const String whatsappSend = 'whatsapp.send';
}

/// Performs one device action on the native side.
abstract class PlatformActionPort {
  /// Invokes [method] (a [PlatformActionMethods] name) with [args].
  Future<PlatformActionResult> invoke(
      String method, Map<String, Object?> args);
}

/// The real port: `neyam_vaani/actions` over a [MethodChannel].
class MethodChannelPlatformActionPort implements PlatformActionPort {
  /// Creates a port. [channel] is injectable for tests.
  MethodChannelPlatformActionPort({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('neyam_vaani/actions');

  final MethodChannel _channel;

  @override
  Future<PlatformActionResult> invoke(
      String method, Map<String, Object?> args) async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>(method, args);
      if (raw is Map) {
        return PlatformActionResult(
          ok: true,
          data: <String, Object?>{
            for (final MapEntry<dynamic, dynamic> entry in raw.entries)
              entry.key.toString(): entry.value,
          },
        );
      }
      return const PlatformActionResult(ok: true);
    } on PlatformException catch (error) {
      return PlatformActionResult(ok: false, errorCode: error.code);
    } on MissingPluginException {
      return const PlatformActionResult(ok: false,
          errorCode: 'missingPlugin');
    }
  }
}

/// One recorded [PlatformActionPort.invoke] call, for tests.
class PlatformPortCall {
  const PlatformPortCall({required this.method, required this.args});

  /// The method that was invoked.
  final String method;

  /// The arguments it was invoked with (a copy, safe to inspect).
  final Map<String, Object?> args;

  @override
  String toString() => 'PlatformPortCall($method, $args)';
}

/// Decides what a fake port answers; defaults to plain success.
typedef PlatformResponder = PlatformActionResult Function(
    String method, Map<String, Object?> args);

PlatformActionResult _defaultResponder(
        String method, Map<String, Object?> args) =>
    const PlatformActionResult(ok: true);

/// A recording fake for tests: every [invoke] is appended to [calls].
class FakePlatformActionPort implements PlatformActionPort {
  /// Creates a fake answering through [respond].
  FakePlatformActionPort({PlatformResponder respond = _defaultResponder})
      : _respond = respond;

  final PlatformResponder _respond;

  /// Every invoke, in order.
  final List<PlatformPortCall> calls = <PlatformPortCall>[];

  @override
  Future<PlatformActionResult> invoke(
      String method, Map<String, Object?> args) async {
    final Map<String, Object?> copied = Map<String, Object?>.of(args);
    calls.add(PlatformPortCall(method: method, args: copied));
    return _respond(method, copied);
  }

  /// Whether [method] was invoked at least once.
  bool invoked(String method) =>
      calls.any((PlatformPortCall call) => call.method == method);

  /// The args of the most recent [method] invocation, or `null`.
  Map<String, Object?>? lastArgsOf(String method) {
    for (final PlatformPortCall call in calls.reversed) {
      if (call.method == method) {
        return call.args;
      }
    }
    return null;
  }
}

/// Checks and requests runtime permissions.
abstract class PermissionsPort {
  /// Whether [permission] is currently granted; no prompts.
  Future<bool> check(VaaniPermission permission);

  /// Asks the user for [permission], showing the one-sentence reason
  /// behind [whyKey] first (the UI resolves the key in the user's
  /// language — the channel only carries the key). Whether the user
  /// granted it.
  Future<bool> request(VaaniPermission permission, String whyKey);
}

/// The real port: `neyam_vaani/permissions` over a [MethodChannel].
class MethodChannelPermissionsPort implements PermissionsPort {
  /// Creates a port. [channel] is injectable for tests.
  MethodChannelPermissionsPort({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('neyam_vaani/permissions');

  final MethodChannel _channel;

  @override
  Future<bool> check(VaaniPermission permission) async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('check',
          <String, Object?>{'permission': permission.id});
      return raw == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> request(VaaniPermission permission, String whyKey) async {
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('request',
          <String, Object?>{'permission': permission.id, 'whyKey': whyKey});
      return raw == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// One recorded [PermissionsPort.request], for tests.
class PermissionRequest {
  const PermissionRequest({required this.permission, required this.whyKey});

  /// The permission that was requested.
  final VaaniPermission permission;

  /// The charter why-key it was requested with.
  final String whyKey;

  @override
  String toString() => 'PermissionRequest(${permission.id}, $whyKey)';
}

/// A programmable fake for tests: [check] answers from the granted set,
/// [request] records itself and answers [requestOutcome].
class FakePermissionsPort implements PermissionsPort {
  /// Creates a fake whose [check] answers `true` exactly for the
  /// permissions in [initiallyGranted].
  FakePermissionsPort({
    Set<VaaniPermission> initiallyGranted = const <VaaniPermission>{},
    this.requestOutcome = false,
  }) : _granted = Set<VaaniPermission>.of(initiallyGranted);

  /// What [request] answers for a permission not yet granted.
  bool requestOutcome;

  final Set<VaaniPermission> _granted;

  /// Every request, in order.
  final List<PermissionRequest> requests = <PermissionRequest>[];

  /// How many times [check] was called.
  int checkCount = 0;

  @override
  Future<bool> check(VaaniPermission permission) async {
    checkCount += 1;
    return _granted.contains(permission);
  }

  @override
  Future<bool> request(VaaniPermission permission, String whyKey) async {
    requests.add(PermissionRequest(permission: permission, whyKey: whyKey));
    if (requestOutcome) {
      _granted.add(permission);
    }
    return requestOutcome;
  }

  /// Simulates the user granting [permission] outside the app (system
  /// settings), so a later [check] sees it.
  void markGranted(VaaniPermission permission) => _granted.add(permission);
}

/// Maps a failed native invocation to the failure kind the user's
/// message depends on: permission-ish error codes stay permission
/// denials, everything else is a platform error.
ActionFailureKind platformErrorKind(String? errorCode) {
  final String code = errorCode ?? '';
  return code.startsWith('permission')
      ? ActionFailureKind.permissionDenied
      : ActionFailureKind.platformError;
}
