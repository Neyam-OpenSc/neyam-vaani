/// Behavior of the action layer: slot validation, the permission gate,
/// and dispatch to the right platform method with the right arguments.
///
/// Everything native is faked ([FakePlatformActionPort],
/// [FakePermissionsPort]); the database-backed actions run against
/// [InMemoryAppDatabase].
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/data/local/database/in_memory_app_database.dart';
import 'package:neyam_vaani/data/local/database/models.dart'
    show Note, Reminder;
import 'package:neyam_vaani/data/repositories/note_repository_impl.dart';
import 'package:neyam_vaani/data/repositories/reminder_repository_impl.dart';
import 'package:neyam_vaani/data/services/action/action_dispatcher.dart';
import 'package:neyam_vaani/data/services/action/permission_gate.dart';
import 'package:neyam_vaani/data/services/action/platform_action_port.dart';
import 'package:neyam_vaani/domain/entities/action_result.dart';

/// One dispatcher wired entirely to fakes, plus the fakes to inspect.
class _Harness {
  final InMemoryAppDatabase database = InMemoryAppDatabase();
  final FakePlatformActionPort port = FakePlatformActionPort();
  final FakePermissionsPort permissions = FakePermissionsPort();

  ActionDispatcher dispatcher({
    Map<VaaniAction, ActionHandler>? handlers,
    PermissionGate? permissionGate,
  }) {
    return ActionDispatcher(
      actionPort: port,
      permissionsPort: permissions,
      reminderRepository: ReminderRepositoryImpl(database: database),
      noteRepository: NoteRepositoryImpl(database: database),
      permissionGate: permissionGate,
      handlers: handlers,
    );
  }
}

void main() {
  group('slot validation', () {
    test('sms without recipient or content fails with missingSlot and '
        'never asks for permission', () async {
      final _Harness harness = _Harness();
      final ActionResult result = await harness
          .dispatcher()
          .execute(VaaniAction.sendSms, <String, String>{});
      expect(result, isA<ActionFailed>());
      final ActionFailed failure = result as ActionFailed;
      expect(failure.kind, ActionFailureKind.missingSlot);
      expect(failure.userMessageKey, ActionMessageKeys.smsMissingDetails);
      expect(harness.permissions.checkCount, 0);
      expect(harness.port.calls, isEmpty);
    });

    test('whatsapp with a recipient but no content fails with missingSlot',
        () async {
      final _Harness harness = _Harness();
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.sendWhatsapp,
        <String, String>{'recipient': 'amma'},
      );
      expect(result, isA<ActionFailed>());
      final ActionFailed failure = result as ActionFailed;
      expect(failure.kind, ActionFailureKind.missingSlot);
      expect(
          failure.userMessageKey, ActionMessageKeys.whatsappMissingDetails);
    });

    test('alarm without hour or minute fails with missingSlot', () async {
      final _Harness harness = _Harness();
      final ActionResult result = await harness
          .dispatcher()
          .execute(VaaniAction.setAlarm, <String, String>{});
      expect(result, isA<ActionFailed>());
      final ActionFailed failure = result as ActionFailed;
      expect(failure.kind, ActionFailureKind.missingSlot);
      expect(failure.userMessageKey, ActionMessageKeys.alarmMissingTime);
    });

    test('alarm with an impossible hour fails with kind validation',
        () async {
      final _Harness harness = _Harness();
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.setAlarm,
        <String, String>{'hour': '25', 'minute': '00'},
      );
      expect(result, isA<ActionFailed>());
      final ActionFailed failure = result as ActionFailed;
      expect(failure.kind, ActionFailureKind.validation);
      expect(failure.userMessageKey, ActionMessageKeys.alarmInvalidTime);
      expect(harness.permissions.checkCount, 0);
    });
  });

  group('permission gate', () {
    test('denied SMS permission surfaces ActionNeedsPermission with the '
        'charter whyKey and never touches the port', () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = false;
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.sendSms,
        <String, String>{'recipient': '9876543210', 'content': 'Coming'},
      );
      expect(result, isA<ActionNeedsPermission>());
      final ActionNeedsPermission needs = result as ActionNeedsPermission;
      expect(needs.permission, VaaniPermission.sms);
      expect(needs.whyKey, PermissionWhyKeys.sms);
      expect(harness.permissions.requests.single.permission,
          VaaniPermission.sms);
      expect(harness.permissions.requests.single.whyKey,
          PermissionWhyKeys.sms);
      expect(harness.port.calls, isEmpty);
    });

    test('denied phone permission carries the phone charter whyKey',
        () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = false;
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.makeCall,
        <String, String>{'number': '9876543210'},
      );
      final ActionNeedsPermission needs = result as ActionNeedsPermission;
      expect(needs.permission, VaaniPermission.phone);
      expect(needs.whyKey, PermissionWhyKeys.phone);
    });

    test('a granted permission is remembered: the next action does not '
        'ask again', () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = true;
      final SlotMap slots = <String, String>{
        'recipient': '9876543210',
        'content': 'Hello',
      };
      expect(
        await harness.dispatcher().execute(VaaniAction.sendSms, slots),
        isA<ActionSucceeded>(),
      );
      expect(
        await harness.dispatcher().execute(VaaniAction.sendSms, slots),
        isA<ActionSucceeded>(),
      );
      expect(harness.permissions.requests, hasLength(1));
    });
  });

  group('dispatch to the platform port', () {
    test('sendSms invokes sms.send with recipient and content', () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = true;
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.sendSms,
        <String, String>{
          'recipient': '9876543210',
          'content': 'I will reach by six',
        },
      );
      expect(result, isA<ActionSucceeded>());
      expect(
          (result as ActionSucceeded).userMessageKey,
          ActionMessageKeys.smsSent);
      expect(harness.port.calls, hasLength(1));
      expect(harness.port.calls.single.method, 'sms.send');
      expect(harness.port.calls.single.args['recipient'], '9876543210');
      expect(
          harness.port.calls.single.args['content'], 'I will reach by six');
    });

    test('makeCall invokes call.dial with the number slot', () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = true;
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.makeCall,
        <String, String>{'number': '1122334455'},
      );
      expect(result, isA<ActionSucceeded>());
      expect(
          (result as ActionSucceeded).userMessageKey,
          ActionMessageKeys.callDialing);
      expect(harness.port.calls.single.method, 'call.dial');
      expect(harness.port.calls.single.args['number'], '1122334455');
    });

    test('makeCall falls back to the recipient slot for the number',
        () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = true;
      await harness.dispatcher().execute(
        VaaniAction.makeCall,
        <String, String>{'recipient': '9876543210'},
      );
      expect(harness.port.calls.single.args['number'], '9876543210');
    });

    test('setAlarm invokes alarm.set with parsed hour, minute and label',
        () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = true;
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.setAlarm,
        <String, String>{'hour': '6', 'minute': '30', 'label': 'medicine'},
      );
      expect(result, isA<ActionSucceeded>());
      expect(
          (result as ActionSucceeded).userMessageKey,
          ActionMessageKeys.alarmSet);
      expect(harness.port.calls.single.method, 'alarm.set');
      expect(harness.port.calls.single.args['hour'], 6);
      expect(harness.port.calls.single.args['minute'], 30);
      expect(harness.port.calls.single.args['label'], 'medicine');
    });

    test('copyText invokes clipboard.copy without asking any permission',
        () async {
      final _Harness harness = _Harness();
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.copyText,
        <String, String>{'text': '25 times 48 is 1200'},
      );
      expect(result, isA<ActionSucceeded>());
      expect(
          (result as ActionSucceeded).userMessageKey,
          ActionMessageKeys.clipboardCopied);
      expect(harness.port.calls.single.method, 'clipboard.copy');
      expect(
          harness.port.calls.single.args['text'], '25 times 48 is 1200');
      expect(harness.permissions.checkCount, 0);
      expect(harness.permissions.requests, isEmpty);
    });

    test('openApp invokes app.open with the package name', () async {
      final _Harness harness = _Harness();
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.openApp,
        <String, String>{'package': 'com.whatsapp'},
      );
      expect(result, isA<ActionSucceeded>());
      expect(
          (result as ActionSucceeded).userMessageKey,
          ActionMessageKeys.appOpened);
      expect(harness.port.calls.single.method, 'app.open');
      expect(harness.port.calls.single.args['package'], 'com.whatsapp');
    });

    test('sendWhatsapp invokes whatsapp.send without any permission',
        () async {
      final _Harness harness = _Harness();
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.sendWhatsapp,
        <String, String>{'recipient': 'amma', 'content': 'Starting now'},
      );
      expect(result, isA<ActionSucceeded>());
      expect(
          (result as ActionSucceeded).userMessageKey,
          ActionMessageKeys.whatsappSent);
      expect(harness.port.calls.single.method, 'whatsapp.send');
      expect(harness.port.calls.single.args['recipient'], 'amma');
      expect(harness.port.calls.single.args['content'], 'Starting now');
      expect(harness.permissions.checkCount, 0);
    });
  });

  group('torch routing', () {
    test('torchOn and torchOff both invoke torch.set with the right flag',
        () async {
      final _Harness harness = _Harness();
      final ActionResult on = await harness
          .dispatcher()
          .execute(VaaniAction.torchOn, <String, String>{});
      expect(on, isA<ActionSucceeded>());
      expect((on as ActionSucceeded).userMessageKey,
          ActionMessageKeys.torchOn);
      expect(harness.port.calls.single.method, 'torch.set');
      expect(harness.port.calls.single.args['on'], isTrue);

      final ActionResult off = await harness
          .dispatcher()
          .execute(VaaniAction.torchOff, <String, String>{});
      expect(off, isA<ActionSucceeded>());
      expect((off as ActionSucceeded).userMessageKey,
          ActionMessageKeys.torchOff);
      expect(harness.port.calls.last.method, 'torch.set');
      expect(harness.port.calls.last.args['on'], isFalse);
    });
  });

  group('database-backed actions', () {
    test('setReminder stores the reminder and echoes the due time',
        () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = true;
      final DateTime due = DateTime.now().add(const Duration(hours: 3));
      final SlotMap reminderSlots = <String, String>{
        'label': 'take medicine',
        'time': due.toIso8601String(),
      };
      final ActionResult result = await harness
          .dispatcher()
          .execute(VaaniAction.setReminder, reminderSlots);
      expect(result, isA<ActionSucceeded>());
      final ActionSucceeded succeeded = result as ActionSucceeded;
      expect(succeeded.userMessageKey, ActionMessageKeys.reminderSaved);
      expect(succeeded.data['dueAt'], due.toIso8601String());
      final List<Reminder> stored = await harness.database.listReminders();
      expect(stored, hasLength(1));
      expect(stored.single.title, 'take medicine');
      expect(stored.single.dueAt, due);
      expect(stored.single.done, isFalse);
    });

    test('setReminder with an unparseable time fails with kind validation',
        () async {
      final _Harness harness = _Harness()
        ..permissions.requestOutcome = true;
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.setReminder,
        <String, String>{'label': 'call amma', 'time': 'sometime'},
      );
      expect(result, isA<ActionFailed>());
      final ActionFailed failure = result as ActionFailed;
      expect(failure.kind, ActionFailureKind.validation);
      expect(failure.userMessageKey, ActionMessageKeys.reminderInvalidTime);
    });

    test('saveNote stores the dictated body through the repository',
        () async {
      final _Harness harness = _Harness();
      final ActionResult result = await harness.dispatcher().execute(
        VaaniAction.saveNote,
        <String, String>{'text': 'electricity bill due on the 12th'},
      );
      expect(result, isA<ActionSucceeded>());
      expect(
          (result as ActionSucceeded).userMessageKey,
          ActionMessageKeys.noteSaved);
      expect(harness.port.calls, isEmpty);
      final List<Note> stored = await harness.database.listNotes();
      expect(stored, hasLength(1));
      expect(stored.single.body, 'electricity bill due on the 12th');
    });
  });

  group('failure mapping', () {
    test('a platform error becomes ActionFailed with kind platformError',
        () async {
      final InMemoryAppDatabase database = InMemoryAppDatabase();
      final FakePlatformActionPort port = FakePlatformActionPort(
        respond: (String method, Map<String, Object?> args) =>
            const PlatformActionResult(ok: false, errorCode: 'io_error'),
      );
      final ActionDispatcher dispatcher = ActionDispatcher(
        actionPort: port,
        permissionsPort: FakePermissionsPort(),
        reminderRepository: ReminderRepositoryImpl(database: database),
        noteRepository: NoteRepositoryImpl(database: database),
      );
      final ActionResult result = await dispatcher.execute(
        VaaniAction.copyText,
        <String, String>{'text': 'hello'},
      );
      expect(result, isA<ActionFailed>());
      final ActionFailed failure = result as ActionFailed;
      expect(failure.kind, ActionFailureKind.platformError);
      expect(failure.userMessageKey, ActionMessageKeys.clipboardFailed);
      expect(failure.detail, contains('io_error'));
    });

    test('a permission-ish platform error keeps kind permissionDenied',
        () async {
      final InMemoryAppDatabase database = InMemoryAppDatabase();
      final FakePlatformActionPort port = FakePlatformActionPort(
        respond: (String method, Map<String, Object?> args) =>
            const PlatformActionResult(
                ok: false, errorCode: 'permissionDenied'),
      );
      final ActionDispatcher dispatcher = ActionDispatcher(
        actionPort: port,
        permissionsPort: FakePermissionsPort(requestOutcome: true),
        reminderRepository: ReminderRepositoryImpl(database: database),
        noteRepository: NoteRepositoryImpl(database: database),
      );
      final ActionResult result = await dispatcher.execute(
        VaaniAction.makeCall,
        <String, String>{'number': '9876543210'},
      );
      expect(result, isA<ActionFailed>());
      expect(
          (result as ActionFailed).kind, ActionFailureKind.permissionDenied);
    });

    test('an action with no registered handler fails with kind validation',
        () async {
      final _Harness harness = _Harness();
      final ActionDispatcher empty = harness.dispatcher(
        handlers: <VaaniAction, ActionHandler>{},
      );
      final ActionResult result = await empty.execute(
        VaaniAction.sendSms,
        <String, String>{'recipient': '9876543210', 'content': 'Hello'},
      );
      expect(result, isA<ActionFailed>());
      final ActionFailed failure = result as ActionFailed;
      expect(failure.kind, ActionFailureKind.validation);
      expect(failure.userMessageKey, ActionMessageKeys.unknownAction);
    });
  });
}
