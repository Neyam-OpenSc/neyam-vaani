/// Opens another app by voice ("open WhatsApp").
library;

import '../../../../domain/entities/action_result.dart';
import '../platform_action_port.dart';

class OpenAppHandler implements ActionHandler {
  /// Creates a handler. Launching another app needs no runtime
  /// permission; the launch itself is the user's explicit request.
  OpenAppHandler({required PlatformActionPort port}) : _port = port;

  final PlatformActionPort _port;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    final String? package = slots.slot(ActionSlots.package);
    if (package == null) {
      return const ActionFailed(
        kind: ActionFailureKind.missingSlot,
        userMessageKey: ActionMessageKeys.appMissingPackage,
        detail: 'openApp needs slot "package"',
      );
    }
    final PlatformActionResult result = await _port.invoke(
      PlatformActionMethods.appOpen,
      <String, Object?>{'package': package},
    );
    if (!result.ok) {
      return ActionFailed(
        kind: platformErrorKind(result.errorCode),
        userMessageKey: ActionMessageKeys.appFailed,
        detail: 'app.open failed: ${result.errorCode}',
      );
    }
    return ActionSucceeded(
      userMessageKey: ActionMessageKeys.appOpened,
      data: <String, String>{'package': package},
    );
  }
}
