/// Copies dictated text to the clipboard ("copy that").
library;

import '../../../../domain/entities/action_result.dart';
import '../platform_action_port.dart';

class ClipboardHandler implements ActionHandler {
  /// Creates a handler. The clipboard needs no runtime permission on
  /// Android; there is no gate to pass.
  ClipboardHandler({required PlatformActionPort port}) : _port = port;

  final PlatformActionPort _port;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    final String? text = slots.slot(ActionSlots.text) ??
        slots.slot(ActionSlots.content);
    if (text == null) {
      return const ActionFailed(
        kind: ActionFailureKind.missingSlot,
        userMessageKey: ActionMessageKeys.clipboardMissingText,
        detail: 'clipboard needs slot "text" (or "content")',
      );
    }
    final PlatformActionResult result = await _port.invoke(
      PlatformActionMethods.clipboardCopy,
      <String, Object?>{'text': text},
    );
    if (!result.ok) {
      return ActionFailed(
        kind: platformErrorKind(result.errorCode),
        userMessageKey: ActionMessageKeys.clipboardFailed,
        detail: 'clipboard.copy failed: ${result.errorCode}',
      );
    }
    return const ActionSucceeded(
      userMessageKey: ActionMessageKeys.clipboardCopied,
    );
  }
}
