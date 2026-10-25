/// On-device translation for Vaani.
///
/// Two engines behind one API:
///
/// * `NativeNllbBridge` — FFI to `libnllb_bridge.so` (the NLLB-200
///   wrapper that lands with `native/`, Phase 8). Probed lazily; any
///   failure to open/bind degrades gracefully to the fallback.
/// * `OfflineDictionaryFallback` — a tiny bundled phrasebook across
///   `ta`/`hi`/`en`. **Dev-only scaffolding**: it translates exact common
///   phrases and honestly fails on everything else. It never guesses —
///   an unknown phrase returns `phraseNotInOfflineDictionary`, which the
///   UI must surface as "I can't translate that yet", not as a wrong
///   answer.
///
/// All translation happens on-device (PRIVACY_CHARTER.md): no network,
/// no logs; the last [cacheCapacity] results are kept in RAM only.
library;

import 'dart:collection';
import 'dart:convert' show utf8;
import 'dart:ffi' as ffi;
import 'dart:typed_data' show Uint8List;

import '../../../core/constants.dart';

/// Why a translation failed. Callers map these to honest user messages.
enum TranslationErrorKind {
  /// No engine on this device (bridge absent and phrase unknown).
  engineUnavailable,

  /// The language pair is not supported at all.
  unsupportedLanguage,

  /// Empty/blank input.
  invalidInput,

  /// The dev-only phrasebook does not know this phrase.
  phraseNotInOfflineDictionary,

  /// The native bridge returned an error.
  engineError,
}

/// Result-like translation outcome: either `ok` with [text] and [engine],
/// or a failure with [errorKind] and a human-oriented [message].
class TranslationResult {
  const TranslationResult._({
    required this.ok,
    required this.text,
    required this.engine,
    this.errorKind,
    this.message,
  });

  /// Creates a successful result.
  const TranslationResult.success(this.text, this.engine)
      : ok = true,
        errorKind = null,
        message = null;

  /// Creates a failure result. Never fabricates output text.
  const TranslationResult.failure(this.errorKind, this.message)
      : ok = false,
        text = '',
        engine = '';

  /// Whether translation succeeded.
  final bool ok;

  /// The translated text (empty on failure).
  final String text;

  /// Which engine produced it: `nllb`, `offline-dictionary`, `identity`.
  final String engine;

  /// Failure kind, when [ok] is false.
  final TranslationErrorKind? errorKind;

  /// Developer-facing message (UI localizes its own strings).
  final String? message;
}

/// A translation backend. See [NativeNllbBridge] and
/// [OfflineDictionaryFallback].
abstract class NllbEngine {
  /// Translates [text] from [from] to [to] (BCP-47-ish codes).
  Future<TranslationResult> translate(String text, String from, String to);
}

/// FFI bridge to the native NLLB wrapper.
///
/// Expected ABI of `libnllb_bridge.so` (implemented in `native/`, Phase 8):
///
/// ```c
/// // 0 on success, negative on error. `out` receives a NUL-terminated
/// // UTF-8 string of at most out_len bytes.
/// int32_t nllb_bridge_translate(
///     const char* text, const char* from, const char* to,
///     char* out, int32_t out_len);
/// ```
///
/// String memory is allocated via libc `malloc` (looked up through
/// `DynamicLibrary.process()`, available on Android) and always freed.
/// Until the library exists, [tryOpen] returns null and the service uses
/// the fallback — no crash, no stub output.
class NativeNllbBridge implements NllbEngine {
  NativeNllbBridge._(
    this._translateNative,
    ffi.Pointer<ffi.Void> Function(int) malloc,
    void Function(ffi.Pointer<ffi.Void>) free,
  )   : _malloc = malloc,
        _free = free;

  static const String _libraryName = 'libnllb_bridge.so';
  static const int _outBufferBytes = 4096;

  final _NllbTranslateDart _translateNative;
  final ffi.Pointer<ffi.Void> Function(int) _malloc;
  final void Function(ffi.Pointer<ffi.Void>) _free;

  /// Opens and binds the bridge, or null when it is not present/usable.
  static NativeNllbBridge? tryOpen() {
    try {
      final ffi.DynamicLibrary lib = ffi.DynamicLibrary.open(_libraryName);
      final _NllbTranslateDart translate =
          lib.lookupFunction<_NllbTranslateNative, _NllbTranslateDart>(
        'nllb_bridge_translate',
      );
      final ffi.DynamicLibrary process = ffi.DynamicLibrary.process();
      final ffi.Pointer<ffi.Void> Function(int) malloc = process
          .lookupFunction<ffi.Pointer<ffi.Void> Function(ffi.IntPtr),
              ffi.Pointer<ffi.Void> Function(int)>('malloc');
      final void Function(ffi.Pointer<ffi.Void>) free = process.lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)>('free');
      return NativeNllbBridge._(translate, malloc, free);
    } catch (_) {
      // Library absent, symbol missing, or FFI unsupported (e.g. tests,
      // desktop dev runs). Graceful degradation is the contract.
      return null;
    }
  }

  ffi.Pointer<ffi.Uint8> _dup(Uint8List bytes) {
    final ffi.Pointer<ffi.Uint8> pointer = _malloc(bytes.length + 1).cast<ffi.Uint8>();
    final Uint8List view = pointer.asTypedList(bytes.length + 1);
    view
      ..setRange(0, bytes.length, bytes)
      ..[bytes.length] = 0;
    return pointer;
  }

  @override
  Future<TranslationResult> translate(String text, String from, String to) async {
    final ffi.Pointer<ffi.Uint8> textPtr = _dup(utf8.encode(text));
    final ffi.Pointer<ffi.Uint8> fromPtr = _dup(utf8.encode(from));
    final ffi.Pointer<ffi.Uint8> toPtr = _dup(utf8.encode(to));
    final ffi.Pointer<ffi.Uint8> outPtr = _malloc(_outBufferBytes).cast<ffi.Uint8>();
    try {
      final int status = _translateNative(textPtr, fromPtr, toPtr, outPtr, _outBufferBytes);
      if (status != 0) {
        return TranslationResult.failure(
          TranslationErrorKind.engineError,
          'nllb_bridge_translate failed with status $status.',
        );
      }
      final Uint8List out = outPtr.asTypedList(_outBufferBytes);
      int length = 0;
      while (length < _outBufferBytes && out[length] != 0) {
        length++;
      }
      return TranslationResult.success(
        utf8.decode(Uint8List.sublistView(out, 0, length)),
        'nllb',
      );
    } on FormatException {
      return const TranslationResult.failure(
        TranslationErrorKind.engineError,
        'The bridge returned invalid UTF-8.',
      );
    } finally {
      _free(textPtr.cast<ffi.Void>());
      _free(fromPtr.cast<ffi.Void>());
      _free(toPtr.cast<ffi.Void>());
      _free(outPtr.cast<ffi.Void>());
    }
  }
}

/// Dev-only exact-phrase phrasebook across `ta`/`hi`/`en`.
///
/// This exists so the translate flow is exercisable before the NLLB pack
/// ships. It is NOT a translator: anything outside the phrasebook is an
/// honest failure ([TranslationErrorKind.phraseNotInOfflineDictionary]).
class OfflineDictionaryFallback implements NllbEngine {
  /// Creates the fallback and builds its reverse index once.
  OfflineDictionaryFallback() : _index = _buildIndex();

  /// Canonical phrase -> per-language wording.
  ///
  /// Keyed by meaning so any pair (`ta->hi`, `en->ta`, …) works.
  static const List<Map<String, String>> _phrasebook = <Map<String, String>>[
    {'key': 'greeting', 'en': 'hello', 'ta': 'வணக்கம்', 'hi': 'नमस्ते'},
    {'key': 'thanks', 'en': 'thank you', 'ta': 'நன்றி', 'hi': 'धन्यवाद'},
    {
      'key': 'how_are_you',
      'en': 'how are you',
      'ta': 'எப்படி இருக்கிறீர்கள்',
      'hi': 'आप कैसे हैं',
    },
    {'key': 'yes', 'en': 'yes', 'ta': 'ஆம்', 'hi': 'हाँ'},
    {'key': 'no', 'en': 'no', 'ta': 'இல்லை', 'hi': 'नहीं'},
    {'key': 'sorry', 'en': 'sorry', 'ta': 'மன்னிக்கவும்', 'hi': 'क्षमा करें'},
    {'key': 'good_morning', 'en': 'good morning', 'ta': 'காலை வணக்கம்', 'hi': 'सुप्रभात'},
    {'key': 'water', 'en': 'water', 'ta': 'தண்ணீர்', 'hi': 'पानी'},
    {'key': 'help', 'en': 'help', 'ta': 'உதவி', 'hi': 'मदद'},
    {'key': 'hospital', 'en': 'hospital', 'ta': 'மருத்துவமனை', 'hi': 'अस्पताल'},
    {'key': 'i_need_help', 'en': 'i need help', 'ta': 'எனக்கு உதவி வேண்டும்', 'hi': 'मुझे मदद चाहिए'},
    {
      'key': 'where_is_the_bus_stop',
      'en': 'where is the bus stop',
      'ta': 'பேருந்து நிறுத்தம் எங்கே',
      'hi': 'बस स्टॉप कहाँ है',
    },
  ];

  /// language -> normalized phrase -> phrase key.
  final Map<String, Map<String, String>> _index;

  static Map<String, Map<String, String>> _buildIndex() {
    final Map<String, Map<String, String>> index = <String, Map<String, String>>{};
    for (final Map<String, String> row in _phrasebook) {
      final String key = row['key']!;
      for (final String lang in row.keys) {
        if (lang == 'key') {
          continue;
        }
        index.putIfAbsent(lang, () => <String, String>{})[_normalize(row[lang]!)] = key;
      }
    }
    return index;
  }

  static String _normalize(String text) => text.trim().toLowerCase();

  @override
  Future<TranslationResult> translate(String text, String from, String to) async {
    if (from == to) {
      return TranslationResult.success(text, 'identity');
    }
    final Map<String, String>? fromIndex = _index[from];
    final String? key = fromIndex?[_normalize(text)];
    if (key == null) {
      return const TranslationResult.failure(
        TranslationErrorKind.phraseNotInOfflineDictionary,
        'This exact phrase is not in the dev phrasebook; on-device neural '
        'translation ships with the NLLB language pack (Phase 8).',
      );
    }
    String? translated;
    for (final Map<String, String> row in _phrasebook) {
      if (row['key'] == key) {
        translated = row[to];
        break;
      }
    }
    if (translated == null) {
      return const TranslationResult.failure(
        TranslationErrorKind.unsupportedLanguage,
        'The phrasebook does not cover the target language.',
      );
    }
    return TranslationResult.success(translated, 'offline-dictionary');
  }
}

/// Facade the app talks to: engine selection, validation, LRU cache.
///
/// ```dart
/// final TranslationService translator = TranslationService();
/// final TranslationResult r = await translator.translate('Hello', 'en', 'ta');
/// ```
class TranslationService {
  /// Creates a service.
  ///
  /// [engine] defaults to the native NLLB bridge when available,
  /// otherwise the dev-only phrasebook fallback. [cacheCapacity] bounds
  /// the in-memory translation cache (LRU, RAM only).
  TranslationService({NllbEngine? engine, int cacheCapacity = 32})
      : _engine = engine ?? NativeNllbBridge.tryOpen() ?? OfflineDictionaryFallback(),
        _cacheCapacity = cacheCapacity {
    if (_cacheCapacity < 1) {
      throw RangeError.value(_cacheCapacity, 'cacheCapacity', 'must be >= 1');
    }
  }

  final NllbEngine _engine;
  final int _cacheCapacity;
  final LinkedHashMap<String, TranslationResult> _cache =
      LinkedHashMap<String, TranslationResult>();
  int _cacheHits = 0;

  /// Number of cached translations.
  int get cacheSize => _cache.length;

  /// Total cache hits served (diagnostics/tests).
  int get cacheHits => _cacheHits;

  /// Empties the cache (RAM only — nothing to purge on disk).
  void clearCache() => _cache.clear();

  String _cacheKey(String text, String from, String to) => '$from|$to|$text';

  /// Translates [text] from [from] to [to].
  ///
  /// Success returns `ok: true` with the translated text. Failure returns
  /// an [TranslationErrorKind] — never a guessed translation.
  Future<TranslationResult> translate(String text, String from, String to) {
    if (text.trim().isEmpty) {
      return Future<TranslationResult>.value(
        const TranslationResult.failure(
          TranslationErrorKind.invalidInput,
          'Nothing to translate: the input is empty.',
        ),
      );
    }
    if (!kSupportedLanguages.contains(from) || !kSupportedLanguages.contains(to)) {
      return Future<TranslationResult>.value(
        TranslationResult.failure(
          TranslationErrorKind.unsupportedLanguage,
          'Unsupported language pair: $from -> $to.',
        ),
      );
    }

    final String key = _cacheKey(text, from, to);
    final TranslationResult? cached = _cache.remove(key);
    if (cached != null) {
      _cacheHits++;
      _cache[key] = cached; // Re-insert: most-recently-used.
      return Future<TranslationResult>.value(cached);
    }

    return _engine.translate(text, from, to).then((TranslationResult result) {
      _cache[key] = result;
      if (_cache.length > _cacheCapacity) {
        _cache.remove(_cache.keys.first);
      }
      return result;
    });
  }
}

typedef _NllbTranslateNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8> text,
  ffi.Pointer<ffi.Uint8> from,
  ffi.Pointer<ffi.Uint8> to,
  ffi.Pointer<ffi.Uint8> out,
  ffi.Int32 outLength,
);

typedef _NllbTranslateDart = int Function(
  ffi.Pointer<ffi.Uint8> text,
  ffi.Pointer<ffi.Uint8> from,
  ffi.Pointer<ffi.Uint8> to,
  ffi.Pointer<ffi.Uint8> out,
  int outLength,
);
