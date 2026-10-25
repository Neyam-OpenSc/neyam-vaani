/// Failure hierarchy for the on-device intelligence layer.
///
/// Rules (PRIVACY_CHARTER.md, TENDER_UX_PRINCIPLES.md):
/// - [detail] is technical, stays on the device, and is for logs only.
///   It is never shown to the user and never sent anywhere.
/// - [userMessageKey] is the localization key for the kind sentence the
///   user actually hears, e.g. "I could not start the assistant's brain.
///   Can we try again?" — kind, plain, no jargon, no error codes.
library;

/// The family a [Failure] belongs to.
enum FailureKind {
  /// The native bridge library (libllama_bridge) is missing or unloadable.
  nativeLibrary,

  /// The model file could not be loaded (missing, corrupt, wrong format).
  modelLoad,

  /// The OS asked us to free memory; models were swapped out.
  memoryPressure,

  /// An operation exceeded its time budget.
  timeout,

  /// Anything else. Detail explains what.
  unknown,
}

/// Base class of every failure in Vaani.
sealed class Failure {
  const Failure(this.detail);

  /// Which family of failure this is.
  FailureKind get kind;

  /// Localization key for the kind, user-facing message (see l10n).
  String get userMessageKey;

  /// Technical detail for on-device logs only. Never shown to the user.
  final String detail;

  @override
  String toString() => '$runtimeType(${kind.name}: $detail)';
}

/// libllama_bridge could not be found or opened on this device.
final class NativeLibraryFailure extends Failure {
  const NativeLibraryFailure({required String detail}) : super(detail);

  @override
  FailureKind get kind => FailureKind.nativeLibrary;

  @override
  String get userMessageKey => 'failure_native_library';
}

/// The GGUF model could not be loaded into the runtime.
final class ModelLoadFailure extends Failure {
  const ModelLoadFailure({required String detail}) : super(detail);

  @override
  FailureKind get kind => FailureKind.modelLoad;

  @override
  String get userMessageKey => 'failure_model_load';
}

/// The system was low on memory and models had to be unloaded.
final class MemoryPressureFailure extends Failure {
  const MemoryPressureFailure({required String detail}) : super(detail);

  @override
  FailureKind get kind => FailureKind.memoryPressure;

  @override
  String get userMessageKey => 'failure_memory_pressure';
}

/// An operation did not finish within its time budget.
final class TimeoutFailure extends Failure {
  const TimeoutFailure({required String detail}) : super(detail);

  @override
  FailureKind get kind => FailureKind.timeout;

  @override
  String get userMessageKey => 'failure_timeout';
}

/// Fallback for failures without a more specific kind.
final class UnknownFailure extends Failure {
  const UnknownFailure({required String detail}) : super(detail);

  @override
  FailureKind get kind => FailureKind.unknown;

  @override
  String get userMessageKey => 'failure_unknown';
}
