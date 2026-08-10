library;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/alignment.dart';
import '../layout/edge_insets.dart';
import '../layout/render_align.dart' as layout;
import '../layout/render_box.dart';
import '../layout/render_colored_box.dart' as layout;
import '../layout/render_padding.dart' as layout;
import '../platform/input_events.dart';
import 'element.dart';
import 'pointer_router.dart';
import 'widget.dart';

/// Positions a smaller child within the space offered by its parent.
final class Align extends SingleChildRenderObjectWidget {
  const Align({
    super.key,
    this.alignment = Alignment.center,
    this.widthFactor,
    this.heightFactor,
    super.child,
  });

  final Alignment alignment;
  final double? widthFactor;
  final double? heightFactor;

  @override
  layout.RenderAlign createRenderObject(BuildContext context) =>
      layout.RenderAlign(
        alignment: alignment,
        widthFactor: widthFactor,
        heightFactor: heightFactor,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderAlign renderObject,
  ) {
    renderObject
      ..alignment = alignment
      ..widthFactor = widthFactor
      ..heightFactor = heightFactor;
  }
}

/// A single-child widget backed by the production layout/render tree.
final class ColoredBox extends SingleChildRenderObjectWidget {
  const ColoredBox({
    super.key,
    required this.color,
    super.child,
  });

  final int color;

  @override
  layout.RenderColoredBox createRenderObject(BuildContext context) =>
      layout.RenderColoredBox(color: color);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderColoredBox renderObject,
  ) {
    renderObject.color = color;
  }
}

/// Insets one child using the production layout implementation.
final class Padding extends SingleChildRenderObjectWidget {
  const Padding({
    super.key,
    required this.padding,
    super.child,
  });

  final EdgeInsets padding;

  @override
  layout.RenderPadding createRenderObject(BuildContext context) =>
      layout.RenderPadding(padding: padding);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant layout.RenderPadding renderObject,
  ) {
    renderObject.padding = padding;
  }
}

/// Recognizes a primary-button tap inside its child's hit-test region.
final class GestureDetector extends SingleChildRenderObjectWidget {
  const GestureDetector({super.key, this.onTap, required super.child});

  final void Function()? onTap;

  @override
  RenderTapGestureDetector createRenderObject(BuildContext context) =>
      RenderTapGestureDetector(onTap: onTap);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderTapGestureDetector renderObject,
  ) {
    renderObject.onTap = onTap;
  }
}

/// Render-tree endpoint for [GestureDetector].
///
/// Hit testing remains delegated to the child, so a detector around a
/// transparent, non-hittable subtree does not invent an interactive region.
final class RenderTapGestureDetector extends RenderSingleChildBox
    implements PointerEventTarget {
  RenderTapGestureDetector({void Function()? onTap}) : _onTap = onTap;

  void Function()? _onTap;
  int? _primaryPointer;

  void Function()? get onTap => _onTap;

  set onTap(void Function()? value) {
    _onTap = value;
    if (value == null) _primaryPointer = null;
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  void handlePointerEvent(PointerEvent event) {
    if (_onTap == null) return;
    switch (event) {
      case PointerDownEvent(button: PointerButton.primary):
        _primaryPointer = event.pointerId;
      case PointerUpEvent(button: PointerButton.primary):
        if (_primaryPointer != event.pointerId) return;
        _primaryPointer = null;
        _onTap?.call();
      case PointerCancelEvent():
        if (_primaryPointer == event.pointerId) _primaryPointer = null;
      case PointerMoveEvent():
      case PointerScrollEvent():
      case PointerDownEvent():
      case PointerUpEvent():
    }
  }
}

/// Text configuration. Shaping and glyph painting remain a renderer concern.
final class Text extends RenderObjectWidget {
  const Text(this.text, {super.key});

  final String text;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderText createRenderObject(BuildContext context) => RenderText(text);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderText renderObject,
  ) {
    renderObject.text = text;
  }
}

/// A layout-correct text leaf pending the canonical shaping implementation.
///
/// It reports zero intrinsic content rather than inventing font metrics. This
/// keeps layout deterministic, while [paint] refuses the missing capability
/// explicitly instead of producing a successful frame with invisible text.
final class RenderText extends RenderBox {
  RenderText(String text) : _text = text;

  String _text;

  String get text => _text;

  set text(String value) {
    if (value == _text) return;
    _text = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    size = constraints.constrain(Size.zero);
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    throw UnsupportedError(
      'Text painting requires shaping, font fallback, and a glyph atlas.',
    );
  }
}

/// Compatibility name; the implementation is the layout layer's real node.
typedef RenderColoredBox = layout.RenderColoredBox;
