/// Storage models for the on-device encrypted database.
///
/// These are deliberately plain, pure-Dart value objects: the same class
/// serves the domain repositories, the in-memory database used by tests,
/// and the row (de)serialization of the SQLCipher-backed implementation
/// that arrives with the native integration. Dates cross the boundary as
/// epoch milliseconds (`int`), the friendliest shape for SQLite.
///
/// Nothing here ever leaves the device (PRIVACY_CHARTER.md).
library;

/// A user-created reminder ("take medicine at 6pm").
class Reminder {
  const Reminder({
    required this.id,
    required this.title,
    required this.dueAt,
    required this.createdAt,
    this.done = false,
  });

  /// Local id from [newLocalId]; never synchronized anywhere.
  final String id;

  /// What to be reminded of, in the user's own words.
  final String title;

  /// When to remind. Always a local wall-clock time.
  final DateTime dueAt;

  /// When the reminder was created.
  final DateTime createdAt;

  /// Whether the user marked it done. Done items are kept until deleted.
  final bool done;

  Reminder copyWith({
    String? id,
    String? title,
    DateTime? dueAt,
    DateTime? createdAt,
    bool? done,
  }) {
    return Reminder(
      id: id ?? this.id,
      title: title ?? this.title,
      dueAt: dueAt ?? this.dueAt,
      createdAt: createdAt ?? this.createdAt,
      done: done ?? this.done,
    );
  }

  /// Row for the database: dates as epoch milliseconds.
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'title': title,
        'dueAt': dueAt.millisecondsSinceEpoch,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'done': done,
      };

  /// Rebuilds a reminder from a database row.
  factory Reminder.fromMap(Map<String, Object?> map) {
    return Reminder(
      id: map['id']! as String,
      title: map['title']! as String,
      dueAt: DateTime.fromMillisecondsSinceEpoch(map['dueAt']! as int),
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(map['createdAt']! as int),
      done: map['done'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Reminder &&
      other.id == id &&
      other.title == title &&
      other.dueAt == dueAt &&
      other.createdAt == createdAt &&
      other.done == done;

  @override
  int get hashCode => Object.hash(id, title, dueAt, createdAt, done);

  @override
  String toString() =>
      'Reminder($id, "$title", due ${dueAt.toIso8601String()}'
      '${done ? ', done' : ''})';
}

/// A dictated note ("note to self: ...").
class Note {
  const Note({
    required this.id,
    required this.body,
    required this.createdAt,
  });

  /// Local id from [newLocalId]; never synchronized anywhere.
  final String id;

  /// The dictated text, in the user's language, verbatim.
  final String body;

  /// When the note was taken.
  final DateTime createdAt;

  Note copyWith({String? id, String? body, DateTime? createdAt}) {
    return Note(
      id: id ?? this.id,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Row for the database.
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'body': body,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  /// Rebuilds a note from a database row.
  factory Note.fromMap(Map<String, Object?> map) {
    return Note(
      id: map['id']! as String,
      body: map['body']! as String,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(map['createdAt']! as int),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Note &&
      other.id == id &&
      other.body == body &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(id, body, createdAt);

  @override
  String toString() => 'Note($id, ${body.length} chars)';
}

/// One conversation turn, stored as clear text only.
///
/// PRIVACY_CHARTER.md: recordings are never persisted — this record holds
/// the transcript and the spoken reply as text, so users with partial
/// hearing can verify what was said, and everyone can delete it.
class HistoryTurn {
  const HistoryTurn({
    required this.id,
    required this.userText,
    required this.assistantText,
    required this.at,
    this.language = '',
  });

  /// Local id from [newLocalId].
  final String id;

  /// What the user said (the transcript).
  final String userText;

  /// What Vaani replied.
  final String assistantText;

  /// When the turn happened.
  final DateTime at;

  /// BCP-47 language code of the turn, when known; '' otherwise.
  final String language;

  HistoryTurn copyWith({
    String? id,
    String? userText,
    String? assistantText,
    DateTime? at,
    String? language,
  }) {
    return HistoryTurn(
      id: id ?? this.id,
      userText: userText ?? this.userText,
      assistantText: assistantText ?? this.assistantText,
      at: at ?? this.at,
      language: language ?? this.language,
    );
  }

  /// Row for the database.
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'userText': userText,
        'assistantText': assistantText,
        'at': at.millisecondsSinceEpoch,
        'language': language,
      };

  /// Rebuilds a turn from a database row.
  factory HistoryTurn.fromMap(Map<String, Object?> map) {
    return HistoryTurn(
      id: map['id']! as String,
      userText: map['userText']! as String,
      assistantText: map['assistantText']! as String,
      at: DateTime.fromMillisecondsSinceEpoch(map['at']! as int),
      language: map['language'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HistoryTurn &&
      other.id == id &&
      other.userText == userText &&
      other.assistantText == assistantText &&
      other.at == at &&
      other.language == language;

  @override
  int get hashCode => Object.hash(id, userText, assistantText, at, language);

  @override
  String toString() => 'HistoryTurn($id, "$userText")';
}

int _localIdCounter = 0;

/// Generates a reasonably unique, time-ordered local id.
///
/// Not a UUID: ids never leave the device, so uniqueness within one
/// device's lifetime is enough. Combining the clock with a per-process
/// counter keeps ids unique even within the same millisecond.
String newLocalId() {
  _localIdCounter += 1;
  final int micros = DateTime.now().microsecondsSinceEpoch;
  return 'local-$micros-${_localIdCounter.toString().padLeft(6, '0')}';
}
