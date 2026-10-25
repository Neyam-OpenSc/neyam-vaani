/// A complete in-memory [AppDatabase].
///
/// Serves tests and first runs until the SQLCipher-backed implementation
/// arrives with the native integration (see [AppDatabase] for what that
/// will guarantee). Data lives only for the process lifetime.
library;

import 'app_database.dart';
import 'models.dart';

/// List-backed implementation of the whole storage contract.
class InMemoryAppDatabase implements AppDatabase {
  final List<Reminder> _reminders = <Reminder>[];
  final List<Note> _notes = <Note>[];
  final List<HistoryTurn> _history = <HistoryTurn>[];

  // -- Reminders ----------------------------------------------------------

  @override
  Future<void> saveReminder(Reminder reminder) async {
    final int index =
        _reminders.indexWhere((Reminder r) => r.id == reminder.id);
    if (index >= 0) {
      _reminders[index] = reminder;
    } else {
      _reminders.add(reminder);
    }
  }

  @override
  Future<List<Reminder>> listReminders({bool includeDone = true}) async {
    final List<Reminder> found = _reminders
        .where((Reminder r) => includeDone || !r.done)
        .toList(growable: false);
    found.sort((Reminder a, Reminder b) => a.dueAt.compareTo(b.dueAt));
    return found;
  }

  @override
  Future<bool> deleteReminder(String id) async {
    final int index = _reminders.indexWhere((Reminder r) => r.id == id);
    if (index < 0) {
      return false;
    }
    _reminders.removeAt(index);
    return true;
  }

  @override
  Future<int> deleteAllReminders() async {
    final int count = _reminders.length;
    _reminders.clear();
    return count;
  }

  @override
  Future<Reminder?> markReminderDone(String id) async {
    final int index = _reminders.indexWhere((Reminder r) => r.id == id);
    if (index < 0) {
      return null;
    }
    final Reminder done = _reminders[index].copyWith(done: true);
    _reminders[index] = done;
    return done;
  }

  // -- Notes --------------------------------------------------------------

  @override
  Future<void> saveNote(Note note) async {
    final int index = _notes.indexWhere((Note n) => n.id == note.id);
    if (index >= 0) {
      _notes[index] = note;
    } else {
      _notes.add(note);
    }
  }

  @override
  Future<List<Note>> listNotes() async {
    final List<Note> notes = List<Note>.of(_notes);
    notes.sort((Note a, Note b) => b.createdAt.compareTo(a.createdAt));
    return notes;
  }

  @override
  Future<bool> deleteNote(String id) async {
    final int index = _notes.indexWhere((Note n) => n.id == id);
    if (index < 0) {
      return false;
    }
    _notes.removeAt(index);
    return true;
  }

  @override
  Future<int> deleteAllNotes() async {
    final int count = _notes.length;
    _notes.clear();
    return count;
  }

  // -- Conversation history ------------------------------------------------

  @override
  Future<void> appendTurn(HistoryTurn turn) async {
    _history.add(turn);
  }

  @override
  Future<int> clearHistoryBefore(DateTime cutoff) async {
    final int before = _history.length;
    _history.removeWhere((HistoryTurn t) => t.at.isBefore(cutoff));
    return before - _history.length;
  }

  @override
  Future<void> clearAllHistory() async {
    _history.clear();
  }
}
