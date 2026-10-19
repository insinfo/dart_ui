/// Shared caption geometry for Linux windows with an integrated title strip.
library;

import '../foundation/value_notifier.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import 'native_window.dart';

mixin ClientTitleBarMixin implements ClientCaptionWindow {
  Size get clientSize;
  WindowState get state;
  bool requestState(WindowState state);

  Rect get _captionBounds =>
      !isTitleBarHidden || state == WindowState.fullscreen
          ? Rect.zero
          : Rect.fromLTWH(
              (clientSize.width - 138).clamp(0.0, double.infinity), 0, 138, 40);

  @override
  late final ValueNotifier<Rect> systemButtons = ValueNotifier(_captionBounds);
  @override
  late final ValueNotifier<WindowState> captionState = ValueNotifier(state);
  @override
  double get titleBarHeight => 40;
  @override
  bool get canMinimize => true;
  @override
  void minimize() => requestState(WindowState.minimised);
  @override
  void toggleMaximized() => requestState(state == WindowState.maximised
      ? WindowState.normal
      : WindowState.maximised);

  /// Called after native configure/state changes, before notifying widgets.
  void updateClientTitleBar() {
    systemButtons.value = _captionBounds;
    captionState.value = state;
  }

  void disposeClientTitleBar() {
    systemButtons.dispose();
    captionState.dispose();
  }
}
