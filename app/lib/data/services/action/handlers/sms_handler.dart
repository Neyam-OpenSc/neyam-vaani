/// Sends an SMS directly (not via the messaging app).
library;

import '../../../../domain/entities/action_result.dart';
import '../permission_gate.dart';
import '../platform_action_port.dart';

class SmsHandler implements ActionHandler {
  /// Creates a handler. [port] performs the send; [gate] holds the
  /// charter permission ("To send the message you asked for").
  SmsHandler({required PlatformActionPort port, required PermissionGate gate})
      : _port = port,
        _gate = gate;

  final PlatformActionPort _port;
  final PermissionGate _gate;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    final String? recipient = slots.slot(ActionSlots.recipient);
    final String? content = slots.slot(ActionSlots.content);
    if (recipient == null || content == null) {
      return const ActionFailed(
        kind: ActionFailureKind.missingSlot,
        userMessageKey: ActionMessageKeys.smsMissingDetails,
        detail: 'sms needs slots "recipient" and "content"',
      );
    }
    if (!await _gate.ensure(VaaniPermission.sms, PermissionWhyKeys.sms)) {
      return const ActionNeedsPermission(
        permission: VaaniPermission.sms,
        whyKey: PermissionWhyKeys.sms,
      );
    }
    final PlatformActionResult result = await _port.invoke(
      PlatformActionMethods.smsSend,
      <String, Object?>{'recipient': recipient, 'content': content},
    );
    if (!result.ok) {
      return ActionFailed(
        kind: platformErrorKind(result.errorCode),
        userMessageKey: ActionMessageKeys.smsFailed,
        detail: 'sms.send failed: ${result.errorCode}',
      );
    }
    return ActionSucceeded(
      userMessageKey: ActionMessageKeys.smsSent,
      data: <String, String>{'recipient': recipient},
    );
  }
}
