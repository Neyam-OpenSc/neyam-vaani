/// Persistence contract for dictated notes.
///
/// Notes live in the encrypted on-device database until the user deletes
/// them (PRIVACY_CHARTER.md). Fallible operations return [Result] and
/// never throw.
library;

import '../../core/errors/failures.dart';
import '../../core/result.dart';
import '../../data/local/database/models.dart';
import '../entities/action_result.dart' show ActionMessageKeys;

/// A note failed validation (blank body).
final class NoteValidationFailure extends Failure {
  const NoteValidationFailure(super.detail);

  @override
  FailureKind get kind => FailureKind.unknown;

  @override
  String get userMessageKey => ActionMessageKeys.noteInvalid;
}

/// Saves, lists, and deletes notes.
abstract class NoteRepository {
  /// Validates and persists [note] (upsert by id).
  ///
  /// Validation: a non-blank body. Returns [Err] with
  /// [NoteValidationFailure] otherwise, and [Ok] with the note as stored
  /// (trimmed body, generated id when empty).
  Future<Result<Note>> saveNote(Note note);

  /// All notes, most recent first.
  Future<List<Note>> listNotes();

  /// Deletes one note by id; `false` when the id was unknown.
  Future<bool> deleteNote(String id);

  /// Deletes every note; returns how many were removed. Backs the
  /// tender-UX "clear any data in three taps" rule.
  Future<int> deleteAllNotes();
}
