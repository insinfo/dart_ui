/// Gives part of the interface its own pointer shape.
library;

import '../geometry/offset.dart';
import '../layout/render_proxy_box.dart';
import '../platform/input_events.dart';
import '../platform/native_window.dart';
import 'element.dart';
import 'pointer_router.dart';
import 'widget.dart';

/// Shows [cursor] while the pointer is over [child], on every platform -
/// a hand over a link, an I-beam over text, a cross over a drawing area.
///
/// The innermost region under the pointer wins, so regions nest the way the
/// interface does. A render object that needs a cursor that depends on where
/// in it the pointer is - over a handle or not - implements
/// [MouseCursorTarget] itself instead.
final class MouseRegion extends SingleChildRenderObjectWidget {
  const MouseRegion({super.key, required this.cursor, super.child});

  final SystemCursor cursor;

  @override
  RenderMouseRegion createRenderObject(BuildContext context) =>
      RenderMouseRegion(cursor);

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderMouseRegion renderObject) {
    renderObject.cursor = cursor;
  }
}

/// The render object of [MouseRegion].
final class RenderMouseRegion extends RenderProxyBox
    implements MouseCursorTarget {
  RenderMouseRegion(this.cursor);

  SystemCursor cursor;

  /// In the hit path even over a child that is not hit-testable itself - an
  /// icon, a label - which is where a cursor is most often wanted.
  @override
  bool hitTestSelf(Offset position) => true;

  @override
  SystemCursor? cursorFor(PointerEvent event) => cursor;
}
