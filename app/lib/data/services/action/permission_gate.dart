/// Just-in-time permission gating.
///
/// PRIVACY_CHARTER.md: a permission is asked for only at the moment an
/// action needs it, and always with one plain sentence in the user's
/// language. The gate holds that sentence's key ([PermissionWhyKeys]);
/// the UI resolves it. Once granted, a permission is never asked for
/// again in this session — the gate remembers.
library;

import '../../../domain/entities/action_result.dart';
import 'platform_action_port.dart';

/// Why-keys for every permission, straight from the charter's table.
abstract final class PermissionWhyKeys {
  /// "To hear you" — first voice use.
  static const String microphone = 'permission.microphone.why';

  /// "To photograph your document" — first document scan.
  static const String camera = 'permission.camera.why';

  /// "To save your document" — first document save.
  static const String storage = 'permission.storage.why';

  /// "To send the message you asked for" — first SMS action.
  static const String sms = 'permission.sms.why';

  /// "To make the call you asked for" — first call action.
  static const String phone = 'permission.phone.why';

  /// "To find what's nearby" — first location action.
  static const String location = 'permission.location.why';

  /// "To remind you when you asked" — first reminder or alarm.
  static const String notifications = 'permission.notifications.why';

  /// The charter table itself.
  static const Map<VaaniPermission, String> charter =
      <VaaniPermission, String>{
    VaaniPermission.microphone: microphone,
    VaaniPermission.camera: camera,
    VaaniPermission.storage: storage,
    VaaniPermission.sms: sms,
    VaaniPermission.phone: phone,
    VaaniPermission.location: location,
    VaaniPermission.notifications: notifications,
  };

  /// The charter why-key for [permission].
  static String forPermission(VaaniPermission permission) =>
      charter[permission] ?? 'permission.unknown.why';
}

/// Ensures a permission is granted, asking at most once per permission
/// per session.
class PermissionGate {
  /// Creates a gate over [port].
  PermissionGate({required PermissionsPort port}) : _port = port;

  final PermissionsPort _port;

  /// Permissions already granted this session; a grant is remembered so
  /// the user is never asked twice for the same thing.
  final Set<VaaniPermission> _granted = <VaaniPermission>{};

  /// Whether [permission] is granted by the time this completes.
  ///
  /// Order: memory, then a silent [PermissionsPort.check], and only then
  /// a [PermissionsPort.request] carrying [whyKey]. Denials are
  /// deliberately **not** cached — the next action may legitimately ask
  /// again, with the same calm sentence.
  Future<bool> ensure(VaaniPermission permission, String whyKey) async {
    if (_granted.contains(permission)) {
      return true;
    }
    if (await _port.check(permission)) {
      _granted.add(permission);
      return true;
    }
    final bool granted = await _port.request(permission, whyKey);
    if (granted) {
      _granted.add(permission);
    }
    return granted;
  }
}
