/// A minimal functional result type for Neyam Vaani.
///
/// Fallible operations in the intelligence layer return a [Result] instead
/// of throwing: the caller decides what a failure means for the user, and
/// the failure path always carries a [Failure] whose technical detail never
/// reaches the UI (see TENDER_UX_PRINCIPLES.md — all errors are kind).
///
/// Pure Dart — no Flutter imports, safe to use from any layer.
library;

import 'errors/failures.dart';

/// The result of an operation that can fail: either [Ok] with a value of
/// `T`, or [Err] with a [Failure].
sealed class Result<T> {
  const Result();

  /// Whether this is [Ok].
  bool get isOk => this is Ok<T>;

  /// Whether this is [Err].
  bool get isErr => this is Err<T>;

  /// The value when [isOk], otherwise `null`.
  T? get valueOrNull {
    return switch (this) {
      Ok<T>(:final T value) => value,
      Err<T>() => null,
    };
  }

  /// The failure when [isErr], otherwise `null`.
  Failure? get failureOrNull {
    return switch (this) {
      Ok<T>() => null,
      Err<T>(:final Failure failure) => failure,
    };
  }

  /// Transforms the success value, or maps the failure to the same type.
  R map<R>(R Function(T value) transform, R Function(Failure failure) onError) {
    return fold<R>(
      (T value) => transform(value),
      (Failure failure) => onError(failure),
    );
  }

  /// Chains another fallible operation after a success.
  Result<R> flatMap<R>(Result<R> Function(T value) transform) {
    return switch (this) {
      Ok<T>(:final T value) => transform(value),
      Err<T>(:final Failure failure) => Err<R>(failure),
    };
  }

  /// Collapses both cases into one value. [onOk] runs first in spirit:
  /// `fold(onOk, onErr)` — kept positional for terseness at call sites.
  R fold<R>(R Function(T value) onOk, R Function(Failure failure) onErr) {
    return switch (this) {
      Ok<T>(:final T value) => onOk(value),
      Err<T>(:final Failure failure) => onErr(failure),
    };
  }

  /// Like [fold] but with named cases, for readability at call sites.
  R when<R>({
    required R Function(T value) ok,
    required R Function(Failure failure) err,
  }) {
    return fold<R>(ok, err);
  }

  /// The success value, or the result of [orElse] on failure.
  T getOrElse(T Function(Failure failure) orElse) {
    return fold<T>(
      (T value) => value,
      (Failure failure) => orElse(failure),
    );
  }
}

/// The success case.
final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;

  @override
  String toString() => 'Ok<$T>($value)';
}

/// The failure case. Always carries a [Failure], never a bare exception.
final class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;

  @override
  String toString() => 'Err<$T>($failure)';
}
