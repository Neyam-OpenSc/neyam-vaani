/// Persistence contract for reminders and history retention.
///
/// Reminders live in the encrypted on-device database until the user
/// deletes them (PRIVACY_CHARTER.md). Conversation-history retention is
/// exposed here as well because the same database and the same
/// "clear my data" gesture (tender UX: three taps) govern both.
///
/// Fallible operations return [Result] and never throw; validation
/// failures carry [ReminderValidationFailure] with technical detail that
/// stays on the device.
library;

import '../../core/errors/failures.dart';
import '../../core/result.dart';
import '../../data/local/database/models.dart';
import '../entities/action_result.dart' show ActionMessageKeys;

/// A reminder failed validation (empty title, due time too far past).
final class ReminderValidationFailure extends Failure {
  const ReminderValidationFailure(String detail) : super(detail);

  @override
  FailureKind get kind => FailureKind.unknown;

  @override
  String get userMessageKey => ActionMessageKeys.reminderInvalid;
}

/// No reminder matched the given id.
final class ReminderNotFoundFailure extends Failure {
  const ReminderNotFoundFailure(String detail) : super(detail);

  @override
  FailureKind get kind => FailureKind.unknown;

  @override
  String get userMessageKey => ActionMessageKeys.reminderMissing;
}

/// Saves, lists, and deletes reminders; purges expired history.
abstract class ReminderRepository {
  /// Validates and persists [reminder] (upsert by id).
  ///
  /// Validation: a non-blank title, and a due time no further in the
  /// past than a small tolerance (dictation takes a moment). Returns
  /// [Err] with [ReminderValidationFailure] otherwise, and [Ok] with the
  /// reminder as stored (trimmed title, generated id when empty).
  Future<Result<Reminder>> saveReminder(Reminder reminder);

  /// All reminders, soonest due first; [includeDone] false hides done.
  Future<List<Reminder>> listReminders({bool includeDone = true});

  /// Deletes one reminder by id; `false` when the id was unknown.
  Future<bool> deleteReminder(String id);

  /// Deletes every reminder; returns how many were removed. Backs the
  /// tender-UX "clear any data in three taps" rule.
  Future<int> deleteAllReminders();

  /// Marks a reminder done; [Err] with [ReminderNotFoundFailure] when
  /// the id is unknown.
  Future<Result<Reminder>> markReminderDone(String id);

  /// Deletes conversation turns strictly older than [cutoff]; returns
  /// how many were removed.
  Future<int> clearHistoryBefore(DateTime cutoff);

  /// Deletes conversation turns older than the user's retention window
  /// (AppPreferencesKeys.retentionDays; 30 days by default — the
  /// charter's default), returning how many were removed.
  Future<int> purgeExpiredHistory();
}
