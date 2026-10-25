/// Intent -> prompt routing.
///
/// Maps a [VaaniIntent] to one of the templates in app/assets/prompts/,
/// loads it (rootBundle by default, injectable for tests), and substitutes
/// `{placeholders}` with the user's language, the transcript and the
/// extracted slot values. Intents without a dedicated template fall back
/// to general_assistant.txt — the deliberately honest fallback prompt.
///
/// Templates are cached per instance (they are assets — they do not
/// change while the app runs).
library;

import 'package:flutter/services.dart' show rootBundle;

import '../../../core/constants.dart' show kLanguageEndonyms;
import '../../../core/errors/failures.dart';
import '../../../core/result.dart';
import '../../../domain/entities/intent.dart';
import '../../../domain/usecases/orchestrate_user_request.dart'
    show PromptBuilding, RoutedPrompt;

/// Routes intents to rendered system prompts.
class PromptRouter implements PromptBuilding {
  PromptRouter({
    Future<String> Function(String assetPath)? assetLoader,
    Map<String, String>? languageNames,
  })  : _loadAsset = assetLoader ?? _rootBundleLoad,
        _languageNames = languageNames ?? kLanguageEndonyms;

  static Future<String> _rootBundleLoad(String path) =>
      rootBundle.loadString(path);

  /// Where prompt templates live inside the asset bundle.
  static const String promptAssetPrefix = 'assets/prompts/';

  /// The honest fallback prompt for intents without a dedicated template.
  static const String fallbackPromptFile = 'general_assistant.txt';

  /// Prompt id of the built-in LLM meta-classification prompt.
  static const String metaPromptId = 'intent_meta_classifier';

  /// Intent -> dedicated template (basename). Unlisted intents use
  /// [fallbackPromptFile]. Keep values in sync with app/assets/prompts/.
  static const Map<VaaniIntent, String> promptFiles = <VaaniIntent, String>{
    VaaniIntent.answerQuestion: 'answer_question.txt',
    VaaniIntent.howToQuestion: 'answer_question.txt',
    VaaniIntent.draftMessage: 'draft_message.txt',
    VaaniIntent.draftLetter: 'draft_message.txt',
    VaaniIntent.explainMedicine: 'explain_medicine.txt',
    VaaniIntent.fillForm: 'fill_form.txt',
    VaaniIntent.translate: 'translate.txt',
    VaaniIntent.readDocument: 'simplify_text.txt',
  };

  final Future<String> Function(String assetPath) _loadAsset;
  final Map<String, String> _languageNames;
  final Map<String, String> _cache = <String, String>{};

  /// Template file (basename) for [intent]; [fallbackPromptFile] when the
  /// intent has no dedicated template.
  String templateFileFor(VaaniIntent intent) =>
      promptFiles[intent] ?? fallbackPromptFile;

  /// Prompt id (template stem) for [intent].
  String promptIdFor(VaaniIntent intent) =>
      templateFileFor(intent).replaceFirst('.txt', '');

  /// Whether [intent] has its own template (used to flag fallback turns).
  bool hasDedicatedPrompt(VaaniIntent intent) =>
      promptFiles.containsKey(intent);

  /// Replaces every `{key}` found in [params]. Unknown placeholders are
  /// left untouched on purpose — a half-filled prompt is easier to spot
  /// in the on-device log than silently deleted instructions.
  static String renderTemplate(
    String template,
    Map<String, String> params,
  ) {
    String out = template;
    for (final MapEntry<String, String> entry in params.entries) {
      out = out.replaceAll('{${entry.key}}', entry.value);
    }
    return out;
  }

  Future<Result<String>> _template(String file) async {
    final String? cached = _cache[file];
    if (cached != null) {
      return Ok<String>(cached);
    }
    try {
      final String text = await _loadAsset('$promptAssetPrefix$file');
      _cache[file] = text;
      return Ok<String>(text);
    } catch (error) {
      return Err<String>(
        UnknownFailure(
          detail: 'could not load prompt template $file: $error',
        ),
      );
    }
  }

  @override
  Future<Result<RoutedPrompt>> buildPrompt({
    required VaaniIntent intent,
    required String userLanguage,
    required String transcript,
    Map<String, String> slotValues = const <String, String>{},
  }) async {
    final bool dedicated = hasDedicatedPrompt(intent);
    String effectiveFile = templateFileFor(intent);
    bool usedFallback = !dedicated;

    Result<String> template = await _template(effectiveFile);
    if (template is Err<String> && effectiveFile != fallbackPromptFile) {
      // Dedicated template missing: degrade to the honest fallback
      // instead of failing the turn.
      effectiveFile = fallbackPromptFile;
      usedFallback = true;
      template = await _template(fallbackPromptFile);
    }

    final String templateText;
    switch (template) {
      case Ok<String>(:final String value):
        templateText = value;
      case Err<String>(:final Failure failure):
        return Err<RoutedPrompt>(failure);
    }

    final Map<String, String> params = <String, String>{
      'user_language': _languageNames[userLanguage] ?? userLanguage,
      'question': transcript,
      'request': transcript,
      'user_input': transcript,
      'text': transcript,
    }..addAll(slotValues);

    return Ok<RoutedPrompt>(
      RoutedPrompt(
        promptId: effectiveFile.replaceFirst('.txt', ''),
        templateFile: effectiveFile,
        text: renderTemplate(templateText, params),
        isFallback: usedFallback,
      ),
    );
  }

  /// Built-in template for LLM meta-classification. Not an asset: it is
  /// infrastructure, not a user-facing persona prompt.
  static const String _metaClassificationTemplate = '''
You are Vaani's intent router. Pick exactly ONE intent id from the list
below that best matches what the user wants. Answer with the id only —
no explanation, no punctuation. If none of the ids fit, answer: none.

The user speaks {user_language}. They said:
{transcript}

Intent ids to choose from:
{candidates}

Intent id:
''';

  @override
  Future<Result<RoutedPrompt>> buildMetaClassificationPrompt({
    required String transcript,
    required String userLanguage,
    required List<VaaniIntent> candidates,
  }) async {
    final String candidateIds = candidates
        .map((VaaniIntent intent) => intent.id)
        .join('\n');
    final String text = renderTemplate(_metaClassificationTemplate, <String, String>{
      'user_language': _languageNames[userLanguage] ?? userLanguage,
      'transcript': transcript,
      'candidates': candidateIds,
    });
    return Ok<RoutedPrompt>(
      RoutedPrompt(
        promptId: metaPromptId,
        templateFile: '(builtin)',
        text: text,
        isFallback: false,
      ),
    );
  }
}
