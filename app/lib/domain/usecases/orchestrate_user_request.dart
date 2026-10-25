/// Use case: turn one raw transcript into an execution plan for one turn.
///
/// Pipeline (docs/architecture.md, "Data flow: one spoken question"):
///
///     transcript
///       -> intent classification            (fast, pure Dart)
///       -> LLM meta-classification          (only if confidence is low)
///       -> slot extraction                  (regex/keyword rules)
///       -> prompt routing                   (intent -> template -> text)
///       -> on-device LLM generation         (streaming tokens)
///       => OrchestrationPlan
///
/// Everything runs on-device (PRIVACY_CHARTER.md): no step touches the
/// network, and nothing leaves this Dart isolate except the final prompt
/// handed to the local llama.cpp bridge.
///
/// This file also declares the ports ([IntentClassifying], [SlotFilling],
/// [PromptBuilding], [LlmGenerating]) and the small LLM contract types
/// ([LlmRequest], [LlmTokenEvent]...) that the data layer implements —
/// that keeps the domain free of data-layer imports while the concrete
/// services stay in lib/data/services/.
library;

import '../../core/errors/failures.dart';
import '../../core/result.dart';
import '../entities/intent.dart';
import '../entities/slot.dart';

// ---------------------------------------------------------------------------
// Ports (implemented in lib/data/services/)
// ---------------------------------------------------------------------------

/// Classifies a transcript to one of the 20 intents.
///
/// Implementations must be fast (<200ms), pure, and offline. When the
/// verdict is shaky, return the best guess with a low [IntentPrediction.confidence];
/// the escalation to the LLM is decided *here*, never inside the classifier.
abstract interface class IntentClassifying {
  IntentPrediction classify(String transcript);
}

/// Extracts typed slots from a transcript, given the already-known intent.
abstract interface class SlotFilling {
  SlotSet extract({required VaaniIntent intent, required String transcript});
}

/// Chooses and renders the system prompt for a turn.
abstract interface class PromptBuilding {
  /// Renders the prompt for [intent]. [slotValues] come from the
  /// SlotExtractor (name -> value) and fill matching `{placeholders}`.
  Future<Result<RoutedPrompt>> buildPrompt({
    required VaaniIntent intent,
    required String userLanguage,
    required String transcript,
    Map<String, String> slotValues = const <String, String>{},
  });

  /// Renders the small built-in prompt used for LLM meta-classification:
  /// the model must answer with exactly one of [candidates]' ids.
  Future<Result<RoutedPrompt>> buildMetaClassificationPrompt({
    required String transcript,
    required String userLanguage,
    required List<VaaniIntent> candidates,
  });
}

/// Generates text with the on-device model. Implemented by the FFI-backed
/// service and by test doubles; cancel must be immediate (Tender UX:
/// interruptions are honored instantly).
abstract interface class LlmGenerating {
  Stream<LlmTokenEvent> generate(LlmRequest request);
  Future<void> cancel();
}

// ---------------------------------------------------------------------------
// LLM contract types (shared with lib/data/services/llm/llm_service.dart)
// ---------------------------------------------------------------------------

/// Why a generation ended.
enum LlmStopReason {
  /// The model finished naturally (EOS or max tokens).
  completed,

  /// The user interrupted; partial output stands.
  cancelled,

  /// The context window filled up.
  contextLimit,
}

/// Base of the events on the generation stream.
sealed class LlmTokenEvent {
  const LlmTokenEvent();
}

/// One decoded piece of the answer.
final class LlmTokenText extends LlmTokenEvent {
  const LlmTokenText(this.text);

  final String text;
}

/// The generation finished. Always the last non-error event.
final class LlmTokenDone extends LlmTokenEvent {
  const LlmTokenDone(this.reason);

  final LlmStopReason reason;
}

/// The generation failed. Always the last event when present.
final class LlmTokenFailed extends LlmTokenEvent {
  const LlmTokenFailed(this.failure);

  final Failure failure;
}

/// One generation request.
class LlmRequest {
  const LlmRequest({
    required this.prompt,
    this.maxTokens = 512,
    this.temperature = 0.7,
    this.lowRam = false,
  });

  /// The fully rendered prompt (system + user text).
  final String prompt;

  /// Hard cap on generated tokens.
  final int maxTokens;

  /// Sampling temperature.
  final double temperature;

  /// 2GB-device mode: the service clamps context and token budgets.
  final bool lowRam;
}

/// A routed, fully rendered prompt: what the LLM will actually receive.
class RoutedPrompt {
  const RoutedPrompt({
    required this.promptId,
    required this.templateFile,
    required this.text,
    required this.isFallback,
  });

  /// Stable id of the prompt (template file stem, or a built-in id).
  final String promptId;

  /// Template file that produced [text] (informational).
  final String templateFile;

  /// The rendered prompt text.
  final String text;

  /// True when the general assistant fallback was used because the intent
  /// has no dedicated template (or its template failed to load).
  final bool isFallback;

  @override
  String toString() => 'RoutedPrompt($promptId${isFallback ? ' [fallback]' : ''})';
}

/// Collects a token stream into a full string, stopping at the first
/// failure. Useful for short, non-streamed uses (meta-classification).
Future<Result<String>> collectLlmText(Stream<LlmTokenEvent> events) async {
  final StringBuffer buffer = StringBuffer();
  await for (final LlmTokenEvent event in events) {
    switch (event) {
      case LlmTokenText(:final String text):
        buffer.write(text);
      case LlmTokenFailed(:final Failure failure):
        return Err<String>(failure);
      case LlmTokenDone():
        // Generation over — the stream closes right after this event.
        break;
    }
  }
  return Ok<String>(buffer.toString());
}

// ---------------------------------------------------------------------------
// The use case
// ---------------------------------------------------------------------------

/// Input for one orchestration turn.
class OrchestrationRequest {
  const OrchestrationRequest({
    required this.transcript,
    required this.userLanguage,
    this.lowRam = false,
    this.maxTokens = 512,
    this.temperature = 0.7,
  });

  /// Raw STT output for this turn.
  final String transcript;

  /// BCP-47-ish language code the user speaks ('ta', 'hi', ...).
  final String userLanguage;

  /// 2GB-device mode flag, forwarded to the LLM.
  final bool lowRam;

  /// Generation budget, forwarded to the LLM.
  final int maxTokens;

  /// Sampling temperature, forwarded to the LLM.
  final double temperature;
}

/// The plan for one turn: what was understood and the streaming answer.
class OrchestrationPlan {
  const OrchestrationPlan({
    required this.intent,
    required this.confidence,
    required this.usedLlmFallback,
    required this.slots,
    required this.promptId,
    required this.promptText,
    required this.isFallbackPrompt,
    required this.response,
  });

  /// The intent this turn was routed to.
  final VaaniIntent intent;

  /// Classification confidence (0..1). When [usedLlmFallback] is true this
  /// is [OrchestrateUserRequest.metaFallbackConfidence].
  final double confidence;

  /// True when the fast classifier was unsure and the on-device LLM
  /// decided the intent.
  final bool usedLlmFallback;

  /// Slots extracted from the transcript.
  final SlotSet slots;

  /// Id of the rendered prompt (template stem).
  final String promptId;

  /// The rendered prompt text (for the conversation log, on-device only).
  final String promptText;

  /// True when the general assistant fallback prompt was used.
  final bool isFallbackPrompt;

  /// Streaming answer. May carry a single [LlmTokenFailed] event when the
  /// on-device model is unavailable — the UI then shows the kind message.
  final Stream<LlmTokenEvent> response;
}

/// Wires the turn together. All collaborators are constructor-injected
/// ports, so tests (and the device/production split) use fakes freely.
class OrchestrateUserRequest {
  OrchestrateUserRequest({
    required this.classifier,
    required this.slotExtractor,
    required this.promptBuilder,
    required this.llm,
    this.fallbackThreshold = defaultFallbackThreshold,
    this.metaTimeout = const Duration(seconds: 10),
  });

  /// Below this confidence the LLM meta-classifier gets a chance
  /// (docs/architecture.md step 4).
  static const double defaultFallbackThreshold = 0.6;

  /// Confidence recorded when the LLM fallback resolved the intent. An
  /// honest estimate, not a measurement — flagged via [OrchestrationPlan.usedLlmFallback].
  static const double metaFallbackConfidence = 0.7;

  final IntentClassifying classifier;
  final SlotFilling slotExtractor;
  final PromptBuilding promptBuilder;
  final LlmGenerating llm;
  final double fallbackThreshold;
  final Duration metaTimeout;

  Future<Result<OrchestrationPlan>> call(OrchestrationRequest request) async {
    final String transcript = request.transcript.trim();
    if (transcript.isEmpty) {
      return const Err<OrchestrationPlan>(
        UnknownFailure(detail: 'transcript is empty'),
      );
    }

    final IntentPrediction prediction = classifier.classify(transcript);
    VaaniIntent intent = prediction.intent;
    double confidence = prediction.confidence;
    bool usedLlmFallback = false;

    if (confidence < fallbackThreshold) {
      final VaaniIntent? metaIntent =
          await _metaClassify(transcript, request.userLanguage);
      if (metaIntent != null) {
        intent = metaIntent;
        confidence = metaFallbackConfidence;
        usedLlmFallback = true;
      }
    }

    final SlotSet slots =
        slotExtractor.extract(intent: intent, transcript: transcript);

    final Result<RoutedPrompt> routed = await promptBuilder.buildPrompt(
      intent: intent,
      userLanguage: request.userLanguage,
      transcript: transcript,
      slotValues: slots.toValueMap(),
    );
    final RoutedPrompt prompt;
    switch (routed) {
      case Ok<RoutedPrompt>(:final RoutedPrompt value):
        prompt = value;
      case Err<RoutedPrompt>(:final Failure failure):
        return Err<OrchestrationPlan>(failure);
    }

    final Stream<LlmTokenEvent> response = llm.generate(
      LlmRequest(
        prompt: prompt.text,
        maxTokens: request.maxTokens,
        temperature: request.temperature,
        lowRam: request.lowRam,
      ),
    );

    return Ok<OrchestrationPlan>(
      OrchestrationPlan(
        intent: intent,
        confidence: confidence,
        usedLlmFallback: usedLlmFallback,
        slots: slots,
        promptId: prompt.promptId,
        promptText: prompt.text,
        isFallbackPrompt: prompt.isFallback,
        response: response,
      ),
    );
  }

  /// Asks the on-device LLM to pick an intent id. Returns `null` whenever
  /// the fallback itself fails or times out — then we honestly keep the
  /// fast classifier's best guess instead of inventing certainty.
  Future<VaaniIntent?> _metaClassify(
    String transcript,
    String userLanguage,
  ) async {
    try {
      final Result<RoutedPrompt> metaPrompt =
          await promptBuilder.buildMetaClassificationPrompt(
        transcript: transcript,
        userLanguage: userLanguage,
        candidates: VaaniIntent.values,
      );
      final RoutedPrompt prompt;
      switch (metaPrompt) {
        case Ok<RoutedPrompt>(:final RoutedPrompt value):
          prompt = value;
        case Err<RoutedPrompt>():
          return null;
      }

      final LlmRequest llmRequest = LlmRequest(
        prompt: prompt.text,
        maxTokens: 24,
        temperature: 0,
        lowRam: true,
      );
      final Result<String> answer =
          await collectLlmText(llm.generate(llmRequest)).timeout(
        metaTimeout,
        onTimeout: () => const Err<String>(
          TimeoutFailure(detail: 'LLM meta-classification timed out'),
        ),
      );
      switch (answer) {
        case Ok<String>(:final String value):
          return _parseIntentId(value);
        case Err<String>():
          await llm.cancel();
          return null;
      }
    } catch (_) {
      // The fallback must never break the turn.
      await llm.cancel();
      return null;
    }
  }

  /// Accepts the first token of the LLM answer and reduces it to a known
  /// intent id ("Answer: draft_message." -> draftMessage).
  VaaniIntent? _parseIntentId(String raw) {
    final List<String> parts =
        raw.trim().toLowerCase().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) {
      return null;
    }
    final String cleaned =
        parts.first.replaceAll(RegExp(r'[^a-z0-9_]'), '');
    if (cleaned.isEmpty) {
      return null;
    }
    return VaaniIntent.fromId(cleaned);
  }
}
