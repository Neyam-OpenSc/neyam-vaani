/// Pure-Dart hybrid search over knowledge-base entries: BM25-lite lexical
/// scoring blended with cosine similarity over deterministic hashing
/// embeddings.
///
/// This file is deliberately dependency-free (no Flutter, no packages) —
/// it is the retrieval core that ships inside every language pack flow
/// and the subject of `app/test/hybrid_search_test.dart`.
///
/// ## EMBEDDING CONTRACT — `nv-hash-v1`
///
/// The embeddings computed here are **bit-for-bit identical** to the ones
/// produced by the Python pipeline (`knowledge/build_embeddings.py`),
/// which documents the same contract from its side. Both implementations
/// must change together (same commit) or the contract name must be bumped
/// to `nv-hash-v2`. A Dart test pins a Python-generated vector to catch
/// accidental drift.
///
/// 1. TOKENIZE (unicode-script aware, identical in Dart and Python):
///    a code point is a *word character* iff it lies inside one of these
///    inclusive ranges — 0x0030-0x0039 ASCII digits, 0x0041-0x005A and
///    0x0061-0x007A ASCII letters, 0x00C0-0x02FF Latin-1/Extended/IPA,
///    0x0370-0x1BFF (Greek, Cyrillic and ALL Brahmic scripts: Devanagari,
///    Bengali, Tamil, Telugu, Kannada, Malayalam, …), 0x1C00-0x1FFF —
///    EXCEPT 0x0964/0x0965 (Devanagari danda, sentence punctuation).
///    Everything else (spaces, punctuation, currency signs, zero-width
///    spaces) splits tokens. Only ASCII A-Z is lowercased — Indic scripts
///    have no case, and locale-free lowercasing is reproducible in every
///    language. Tokens are maximal runs of word characters.
/// 2. EMBED (signed hashing trick, 384 dimensions): for each token,
///    `h1 = fnv1a(token, seed 0x811C9DC5)` picks `index = h1 % 384` and
///    `h2 = fnv1a(token, seed 0x1B873599)` picks
///    `sign = (h2 & 1) == 1 ? +1.0 : -1.0`; `vec[index] += sign` per
///    occurrence; finally L2-normalize. FNV-1a is computed over the
///    token's code points (`runes` here, `ord(ch)` in Python) — never
///    bytes or UTF-16 units — with `h = ((h ^ cp) * 0x01000193) & 0xFFFFFFFF`.
///    (The multiply fits in Dart's 64-bit int; this targets the VM/AOT,
///    not the web backend.)
/// 3. DOCUMENT INPUT: documents embed `title + ' ' + text` (tags are for
///    lexical search only). Queries embed the raw query.
///
/// ## SCORING
///
/// `score = 0.6 * lexicalNorm + 0.4 * semantic` where `lexicalNorm` is
/// BM25 (k1 = 1.5, b = 0.75) normalized by the best lexical score in the
/// candidate set, and `semantic` is cosine similarity clamped to [0, 1].
/// Hits below `threshold` (default [kDefaultThreshold]) are dropped — an
/// honest "no answer found" beats a confident guess.
///
/// Note: hashing embeddings match exact tokens only (bag-of-words). The
/// semantic channel exists so the blend, API shape, and pack contract are
/// ready for real MiniLM embeddings in Phase 6 — the algorithm name will
/// change then.
library;

import 'dart:math' as math;

/// Dimension of the nv-hash-v1 embedding space.
///
/// Must equal `DIM` in `knowledge/build_embeddings.py` — the Dart test
/// pins this against the Python pipeline.
const int kEmbeddingDim = 384;

/// Default hybrid-score cutoff below which hits are treated as noise.
const double kDefaultThreshold = 0.15;

/// BM25 term-frequency saturation (see BM25 literature).
const double kBm25K1 = 1.5;

/// BM25 length-normalization strength.
const double kBm25B = 0.75;

/// One knowledge-base document, in the schema of `knowledge/sources/*.json`
/// and `app/assets/knowledge/sample_kb.json`.
class KbEntry {
  /// Creates an immutable entry.
  const KbEntry({
    required this.id,
    required this.title,
    required this.lang,
    required this.text,
    this.tags = const <String>[],
  });

  /// Stable, unique, curator-chosen id (`topic-lang` convention).
  final String id;

  /// Display title in the entry's language.
  final String title;

  /// BCP-47-ish language code from `kSupportedLanguages`.
  final String lang;

  /// Body passage (the text retrieval returns to the orchestrator).
  final String text;

  /// Topic tags; indexed for lexical search, not part of embeddings.
  final List<String> tags;

  /// Parses the JSON shape used by the pipeline and the bundled sample.
  factory KbEntry.fromJson(Map<String, dynamic> json) {
    final Object? tags = json['tags'];
    return KbEntry(
      id: json['id'] as String,
      title: json['title'] as String,
      lang: json['lang'] as String,
      text: json['text'] as String,
      tags: tags is List
          ? List<String>.unmodifiable(
              tags.whereType<String>(),
            )
          : const <String>[],
    );
  }

  /// Serializes back to the pipeline JSON shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'lang': lang,
        'text': text,
        'tags': tags,
      };
}

/// A scored search result.
class SearchHit {
  /// Creates a hit. [score] is the blended hybrid score.
  const SearchHit({
    required this.entry,
    required this.score,
    required this.lexicalScore,
    required this.semanticScore,
  });

  /// The matched entry.
  final KbEntry entry;

  /// Hybrid score: `0.6 * lexicalScore + 0.4 * semanticScore`.
  final double score;

  /// BM25-lite score normalized by the best lexical score of this query.
  final double lexicalScore;

  /// Cosine similarity between query and document embeddings, clamped to
  /// [0, 1].
  final double semanticScore;
}

/// Word-character code-point ranges shared with the Python pipeline.
///
/// Inclusive; keep in sync with `WORD_CHAR_RANGES` in
/// `knowledge/build_embeddings.py` (see the contract in the library
/// comment above).
const List<List<int>> _kWordCharRanges = <List<int>>[
  [0x0030, 0x0039], // ASCII digits
  [0x0041, 0x005A], // A-Z
  [0x0061, 0x007A], // a-z
  [0x00C0, 0x02FF], // Latin-1 letters, Latin Extended, IPA
  [0x0370, 0x1BFF], // Greek, Cyrillic, and all Brahmic/Indic blocks
  [0x1C00, 0x1CFF],
  [0x1D00, 0x1DFF],
  [0x1E00, 0x1FFF],
];

/// Word characters that live inside a range above but still split tokens:
/// Devanagari danda (।) and double danda (॥) are sentence punctuation.
const Set<int> _kWordCharExceptions = <int>{0x0964, 0x0965};

bool _isWordChar(int codePoint) {
  if (_kWordCharExceptions.contains(codePoint)) {
    return false;
  }
  for (final List<int> range in _kWordCharRanges) {
    if (codePoint >= range[0] && codePoint <= range[1]) {
      return true;
    }
  }
  return false;
}

int _asciiLower(int codePoint) =>
    codePoint >= 0x41 && codePoint <= 0x5A ? codePoint + 0x20 : codePoint;

/// Tokenizes [text] per the nv-hash-v1 contract: unicode-script-aware
/// word runs with ASCII-only lowercasing.
///
/// ```dart
/// tokenize('Hello, World!');      // [hello, world]
/// tokenize('नमस्ते। वाणी');       // [नमस्ते, वाणी] (danda splits)
/// tokenize('அவசர உதவி 112');     // [அவசர, உதவி, 112]
/// ```
List<String> tokenize(String text) {
  final List<String> tokens = <String>[];
  final List<int> current = <int>[];
  for (final int codePoint in text.runes) {
    if (_isWordChar(codePoint)) {
      current.add(_asciiLower(codePoint));
    } else if (current.isNotEmpty) {
      tokens.add(String.fromCharCodes(current));
      current.clear();
    }
  }
  if (current.isNotEmpty) {
    tokens.add(String.fromCharCodes(current));
  }
  return tokens;
}

int _fnv1a(String token, int seed) {
  int hash = seed;
  for (final int codePoint in token.runes) {
    hash = ((hash ^ codePoint) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Embeds [text] as a deterministic 384-dim nv-hash-v1 vector
/// (L2-normalized; all-zero input yields the zero vector).
///
/// Identical to `embed()` in `knowledge/build_embeddings.py`.
List<double> embedText(String text) {
  final List<double> vector = List<double>.filled(kEmbeddingDim, 0.0);
  for (final String token in tokenize(text)) {
    final int index = _fnv1a(token, 0x811C9DC5) % kEmbeddingDim;
    final double sign = (_fnv1a(token, 0x1B873599) & 1) == 1 ? 1.0 : -1.0;
    vector[index] += sign;
  }
  double sumOfSquares = 0.0;
  for (final double value in vector) {
    sumOfSquares += value * value;
  }
  if (sumOfSquares > 0.0) {
    final double norm = math.sqrt(sumOfSquares);
    for (int i = 0; i < vector.length; i++) {
      vector[i] /= norm;
    }
  }
  return vector;
}

/// Cosine similarity of two vectors; 0.0 when either has zero magnitude.
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) {
    return 0.0;
  }
  double dot = 0.0;
  double normA = 0.0;
  double normB = 0.0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0.0 || normB == 0.0) {
    return 0.0;
  }
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}

/// Hybrid (BM25-lite + cosine) search over a set of [KbEntry]s.
///
/// Construct once per loaded corpus (embeddings are precomputed), then
/// call [search] per query. All computation is local; there is no cache
/// of queries and nothing leaves the process.
class HybridSearch {
  /// Creates an index over [entries].
  ///
  /// [lexicalWeight] + [semanticWeight] should be 1.0 (defaults 0.6/0.4
  /// per the design); [threshold] drops hits below the cutoff.
  HybridSearch(
    List<KbEntry> entries, {
    double lexicalWeight = 0.6,
    double semanticWeight = 0.4,
    double threshold = kDefaultThreshold,
  })  : _entries = List<KbEntry>.unmodifiable(entries),
        _lexicalWeight = lexicalWeight,
        _semanticWeight = semanticWeight,
        _threshold = threshold {
    final Map<String, KbEntry> byId = <String, KbEntry>{};
    final List<List<String>> lexicalTokens = <List<String>>[];
    final List<List<double>> embeddings = <List<double>>[];
    for (final KbEntry entry in _entries) {
      byId[entry.id] = entry;
      // Lexical field includes tags; the embedding field does not
      // (contract step 3).
      lexicalTokens.add(
        tokenize('${entry.title} ${entry.text} ${entry.tags.join(' ')}'),
      );
      embeddings.add(embedText('${entry.title} ${entry.text}'));
    }
    _entriesById = Map<String, KbEntry>.unmodifiable(byId);
    _lexicalTokens = List<List<String>>.unmodifiable(lexicalTokens);
    _embeddings = List<List<double>>.unmodifiable(embeddings);
  }

  final List<KbEntry> _entries;
  final double _lexicalWeight;
  final double _semanticWeight;
  final double _threshold;
  // Index-time arrays, positional with _entries.
  late final List<List<String>> _lexicalTokens;
  late final List<List<double>> _embeddings;
  late final Map<String, KbEntry> _entriesById;

  /// The indexed entries, in construction order.
  List<KbEntry> get entries => _entries;

  /// Looks an entry up by id, or null.
  KbEntry? entryById(String id) => _entriesById[id];

  /// Searches the corpus.
  ///
  /// [lang] restricts the candidate set before scoring (BM25 statistics
  /// are computed over that subset). [topK] bounds the result; hits whose
  /// hybrid score is below the effective threshold are dropped, so the
  /// result may be empty — callers should treat that as an honest
  /// "nothing found".
  List<SearchHit> search(
    String query, {
    String? lang,
    int topK = 5,
    double? threshold,
  }) {
    final double cutoff = threshold ?? _threshold;
    final List<int> candidates = <int>[];
    for (int i = 0; i < _entries.length; i++) {
      if (lang == null || _entries[i].lang == lang) {
        candidates.add(i);
      }
    }
    final List<String> queryTokens = tokenize(query);
    if (candidates.isEmpty || queryTokens.isEmpty) {
      return const <SearchHit>[];
    }

    // BM25-lite over the (language-filtered) candidate sub-corpus.
    final int n = candidates.length;
    final Map<String, int> docFrequency = <String, int>{};
    double totalLength = 0;
    for (final int i in candidates) {
      totalLength += _lexicalTokens[i].length;
      final Set<String> unique = _lexicalTokens[i].toSet();
      for (final String term in unique) {
        docFrequency[term] = (docFrequency[term] ?? 0) + 1;
      }
    }
    final double avgLength = n == 0 ? 0.0 : totalLength / n;

    final List<double> lexicalRaw = List<double>.filled(n, 0.0);
    double maxLexical = 0.0;
    for (int c = 0; c < n; c++) {
      final int i = candidates[c];
      final List<String> docTokens = _lexicalTokens[i];
      final Map<String, int> termFrequency = <String, int>{};
      for (final String token in docTokens) {
        termFrequency[token] = (termFrequency[token] ?? 0) + 1;
      }
      double score = 0.0;
      for (final String term in queryTokens.toSet()) {
        final int tf = termFrequency[term] ?? 0;
        final int df = docFrequency[term] ?? 0;
        if (tf == 0 || df == 0) {
          continue;
        }
        final double idf =
            math.log(1.0 + (n - df + 0.5) / (df + 0.5));
        score += idf *
            (tf * (kBm25K1 + 1.0)) /
            (tf + kBm25K1 * (1.0 - kBm25B + kBm25B * docTokens.length / avgLength));
      }
      lexicalRaw[c] = score;
      if (score > maxLexical) {
        maxLexical = score;
      }
    }

    final List<double> queryEmbedding = embedText(query);
    final List<SearchHit> hits = <SearchHit>[];
    for (int c = 0; c < n; c++) {
      final double lexicalNorm = maxLexical > 0.0 ? lexicalRaw[c] / maxLexical : 0.0;
      final double cosine =
          cosineSimilarity(queryEmbedding, _embeddings[candidates[c]]);
      final double semantic = cosine < 0.0 ? 0.0 : (cosine > 1.0 ? 1.0 : cosine);
      final double hybrid = _lexicalWeight * lexicalNorm + _semanticWeight * semantic;
      if (hybrid >= cutoff) {
        hits.add(SearchHit(
          entry: _entries[candidates[c]],
          score: hybrid,
          lexicalScore: lexicalNorm,
          semanticScore: semantic,
        ));
      }
    }
    hits.sort((SearchHit a, SearchHit b) => b.score.compareTo(a.score));
    if (hits.length > topK) {
      return hits.sublist(0, topK);
    }
    return hits;
  }
}
