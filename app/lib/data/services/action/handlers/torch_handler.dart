/// Turns the flashlight on or off.
library;

import '../../../../domain/entities/action_result.dart';
import '../platform_action_port.dart';

class TorchHandler implements ActionHandler {
  /// Creates a handler for one direction of the toggle. [on] is fixed at
  /// construction so [VaaniAction.torchOn] and [VaaniAction.torchOff]
  /// stay two distinct, unambiguous routes.
  const TorchHandler({required PlatformActionPort port, required this.on})
      : _port = port;

  final PlatformActionPort _port;

  /// Whether this instance turns the torch on (true) or off (false).
  final bool on;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    final PlatformActionResult result = await _port.invoke(
      PlatformActionMethods.torchSet,
      <String, Object?>{'on': on},
    );
    if (!result.ok) {
      return ActionFailed(
        kind: platformErrorKind(result.errorCode),
        userMessageKey: ActionMessageKeys.torchFailed,
        detail: 'torch.set failed: ${result.errorCode}',
      );
    }
    return ActionSucceeded(
      userMessageKey:
          on ? ActionMessageKeys.torchOn : ActionMessageKeys.torchOff,
    );
  }
}
