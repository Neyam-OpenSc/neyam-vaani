/// Hands a dictated message to WhatsApp.
///
/// No runtime permission is requested: the message is handed off to the
/// WhatsApp app, where the user sees and sends it themselves — the user
/// stays in control (tender UX), and the charter's SMS permission is not
/// spent on an action that does not need it.
library;

import '../../../../domain/entities/action_result.dart';
import '../platform_action_port.dart';

class WhatsappHandler implements ActionHandler {
  /// Creates a handler over [port].
  WhatsappHandler({required PlatformActionPort port}) : _port = port;

  final PlatformActionPort _port;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    final String? recipient = slots.slot(ActionSlots.recipient);
    final String? content = slots.slot(ActionSlots.content);
    if (recipient == null || content == null) {
      return const ActionFailed(
        kind: ActionFailureKind.missingSlot,
        userMessageKey: ActionMessageKeys.whatsappMissingDetails,
        detail: 'whatsapp needs slots "recipient" and "content"',
      );
    }
    final PlatformActionResult result = await _port.invoke(
      PlatformActionMethods.whatsappSend,
      <String, Object?>{'recipient': recipient, 'content': content},
    );
    if (!result.ok) {
      return ActionFailed(
        kind: platformErrorKind(result.errorCode),
        userMessageKey: ActionMessageKeys.whatsappFailed,
        detail: 'whatsapp.send failed: ${result.errorCode}',
      );
    }
    return ActionSucceeded(
      userMessageKey: ActionMessageKeys.whatsappSent,
      data: <String, String>{'recipient': recipient},
    );
  }
}
