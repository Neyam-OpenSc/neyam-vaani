/// On-device storage contract for Vaani.
///
/// The production implementation (arriving with the native integration)
/// is a **SQLCipher-encrypted SQLite** database:
///
/// - **AES-256** full-database encryption via SQLCipher community edition.
/// - The key is generated once, held in the **Android Keystore**
///   (hardware-backed where available), and fetched at open time through
///   the `KeyStore` port (`PlatformChannelKeyStore.databaseKey()`). The
///   key itself is never written to app storage.
/// - **WAL journal mode**, so a voice-pipeline read never blocks an
///   action-layer write on a low-end phone.
/// - **Zero network**: nothing in this contract may ever leave the
///   device. No sync, no backup, no telemetry (PRIVACY_CHARTER.md).
///
/// Until that lands, [InMemoryAppDatabase] implements this contract for
/// tests and first runs — code written against this interface needs no
/// change when the encrypted database replaces it.
library;

import 'models.dart';

/// Reminders, notes, and clear-text conversation history.
abstract class AppDatabase {
  // -- Reminders (kept until the user deletes them) ----------------------

  /// Inserts [reminder], or replaces the stored one with the same id.
  Future<void> saveReminder(Reminder reminder);

  /// All reminders, soonest due first.
  ///
  /// [includeDone] false hides items the user already marked done.
  Future<List<Reminder>> listReminders({bool includeDone = true});

  /// Deletes one reminder by id; `false` when the id was unknown.
  Future<bool> deleteReminder(String id);

  /// Deletes every reminder; returns how many were removed. Backs the
  /// tender-UX "clear any data in three taps" rule.
  Future<int> deleteAllReminders();

  /// Marks the reminder done; `null` when the id was unknown.
  Future<Reminder?> markReminderDone(String id);

  // -- Notes (kept until the user deletes them) --------------------------

  /// Inserts [note], or replaces the stored one with the same id.
  Future<void> saveNote(Note note);

  /// All notes, most recent first.
  Future<List<Note>> listNotes();

  /// Deletes one note by id; `false` when the id was unknown.
  Future<bool> deleteNote(String id);

  /// Deletes every note; returns how many were removed.
  Future<int> deleteAllNotes();

  // -- Conversation history (clear text only, never audio) ---------------

  /// Appends one clear-text turn. Recordings are never persisted
  /// (PRIVACY_CHARTER.md) — audio exists in RAM only.
  Future<void> appendTurn(HistoryTurn turn);

  /// Deletes every turn strictly older than [cutoff]; returns how many
  /// were removed. This is the retention mechanism (30 days default).
  Future<int> clearHistoryBefore(DateTime cutoff);

  /// Deletes the entire conversation history. Backs the tender-UX
  /// "clear any data in three taps" rule.
  Future<void> clearAllHistory();
}
