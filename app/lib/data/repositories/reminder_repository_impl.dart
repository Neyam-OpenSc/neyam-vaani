/// [ReminderRepository] over any [AppDatabase].
///
/// Validation happens here, once, so every caller (action handlers, the
/// reminders screen) gets the same rules — and so the database layer
/// stays a dumb store that the encrypted implementation can swap into.
library;

import '../../core/result.dart';
import '../../domain/repositories/reminder_repository.dart';
import '../local/database/app_database.dart';
import '../local/database/models.dart';
import '../local/preferences/app_preferences.dart';

class ReminderRepositoryImpl implements ReminderRepository {
  /// Creates a repository over [database]. [preferences] supplies the
  /// retention window for [purgeExpiredHistory]; when absent, the
  /// charter default (30 days) applies.
  ReminderRepositoryImpl({required AppDatabase database,
      AppPreferences? preferences})
      : _database = database,
        _preferences = preferences;

  /// How far in the past a due time may lie and still be accepted:
  /// listening, transcribing, and confirming take a moment, and a
  /// reminder for "now" is legitimate.
  static const Duration pastDueTolerance = Duration(minutes: 2);

  final AppDatabase _database;
  final AppPreferences? _preferences;

  @override
  Future<Result<Reminder>> saveReminder(Reminder reminder) async {
    final String title = reminder.title.trim();
    if (title.isEmpty) {
      return const Err<Reminder>(ReminderValidationFailure('blank title'));
    }
    if (reminder.dueAt
        .isBefore(DateTime.now().subtract(pastDueTolerance))) {
      return Err<Reminder>(ReminderValidationFailure(
          'dueAt ${reminder.dueAt.toIso8601String()} is further in the '
          'past than the $pastDueTolerance tolerance'));
    }
    final Reminder stored = reminder.copyWith(
      id: reminder.id.isEmpty ? newLocalId() : reminder.id,
      title: title,
    );
    await _database.saveReminder(stored);
    return Ok<Reminder>(stored);
  }

  @override
  Future<List<Reminder>> listReminders({bool includeDone = true}) {
    return _database.listReminders(includeDone: includeDone);
  }

  @override
  Future<bool> deleteReminder(String id) {
    return _database.deleteReminder(id);
  }

  @override
  Future<int> deleteAllReminders() {
    return _database.deleteAllReminders();
  }

  @override
  Future<Result<Reminder>> markReminderDone(String id) async {
    final Reminder? updated = await _database.markReminderDone(id);
    if (updated == null) {
      return Err<Reminder>(
          ReminderNotFoundFailure('no reminder with id "$id"'));
    }
    return Ok<Reminder>(updated);
  }

  @override
  Future<int> clearHistoryBefore(DateTime cutoff) {
    return _database.clearHistoryBefore(cutoff);
  }

  @override
  Future<int> purgeExpiredHistory() async {
    final int retentionDays = await _retentionDays();
    final DateTime cutoff =
        DateTime.now().subtract(Duration(days: retentionDays));
    return _database.clearHistoryBefore(cutoff);
  }

  /// The user's retention window, or the charter default when unset or
  /// not a positive number.
  Future<int> _retentionDays() async {
    final AppPreferences? preferences = _preferences;
    if (preferences == null) {
      return AppPreferenceDefaults.retentionDays;
    }
    final String? raw =
        await preferences.getString(AppPreferencesKeys.retentionDays);
    final int? parsed = raw == null ? null : int.tryParse(raw);
    if (parsed == null || parsed < 1) {
      return AppPreferenceDefaults.retentionDays;
    }
    return parsed;
  }
}
