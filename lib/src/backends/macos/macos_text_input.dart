/// Input methods on macOS: the AppKit text input system, through the host.
///
/// The host's view is an `NSTextInputClient` and every key press goes through
/// `interpretKeyEvents:`, which is where the layout's dead keys and any input
/// method live. What the system is composing comes back as `COMPOSE` lines
/// (from `setMarkedText:`), and text that ends a composition as `COMMIT`
/// (from `insertText:`). This file routes both to the focused
/// [TextInputClient], and sends it the two things the system needs back: the
/// caret, so the candidate window opens beside the text rather than in a
/// corner, and a cancel, when Escape or a focus change abandons the preedit.
///
/// ## Typing does not depend on this
///
/// Text that is not part of a composition arrives as `TEXT_INPUT` and becomes
/// a `TextInputEvent`, attached client or not. And a `COMMIT` that arrives with
/// no enabled client - a dead key resolved while focus was elsewhere - is
/// turned into a `TextInputEvent` by the window rather than dropped.
///
/// ## Not used
///
/// Surrounding text: `attributedSubstringForProposedRange:` answers nil, so an
/// input method converts without document context, as on Win32.
/// [usesSurroundingText] says so.
library;

import 'dart:convert';

import '../../geometry/rect.dart';
import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import '../../platform/window_events.dart';
import 'host_protocol.dart';

/// What a window hands its host's composition messages to.
abstract interface class MacosImeHandler {
  /// Whether composition is routed to a client right now. When false, the
  /// window treats a `COMMIT` as typing.
  bool get isEnabled;

  /// A `COMPOSE` line, decoded. An empty [text] ends the preedit.
  void onComposition(String text, int selectedLocation, int selectedLength);

  /// A `COMMIT` line, decoded.
  void onCommit(String text);
}

/// The window side a connection needs: its id, a way to talk to its host, and
/// a slot for the handler. [MacosWindow] implements it; tests fake it.
abstract interface class MacosImeWindow {
  NativeWindowId get id;

  /// Sends one command line to the window's host. False when there is none.
  bool sendImeCommand(String command);

  MacosImeHandler? get imeHandler;
  set imeHandler(MacosImeHandler? handler);
}

/// [TextInputBackend] over the AppKit text input system.
final class MacosTextInputBackend implements TextInputBackend {
  const MacosTextInputBackend();

  @override
  String get name => 'nstextinputclient';

  @override
  bool get supportsComposition => true;

  @override
  bool get usesSurroundingText => false;

  @override
  TextInputConnection attach({
    required NativeWindow window,
    required TextInputClient client,
  }) {
    if (window is! MacosImeWindow) {
      throw TextInputException(
        operation: 'attach',
        reason: 'the AppKit text input system needs a macOS window; it was '
            'given a ${window.runtimeType}',
        backend: name,
      );
    }
    final connection =
        MacosTextInputConnection(window as MacosImeWindow, client);
    (window as MacosImeWindow).imeHandler = connection;
    return connection;
  }
}

/// One window's input method, wired to one focused client.
final class MacosTextInputConnection
    implements TextInputConnection, MacosImeHandler {
  MacosTextInputConnection(this._window, this._client);

  final MacosImeWindow _window;
  final TextInputClient _client;

  bool _attached = true;
  bool _enabled = false;
  bool _composing = false;
  Rect? _lastCaret;

  @override
  NativeWindowId get windowId => _window.id;

  @override
  bool get isAttached => _attached;

  @override
  bool get isEnabled => _enabled;

  bool get isComposing => _composing;

  @override
  void enable() {
    if (!_attached) return;
    // Re-read on every enable, as on Win32: a field that turned obscured
    // between two focus changes must stop being composed into. A password
    // field still gets its keys and the layout's dead keys - those arrive as
    // plain text - but never a preedit an input method could read.
    _enabled = !_client.textInputConfiguration.isSensitive;
    if (_enabled) updateEditingState();
  }

  @override
  void disable() {
    if (!_attached) return;
    // Cancelled, not committed: the preedit was provisional and the user
    // moved somewhere else.
    cancelComposition();
    _enabled = false;
  }

  @override
  void updateEditingState() {
    if (!_attached || !_enabled) return;
    final Rect caret = _client.caretRect;
    if (caret == _lastCaret) return;
    if (_window.sendImeCommand(HostCommands.imeCaret(
      caret.left,
      caret.top,
      caret.width < 1 ? 1 : caret.width,
      caret.height,
    ))) {
      _lastCaret = caret;
    }
  }

  @override
  void cancelComposition() {
    if (!_attached) return;
    _window.sendImeCommand(HostCommands.imeCancel());
    if (_composing) {
      _composing = false;
      _client.updateComposition(ImeComposition.none);
    }
  }

  @override
  void detach() {
    if (!_attached) return;
    _attached = false;
    _enabled = false;
    if (identical(_window.imeHandler, this)) _window.imeHandler = null;
  }

  @override
  void onComposition(String text, int selectedLocation, int selectedLength) {
    if (!_attached || !_enabled) return;
    if (text.isEmpty) {
      if (!_composing) return;
      _composing = false;
      _client.updateComposition(ImeComposition.none);
      return;
    }
    _composing = true;
    final int start = selectedLocation.clamp(0, text.length);
    final int end =
        (selectedLocation + selectedLength).clamp(start, text.length);
    _client.updateComposition(
      ImeComposition(text: text, cursorStart: start, cursorEnd: end),
    );
  }

  @override
  void onCommit(String text) {
    if (!_attached || !_enabled) return;
    _composing = false;
    _client.commitText(text);
  }
}

/// Decodes the base64 of a `COMPOSE` or `COMMIT` line, or null when it is not
/// base64 of UTF-8.
String? decodeImeText(String base64Text) {
  if (base64Text.isEmpty) return '';
  try {
    return utf8.decode(base64.decode(base64Text));
  } on FormatException {
    return null;
  }
}
