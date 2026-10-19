/// The handle of a window whose title bar is hidden: the empty parts of
/// the strip the application drew there.
library;

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../layout/render_proxy_box.dart';
import '../layout/render_stack.dart' show StackFit;
import '../platform/input_events.dart';
import '../platform/native_window.dart';
import 'basic.dart';
import 'client_decoration.dart' show WindowCaptionControls;
import 'element.dart';
import 'pointer_router.dart';
import 'value_listenable_builder.dart';
import 'widget.dart';
import 'window_scope.dart';

/// Makes the empty parts of [child] move the window - a press and drag -
/// and zoom it - a double click - as a title bar would.
///
/// "Empty" is decided by hit testing: the handle lies behind [child], so a
/// tab, a button or a field in it takes its own clicks and only what is
/// left over reaches the handle. In a window that kept its title bar, or on
/// a platform that cannot hide it, this is just [child].
final class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final HiddenTitleBarWindow? window =
        WindowScope.of(context)?.hiddenTitleBar;
    if (window == null) return child;
    // Passthrough: the child is laid out exactly as it would be without
    // the handle, so a strip that fills its slot still fills it here.
    Widget area(Rect? bounds) => Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            Positioned.fill(child: _DragHandle(window: window)),
            child,
            if (window is ClientCaptionWindow &&
                bounds != null &&
                !bounds.isEmpty)
              Positioned(
                  left: bounds.left,
                  top: bounds.top,
                  width: bounds.width,
                  height: bounds.height,
                  child: WindowCaptionControls(window: window)),
          ],
        );
    if (window is ClientCaptionWindow) {
      return ValueListenableBuilder<Rect>(
          valueListenable: window.systemButtons,
          builder: (context, bounds, _) => area(bounds));
    }
    return area(null);
  }
}

final class _DragHandle extends SingleChildRenderObjectWidget {
  const _DragHandle({required this.window});

  final HiddenTitleBarWindow window;

  @override
  _RenderDragHandle createRenderObject(BuildContext context) =>
      _RenderDragHandle(window);

  @override
  void updateRenderObject(
          BuildContext context, covariant _RenderDragHandle renderObject) =>
      renderObject.window = window;
}

final class _RenderDragHandle extends RenderProxyBox
    implements PointerEventTarget {
  _RenderDragHandle(this.window);

  HiddenTitleBarWindow window;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    if (event.button == PointerButton.secondary &&
        window is ClientCaptionWindow) {
      (window as ClientCaptionWindow).showWindowMenu(event.logicalPosition);
      return;
    }
    if (event.button != PointerButton.primary) return;
    if (event.clickCount >= 2) {
      window.toggleMaximized();
    } else {
      window.beginMove();
    }
  }
}
