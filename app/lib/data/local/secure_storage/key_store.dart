/// The source of the SQLCipher database encryption key.
///
/// Production keeps the key in the **Android Keystore** (hardware-backed
/// where available) — the Dart side only asks the native layer for it
/// over a method channel, once, at database-open time. The key is never
/// logged, never cached to disk, never sent anywhere (PRIVACY_CHARTER.md,
/// "Security implementation").
library;

import 'dart:convert' show base64UrlEncode;
import 'dart:math' show Random;

import 'package:flutter/services.dart';

/// Provides the AES-256 key for the encrypted database.
abstract class KeyStore {
  /// Returns the key material (base64). Callers must not persist it.
  Future<String> databaseKey();
}

/// A random key that exists only in process memory.
///
/// **NOT FOR PRODUCTION.** Without the Android Keystore there is nowhere
/// durable and hardware-backed to keep the key: a process restart would
/// mint a different key and the database would be unreadable forever.
/// Use [PlatformChannelKeyStore] on devices; this one exists for tests
/// and local development only.
class DevOnlyInMemoryKeyStore implements KeyStore {
  /// Creates a dev key store. [random] is injectable for deterministic
  /// tests.
  DevOnlyInMemoryKeyStore({Random? random})
      : _random = random ?? Random.secure();

  final Random _random;
  String? _key;

  @override
  Future<String> databaseKey() async => _key ??= _generate();

  /// One 256-bit key, base64-encoded, minted on first use.
  String _generate() {
    final List<int> bytes =
        List<int>.generate(32, (int _) => _random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}

/// Fetches the key from the native side over `neyam_vaani/keystore`.
///
/// The Android implementation (arriving with the native integration)
/// generates the key in the Keystore on first call and returns the
/// wrapped/exported material this port needs. Until it lands, calls fail
/// loudly: a missing key must never be silently replaced by an empty or
/// weak one — an unencrypted "encrypted" database would violate the
/// charter.
class PlatformChannelKeyStore implements KeyStore {
  /// Creates a keystore client. [channel] is injectable for tests.
  PlatformChannelKeyStore({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('neyam_vaani/keystore');

  final MethodChannel _channel;

  @override
  Future<String> databaseKey() async {
    try {
      final String? key = await _channel.invokeMethod<String>('databaseKey');
      if (key == null || key.isEmpty) {
        throw StateError(
          'neyam_vaani/keystore returned no database key; refusing to '
          'open the database unencrypted',
        );
      }
      return key;
    } on PlatformException catch (error) {
      throw StateError('neyam_vaani/keystore failed: ${error.code}');
    }
  }
}
