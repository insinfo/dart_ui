/// Input methods and dead keys, as a port the core can name and no backend
/// owns.
///
/// `Capability.textComposition` has been in [Capability] since the first
/// commit with nothing behind it, and `text_editing.dart` has carried a
/// `TextEditingValue.composing` range with a paragraph of prose describing the
/// bridge that was supposed to fill it. This file is that bridge's contract.
///
/// Without it the framework cannot type Chinese, Japanese or Korean at all, and
/// cannot type `á` on any layout where the accent is a dead key - which is most
/// of Europe and all of Brazil. That is not a missing nicety; it is the
/// framework being unusable in the language its own repository is written in.
///
/// ## The three protocols, and where they actually disagree
///
/// The same table `drag_drop.dart` opens with, for the same reason: every
/// compromise below is a consequence of one of these rows.
///
/// |                        | Win32 (IMM32)                          | Wayland (`zwp_text_input_v3`)          | X11 (XIM)                          |
/// |------------------------|----------------------------------------|----------------------------------------|------------------------------------|
/// | who drives             | the **application**, by pulling        | the **input method**, by pushing       | a separate **IM server** process   |
/// | preedit arrives as     | a *notification* (`WM_IME_COMPOSITION`) that something changed; the text is then **read** with `ImmGetCompositionStringW` | `preedit_string` events, already carrying the text | `XIM_PREEDIT_DRAW` over an ICE-like protocol |
/// | when it may be read    | **only inside the WndProc**, before returning | any time; it is already in hand   | in the callback                    |
/// | clause styling         | one attribute byte per code unit (`GCS_COMPATTR`) | **none at all** - v3 dropped v2's styling | per-draw feedback array   |
/// | surrounding text       | *pulled* by the OS (`WM_IME_REQUEST`)  | *pushed* by the client (`set_surrounding_text`) | pulled by callback        |
/// | deleting around caret  | not expressible                        | `delete_surrounding_text`, mandatory   | not expressible                    |
/// | state changes          | take effect on the call                | are staged and take effect on `commit`, which must echo the serial of the last `done` | round trip |
/// | candidate window       | positioned by the app (`ImmSetCandidateWindow`) | positioned by the compositor from `set_cursor_rectangle` | positioned by the app     |
///
/// Four consequences run through the whole design:
///
///  1. **Reading is synchronous on Win32 and impossible to make so anywhere
///     else.** `ImmGetCompositionStringW` is only valid while the
///     `WM_IME_COMPOSITION` that announced it is being handled: return from the
///     WndProc and the string is gone. So the Win32 bridge reads *inside* the
///     message handler and calls [TextInputClient.updateComposition] with a
///     finished [ImeComposition] - it satisfies the push contract rather than
///     being shaped by the pull one. Nothing after an `await` in a client
///     callback can run before that handler must return, exactly as
///     `LiveResizeWindow` and the OLE drop path already document, so **no
///     method on [TextInputClient] returns a `Future`**.
///  2. **State is transactional on Wayland and immediate everywhere else.**
///     `set_surrounding_text`, `set_content_type` and `set_cursor_rectangle`
///     do nothing until `commit`, and that `commit` carries a count that must
///     match the number of `done` events received - get it wrong and the
///     compositor silently applies the update to a state the client no longer
///     has. That bookkeeping is [TextInputConnection.updateEditingState]'s
///     job and never the caller's; see `wayland_text_input.dart` for the
///     serial rule spelled out.
///  3. **Surrounding text is pushed, not asked for.** Win32 has no place to
///     push it (the OS asks, through `WM_IME_REQUEST`/`IMR_DOCUMENTFEED`,
///     which this backend does not answer yet), so its bridge ignores what it
///     is given. That is a real capability gap and it is
///     [TextInputBackend.usesSurroundingText] rather than a silent no-op.
///  4. **Deleting around the caret only exists on Wayland**, and it is not
///     optional there: an input method that asks for it and is ignored leaves
///     duplicated characters in the document. So it is on the client contract
///     even though two of three platforms never call it.
///
/// ## What a backend that cannot do this returns
///
/// [UnavailableTextInput], carrying the reason - never null and never a silent
/// no-op. A headless run, the web backend and (see `x11_compose.dart` for the
/// evidence) the X11 backend all take that path, so a field mounted on them
/// keeps working exactly as it does today: the platform's own keyboard
/// translation still produces [TextInputEvent]s, and only *composition* is
/// absent.
///
/// ## What is deliberately not in this contract
///
///  * **Reconversion** (`IMR_RECONVERTSTRING`, selecting committed text and
///    asking the IME to convert it again). Win32 has it, Wayland has nothing
///    like it, and a port with one implementation is not a port.
///  * **Drawing the candidate window ourselves.** Every platform draws its own;
///    all this contract does is say *where*, through
///    [TextInputClient.caretRect].
///  * **A composition the framework starts.** Composition begins because the
///    user pressed a key the input method claimed. There is no "start
///    composing" call on any of the three, and inventing one would mean
///    modelling a state the platform does not have.
library;

import '../geometry/rect.dart';
import '../platform/native_window.dart';
import '../platform/window_events.dart';
import 'text_input_types.dart';

export 'text_input_types.dart';

/// The editor an input method is composing into.
///
/// One client per focused field. The framework's own implementation is
/// `RenderTextField`, which turns these calls into
/// [TextEditingController.replaceComposingRegion] and its siblings; an
/// application that wants the raw stream may implement this directly and attach
/// it to the backend.
///
/// **No method here may await and none may be expensive.** They run inside the
/// platform's own message handling - literally inside a `WndProc` on Win32 -
/// and [updateComposition] arrives at keystroke rate while a CJK method is
/// converting. The rule is `DropTargetHandler`'s and it survives into this port
/// unchanged.
abstract interface class TextInputClient {
  /// What kind of text this field holds.
  ///
  /// Read when the connection is enabled and whenever
  /// [TextInputConnection.updateEditingState] runs, so a field that becomes
  /// read-only or obscured stops being composed into without having to
  /// re-attach.
  TextInputConfiguration get textInputConfiguration;

  /// The text around the caret, **without** the preedit in it.
  ///
  /// See [ImeSurroundingText] for the three rules. A field whose configuration
  /// [TextInputConfiguration.isSensitive] returns [ImeSurroundingText.empty]
  /// here, and must: handing a password to an input-method process is the same
  /// leak as putting it on the clipboard.
  ImeSurroundingText get surroundingText;

  /// Where the caret is, in **this window's client coordinates**, logical
  /// units.
  ///
  /// Client coordinates rather than screen ones on purpose. Wayland's
  /// `set_cursor_rectangle` is surface-local and there is no way to learn a
  /// surface's position on the desktop, so a screen rectangle is not merely
  /// inconvenient there - it is not expressible. Win32's `CANDIDATEFORM` and
  /// `COMPOSITIONFORM` are client-relative too, so the conversion that would
  /// have to happen is *none* on both platforms that have one.
  ///
  /// The rectangle is the caret itself, not the field: the candidate window
  /// opens below it, and a whole-field rectangle would put the candidate list
  /// under the wrong line of a multi-line editor.
  Rect get caretRect;

  /// Replaces the preedit with [composition].
  ///
  /// [ImeComposition.none] ends the composition without committing anything -
  /// `WM_IME_ENDCOMPOSITION`, or a `preedit_string` with an empty string.
  void updateComposition(ImeComposition composition);

  /// Commits [text], replacing the preedit if there is one and the selection
  /// otherwise.
  ///
  /// `GCS_RESULTSTR` on Win32, `commit_string` on Wayland. The preedit is over
  /// afterwards; a method that wants to keep composing sends a new
  /// [updateComposition] in the same transaction, which is why the Wayland
  /// bridge applies its `done` events in the protocol's mandated order -
  /// delete, commit, preedit - and not in the order they happened to arrive.
  void commitText(String text);

  /// Deletes [beforeLength] UTF-16 units before the caret and [afterLength]
  /// after it, then places the caret where they met.
  ///
  /// `zwp_text_input_v3.delete_surrounding_text`, and the reason it is on this
  /// contract at all: a method that asks for it and is ignored ends up
  /// duplicating the characters it meant to replace. Neither Win32 nor XIM can
  /// ask for it, so on those platforms this is never called - which is a fact
  /// about them, not a licence to leave it unimplemented.
  ///
  /// Lengths are clamped by the implementation: a method that asks to delete
  /// more than exists deletes what exists, because refusing outright would
  /// leave the method's own idea of the document permanently ahead of the
  /// field's.
  void deleteSurroundingText({
    required int beforeLength,
    required int afterLength,
  });
}

/// A live association between one window's input method and one client.
///
/// Held by whoever attached it, and detached before the window is destroyed or
/// the client is disposed. On Win32 that ordering matters for the same reason
/// `RevokeDragDrop` does: an input context left associated with a dead `HWND`
/// keeps IMM32 holding a handle into this process.
abstract interface class TextInputConnection {
  NativeWindowId get windowId;

  /// Whether the platform still routes composition to this client.
  bool get isAttached;

  /// Whether composition is currently switched on for this client.
  bool get isEnabled;

  /// Turns the input method on for this client, with its current
  /// [TextInputClient.textInputConfiguration].
  ///
  /// Called when the field takes focus. Idempotent: a second call re-reads the
  /// configuration, which is how a field that turned read-only stops accepting
  /// composition.
  void enable();

  /// Turns the input method off and abandons any composition in progress.
  ///
  /// Called when the field loses focus. A composition that was in flight is
  /// **cancelled, not committed**: the characters were provisional and the user
  /// moved somewhere else, so committing them would insert text nobody
  /// accepted. Windows' own `EDIT` control does the same.
  void disable();

  /// Tells the platform that the caret, the selection or the document moved.
  ///
  /// Pulls [TextInputClient.caretRect] and [TextInputClient.surroundingText]
  /// and pushes whatever this platform can use. Cheap to call often and safe to
  /// call when nothing changed; implementations that talk over a socket
  /// compare against what they last sent rather than making the caller
  /// remember.
  void updateEditingState();

  /// Abandons the composition in progress without committing it.
  ///
  /// Escape inside a preedit. `ImmNotifyIME(NI_COMPOSITIONSTR,
  /// CPS_CANCEL)` on Win32; on Wayland there is no such request, so the bridge
  /// disables and re-enables, which is the documented way to reset the input
  /// method's state.
  void cancelComposition();

  /// Stops routing composition here. Idempotent: a window teardown and an
  /// explicit detach race by design.
  void detach();
}

/// Everything one platform can do with input methods.
///
/// A **separate** interface from `WindowingBackend` for the reason
/// [ClipboardProvider] and `DragDropProvider` are separate: that contract is
/// implemented by every backend *and by every test double in the suite*, and
/// adding a required member to it would break each one for a capability most of
/// them do not have.
abstract interface class TextInputBackend {
  /// Which implementation this is - `imm32`, `text-input-v3`. Appears in every
  /// [TextInputException] this backend raises.
  String get name;

  /// Whether this backend can deliver a preedit at all.
  ///
  /// False for [UnavailableTextInput] and for a platform where the protocol
  /// exists but the compositor did not advertise it. A caller uses it to decide
  /// whether to bother attaching, never to decide whether typing works: plain
  /// typing goes through `TextInputEvent` and is unaffected.
  bool get supportsComposition;

  /// Whether [TextInputConnection.updateEditingState] does anything with
  /// [TextInputClient.surroundingText].
  ///
  /// False on Win32, and stated rather than silently ignored: an input method
  /// there converts without document context, which is a real quality
  /// difference for Japanese and a thing a diagnostic should be able to say.
  bool get usesSurroundingText;

  /// Associates [client] with [window]'s input method.
  ///
  /// **Synchronous, unlike `DragDropBackend.registerDropTarget`**, and
  /// deliberately: a drop target is registered once per window, while this is
  /// attached and detached on every focus change - including the two that
  /// happen in one frame when focus moves between two fields. An asynchronous
  /// attach would let those two land in the wrong order and leave the input
  /// method pointed at the field the user just left. Neither IMM32 nor
  /// `zwp_text_input_v3` needs a round trip to do it, so the future would have
  /// bought nothing but the race.
  ///
  /// Throws [TextInputException] when the platform refused - never returns a
  /// connection that quietly does nothing.
  TextInputConnection attach({
    required NativeWindow window,
    required TextInputClient client,
  });
}

/// A windowing backend that can hand out the platform's input method.
///
/// The shape of [ClipboardProvider], and the same argument for why it is a
/// separate interface rather than a member on `WindowingBackend`.
abstract interface class TextInputProvider {
  /// The input method for this backend.
  ///
  /// Never null: a backend whose platform input method is unavailable returns
  /// an [UnavailableTextInput] carrying the reason, so the failure keeps its
  /// explanation instead of collapsing into "no input method was configured".
  TextInputBackend get textInput;
}

/// The input method of an application running where there is none.
///
/// Exists so that "this platform has no IME" is a named fact rather than a null
/// a caller has to test for, and so that a field never holds a
/// `TextInputBackend?`. [attach] throws; everything else answers honestly.
///
/// **Attaching throws rather than returning an inert connection.** An inert one
/// would make a field that silently never composes look identical to a field
/// whose backend works, which is the failure mode this whole file exists to
/// end. A caller that would rather not fail checks [supportsComposition] first,
/// which is what `RenderTextField` does.
final class UnavailableTextInput implements TextInputBackend {
  const UnavailableTextInput({required this.name, required this.reason});

  @override
  final String name;

  final String reason;

  @override
  bool get supportsComposition => false;

  @override
  bool get usesSurroundingText => false;

  @override
  TextInputConnection attach({
    required NativeWindow window,
    required TextInputClient client,
  }) =>
      throw TextInputException(
        operation: 'attach',
        reason: reason,
        backend: name,
      );

  @override
  String toString() => 'UnavailableTextInput($name: $reason)';
}
