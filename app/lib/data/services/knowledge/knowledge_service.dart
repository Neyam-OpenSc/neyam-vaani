/// Local knowledge-base service: loads entries, answers searches.
///
/// Everything is on-device. The KB source is an injected loader — the
/// default reads the bundled sample from the app bundle via `rootBundle`;
/// tests inject inline JSON; Phase 6 swaps the loader for the installed
/// language pack (see `docs/language-pack-spec.md`). There is no network
/// anywhere in this class, ever (see PRIVACY_CHARTER.md).
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'hybrid_search.dart';

/// Loads the raw KB JSON (the contract of an injectable KB source).
typedef KbSourceLoader = Future<String> Function();

/// Serves knowledge-base lookups from a local, preloaded index.
///
/// ```dart
/// final KnowledgeService kb = KnowledgeService();
/// final List<SearchHit> hits = await kb.search('emergency', 'en');
/// ```
///
/// The first [search]/[ensureLoaded] call parses the source and builds
/// the [HybridSearch] index once; concurrent callers share that load.
class KnowledgeService {
  /// Creates a service.
  ///
  /// [sourceLoader] defaults to the bundled sample asset
  /// [kDefaultKbAssetPath]; tests pass an inline loader. [threshold] is
  /// the hybrid-score cutoff passed to [HybridSearch].
  KnowledgeService({
    KbSourceLoader? sourceLoader,
    double threshold = kDefaultThreshold,
  })  : _sourceLoader = sourceLoader ?? _loadFromAppBundle,
        _threshold = threshold;

  /// Asset path of the KB that ships in the APK
  /// (`app/assets/knowledge/sample_kb.json`).
  ///
  /// Registering `assets/knowledge/` in `app/pubspec.yaml` is handled by
  /// the asset-wiring task; this constant is the single source of truth
  /// for the path.
  static const String kDefaultKbAssetPath = 'assets/knowledge/sample_kb.json';

  final KbSourceLoader _sourceLoader;
  final double _threshold;

  HybridSearch? _index;
  Future<void>? _loading;

  static Future<String> _loadFromAppBundle() => rootBundle.loadString(
        kDefaultKbAssetPath,
      );

  /// Whether the index has been built.
  bool get isLoaded => _index != null;

  /// The loaded entries (empty before the first [ensureLoaded]).
  List<KbEntry> get entries => _index?.entries ?? const <KbEntry>[];

  /// Entry by id, or null (also null before loading).
  KbEntry? get(String id) => _index?.entryById(id);

  /// Completes when the index is ready; safe to call repeatedly.
  ///
  /// Loader or parse failures propagate to the caller (an honest error
  /// beats an empty answer); the failed attempt is not cached, so a later
  /// call retries.
  Future<void> ensureLoaded() {
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final String raw = await _sourceLoader();
      _index = HybridSearch(parseKbJson(raw), threshold: _threshold);
    } catch (_) {
      // A failed load is not memoized: the next call retries.
      _loading = null;
      rethrow;
    }
  }

  /// Searches the KB for [query], restricted to [lang].
  ///
  /// Returns at most [k] hits above the relevance threshold; an empty
  /// list is an honest "nothing found". Async because the first call
  /// loads the index; scoring itself is synchronous and local.
  Future<List<SearchHit>> search(String query, String lang, {int k = 5}) async {
    await ensureLoaded();
    return _index!.search(query, lang: lang, topK: k);
  }
}

/// Parses KB JSON in the pipeline schema into [KbEntry]s.
///
/// Accepts both the interchange shape `{'documents': [...]}` (used by
/// `knowledge/build_kb.py` output and `sample_kb.json`) and a bare list
/// (used by raw source files). Throws [FormatException] with a precise
/// message on anything else — a corrupt KB must fail loudly, not
/// silently return nothing.
List<KbEntry> parseKbJson(String raw) {
  final Object? decoded = jsonDecode(raw);
  final Object? documents =
      decoded is Map<String, dynamic> ? decoded['documents'] : decoded;
  if (documents is! List) {
    throw const FormatException(
      'Knowledge base JSON must be a list of documents or an object with '
      'a "documents" list.',
    );
  }
  final List<KbEntry> entries = <KbEntry>[];
  for (int i = 0; i < documents.length; i++) {
    final Object? item = documents[i];
    if (item is! Map<String, dynamic>) {
      throw FormatException('Knowledge base document at index $i is not an object.');
    }
    for (final String field in <String>['id', 'title', 'lang', 'text']) {
      if (item[field] is! String) {
        throw FormatException(
          'Knowledge base document at index $i is missing field "$field".',
        );
      }
    }
    entries.add(KbEntry.fromJson(item));
  }
  return entries;
}
