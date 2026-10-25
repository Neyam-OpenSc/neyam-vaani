/// Repository semantics: validation on save, list ordering, delete and
/// markDone behavior, and the retention rules for conversation history.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/core/result.dart';
import 'package:neyam_vaani/data/local/database/in_memory_app_database.dart';
import 'package:neyam_vaani/data/local/database/models.dart';
import 'package:neyam_vaani/data/local/preferences/app_preferences.dart';
import 'package:neyam_vaani/data/repositories/note_repository_impl.dart';
import 'package:neyam_vaani/data/repositories/reminder_repository_impl.dart';
import 'package:neyam_vaani/domain/repositories/reminder_repository.dart';

Reminder _reminder({
  String id = '',
  String title = 'buy milk',
  DateTime? dueAt,
}) {
  return Reminder(
    id: id,
    title: title,
    dueAt: dueAt ?? DateTime.now().add(const Duration(hours: 1)),
    createdAt: DateTime.now(),
  );
}

void main() {
  group('ReminderRepositoryImpl save', () {
    test('trims the title and generates an id when none is given',
        () async {
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: InMemoryAppDatabase());
      final Result<Reminder> saved =
          await repo.saveReminder(_reminder(title: '  pay the bill  '));
      expect(saved.isOk, isTrue);
      final Reminder reminder = saved.valueOrNull!;
      expect(reminder.title, 'pay the bill');
      expect(reminder.id, isNotEmpty);
    });

    test('rejects an empty or whitespace-only title', () async {
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: InMemoryAppDatabase());
      for (final String title in <String>['', '   ']) {
        final Result<Reminder> saved =
            await repo.saveReminder(_reminder(title: title));
        expect(saved.isErr, isTrue, reason: '"$title"');
        expect(saved.failureOrNull, isA<ReminderValidationFailure>());
      }
    });

    test('rejects a due time further in the past than the tolerance',
        () async {
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: InMemoryAppDatabase());
      final Result<Reminder> saved = await repo.saveReminder(_reminder(
        dueAt: DateTime.now().subtract(
            ReminderRepositoryImpl.pastDueTolerance +
                const Duration(minutes: 5)),
      ));
      expect(saved.isErr, isTrue);
      expect(saved.failureOrNull, isA<ReminderValidationFailure>());
    });

    test('accepts a due time inside the past-due tolerance', () async {
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: InMemoryAppDatabase());
      final Result<Reminder> saved = await repo.saveReminder(_reminder(
        dueAt: DateTime.now().subtract(const Duration(seconds: 30)),
      ));
      expect(saved.isOk, isTrue);
    });

    test('upserts by id instead of duplicating', () async {
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: InMemoryAppDatabase());
      await repo.saveReminder(_reminder(id: 'r1', title: 'first'));
      await repo.saveReminder(_reminder(id: 'r1', title: 'renamed'));
      final List<Reminder> listed = await repo.listReminders();
      expect(listed, hasLength(1));
      expect(listed.single.title, 'renamed');
    });
  });

  group('ReminderRepositoryImpl list and delete', () {
    test('lists reminders soonest due first', () async {
      final InMemoryAppDatabase db = InMemoryAppDatabase();
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: db);
      final DateTime now = DateTime.now();
      await repo.saveReminder(
          _reminder(id: 'late', dueAt: now.add(const Duration(days: 2))));
      await repo.saveReminder(
          _reminder(id: 'soon', dueAt: now.add(const Duration(hours: 2))));
      final List<Reminder> listed = await repo.listReminders();
      expect(listed.map((Reminder r) => r.id), <String>['soon', 'late']);
    });

    test('listReminders can hide done items', () async {
      final InMemoryAppDatabase db = InMemoryAppDatabase();
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: db);
      await repo.saveReminder(_reminder(id: 'r1'));
      await repo.saveReminder(_reminder(id: 'r2'));
      await repo.markReminderDone('r1');
      expect(await repo.listReminders(includeDone: false),
          hasLength(1));
      expect(
        (await repo.listReminders(includeDone: false)).single.id,
        'r2',
      );
    });

    test('deleteReminder reports whether the id existed', () async {
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: InMemoryAppDatabase());
      await repo.saveReminder(_reminder(id: 'r1'));
      expect(await repo.deleteReminder('r1'), isTrue);
      expect(await repo.deleteReminder('r1'), isFalse);
      expect(await repo.listReminders(), isEmpty);
    });

    test('deleteAllReminders removes everything and returns the count',
        () async {
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: InMemoryAppDatabase());
      await repo.saveReminder(_reminder(id: 'r1'));
      await repo.saveReminder(_reminder(id: 'r2'));
      expect(await repo.deleteAllReminders(), 2);
      expect(await repo.listReminders(), isEmpty);
    });

    test('markReminderDone marks, returns, and errs on unknown ids',
        () async {
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: InMemoryAppDatabase());
      await repo.saveReminder(_reminder(id: 'r1'));
      final Result<Reminder> marked = await repo.markReminderDone('r1');
      expect(marked.isOk, isTrue);
      expect(marked.valueOrNull!.done, isTrue);
      expect((await repo.listReminders()).single.done, isTrue);

      final Result<Reminder> missing = await repo.markReminderDone('nope');
      expect(missing.isErr, isTrue);
      expect(missing.failureOrNull, isA<ReminderNotFoundFailure>());
    });
  });

  group('history retention', () {
    test('clearHistoryBefore deletes only turns strictly older than the '
        'cutoff', () async {
      final InMemoryAppDatabase db = InMemoryAppDatabase();
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: db);
      final DateTime now = DateTime.now();
      await db.appendTurn(HistoryTurn(
        id: 'old1',
        userText: 'what is the time',
        assistantText: 'It is four in the evening.',
        at: now.subtract(const Duration(days: 45)),
      ));
      await db.appendTurn(HistoryTurn(
        id: 'old2',
        userText: 'set an alarm',
        assistantText: 'Alarm set for six.',
        at: now.subtract(const Duration(days: 35)),
      ));
      await db.appendTurn(HistoryTurn(
        id: 'recent',
        userText: 'read this letter',
        assistantText: 'It says...',
        at: now.subtract(const Duration(days: 2)),
      ));

      final DateTime cutoff = now.subtract(const Duration(days: 30));
      expect(await repo.clearHistoryBefore(cutoff), 2);
      // Exactly one turn survives the cutoff — the recent one: clearing
      // past "now" removes it and nothing else.
      expect(await repo.clearHistoryBefore(now.add(const Duration(days: 1))),
          1);
    });

    test('purgeExpiredHistory honors the retention preference', () async {
      final InMemoryAppDatabase db = InMemoryAppDatabase();
      final InMemoryAppPreferences prefs = InMemoryAppPreferences();
      await prefs.setString(AppPreferencesKeys.retentionDays, '7');
      final ReminderRepositoryImpl repo = ReminderRepositoryImpl(
        database: db,
        preferences: prefs,
      );
      final DateTime now = DateTime.now();
      Future<void> turn(String id, Duration age) async {
        await db.appendTurn(HistoryTurn(
          id: id,
          userText: 'question $id',
          assistantText: 'answer $id',
          at: now.subtract(age),
        ));
      }

      await turn('expired', const Duration(days: 10));
      await turn('kept', const Duration(days: 2));
      expect(await repo.purgeExpiredHistory(), 1);
      // The kept turn is still there; this clear removes exactly it.
      expect(await repo.clearHistoryBefore(now.add(const Duration(days: 1))),
          1);
    });

    test('purgeExpiredHistory falls back to the 30-day charter default',
        () async {
      final InMemoryAppDatabase db = InMemoryAppDatabase();
      final ReminderRepositoryImpl repo =
          ReminderRepositoryImpl(database: db);
      final DateTime now = DateTime.now();
      await db.appendTurn(HistoryTurn(
        id: 'month-old',
        userText: 'old question',
        assistantText: 'old answer',
        at: now.subtract(const Duration(days: 40)),
      ));
      await db.appendTurn(HistoryTurn(
        id: 'this-month',
        userText: 'new question',
        assistantText: 'new answer',
        at: now.subtract(const Duration(days: 3)),
      ));
      expect(await repo.purgeExpiredHistory(), 1);
      expect(await repo.clearHistoryBefore(now.add(const Duration(days: 1))),
          1);
    });
  });

  group('NoteRepositoryImpl', () {
    test('saves, lists newest first, and validates the body', () async {
      final NoteRepositoryImpl repo =
          NoteRepositoryImpl(database: InMemoryAppDatabase());
      final Result<Note> blank = await repo.saveNote(Note(
        id: 'n0',
        body: '   ',
        createdAt: DateTime.now(),
      ));
      expect(blank.isErr, isTrue);
      expect(blank.failureOrNull!.userMessageKey, 'action.note.invalid');

      final DateTime now = DateTime.now();
      final Result<Note> first = await repo.saveNote(Note(
        id: 'n1',
        body: 'first note',
        createdAt: now.subtract(const Duration(minutes: 10)),
      ));
      expect(first.isOk, isTrue);
      await repo.saveNote(Note(
        id: 'n2',
        body: 'second note',
        createdAt: now,
      ));
      final List<Note> listed = await repo.listNotes();
      expect(listed.map((Note n) => n.id), <String>['n2', 'n1']);
    });

    test('deleteNote reports existence; deleteAllNotes counts', () async {
      final NoteRepositoryImpl repo =
          NoteRepositoryImpl(database: InMemoryAppDatabase());
      await repo.saveNote(
          Note(id: 'n1', body: 'a', createdAt: DateTime.now()));
      expect(await repo.deleteNote('n1'), isTrue);
      expect(await repo.deleteNote('n1'), isFalse);
      await repo.saveNote(
          Note(id: 'n2', body: 'b', createdAt: DateTime.now()));
      await repo.saveNote(
          Note(id: 'n3', body: 'c', createdAt: DateTime.now()));
      expect(await repo.deleteAllNotes(), 2);
      expect(await repo.listNotes(), isEmpty);
    });
  });

  group('storage models', () {
    test('Reminder and Note round-trip through their row maps', () {
      final Reminder reminder = Reminder(
        id: 'r1',
        title: 'take medicine',
        dueAt: DateTime(2026, 10, 26, 18),
        createdAt: DateTime(2026, 10, 25, 6),
        done: true,
      );
      expect(Reminder.fromMap(reminder.toMap()), reminder);

      final Note note = Note(
        id: 'n1',
        body: 'bill due',
        createdAt: DateTime(2026, 10, 25, 7, 30),
      );
      expect(Note.fromMap(note.toMap()), note);
    });
  });
}
