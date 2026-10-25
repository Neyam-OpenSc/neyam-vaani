/// Use case: retrieve knowledge-base passages for a question.
///
/// This is the retrieval half of RAG (Phase 6): it returns the top KB
/// passages for the LLM orchestrator to ground an answer in. It is
/// deliberately independent of any LLM — no model imports here — so it
/// can be tested and shipped on its own. When no passage clears the
/// relevance threshold, [KbAnswer.hasAnswer] is false and the assistant
/// must say "I don't know" rather than improvise.
library;

import '../../data/services/knowledge/hybrid_search.dart';
import '../../data/services/knowledge/knowledge_service.dart';

/// One retrieved passage, flattened for consumers that should not need
/// the search-layer types.
class KbPassage {
  /// Creates a passage.
  const KbPassage({
    required this.id,
    required this.title,
    required this.text,
    required this.lang,
    required this.score,
  });

  /// Adapts a [SearchHit].
  factory KbPassage.fromHit(SearchHit hit) => KbPassage(
        id: hit.entry.id,
        title: hit.entry.title,
        text: hit.entry.text,
        lang: hit.entry.lang,
        score: hit.score,
      );

  /// Source entry id (stable across packs).
  final String id;

  /// Entry title in its language.
  final String title;

  /// Passage body.
  final String text;

  /// Language of the passage.
  final String lang;

  /// Hybrid relevance score in [0, 1].
  final double score;
}

/// Retrieval outcome for one question.
class KbAnswer {
  /// Creates an answer envelope.
  const KbAnswer({
    required this.question,
    required this.lang,
    required this.passages,
  });

  /// The question that was asked.
  final String question;

  /// The language the question was asked in (and results restricted to).
  final String lang;

  /// Retrieved passages, best first.
  final List<KbPassage> passages;

  /// False when nothing cleared the threshold — the honest "I don't know".
  bool get hasAnswer => passages.isNotEmpty;
}

/// Answers questions from the local knowledge base.
///
/// ```dart
/// final AnswerFromKb answerFromKb = AnswerFromKb(KnowledgeService());
/// final KbAnswer answer = await answerFromKb('அவசர எண் எது?', 'ta');
/// ```
class AnswerFromKb {
  /// Creates the use case over a [KnowledgeService].
  const AnswerFromKb(this._knowledge);

  final KnowledgeService _knowledge;

  /// Retrieves up to [k] passages for [question] in [lang].
  Future<KbAnswer> call(String question, String lang, {int k = 3}) async {
    final List<SearchHit> hits = await _knowledge.search(question, lang, k: k);
    return KbAnswer(
      question: question,
      lang: lang,
      passages:
          hits.map((SearchHit hit) => KbPassage.fromHit(hit)).toList(growable: false),
    );
  }
}
