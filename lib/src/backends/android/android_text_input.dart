/// The Android input method, through the host activity.
///
/// The host's view is a text editor to Android (`onCheckIsTextEditor`), and
/// its `InputConnection` forwards what the keyboard commits. This side decides
/// when the keyboard is up: a focused field enables its connection, which
/// raises it; leaving the field lowers it. Composition stays in the keyboard
/// for now - the host reports committed text only, so a word appears when
/// the keyboard finishes it.
library;

import '../../platform/native_window.dart';
import '../../platform/text_input.dart';
import '../../platform/window_events.dart';
import 'android_window.dart';

final class AndroidTextInputBackend implements TextInputBackend {
  const AndroidTextInputBackend();

  @override
  String get name => 'android-ime';

  @override
  bool get supportsComposition => true;

  @override
  bool get usesSurroundingText => false;

  @override
  TextInputConnection attach({
    required NativeWindow window,
    required TextInputClient client,
  }) {
    if (window is! AndroidWindow) {
      throw TextInputException(
        operation: 'attach',
        reason: 'the Android input method needs the activity window; it was '
            'given a ${window.runtimeType}',
        backend: name,
      );
    }
    final AndroidTextInputConnection connection =
        AndroidTextInputConnection(window, client);
    window.textInput = connection;
    return connection;
  }
}

final class AndroidTextInputConnection
    implements TextInputConnection, AndroidImeHandler {
  AndroidTextInputConnection(this._window, this._client);

  final AndroidWindow _window;
  final TextInputClient _client;
  bool _attached = true;
  bool _enabled = false;

  @override
  NativeWindowId get windowId => _window.id;

  @override
  bool get isAttached => _attached;

  @override
  bool get isEnabled => _enabled;

  @override
  void enable() {
    if (!_attached) return;
    _enabled = true;
    _window.showKeyboard(show: true);
  }

  @override
  void disable() {
    if (!_attached || !_enabled) return;
    _enabled = false;
    _window.showKeyboard(show: false);
  }

  /// The host keeps no copy of the field, so there is nothing to update.
  @override
  void updateEditingState() {}

  @override
  void cancelComposition() {}

  @override
  void detach() {
    if (!_attached) return;
    disable();
    _attached = false;
    if (identical(_window.textInput, this)) _window.textInput = null;
  }

  @override
  void onCommit(String text) => _client.commitText(text);
}
