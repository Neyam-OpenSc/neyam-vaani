/// Saves a reminder ("remind me to take medicine at 6pm") — database
/// backed, not a native alarm.
library;

import '../../../../core/errors/failures.dart' show Failure;
import '../../../../core/result.dart' show Result;
import '../../../../domain/entities/action_result.dart';
import '../../../../domain/repositories/reminder_repository.dart';
import '../../../local/database/models.dart';
import '../permission_gate.dart';

class ReminderHandler implements ActionHandler {
  /// Creates a handler over [repository]. [gate] holds the charter
  /// permission ("To remind you when you asked").
  ReminderHandler({
    required ReminderRepository repository,
    required PermissionGate gate,
  })  : _repository = repository,
        _gate = gate;

  final ReminderRepository _repository;
  final PermissionGate _gate;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    final String? title =
        slots.slot(ActionSlots.label) ?? slots.slot(ActionSlots.content);
    final String? time = slots.slot(ActionSlots.time);
    if (title == null || time == null) {
      return const ActionFailed(
        kind: ActionFailureKind.missingSlot,
        userMessageKey: ActionMessageKeys.reminderMissingDetails,
        detail: 'reminder needs slots "label" (or "content") and "time"',
      );
    }
    final DateTime? dueAt = _parseWhen(time);
    if (dueAt == null) {
      return ActionFailed(
        kind: ActionFailureKind.validation,
        userMessageKey: ActionMessageKeys.reminderInvalidTime,
        detail: 'reminder time "$time" could not be understood',
      );
    }
    if (!await _gate.ensure(
        VaaniPermission.notifications, PermissionWhyKeys.notifications)) {
      return const ActionNeedsPermission(
        permission: VaaniPermission.notifications,
        whyKey: PermissionWhyKeys.notifications,
      );
    }
    final Result<Reminder> saved = await _repository.saveReminder(Reminder(
      id: newLocalId(),
      title: title,
      dueAt: dueAt,
      createdAt: DateTime.now(),
    ));
    return saved.fold<ActionResult>(
      (Reminder reminder) => ActionSucceeded(
        userMessageKey: ActionMessageKeys.reminderSaved,
        data: <String, String>{
          'id': reminder.id,
          'dueAt': reminder.dueAt.toIso8601String(),
        },
      ),
      (Failure failure) => ActionFailed(
        kind: ActionFailureKind.validation,
        userMessageKey: ActionMessageKeys.reminderSaveFailed,
        detail: failure.detail,
      ),
    );
  }

  /// Understands `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM`, and a bare `HH:MM`
  /// (which means today at that time — no silent day-rollover guessing;
  /// the user hears the time echoed back and can correct it).
  static DateTime? _parseWhen(String raw) {
    final DateTime? parsed = DateTime.tryParse(raw.trim());
    if (parsed != null) {
      return parsed;
    }
    final RegExpMatch? match = _clockTime.firstMatch(raw.trim());
    if (match == null) {
      return null;
    }
    final int hour = int.parse(match.group(1)!);
    final int minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) {
      return null;
    }
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day, hour, minute);
  }
}

final RegExp _clockTime = RegExp(r'^(\d{1,2}):(\d{2})$');
