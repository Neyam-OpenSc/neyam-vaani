import 'package:flutter_test/flutter_test.dart';

import 'package:neyam_vaani/core/errors/failures.dart';
import 'package:neyam_vaani/core/result.dart';

void main() {
  group('Ok', () {
    test('isOk / isErr / accessors', () {
      const Result<int> result = Ok<int>(42);
      expect(result.isOk, isTrue);
      expect(result.isErr, isFalse);
      expect(result.valueOrNull, 42);
      expect(result.failureOrNull, isNull);
    });

    test('map transforms the value', () {
      const Result<int> result = Ok<int>(6);
      expect(result.map<int>((int v) => v * 7, (Failure f) => -1), 42);
    });

    test('fold runs the ok branch', () {
      const Result<String> result = Ok<String>('hello');
      expect(
        result.fold<String>(
          (String value) => 'ok:$value',
          (Failure failure) => 'err:${failure.userMessageKey}',
        ),
        'ok:hello',
      );
    });

    test('when runs the ok case', () {
      const Result<bool> result = Ok<bool>(true);
      expect(
        result.when<String>(ok: (bool v) => 'yes', err: (Failure f) => 'no'),
        'yes',
      );
    });

    test('getOrElse returns the value', () {
      const Result<int> result = Ok<int>(5);
      expect(result.getOrElse((Failure f) => 0), 5);
    });

    test('flatMap chains the next result', () {
      const Result<int> result = Ok<int>(2);
      expect(result.flatMap<String>((int v) => Ok<String>('v$v')).valueOrNull,
          'v2');
    });
  });

  group('Err', () {
    test('isOk / isErr / accessors', () {
      const Result<int> result =
          Err<int>(UnknownFailure(detail: 'nope'));
      expect(result.isOk, isFalse);
      expect(result.isErr, isTrue);
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull, isA<UnknownFailure>());
    });

    test('map routes to the error branch', () {
      const Result<int> result = Err<int>(TimeoutFailure(detail: 'slow'));
      expect(result.map<int>((int v) => v, (Failure f) => -1), -1);
    });

    test('fold runs the error branch', () {
      const Result<int> result =
          Err<int>(NativeLibraryFailure(detail: 'missing'));
      expect(
        result.fold<String>(
          (int value) => 'ok',
          (Failure failure) => failure.userMessageKey,
        ),
        'failure_native_library',
      );
    });

    test('when runs the err case', () {
      const Result<int> result =
          Err<int>(MemoryPressureFailure(detail: 'low'));
      expect(
        result.when<String>(ok: (int v) => 'yes', err: (Failure f) => 'no'),
        'no',
      );
    });

    test('getOrElse falls back', () {
      const Result<int> result = Err<int>(UnknownFailure(detail: 'x'));
      expect(result.getOrElse((Failure f) => 99), 99);
    });

    test('flatMap keeps the failure', () {
      const Result<int> result = Err<int>(ModelLoadFailure(detail: 'bad'));
      final Result<String> chained =
          result.flatMap<String>((int v) => Ok<String>('never'));
      expect(chained.isErr, isTrue);
      expect(chained.failureOrNull, isA<ModelLoadFailure>());
    });
  });

  group('Failure hierarchy', () {
    test('every failure carries kind, message key and detail', () {
      const List<Failure> failures = <Failure>[
        NativeLibraryFailure(detail: 'a'),
        ModelLoadFailure(detail: 'b'),
        MemoryPressureFailure(detail: 'c'),
        TimeoutFailure(detail: 'd'),
        UnknownFailure(detail: 'e'),
      ];
      const List<FailureKind> kinds = <FailureKind>[
        FailureKind.nativeLibrary,
        FailureKind.modelLoad,
        FailureKind.memoryPressure,
        FailureKind.timeout,
        FailureKind.unknown,
      ];
      const List<String> keys = <String>[
        'failure_native_library',
        'failure_model_load',
        'failure_memory_pressure',
        'failure_timeout',
        'failure_unknown',
      ];
      for (int i = 0; i < failures.length; i++) {
        expect(failures[i].kind, kinds[i]);
        expect(failures[i].userMessageKey, keys[i]);
        expect(failures[i].detail, isNotEmpty);
      }
    });
  });
}
