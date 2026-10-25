/// Routes a classified intent to its device-action handler.
///
/// The dispatcher is deliberately boring: one [VaaniAction] maps to one
/// [ActionHandler], registration happens once in the constructor, and
/// everything the handlers need (ports, gate, repositories) is injected
/// so tests — and later the riverpod wiring — can substitute fakes.
library;

import '../../../domain/entities/action_result.dart';
import '../../../domain/repositories/note_repository.dart';
import '../../../domain/repositories/reminder_repository.dart';
import 'handlers/alarm_handler.dart';
import 'handlers/call_handler.dart';
import 'handlers/clipboard_handler.dart';
import 'handlers/note_handler.dart';
import 'handlers/open_app_handler.dart';
import 'handlers/reminder_handler.dart';
import 'handlers/sms_handler.dart';
import 'handlers/torch_handler.dart';
import 'handlers/whatsapp_handler.dart';
import 'permission_gate.dart';
import 'platform_action_port.dart';

/// The device actions the dispatcher can route to.
///
/// Companion of `VaaniIntent` in the intent layer: the intent classifier
/// decides *what the user wants*; [VaaniAction] names *what the device
/// does* about it. One intent may map to more than one action (an alarm
/// and a reminder are both scheduled through their own action).
enum VaaniAction {
  /// Send an SMS directly.
  sendSms,

  /// Place a phone call.
  makeCall,

  /// Set a native alarm clock.
  setAlarm,

  /// Save a reminder in the encrypted database.
  setReminder,

  /// Copy text to the clipboard.
  copyText,

  /// Open another app by package name.
  openApp,

  /// Save a dictated note in the encrypted database.
  saveNote,

  /// Turn the flashlight on.
  torchOn,

  /// Turn the flashlight off.
  torchOff,

  /// Hand a message to WhatsApp.
  sendWhatsapp,
}

class ActionDispatcher {
  /// Creates a dispatcher with every [VaaniAction] registered.
  ///
  /// [actionPort] and [permissionsPort] are the native channels (inject
  /// fakes in tests); [reminderRepository] and [noteRepository] back the
  /// storage-backed actions; [permissionGate] overrides the default gate
  /// built over [permissionsPort] when a caller wants to share one gate
  /// across dispatchers; [handlers] replaces the whole registration map
  /// (niche — tests of the unknown-action path).
  ActionDispatcher({
    required PlatformActionPort actionPort,
    required PermissionsPort permissionsPort,
    required ReminderRepository reminderRepository,
    required NoteRepository noteRepository,
    PermissionGate? permissionGate,
    Map<VaaniAction, ActionHandler>? handlers,
  }) {
    final PermissionGate gate =
        permissionGate ?? PermissionGate(port: permissionsPort);
    _handlers = handlers ??
        <VaaniAction, ActionHandler>{
          VaaniAction.sendSms:
              SmsHandler(port: actionPort, gate: gate),
          VaaniAction.makeCall:
              CallHandler(port: actionPort, gate: gate),
          VaaniAction.setAlarm:
              AlarmHandler(port: actionPort, gate: gate),
          VaaniAction.setReminder:
              ReminderHandler(repository: reminderRepository, gate: gate),
          VaaniAction.copyText: ClipboardHandler(port: actionPort),
          VaaniAction.openApp: OpenAppHandler(port: actionPort),
          VaaniAction.saveNote: NoteHandler(repository: noteRepository),
          VaaniAction.torchOn: TorchHandler(port: actionPort, on: true),
          VaaniAction.torchOff: TorchHandler(port: actionPort, on: false),
          VaaniAction.sendWhatsapp: WhatsappHandler(port: actionPort),
        };
  }

  late final Map<VaaniAction, ActionHandler> _handlers;

  /// Runs [action] with [slots]; never throws, always answers with an
  /// [ActionResult]. An unregistered action fails with
  /// [ActionFailureKind.validation] — honest, not a crash.
  Future<ActionResult> execute(VaaniAction action, SlotMap slots) async {
    final ActionHandler? handler = _handlers[action];
    if (handler == null) {
      return ActionFailed(
        kind: ActionFailureKind.validation,
        userMessageKey: ActionMessageKeys.unknownAction,
        detail: 'no handler registered for ${action.name}',
      );
    }
    return handler.execute(slots);
  }
}
