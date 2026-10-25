/// The action layer's shared contract: results, slots, permissions, and
/// the handler interface every device action implements.
///
/// Every user-facing string is a message key in the 'action.*' namespace
/// (see [ActionMessageKeys]); l10n turns keys into kind sentences in the
/// user's language. Hardcoded sentences are forbidden here — a Tamil
/// grandmother must never hear English because a developer typed one
/// (TENDER_UX_PRINCIPLES.md, PRIVACY_CHARTER.md).
library;

import 'slot.dart' show SlotNames;

/// Slot values for one action, keyed by slot name.
///
/// This is exactly what `SlotSet.toValueMap()` produces, so the intent
/// layer's output can be handed straight to the action dispatcher.
typedef SlotMap = Map<String, String>;

/// Slot keys the action layer reads.
///
/// `recipient`, `content` and `time` deliberately reuse [SlotNames] so a
/// slot set captured upstream needs no translation. The rest are
/// action-specific (`hour`, `minute`, `number`, ...).
abstract final class ActionSlots {
  /// Who the action targets (a resolved phone number or contact name).
  static const String recipient = SlotNames.recipient;

  /// The dictated body of a message or note.
  static const String content = SlotNames.content;

  /// ISO-ish due time: `YYYY-MM-DD`, `HH:MM`, or `YYYY-MM-DDTHH:MM`.
  static const String time = SlotNames.time;

  /// A phone number to dial (already resolved from contacts).
  static const String number = 'number';

  /// Alarm hour, 0–23, as digits.
  static const String hour = 'hour';

  /// Alarm minute, 0–59, as digits.
  static const String minute = 'minute';

  /// A short name for an alarm or reminder ("medicine", "school bus").
  static const String label = 'label';

  /// Free text for clipboard and note actions.
  static const String text = 'text';

  /// Android package name of the app to open.
  static const String package = 'package';
}

/// Every message key the action layer can emit, as one catalog for l10n.
///
/// Keys are stable identifiers: 'action.<thing>.<outcome>'. Never rename
/// one — localization files and the intent layer reference them verbatim.
abstract final class ActionMessageKeys {
  // -- SMS ---------------------------------------------------------------
  static const String smsSent = 'action.sms.sent';
  static const String smsMissingDetails =
      'action.sms.missing_details';
  static const String smsFailed = 'action.sms.failed';

  // -- Call --------------------------------------------------------------
  static const String callDialing = 'action.call.dialing';
  static const String callMissingNumber = 'action.call.missing_number';
  static const String callFailed = 'action.call.failed';

  // -- Alarm -------------------------------------------------------------
  static const String alarmSet = 'action.alarm.set';
  static const String alarmMissingTime = 'action.alarm.missing_time';
  static const String alarmInvalidTime = 'action.alarm.invalid_time';
  static const String alarmFailed = 'action.alarm.failed';

  // -- Reminder ----------------------------------------------------------
  static const String reminderSaved = 'action.reminder.saved';
  static const String reminderMissingDetails =
      'action.reminder.missing_details';
  static const String reminderInvalidTime = 'action.reminder.invalid_time';
  static const String reminderInvalid = 'action.reminder.invalid';
  static const String reminderMissing = 'action.reminder.missing';
  static const String reminderSaveFailed = 'action.reminder.save_failed';

  // -- Clipboard ---------------------------------------------------------
  static const String clipboardCopied = 'action.clipboard.copied';
  static const String clipboardMissingText = 'action.clipboard.missing_text';
  static const String clipboardFailed = 'action.clipboard.failed';

  // -- Open app ----------------------------------------------------------
  static const String appOpened = 'action.app.opened';
  static const String appMissingPackage = 'action.app.missing_package';
  static const String appFailed = 'action.app.failed';

  // -- Note --------------------------------------------------------------
  static const String noteSaved = 'action.note.saved';
  static const String noteMissingText = 'action.note.missing_text';
  static const String noteInvalid = 'action.note.invalid';
  static const String noteSaveFailed = 'action.note.save_failed';

  // -- Torch -------------------------------------------------------------
  static const String torchOn = 'action.torch.on';
  static const String torchOff = 'action.torch.off';
  static const String torchFailed = 'action.torch.failed';

  // -- WhatsApp ----------------------------------------------------------
  static const String whatsappSent = 'action.whatsapp.sent';
  static const String whatsappMissingDetails =
      'action.whatsapp.missing_details';
  static const String whatsappFailed = 'action.whatsapp.failed';

  // -- Dispatcher --------------------------------------------------------
  static const String unknownAction = 'action.unknown';
}

/// The runtime permissions Vaani can ask for, just-in-time.
///
/// The [id] strings are stable: they cross the `neyam_vaani/permissions`
/// method channel and name the Android permission on the native side.
enum VaaniPermission {
  /// "To hear you" — first voice use.
  microphone('microphone'),

  /// "To photograph your document" — first document scan.
  camera('camera'),

  /// "To save your document" — first document save.
  storage('storage'),

  /// "To send the message you asked for" — first SMS action.
  sms('sms'),

  /// "To make the call you asked for" — first call action.
  phone('phone'),

  /// "To find what's nearby" — first location action.
  location('location'),

  /// "To remind you when you asked" — first reminder or alarm.
  notifications('notifications');

  const VaaniPermission(this.id);

  /// Stable id sent over the method channel.
  final String id;
}

/// Why an action did not succeed.
enum ActionFailureKind {
  /// A required slot (recipient, time, ...) was missing from the utterance.
  missingSlot,

  /// The user declined (or the OS denied) a needed permission.
  permissionDenied,

  /// The platform side reported an error (channel errorCode in detail).
  platformError,

  /// The slots were present but not usable (garbage time, bad number...).
  validation,
}

/// The outcome of one device action.
sealed class ActionResult {
  const ActionResult();
}

/// The action finished. [userMessageKey] is the calm confirmation to
/// speak ("message sent"), never a celebration (TENDER_UX: all
/// confirmations are calm).
final class ActionSucceeded extends ActionResult {
  const ActionSucceeded({
    required this.userMessageKey,
    this.data = const <String, String>{},
  });

  /// Key of the one-sentence confirmation, e.g. 'action.sms.sent'.
  final String userMessageKey;

  /// Plain-string facts the UI may echo back (recipient, due time...).
  final Map<String, String> data;

  @override
  String toString() => 'ActionSucceeded($userMessageKey)';
}

/// The action needs a permission the user has not granted yet. The UI
/// shows the charter explanation ([whyKey]) and asks once, plainly.
final class ActionNeedsPermission extends ActionResult {
  const ActionNeedsPermission({required this.permission, required this.whyKey});

  /// The permission to request.
  final VaaniPermission permission;

  /// Key of the one-sentence charter reason, e.g. 'permission.sms.why'.
  final String whyKey;

  @override
  String toString() => 'ActionNeedsPermission(${permission.id})';
}

/// The action could not run. [detail] is technical, stays on the device,
/// and is for logs only — the user hears the kind sentence behind
/// [userMessageKey], never an error code (TENDER_UX: all errors are kind).
final class ActionFailed extends ActionResult {
  const ActionFailed({
    required this.kind,
    required this.userMessageKey,
    this.detail = '',
  });

  /// What went wrong, for control flow.
  final ActionFailureKind kind;

  /// Key of the kind sentence the user hears.
  final String userMessageKey;

  /// Technical detail for on-device logs only. Never shown, never sent.
  final String detail;

  @override
  String toString() => 'ActionFailed(${kind.name}: $detail)';
}

/// The user stopped the action themselves (said "cancel", backed out of a
/// confirmation). Not an error: never apologize for it, just stop.
final class ActionCancelled extends ActionResult {
  const ActionCancelled();

  @override
  String toString() => 'ActionCancelled()';
}

/// One executable device action (send an SMS, set a reminder...).
///
/// Handlers validate slots, pass the permission gate, then talk to the
/// platform port or a repository — in that order, always.
abstract interface class ActionHandler {
  /// Runs the action with [slots]; never throws, always returns an
  /// [ActionResult].
  Future<ActionResult> execute(SlotMap slots);
}

/// Reading helpers for [SlotMap].
extension SlotMapRead on SlotMap {
  /// The value for [key], whitespace trimmed, or `null` when the slot is
  /// absent or blank.
  String? slot(String key) {
    final String? value = this[key];
    if (value == null) {
      return null;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
