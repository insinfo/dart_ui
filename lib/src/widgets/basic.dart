library;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../graphics/display_list.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import '../layout/render_colored_box.dart' as layout;
import '../layout/render_padding.dart' as layout;
import 'element.dart';
import 'widget.dart';

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

/// A semantic placeholder for gesture routing.
///
/// Pointer routing is not part of the widget nucleus yet, so this deliberately
/// preserves its child without pretending that [onTap] is wired.
final class GestureDetector extends StatelessWidget {
  const GestureDetector({super.key, this.onTap, required this.child});

  final void Function()? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (onTap != null) {
      throw UnsupportedError(
        'GestureDetector.onTap requires pointer routing, which is not part of '
        'the widget nucleus yet.',
      );
    }
    return child;
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
