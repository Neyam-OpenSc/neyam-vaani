/// Saves a dictated note ("note this down") — database backed.
library;

import '../../../../core/errors/failures.dart' show Failure;
import '../../../../core/result.dart' show Result;
import '../../../../domain/entities/action_result.dart';
import '../../../../domain/repositories/note_repository.dart';
import '../../../local/database/models.dart';

class NoteHandler implements ActionHandler {
  /// Creates a handler over [repository]. Writing to the app's own
  /// encrypted database needs no runtime permission.
  NoteHandler({required NoteRepository repository})
      : _repository = repository;

  final NoteRepository _repository;

  @override
  Future<ActionResult> execute(SlotMap slots) async {
    final String? body =
        slots.slot(ActionSlots.text) ?? slots.slot(ActionSlots.content);
    if (body == null) {
      return const ActionFailed(
        kind: ActionFailureKind.missingSlot,
        userMessageKey: ActionMessageKeys.noteMissingText,
        detail: 'note needs slot "text" (or "content")',
      );
    }
    final Result<Note> saved = await _repository.saveNote(Note(
      id: newLocalId(),
      body: body,
      createdAt: DateTime.now(),
    ));
    return saved.fold<ActionResult>(
      (Note note) => ActionSucceeded(
        userMessageKey: ActionMessageKeys.noteSaved,
        data: <String, String>{'id': note.id},
      ),
      (Failure failure) => ActionFailed(
        kind: ActionFailureKind.validation,
        userMessageKey: ActionMessageKeys.noteSaveFailed,
        detail: failure.detail,
      ),
    );
  }
}
