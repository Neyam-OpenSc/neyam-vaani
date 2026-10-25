/// On-device LLM runtime access.
///
/// Two implementations share the [LlmService] contract:
///
/// - [FfiLlmService] — dart:ffi bindings to `libnv_llama_bridge.so` (the
///   C++ llama.cpp bridge owned by the native team). Tokens are pushed
///   from the bridge's worker thread through a callback registered with
///   `NativeCallable.listener`, which delivers each token to the Dart
///   event loop; a Dart [Stream] is what callers consume.
/// - [DeterministicLlm] — canned responses for tests and CI, selected by
///   substring markers in the prompt. No native library needed.
///
/// Privacy (PRIVACY_CHARTER.md): the prompt is the only data handed to the
/// native layer, and it never leaves the device. There is no code path
/// from this file to any network API.
///
/// ## C ABI of libnv_llama_bridge (all symbols prefixed `nv_`)
///
/// ```c
/// int  nv_llama_init(const char* gguf_path, int32_t ctx_tokens, bool low_ram);
/// // Loads the model (singleton bridge — no handles). Non-zero on success,
/// // 0 on failure. ctx_tokens/low_ram control memory budgets.
///
/// int  nv_llama_generate(const char* system, const char* user,
///                        nv_llama_token_cb cb);
/// // Starts one generation on a worker thread; the callback fires from
/// // that thread. Non-zero on success, 0 on failure. One generation at a
/// // time. Token/temperature budgets are bridge-owned (set at init); the
/// // Dart-side maxTokens/temperature fields are not forwarded.
///
/// typedef void (*nv_llama_token_cb)(const char* piece, const char* full,
///                                    int32_t n_tokens, bool is_final);
/// // `piece` is the incremental token, `full` the accumulated text.
/// // EXACTLY ONE is_final=true fires per generate() call — also when the
/// // generation is stopped or errors out. The bridge keeps `piece`/`full`
/// // alive until the Dart listener callback has been delivered (that is
/// // the standard NativeCallable.listener contract).
///
/// void nv_llama_stop();               // request cancellation
/// void nv_llama_unload();             // free the model (quiesces the worker)
/// int  nv_llama_reload();             // reload the last model after unload
/// bool nv_llama_is_loaded();
/// bool nv_llama_is_generating();
/// double nv_llama_tokens_per_second();
/// int64_t nv_llama_ram_bytes();        // RAM held by the models
/// int64_t nv_llama_process_peak_rss(); // process peak RSS (memory pressure)
/// int32_t nv_llama_last_status();      // 0 = ok, 1 = cancelled, >=2 = error
/// const char* nv_llama_last_full_text(); // owned by the caller after return
/// void nv_llama_free(const char* s);   // free a string from the bridge
/// ```
///
/// The status mapping above must stay in sync with the bridge's enum.
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:ffi';

import 'package:ffi/ffi.dart' show Utf8, calloc;

import '../../../core/errors/failures.dart';
import '../../../core/result.dart';
import '../../../domain/usecases/orchestrate_user_request.dart'
    show LlmGenerating, LlmRequest, LlmTokenDone, LlmTokenEvent,
    LlmTokenFailed, LlmStopReason, LlmTokenText;

/// Lifecycle of the on-device model runtime.
enum LlmState {
  /// Constructed; neither library nor model touched yet.
  unloaded,

  /// Model load in progress.
  loading,

  /// Model loaded; generate() can run.
  ready,

  /// A generation is streaming.
  generating,

  /// The native bridge (or model) is not usable on this device. The app
  /// keeps working with honest, non-LLM features instead of crashing.
  unavailable,
}

/// Contract every LLM backend implements: device lifecycle plus the
/// [LlmGenerating] streaming API used by the orchestrator.
abstract interface class LlmService implements LlmGenerating {
  /// Current runtime state.
  LlmState get state;

  /// Whether the native bridge can be used on this device at all.
  bool get isAvailable;

  /// Loads (or reloads) a GGUF model. [lowRam] selects 2GB-device budgets.
  Future<Result<void>> load({required String modelPath, bool lowRam});

  @override
  Stream<LlmTokenEvent> generate(LlmRequest request);

  @override
  Future<void> cancel();

  /// Unloads the model and releases native memory. Safe to call anytime
  /// when no generation is streaming (stop it first — cancel()).
  Future<void> unload();
}

// ---------------------------------------------------------------------------
// FFI bindings
// ---------------------------------------------------------------------------

/// `void nv_llama_token_cb(const char* piece, const char* full,
/// int32_t n_tokens, bool is_final)` — fired on the bridge worker thread.
typedef _TokenCallbackNative = Void Function(
  Pointer<Utf8> piece,
  Pointer<Utf8> full,
  Int32 nTokens,
  Bool isFinal,
);

typedef _InitNative = Int32 Function(
  Pointer<Utf8> ggufPath,
  Int32 ctxTokens,
  Bool lowRam,
);
typedef _Init = int Function(Pointer<Utf8>, int, bool);

typedef _GenerateNative = Int32 Function(
  Pointer<Utf8> system,
  Pointer<Utf8> user,
  Pointer<NativeFunction<_TokenCallbackNative>> callback,
);
typedef _Generate = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<NativeFunction<_TokenCallbackNative>>,
);

typedef _StopNative = Void Function();
typedef _Stop = void Function();

typedef _UnloadNative = Void Function();
typedef _Unload = void Function();

typedef _ReloadNative = Int32 Function();
typedef _Reload = int Function();

typedef _IsLoadedNative = Bool Function();
typedef _IsLoaded = bool Function();

typedef _IsGeneratingNative = Bool Function();
typedef _IsGenerating = bool Function();

typedef _TokensPerSecondNative = Double Function();
typedef _TokensPerSecond = double Function();

typedef _RamBytesNative = Int64 Function();
typedef _RamBytes = int Function();

typedef _PeakRssNative = Int64 Function();
typedef _PeakRss = int Function();

typedef _LastStatusNative = Int32 Function();
typedef _LastStatus = int Function();

typedef _LastFullTextNative = Pointer<Utf8> Function();
typedef _LastFullText = Pointer<Utf8> Function();

typedef _FreeTextNative = Void Function(Pointer<Utf8> text);
typedef _FreeText = void Function(Pointer<Utf8>);

/// nv_llama_last_status() codes (keep in sync with the bridge enum).
const int _nvStatusOk = 0;
const int _nvStatusCancelled = 1;

/// Hand-rolled `String -> Pointer<Utf8>` (package:ffi is not a dependency).
extension _NativeUtf8 on String {
  Pointer<Utf8> toNative() {
    final List<int> bytes = utf8.encode(this);
    final Pointer<Uint8> out = calloc<Uint8>(bytes.length + 1);
    final view = out.asTypedList(bytes.length + 1);
    view.setRange(0, bytes.length, bytes);
    view[bytes.length] = 0;
    return out.cast<Utf8>();
  }
}

/// Hand-rolled `Pointer<Utf8> -> String` copy (valid only while the native
/// buffer is alive — copy out immediately, like the token callback does).
String _derefUtf8(Pointer<Utf8> ptr) {
  final Pointer<Uint8> bytes = ptr.cast<Uint8>();
  int length = 0;
  while (bytes[length] != 0) {
    length += 1;
  }
  return utf8.decode(bytes.asTypedList(length), allowMalformed: true);
}

// ---------------------------------------------------------------------------
// FFI-backed implementation
// ---------------------------------------------------------------------------

/// Talks to libnv_llama_bridge over dart:ffi.
///
/// Missing library is not an error: [isAvailable] reports false,
/// [generate] yields a single [LlmTokenFailed] with a
/// [NativeLibraryFailure], and the rest of the app keeps working. This is
/// what lets unit tests (and the CI matrix) run without any native code.
final class FfiLlmService implements LlmService {
  FfiLlmService({this.libraryName = defaultLibraryName});

  /// Bridge library file name. Android: `libnv_llama_bridge.so`.
  static const String defaultLibraryName = 'libnv_llama_bridge.so';

  final String libraryName;

  DynamicLibrary? _lib;
  bool _openAttempted = false;
  NativeCallable<_TokenCallbackNative>? _tokenCallable;
  StreamController<LlmTokenEvent>? _activeController;
  LlmState _state = LlmState.unavailable;

  @override
  LlmState get state => _state;

  @override
  bool get isAvailable => _libraryOrNull() != null;

  DynamicLibrary? _libraryOrNull() {
    final DynamicLibrary? cached = _lib;
    if (cached != null) {
      return cached;
    }
    if (_openAttempted) {
      return null;
    }
    _openAttempted = true;
    try {
      // Statically linked bridge ships inside the app binary.
      final DynamicLibrary process = DynamicLibrary.process();
      if (process.providesSymbol('nv_llama_init')) {
        _lib = process;
        return process;
      }
    } catch (_) {
      // Process lookup unsupported on this platform; try opening the file.
    }
    try {
      final DynamicLibrary opened = DynamicLibrary.open(libraryName);
      _lib = opened;
      return opened;
    } catch (_) {
      // Graceful degradation: no bridge on this device (tests, desktop).
      return null;
    }
  }

  /// The listener callable the bridge calls from its worker thread.
  /// Created once, kept alive for the service's lifetime, closed in
  /// [unload].
  NativeCallable<_TokenCallbackNative>? _ensureCallable() {
    final NativeCallable<_TokenCallbackNative>? existing = _tokenCallable;
    if (existing != null) {
      return existing;
    }
    try {
      _tokenCallable =
          NativeCallable<_TokenCallbackNative>.listener(_onNativeToken);
      return _tokenCallable;
    } catch (_) {
      return null;
    }
  }

  /// Bridge -> Dart. Runs on the Dart event loop (scheduled thread-safely
  /// by NativeCallable.listener); by then the bridge has kept `piece` and
  /// `full` valid, and we copy the piece out immediately.
  void _onNativeToken(
    Pointer<Utf8> piece,
    Pointer<Utf8> full,
    int nTokens,
    bool isFinal,
  ) {
    final StreamController<LlmTokenEvent>? controller = _activeController;
    if (controller == null || controller.isClosed) {
      // Late event after cancel()/unload() — drop it.
      return;
    }
    if (isFinal) {
      // Exactly one is_final per generate, also on stop/error; the status
      // code tells us which ending this was.
      _finish(controller, _finalEventForStatus());
      return;
    }
    if (piece != nullptr) {
      controller.add(LlmTokenText(_derefUtf8(piece)));
    }
  }

  LlmTokenEvent _finalEventForStatus() {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return const LlmTokenDone(LlmStopReason.completed);
    }
    final int status = lib
        .lookupFunction<_LastStatusNative, _LastStatus>('nv_llama_last_status')();
    switch (status) {
      case _nvStatusOk:
        return const LlmTokenDone(LlmStopReason.completed);
      case _nvStatusCancelled:
        return const LlmTokenDone(LlmStopReason.cancelled);
      default:
        return LlmTokenFailed(
          UnknownFailure(detail: 'nv_llama_bridge ended with status $status'),
        );
    }
  }

  @override
  Future<Result<void>> load({
    required String modelPath,
    bool lowRam = false,
  }) async {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      _state = LlmState.unavailable;
      return Err<void>(
        NativeLibraryFailure(
          detail: 'libnv_llama_bridge ($libraryName) not found on this device',
        ),
      );
    }
    _state = LlmState.loading;
    final int contextSize = lowRam ? 1024 : 4096;
    final Pointer<Utf8> pathPtr = modelPath.toNative();
    try {
      final int ok = lib
          .lookupFunction<_InitNative, _Init>('nv_llama_init')(
        pathPtr,
        contextSize,
        lowRam,
      );
      if (ok == 0) {
        _state = LlmState.unavailable;
        return Err<void>(
          ModelLoadFailure(
            detail:
                'nv_llama_init failed for $modelPath (ctx=$contextSize, '
                'status=${_lastStatusOf(lib)})',
          ),
        );
      }
      if (_ensureCallable() == null) {
        _state = LlmState.unavailable;
        return const Err<void>(
          ModelLoadFailure(
            detail: 'could not register the nv_llama_token_cb listener',
          ),
        );
      }
      _state = LlmState.ready;
      return const Ok<void>(null);
    } finally {
      calloc.free(pathPtr);
    }
  }

  int _lastStatusOf(DynamicLibrary lib) {
    try {
      return lib
          .lookupFunction<_LastStatusNative, _LastStatus>(
              'nv_llama_last_status')();
    } catch (_) {
      return -1;
    }
  }

  bool _bridgeIsLoaded(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<_IsLoadedNative, _IsLoaded>(
          'nv_llama_is_loaded')();
    } catch (_) {
      return false;
    }
  }

  bool _bridgeIsGenerating(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<_IsGeneratingNative, _IsGenerating>(
          'nv_llama_is_generating')();
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<LlmTokenEvent> generate(LlmRequest request) {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return _failedStream(
        NativeLibraryFailure(
          detail:
              'libnv_llama_bridge ($libraryName) not found on this device',
        ),
      );
    }
    if (!_bridgeIsLoaded(lib) || _state == LlmState.unavailable) {
      return _failedStream(
        ModelLoadFailure(
          detail:
              'model not loaded (state: ${_state.name}) — call load() first',
        ),
      );
    }
    if (_state == LlmState.generating ||
        _activeController != null ||
        _bridgeIsGenerating(lib)) {
      return _failedStream(
        const UnknownFailure(
          detail: 'another generation is already in progress',
        ),
      );
    }
    late final StreamController<LlmTokenEvent> controller;
    controller = StreamController<LlmTokenEvent>(
      onListen: () => _begin(lib, request, controller),
      onCancel: () {
        unawaited(cancel());
      },
    );
    return controller.stream;
  }

  Stream<LlmTokenEvent> _failedStream(Failure failure) {
    return Stream<LlmTokenEvent>.fromIterable(
      <LlmTokenEvent>[LlmTokenFailed(failure)],
    );
  }

  void _begin(
    DynamicLibrary lib,
    LlmRequest request,
    StreamController<LlmTokenEvent> controller,
  ) {
    _state = LlmState.generating;
    _activeController = controller;
    final NativeCallable<_TokenCallbackNative>? callable = _ensureCallable();
    if (callable == null) {
      _finish(
        controller,
        const LlmTokenFailed(
          ModelLoadFailure(
            detail: 'could not register the nv_llama_token_cb listener',
          ),
        ),
      );
      return;
    }
    // PromptRouter renders one block; the bridge gets an empty system
    // prompt and the full rendered prompt as the user prompt.
    final Pointer<Utf8> systemPtr = ''.toNative();
    final Pointer<Utf8> userPtr = request.prompt.toNative();
    try {
      final int started = lib
          .lookupFunction<_GenerateNative, _Generate>('nv_llama_generate')(
        systemPtr,
        userPtr,
        callable.nativeFunction,
      );
      if (started == 0) {
        _finish(
          controller,
          LlmTokenFailed(
            ModelLoadFailure(
              detail: 'nv_llama_generate failed to start '
                  '(status=${_lastStatusOf(lib)})',
            ),
          ),
        );
        return;
      }
      // Tokens now arrive through _onNativeToken; exactly one is_final
      // event will end the stream (also on stop/error).
    } finally {
      calloc.free(systemPtr);
      calloc.free(userPtr);
    }
  }

  void _finish(StreamController<LlmTokenEvent> controller, LlmTokenEvent last) {
    _activeController = null;
    if (_state == LlmState.generating) {
      _state = LlmState.ready;
    }
    if (!controller.isClosed) {
      controller.add(last);
      unawaited(controller.close());
    }
  }

  @override
  Future<void> cancel() async {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib != null && _bridgeIsGenerating(lib)) {
      lib.lookupFunction<_StopNative, _Stop>('nv_llama_stop')();
      // The bridge still fires its single is_final=true callback (with
      // status cancelled), which closes the stream honestly.
    }
  }

  @override
  Future<void> unload() async {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib != null) {
      if (_bridgeIsGenerating(lib)) {
        lib.lookupFunction<_StopNative, _Stop>('nv_llama_stop')();
      }
      lib.lookupFunction<_UnloadNative, _Unload>('nv_llama_unload')();
    }
    final StreamController<LlmTokenEvent>? controller = _activeController;
    _activeController = null;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
    // unload() quiesces the worker thread, so the callable can be closed
    // safely now; it is re-created by the next load().
    _tokenCallable?.close();
    _tokenCallable = null;
    _state = LlmState.unavailable;
  }

  // -- Bridge introspection (memory-pressure and perf wiring) -----------

  /// Whether the bridge currently holds a loaded model.
  bool get isLoaded {
    final DynamicLibrary? lib = _libraryOrNull();
    return lib != null && _bridgeIsLoaded(lib);
  }

  /// Whether a generation is streaming right now.
  bool get isGenerating {
    final DynamicLibrary? lib = _libraryOrNull();
    return lib != null && _bridgeIsGenerating(lib);
  }

  /// Recent generation speed, for honest progress feedback only.
  double get tokensPerSecond {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return 0;
    }
    try {
      return lib
          .lookupFunction<_TokensPerSecondNative, _TokensPerSecond>(
              'nv_llama_tokens_per_second')();
    } catch (_) {
      return 0;
    }
  }

  /// RAM currently held by the models (for the unload-under-pressure rule).
  int get ramBytes {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return 0;
    }
    try {
      return lib
          .lookupFunction<_RamBytesNative, _RamBytes>('nv_llama_ram_bytes')();
    } catch (_) {
      return 0;
    }
  }

  /// Process peak RSS in bytes (device-tier and memory-pressure checks).
  int get processPeakRssBytes {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return 0;
    }
    try {
      return lib.lookupFunction<_PeakRssNative, _PeakRss>(
          'nv_llama_process_peak_rss')();
    } catch (_) {
      return 0;
    }
  }

  /// Reloads the last model after an [unload] (e.g. after memory
  /// pressure forced a swap — see docs/architecture.md).
  Future<Result<void>> reload() async {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return Err<void>(
        NativeLibraryFailure(
          detail:
              'libnv_llama_bridge ($libraryName) not found on this device',
        ),
      );
    }
    final int ok = lib.lookupFunction<_ReloadNative, _Reload>('nv_llama_reload')();
    if (ok == 0) {
      return Err<void>(
        UnknownFailure(
          detail:
              'nv_llama_reload failed (status=${_lastStatusOf(lib)})',
        ),
      );
    }
    _state = LlmState.ready;
    return const Ok<void>(null);
  }

  /// The full text of the last generation (bridge-owned copy freed here).
  /// Useful to recover the partial answer after a cancellation.
  String? lastFullText() {
    final DynamicLibrary? lib = _libraryOrNull();
    if (lib == null) {
      return null;
    }
    final Pointer<Utf8> text = lib
        .lookupFunction<_LastFullTextNative, _LastFullText>(
            'nv_llama_last_full_text')();
    if (text == nullptr) {
      return null;
    }
    try {
      return _derefUtf8(text);
    } finally {
      lib.lookupFunction<_FreeTextNative, _FreeText>('nv_llama_free')(text);
    }
  }
}

// ---------------------------------------------------------------------------
// Deterministic test double
// ---------------------------------------------------------------------------

/// An [LlmService] that never touches native code: it looks for the first
/// marker whose key occurs in the prompt and streams the mapped response
/// in small chunks. The default response is Vaani's honest "I don't know."
/// (TENDER_UX_PRINCIPLES.md: honest uncertainty beats a guess).
final class DeterministicLlm implements LlmService {
  DeterministicLlm({
    Map<String, String> cannedResponses = const <String, String>{},
    this.defaultResponse = 'I don\'t know.',
  }) : _canned = Map<String, String>.of(cannedResponses);

  final Map<String, String> _canned;
  final String defaultResponse;

  /// Every request seen, for assertions in tests.
  final List<LlmRequest> requests = <LlmRequest>[];

  bool _cancelled = false;

  /// Adds or replaces a marker -> response pair.
  void setCannedResponse(String marker, String response) =>
      _canned[marker] = response;

  /// Clears the request log.
  void clearRequests() => requests.clear();

  @override
  LlmState get state => LlmState.ready;

  @override
  bool get isAvailable => true;

  @override
  Future<Result<void>> load({
    required String modelPath,
    bool lowRam = false,
  }) async {
    return const Ok<void>(null);
  }

  @override
  Stream<LlmTokenEvent> generate(LlmRequest request) async* {
    requests.add(request);
    _cancelled = false;
    String text = defaultResponse;
    for (final MapEntry<String, String> entry in _canned.entries) {
      if (request.prompt.contains(entry.key)) {
        text = entry.value;
        break;
      }
    }
    const int chunkSize = 8;
    for (int i = 0; i < text.length; i += chunkSize) {
      if (_cancelled) {
        yield const LlmTokenDone(LlmStopReason.cancelled);
        return;
      }
      final int end = i + chunkSize > text.length ? text.length : i + chunkSize;
      yield LlmTokenText(text.substring(i, end));
      // Yield to the event loop so cancel() is observable mid-stream.
      // (Not a fake delay — no wall-clock time passes.)
      await Future<void>.delayed(Duration.zero);
    }
    yield const LlmTokenDone(LlmStopReason.completed);
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
  }

  @override
  Future<void> unload() async {}
}
