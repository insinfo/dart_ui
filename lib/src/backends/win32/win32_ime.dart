/// `imm32.dll` and the `WM_IME_*` half of the Win32 backend.
///
/// Kept out of `win32_api.dart` for the reason `win32_ole.dart` is: that file
/// opens kernel32, user32 and gdi32 - the three libraries a *window* needs, and
/// a process that cannot open them cannot run at all. imm32 is not in that
/// class. A Windows install with no input method still has imm32, but a process
/// that fails to bind it has a perfectly good window and merely no composition,
/// and the probe has to be able to say exactly that.
///
/// ## The one rule that shapes this whole file
///
/// **`ImmGetCompositionStringW` is only valid inside the `WM_IME_COMPOSITION`
/// that announced the change.** The message carries no text - only a bitmask of
/// what changed - and the string it grants access to belongs to an input
/// context that the IME is free to rewrite the moment the handler returns. So
/// this file reads *everything* it will ever need while still inside the
/// WndProc, builds an immutable [ImeComposition], and pushes it at the client.
/// Nothing here hands out a lazy accessor and nothing here awaits, which is the
/// same discipline `win32_drag_drop.dart` applies to `IDataObject`.
///
/// The corollary is that a client callback runs *inside a message handler*. An
/// exception from it must not escape into the OS: the shared WndProc already
/// catches at the top and answers `DefWindowProcW`, but for
/// `WM_IME_SETCONTEXT` that fallback would forward the message with the IME's
/// own composition window still switched on - drawing the preedit twice, once
/// by us and once by Windows. So the reads and the callbacks are guarded here
/// too, and a failure is recorded rather than thrown.
///
/// ## What `DefWindowProcW` would do, and why most of it is refused
///
/// Left alone, IMM32 draws the preedit itself, in a window of its own, in a
/// font of its choosing, at a position it guesses. This framework lays the
/// provisional text out in the document - in the right font, wrapped with the
/// text around it, underlined per clause - so the platform's version is not a
/// fallback but a duplicate. Clearing `ISC_SHOWUICOMPOSITIONWINDOW` from
/// `WM_IME_SETCONTEXT`'s `lParam` is what switches it off, and swallowing
/// `WM_IME_STARTCOMPOSITION` / `WM_IME_ENDCOMPOSITION` is what keeps it off.
///
/// The **candidate list** is the opposite case and is deliberately left to the
/// platform: it is a whole popup UI with its own paging, its own keyboard
/// handling and its own per-IME conventions, and no framework that draws it
/// itself has ever matched what users expect from their own IME. All this
/// backend does is say *where* it should open, through `ImmSetCandidateWindow`.
///
/// ## What is not implemented, named rather than shrugged at
///
///   * **`WM_IME_REQUEST`**. `IMR_DOCUMENTFEED` is how an IMM32 method obtains
///     the text around the caret for contextual conversion, and
///     `IMR_RECONVERTSTRING` is reconversion. Neither is answered, so
///     [Win32TextInputBackend.usesSurroundingText] is false and a Japanese
///     method here converts each phrase without knowing what precedes it. The
///     port carries surrounding text because Wayland requires it; this backend
///     reports honestly that it drops it.
///   * **TSF** (the Text Services Framework), which is what roadmap 13.7 calls
///     the optional fourth phase. IMM32 is the compatibility layer TSF itself
///     emulates for applications that do not implement `ITfContextOwner`; it
///     covers composition, candidates and dead keys, and does not cover
///     handwriting or speech panels that only publish a TSF interface.
library;

import 'dart:ffi';

import '../../foundation/diagnostics.dart';
import '../../geometry/rect.dart';
import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import '../../platform/window_events.dart';
import 'win32_api.dart';
import 'win32_constants.dart';
import 'win32_structs.dart';
import 'win32_window.dart';

/// What [Imm32Api.load] found, whether or not it succeeded.
final class Imm32LoadResult {
  const Imm32LoadResult({required this.api, required this.diagnostics});

  /// Null when imm32 or one of its required symbols was missing.
  final Imm32Api? api;

  final List<BackendDiagnostic> diagnostics;
}

/// The IMM32 entry points, loaded once per process.
///
/// Fields are lowerCamelCase versions of the native names, the convention
/// `Win32Api` established.
final class Imm32Api {
  Imm32Api._(this._imm32) {
    _bind();
  }

  final DynamicLibrary _imm32;

  static Imm32LoadResult? _cached;

  /// Loads and binds, or explains what stopped it. Cached: a probe runs per
  /// backend selection and reopening the DLL each time is wasted work.
  static Imm32LoadResult load() {
    final Imm32LoadResult? cached = _cached;
    if (cached != null) return cached;

    DynamicLibrary imm32;
    try {
      imm32 = DynamicLibrary.open('imm32.dll');
    } on Object catch (error) {
      final result = Imm32LoadResult(
        api: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary('imm32.dll', detail: '$error'),
        ],
      );
      _cached = result;
      return result;
    }

    Imm32LoadResult result;
    try {
      result = Imm32LoadResult(
        api: Imm32Api._(imm32),
        diagnostics: const <BackendDiagnostic>[],
      );
    } on ArgumentError catch (error) {
      result = Imm32LoadResult(
        api: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingSymbol(
            '$error',
            detail: 'required imm32 symbol',
          ),
        ],
      );
    }
    _cached = result;
    return result;
  }

  /// Drops the cache. Only for tests that want to observe a fresh load.
  static void debugResetCache() => _cached = null;

  /// `ImmGetContext` - the window's input context, or 0 when it has none.
  ///
  /// Every successful call must be matched by [immReleaseContext]. IMM32 keeps
  /// a per-context lock count and a leaked `HIMC` wedges the input method for
  /// the whole thread, not merely for this window.
  late final int Function(int hwnd) immGetContext;

  late final int Function(int hwnd, int himc) immReleaseContext;

  /// `ImmGetCompositionStringW`.
  ///
  /// With a null buffer and zero length it returns the *size in bytes* the
  /// buffer must have - except for `GCS_CURSORPOS` and `GCS_DELTASTART`, where
  /// the return value is the answer itself. A negative return is
  /// `IMM_ERROR_NODATA` or `IMM_ERROR_GENERAL`, never a length.
  late final int Function(int himc, int index, Pointer<Void> buffer, int length)
      immGetCompositionStringW;

  late final int Function(int himc, Pointer<CompositionForm> form)
      immSetCompositionWindow;

  late final int Function(int himc, Pointer<CandidateForm> form)
      immSetCandidateWindow;

  /// `ImmNotifyIME` - the one way to tell a method to abandon what it is
  /// composing.
  late final int Function(int himc, int action, int index, int value)
      immNotifyIME;

  /// `ImmAssociateContextEx` - attaches or detaches a window's input context.
  ///
  /// Detaching (`hIMC == 0`, no `IACE_DEFAULT`) is how composition is switched
  /// off for a password field; passing `IACE_DEFAULT` restores it. The `Ex`
  /// form rather than plain `ImmAssociateContext` because only it can restore
  /// the *default* context, and remembering the previous `HIMC` by hand across
  /// a focus change is how applications end up associating one window's context
  /// with another window.
  late final int Function(int hwnd, int himc, int flags) immAssociateContextEx;

  void _bind() {
    immGetContext =
        _imm32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
            'ImmGetContext');
    immReleaseContext = _imm32.lookupFunction<Int32 Function(IntPtr, IntPtr),
        int Function(int, int)>('ImmReleaseContext');
    immGetCompositionStringW = _imm32.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
        int Function(int, int, Pointer<Void>, int)>('ImmGetCompositionStringW');
    immSetCompositionWindow = _imm32.lookupFunction<
        Int32 Function(IntPtr, Pointer<CompositionForm>),
        int Function(int, Pointer<CompositionForm>)>('ImmSetCompositionWindow');
    immSetCandidateWindow = _imm32.lookupFunction<
        Int32 Function(IntPtr, Pointer<CandidateForm>),
        int Function(int, Pointer<CandidateForm>)>('ImmSetCandidateWindow');
    immNotifyIME = _imm32.lookupFunction<
        Int32 Function(IntPtr, Uint32, Uint32, Uint32),
        int Function(int, int, int, int)>('ImmNotifyIME');
    immAssociateContextEx = _imm32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Uint32),
        int Function(int, int, int)>('ImmAssociateContextEx');
  }
}

// ---------------------------------------------------------------------------
// Pure decoding: the part that is testable without an input method installed
// ---------------------------------------------------------------------------

/// Turns `GCS_COMPATTR`'s byte-per-code-unit array into clause runs.
///
/// IMM32 reports one attribute per UTF-16 code unit of the composition string,
/// which for a CJK preedit means one per character and for anything astral
/// means two identical bytes. Adjacent equal bytes are one clause; that
/// coalescing is not an optimisation but the actual shape of the data - the
/// IME's clauses *are* the runs, and `GCS_COMPCLAUSE` (which reports the same
/// boundaries as an index array) is redundant with it for drawing purposes.
///
/// An attribute byte this framework does not know maps to
/// [ImeCompositionStyle.input], which is the conservative reading: it draws as
/// "raw, unconverted", which is what an unknown state most likely is and which
/// never claims a run is converted when it is not.
List<ImeCompositionClause> decodeCompositionAttributes(List<int> attributes) {
  if (attributes.isEmpty) return const <ImeCompositionClause>[];
  final clauses = <ImeCompositionClause>[];
  int runStart = 0;
  int runValue = attributes[0];
  for (int i = 1; i <= attributes.length; i++) {
    final int value = i == attributes.length ? -1 : attributes[i];
    if (value == runValue) continue;
    clauses.add(
      ImeCompositionClause(
        start: runStart,
        end: i,
        style: imeCompositionStyleForAttribute(runValue),
      ),
    );
    runStart = i;
    runValue = value;
  }
  return clauses;
}

/// The `lParam` to forward `WM_IME_SETCONTEXT` on with.
///
/// One bit cleared, and it is the bit that decides whether the preedit is drawn
/// once or twice: `ISC_SHOWUICOMPOSITIONWINDOW` is `DefWindowProcW`'s
/// instruction to create the IME's own composition window, and this framework
/// lays the provisional text out in the document instead.
///
/// `ISC_SHOWUICANDIDATEWINDOW` is deliberately **left set**. The candidate list
/// is a whole popup with its own paging and per-IME conventions, and no
/// framework that has drawn it itself has matched what users expect from their
/// own input method; all this backend does is say where it opens.
///
/// A pure function so the rule is a test rather than an unobservable side
/// effect of a call into user32.
int imeSetContextLParam(int lParam) => lParam & ~iscShowUiCompositionWindow;

/// The framework style for one `ATTR_*` byte.
ImeCompositionStyle imeCompositionStyleForAttribute(int attribute) {
  switch (attribute) {
    case imeAttrTargetConverted:
      return ImeCompositionStyle.targetConverted;
    case imeAttrConverted:
      return ImeCompositionStyle.converted;
    case imeAttrTargetNotconverted:
      return ImeCompositionStyle.targetNotConverted;
    case imeAttrInputError:
      return ImeCompositionStyle.error;
    case imeAttrFixedconverted:
      return ImeCompositionStyle.fixedConverted;
    case imeAttrInput:
    default:
      return ImeCompositionStyle.input;
  }
}

/// Builds the composition a `WM_IME_COMPOSITION` describes, from parts that
/// have already been read out of the input context.
///
/// Separate from the reading so that the arithmetic - clause runs, a cursor
/// clamped into the string, a cursor Windows reported past the end - is
/// testable on a machine with no Japanese IME installed and no human typing.
/// See `win32_ime_test.dart`, which is where the cases that need a real IME are
/// listed as untestable.
ImeComposition buildComposition({
  required String text,
  required List<int> attributes,
  required int cursorPosition,
}) {
  if (text.isEmpty) return ImeComposition.none;
  // Windows reports the caret in code units, always inside the string. A
  // *negative* value is `IMM_ERROR_NODATA` or `IMM_ERROR_GENERAL` and never a
  // request to hide the caret - IMM32 has no such request, and reading -1 as
  // one the way Wayland spells it would silently remove the caret on every
  // failed read. So it clamps to the end of the preedit, which is where every
  // input method puts the caret by default.
  //
  // Attribute bytes past the end of the string are dropped rather than trusted:
  // an edit that raced the message leaves the context describing the previous,
  // longer string, and a clause that ran past the end would ask the paragraph
  // for boxes it has no glyphs for.
  final int caret =
      cursorPosition < 0 ? text.length : cursorPosition.clamp(0, text.length);
  return ImeComposition(
    text: text,
    clauses: decodeCompositionAttributes(
      attributes.length > text.length
          ? attributes.sublist(0, text.length)
          : attributes,
    ),
    cursorStart: caret,
    cursorEnd: caret,
  );
}

// ---------------------------------------------------------------------------
// The backend
// ---------------------------------------------------------------------------

/// IMM32 behind the framework's [TextInputBackend] contract.
///
/// Built once per backend and handed out by `Win32WindowingBackend.textInput`;
/// it owns the imm32 binding and nothing per-window, so attaching a second
/// window costs one object.
final class Win32TextInputBackend implements TextInputBackend {
  Win32TextInputBackend._(this._api, this._imm);

  /// Loads imm32 and reports what it found.
  ///
  /// Never throws: a machine without the library gets an
  /// [UnavailableTextInput] naming it, exactly as a machine without ole32 gets
  /// an `UnavailableDragDrop`.
  static ({TextInputBackend backend, List<BackendDiagnostic> diagnostics})
      create(Win32Api api) {
    final Imm32LoadResult loaded = Imm32Api.load();
    final Imm32Api? imm = loaded.api;
    if (imm == null) {
      return (
        backend: const UnavailableTextInput(
          name: 'imm32',
          reason: 'imm32.dll could not be loaded or is missing a required '
              'symbol, so no composition is possible; plain typing still '
              'works, because it comes from WM_CHAR and not from the IME',
        ),
        diagnostics: loaded.diagnostics,
      );
    }
    return (
      backend: Win32TextInputBackend._(api, imm),
      diagnostics: loaded.diagnostics,
    );
  }

  final Win32Api _api;
  final Imm32Api _imm;

  @override
  String get name => 'imm32';

  @override
  bool get supportsComposition => true;

  /// False, and it is a real gap rather than an oversight.
  ///
  /// IMM32 does not accept pushed context: an input method *asks* for it, with
  /// `WM_IME_REQUEST` / `IMR_DOCUMENTFEED`, and this backend does not answer
  /// that message yet. Reporting true and dropping what it was given would make
  /// a Japanese method's worse conversions look like a framework mystery
  /// instead of a named missing feature.
  @override
  bool get usesSurroundingText => false;

  @override
  TextInputConnection attach({
    required NativeWindow window,
    required TextInputClient client,
  }) {
    if (window is! Win32Window) {
      throw TextInputException(
        operation: 'attach',
        reason: 'the imm32 input method needs a Win32Window; it was given a '
            '${window.runtimeType}',
        backend: name,
      );
    }
    if (window.handle == 0) {
      throw const TextInputException(
        operation: 'attach',
        reason: 'the window has no HWND yet, or has already been destroyed',
        backend: 'imm32',
      );
    }
    final connection = Win32TextInputConnection._(
      api: _api,
      imm: _imm,
      window: window,
      client: client,
    );
    window.imeHandler = connection;
    return connection;
  }
}

/// One window's input context, wired to one focused client.
///
/// Implements [Win32ImeMessageHandler] as well as [TextInputConnection]: the
/// window routes `WM_IME_*` here, and the framework drives enable/disable and
/// caret updates from the other side. Both halves are the same state machine,
/// which is why they are the same object - splitting them would mean two places
/// that each believe they know whether a composition is in progress.
final class Win32TextInputConnection
    implements TextInputConnection, Win32ImeMessageHandler {
  Win32TextInputConnection._({
    required Win32Api api,
    required Imm32Api imm,
    required Win32Window window,
    required TextInputClient client,
  })  : _api = api,
        _imm = imm,
        _window = window,
        _client = client;

  final Win32Api _api;
  final Imm32Api _imm;
  final Win32Window _window;
  final TextInputClient _client;

  bool _attached = true;
  bool _enabled = false;
  bool _composing = false;

  /// What was last handed to `ImmSetCompositionWindow`, in physical client
  /// pixels, so an unchanged caret costs no syscall. A caret update runs on
  /// every keystroke.
  int _lastCaretX = -1;
  int _lastCaretY = -1;
  int _lastCaretBottom = -1;

  /// Why the last operation did not happen, or null. Read by the backend's
  /// diagnostics rather than thrown, because everything here runs inside a
  /// message handler where throwing means losing the message.
  TextInputException? lastError;

  @override
  NativeWindowId get windowId => _window.id;

  @override
  bool get isAttached => _attached;

  @override
  bool get isEnabled => _enabled;

  /// Whether a preedit is in progress right now. Diagnostics and tests.
  bool get isComposing => _composing;

  @override
  void enable() {
    if (!_attached) return;
    // Re-read the configuration on every enable: a field that turned read-only
    // or obscured between two focus changes must stop being composed into, and
    // re-attaching to express that would be a second way to say the same
    // thing.
    final bool sensitive = _client.textInputConfiguration.isSensitive;
    _associateContext(enabled: !sensitive);
    _enabled = !sensitive;
    if (_enabled) updateEditingState();
  }

  @override
  void disable() {
    if (!_attached) return;
    // Cancel rather than complete: the preedit was provisional and the user
    // moved somewhere else. Completing it would insert characters nobody
    // accepted, which is what a `CPS_COMPLETE` here would do.
    cancelComposition();
    _associateContext(enabled: false);
    _enabled = false;
  }

  /// `ImmAssociateContextEx`, the only IMM32 switch for "compose here or do
  /// not".
  ///
  /// A password field is the case that matters: an input method left associated
  /// with one shows a candidate window full of the user's password, and on some
  /// methods writes it to a user dictionary. Windows' own `ES_PASSWORD` edit
  /// control detaches the context for the same reason.
  void _associateContext({required bool enabled}) {
    final int hwnd = _window.handle;
    if (hwnd == 0) return;
    final int result = _imm.immAssociateContextEx(
      hwnd,
      0,
      enabled ? iaceDefault : iaceIgnorenocontext,
    );
    if (result == 0) {
      lastError = TextInputException(
        operation: 'ImmAssociateContextEx',
        reason: 'the window refused to ${enabled ? 'take' : 'drop'} its '
            'default input context (GetLastError ${_api.getLastError()})',
        backend: 'imm32',
      );
    }
  }

  @override
  void updateEditingState() {
    if (!_attached || !_enabled) return;
    // `surroundingText` is deliberately not read: see
    // `Win32TextInputBackend.usesSurroundingText`. Reading it and dropping it
    // would cost a document scan per keystroke for nothing.
    _positionCandidateWindow(_client.caretRect);
  }

  /// Puts the composition and candidate windows at the caret.
  ///
  /// Both are set, and they are not the same thing:
  ///
  ///   * `ImmSetCompositionWindow` moves where the *IME* would draw a preedit.
  ///     This framework draws its own, so the only effect is on methods that
  ///     show an extra floating hint - and a form left at the origin puts that
  ///     hint in the window's top-left corner, which is the classic "why is the
  ///     IME tooltip in the wrong place" bug.
  ///   * `ImmSetCandidateWindow` moves the candidate list, which the platform
  ///     really does draw. `CFS_EXCLUDE` with the caret's own rectangle is what
  ///     keeps the list from opening on top of the text being composed;
  ///     `CFS_CANDIDATEPOS` alone routinely does.
  void _positionCandidateWindow(Rect caretRect) {
    final int hwnd = _window.handle;
    if (hwnd == 0) return;
    final double scale = _window.renderScale;
    final int x = (caretRect.left * scale).round();
    final int y = (caretRect.top * scale).round();
    final int bottom = (caretRect.bottom * scale).round();
    if (x == _lastCaretX && y == _lastCaretY && bottom == _lastCaretBottom) {
      return;
    }
    final int himc = _imm.immGetContext(hwnd);
    if (himc == 0) return;
    try {
      final right = (caretRect.right * scale).round();
      final composition = _api.allocator<CompositionForm>();
      final candidate = _api.allocator<CandidateForm>();
      try {
        composition.ref
          ..dwStyle = cfsPoint
          ..ptCurrentPos.x = x
          ..ptCurrentPos.y = y;
        _imm.immSetCompositionWindow(himc, composition);
        candidate.ref
          ..dwIndex = 0
          ..dwStyle = cfsExclude
          ..ptCurrentPos.x = x
          ..ptCurrentPos.y = y
          ..rcArea.left = x
          ..rcArea.top = y
          ..rcArea.right = right > x ? right : x + 1
          ..rcArea.bottom = bottom > y ? bottom : y + 1;
        _imm.immSetCandidateWindow(himc, candidate);
      } finally {
        _api.allocator
          ..free(composition)
          ..free(candidate);
      }
      _lastCaretX = x;
      _lastCaretY = y;
      _lastCaretBottom = bottom;
    } finally {
      _imm.immReleaseContext(hwnd, himc);
    }
  }

  @override
  void cancelComposition() {
    if (!_attached) return;
    final int hwnd = _window.handle;
    if (hwnd == 0) return;
    final int himc = _imm.immGetContext(hwnd);
    if (himc == 0) return;
    try {
      // CPS_CANCEL, not CPS_COMPLETE: the difference is whether the
      // provisional characters end up in the document. Escape means they must
      // not.
      _imm.immNotifyIME(himc, niCompositionstr, cpsCancel, 0);
    } finally {
      _imm.immReleaseContext(hwnd, himc);
    }
    if (_composing) {
      _composing = false;
      _guard('cancelComposition', () {
        _client.updateComposition(ImeComposition.none);
      });
    }
  }

  @override
  void detach() {
    if (!_attached) return;
    cancelComposition();
    // Restore the default association before letting go, or a field that took
    // focus and then vanished leaves the window unable to compose at all.
    _associateContext(enabled: true);
    _attached = false;
    _enabled = false;
    if (identical(_window.imeHandler, this)) _window.imeHandler = null;
  }

  // -------------------------------------------------------------------------
  // The WndProc half
  // -------------------------------------------------------------------------

  @override
  int? handleImeMessage(int hwnd, int msg, int wParam, int lParam) {
    if (!_attached) return null;
    switch (msg) {
      case wmImeSetcontext:
        // Forwarded, not swallowed: this message is also what associates the
        // context with the window, and a window that answers 0 to it loses the
        // input method entirely. Only the UI bits are edited - the composition
        // window is ours to draw, the candidate list is the platform's.
        return _api.defWindowProcW(
          hwnd,
          msg,
          wParam,
          imeSetContextLParam(lParam),
        );

      case wmImeStartcomposition:
        _composing = true;
        // The candidate list is positioned *now*, before the first
        // WM_IME_COMPOSITION, because a method that opens its list on the very
        // first keystroke reads the form at start time. Doing it only on
        // composition updates puts the first list in the corner.
        _positionCandidateWindow(_client.caretRect);
        // Swallowed: see the library comment. Answering 0 is what tells
        // DefWindowProcW not to create its own composition window.
        return 0;

      case wmImeComposition:
        _onComposition(hwnd, lParam);
        return 0;

      case wmImeEndcomposition:
        if (_composing) {
          _composing = false;
          _guard('WM_IME_ENDCOMPOSITION', () {
            _client.updateComposition(ImeComposition.none);
          });
        }
        return 0;

      default:
        // WM_IME_NOTIFY, WM_IME_CHAR, WM_IME_REQUEST: the platform's, named in
        // `win32_constants.dart` with the reason each is left alone.
        return null;
    }
  }

  /// Reads everything `WM_IME_COMPOSITION` grants access to, in one pass.
  ///
  /// Order matters and is the protocol's, not a preference: `GCS_RESULTSTR`
  /// first, because the result string is the *previous* composition being
  /// accepted, and `GCS_COMPSTR` second, because a method that commits one
  /// clause and keeps composing the rest sets both bits in the same message.
  /// Applying them the other way round would drop the new preedit.
  void _onComposition(int hwnd, int lParam) {
    final int himc = _imm.immGetContext(hwnd);
    if (himc == 0) {
      lastError = const TextInputException(
        operation: 'ImmGetContext',
        reason: 'the window has no input context while composing; something '
            'detached it between WM_IME_STARTCOMPOSITION and this message',
        backend: 'imm32',
      );
      return;
    }
    try {
      if ((lParam & gcsResultstr) != 0) {
        final String? result = _readString(himc, gcsResultstr);
        if (result != null && result.isNotEmpty) {
          _composing = false;
          _guard('GCS_RESULTSTR', () => _client.commitText(result));
        }
      }
      if ((lParam & gcsCompstr) != 0) {
        final String text = _readString(himc, gcsCompstr) ?? '';
        if (text.isEmpty) {
          if (_composing) {
            _composing = false;
            _guard('GCS_COMPSTR', () {
              _client.updateComposition(ImeComposition.none);
            });
          }
          return;
        }
        final List<int> attributes =
            (lParam & gcsCompattr) != 0 ? _readAttributes(himc) : const <int>[];
        final int cursor = _imm.immGetCompositionStringW(
          himc,
          gcsCursorpos,
          nullptr,
          0,
        );
        _composing = true;
        final ImeComposition composition = buildComposition(
          text: text,
          attributes: attributes,
          cursorPosition: cursor,
        );
        _guard('GCS_COMPSTR', () => _client.updateComposition(composition));
        _positionCandidateWindow(_client.caretRect);
      }
    } finally {
      _imm.immReleaseContext(hwnd, himc);
    }
  }

  /// One `GCS_*` string, or null when the context has none.
  ///
  /// Two calls: the first with a null buffer asks how many **bytes** are
  /// needed, the second fills them. The count is bytes and the units are
  /// UTF-16, so the division by two is not a rounding convenience - a caller
  /// that treats the answer as a character count reads half a string.
  String? _readString(int himc, int index) {
    final int bytes = _imm.immGetCompositionStringW(himc, index, nullptr, 0);
    if (bytes <= 0) return bytes == 0 ? '' : null;
    final int units = bytes ~/ 2;
    final Pointer<Uint16> buffer = _api.allocator<Uint16>(units + 1);
    try {
      final int written = _imm.immGetCompositionStringW(
        himc,
        index,
        buffer.cast<Void>(),
        bytes,
      );
      if (written <= 0) return null;
      return String.fromCharCodes(buffer.asTypedList(written ~/ 2));
    } finally {
      _api.allocator.free(buffer);
    }
  }

  /// `GCS_COMPATTR`: one byte per code unit of the composition string.
  List<int> _readAttributes(int himc) {
    final int bytes =
        _imm.immGetCompositionStringW(himc, gcsCompattr, nullptr, 0);
    if (bytes <= 0) return const <int>[];
    final Pointer<Uint8> buffer = _api.allocator<Uint8>(bytes);
    try {
      final int written = _imm.immGetCompositionStringW(
        himc,
        gcsCompattr,
        buffer.cast<Void>(),
        bytes,
      );
      if (written <= 0) return const <int>[];
      return List<int>.from(buffer.asTypedList(written));
    } finally {
      _api.allocator.free(buffer);
    }
  }

  /// Runs a client callback where an exception must not escape.
  ///
  /// The shared WndProc already catches at the top and answers
  /// `DefWindowProcW`, but for the IME messages that fallback is *wrong*, not
  /// merely different: it would let Windows draw the composition window this
  /// backend spent `WM_IME_SETCONTEXT` switching off. So the failure is
  /// recorded here and the message is still answered correctly.
  void _guard(String operation, void Function() body) {
    try {
      body();
    } on Object catch (error) {
      lastError = TextInputException(
        operation: operation,
        reason: 'the focused text client threw while being told about the '
            'composition: $error',
        backend: 'imm32',
      );
    }
  }
}
