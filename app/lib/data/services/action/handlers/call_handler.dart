/// Places a call by voice.
library;

import '../../../../domain/entities/action_result.dart';
import '../permission_gate.dart';
import '../platform_action_port.dart';

class CallHandler implements ActionHandler {
  /// Creates a handler. [gate] holds the charter permission ("To make
  /// the call you asked for").
  CallHandler({required PlatformActionPort port, required PermissionGate gate})
      : _port = port,
        _gate = gate;

  final PlatformActionPort _port;
  final PermissionGate _gate;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    // Prefer an explicit number; contact resolution upstream may also
    // land the resolved number in the "recipient" slot.
    final String? number =
        slots.slot(ActionSlots.number) ?? slots.slot(ActionSlots.recipient);
    if (number == null) {
      return const ActionFailed(
        kind: ActionFailureKind.missingSlot,
        userMessageKey: ActionMessageKeys.callMissingNumber,
        detail: 'call needs slot "number" (or a resolved "recipient")',
      );
    }
    if (!await _gate.ensure(VaaniPermission.phone, PermissionWhyKeys.phone)) {
      return const ActionNeedsPermission(
        permission: VaaniPermission.phone,
        whyKey: PermissionWhyKeys.phone,
      );
    }
    final PlatformActionResult result = await _port.invoke(
      PlatformActionMethods.callDial,
      <String, Object?>{'number': number},
    );
    if (!result.ok) {
      return ActionFailed(
        kind: platformErrorKind(result.errorCode),
        userMessageKey: ActionMessageKeys.callFailed,
        detail: 'call.dial failed: ${result.errorCode}',
      );
    }
    return ActionSucceeded(
      userMessageKey: ActionMessageKeys.callDialing,
      data: <String, String>{'number': number},
    );
  }
}
