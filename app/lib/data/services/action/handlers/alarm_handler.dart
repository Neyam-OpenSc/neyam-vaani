/// Sets an alarm ("wake me at 6").
library;

import '../../../../domain/entities/action_result.dart';
import '../permission_gate.dart';
import '../platform_action_port.dart';

class AlarmHandler implements ActionHandler {
  /// Creates a handler. [gate] holds the charter permission ("To remind
  /// you when you asked") — scheduling an alarm is a reminder promise.
  AlarmHandler({required PlatformActionPort port, required PermissionGate gate})
      : _port = port,
        _gate = gate;

  final PlatformActionPort _port;
  final PermissionGate _gate;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    final String? hour = slots.slot(ActionSlots.hour);
    final String? minute = slots.slot(ActionSlots.minute);
    if (hour == null || minute == null) {
      return const ActionFailed(
        kind: ActionFailureKind.missingSlot,
        userMessageKey: ActionMessageKeys.alarmMissingTime,
        detail: 'alarm needs slots "hour" and "minute"',
      );
    }
    final int? parsedHour = int.tryParse(hour);
    final int? parsedMinute = int.tryParse(minute);
    if (parsedHour == null ||
        parsedMinute == null ||
        parsedHour < 0 ||
        parsedHour > 23 ||
        parsedMinute < 0 ||
        parsedMinute > 59) {
      return ActionFailed(
        kind: ActionFailureKind.validation,
        userMessageKey: ActionMessageKeys.alarmInvalidTime,
        detail: 'alarm time $hour:$minute is not a valid clock time',
      );
    }
    final String label = slots.slot(ActionSlots.label) ?? '';
    if (!await _gate.ensure(
        VaaniPermission.notifications, PermissionWhyKeys.notifications)) {
      return const ActionNeedsPermission(
        permission: VaaniPermission.notifications,
        whyKey: PermissionWhyKeys.notifications,
      );
    }
    final PlatformActionResult result = await _port.invoke(
      PlatformActionMethods.alarmSet,
      <String, Object?>{
        'hour': parsedHour,
        'minute': parsedMinute,
        'label': label,
      },
    );
    if (!result.ok) {
      return ActionFailed(
        kind: platformErrorKind(result.errorCode),
        userMessageKey: ActionMessageKeys.alarmFailed,
        detail: 'alarm.set failed: ${result.errorCode}',
      );
    }
    return ActionSucceeded(
      userMessageKey: ActionMessageKeys.alarmSet,
      data: <String, String>{
        'hour': parsedHour.toString(),
        'minute': parsedMinute.toString(),
      },
    );
  }
}
