/// [NoteRepository] over any [AppDatabase].
///
/// As with reminders: validation lives here so handlers and screens get
/// identical rules, and the database stays a replaceable store.
library;

import '../../core/result.dart';
import '../../domain/repositories/note_repository.dart';
import '../local/database/app_database.dart';
import '../local/database/models.dart';

class NoteRepositoryImpl implements NoteRepository {
  /// Creates a repository over [database].
  NoteRepositoryImpl({required AppDatabase database}) : _database = database;

  final AppDatabase _database;

  @override
  Future<Result<Note>> saveNote(Note note) async {
    final String body = note.body.trim();
    if (body.isEmpty) {
      return const Err<Note>(NoteValidationFailure('blank body'));
    }
    final Note stored = note.copyWith(
      id: note.id.isEmpty ? newLocalId() : note.id,
      body: body,
    );
    await _database.saveNote(stored);
    return Ok<Note>(stored);
  }

  @override
  Future<List<Note>> listNotes() {
    return _database.listNotes();
  }

  @override
  Future<bool> deleteNote(String id) {
    return _database.deleteNote(id);
  }

  @override
  Future<int> deleteAllNotes() {
    return _database.deleteAllNotes();
  }
}
