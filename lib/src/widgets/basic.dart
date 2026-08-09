library;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import '../rendering/render_object.dart';
import 'element.dart';
import 'widget.dart';

/// A widget that paints a solid color.
class ColoredBox extends RenderObjectWidget {
  const ColoredBox({
    super.key,
    required this.color,
    this.child,
  });

  final int color;
  final Widget? child;

  @override
  RenderObjectElement createElement() => ColoredBoxElement(this);

  @override
  RenderColoredBox createRenderObject(BuildContext context) {
    return RenderColoredBox(color: color);
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderColoredBox renderObject) {
    renderObject.color = color;
  }
}

class ColoredBoxElement extends RenderObjectElement {
  ColoredBoxElement(ColoredBox super.widget);

  @override
  ColoredBox get widget => super.widget as ColoredBox;

  Element? _child;

  @override
  void mount(Element? parent) {
    super.mount(parent);
    _child = updateChild(_child, widget.child);
  }

  @override
  void update(ColoredBox newWidget) {
    super.update(newWidget);
    _child = updateChild(_child, widget.child);
  }
}

class RenderColoredBox extends RenderObject {
  RenderColoredBox({required this.color});

  int color;

  @override
  void layout(Size constraints) {
    // Very naive layout for slice
  }

  @override
  void paint(Offset offset) {
    // Will paint to surface in a real implementation
  }
}

/// A widget that detects gestures.
class GestureDetector extends StatelessWidget {
  const GestureDetector({
    super.key,
    this.onTap,
    this.child,
  });

  final void Function()? onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // For now, this is just a passthrough. The hit testing will be added later.
    return child ?? const ColoredBox(color: 0x00000000);
  }
}

/// A widget that displays text.
class Text extends RenderObjectWidget {
  const Text(this.text, {super.key});

  final String text;

  @override
  RenderObjectElement createElement() => TextElement(this);

  @override
  RenderText createRenderObject(BuildContext context) {
    return RenderText(text: text);
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderText renderObject) {
    renderObject.text = text;
  }
}

class TextElement extends RenderObjectElement {
  TextElement(Text super.widget);

  @override
  Text get widget => super.widget as Text;
}

class RenderText extends RenderObject {
  RenderText({required this.text});

  String text;

  @override
  void layout(Size constraints) {
    // Measure text
  }

  @override
  void paint(Offset offset) {
    // Draw text using GDI or skia
  }
}
