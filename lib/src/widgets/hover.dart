/// Hover, as a widget: a region that says when the pointer enters and
/// leaves it, for the custom rows, tiles and tabs that are not a framework
/// control but must still light up under the mouse.
library;

import '../geometry/offset.dart';
import '../layout/render_proxy_box.dart';
import 'element.dart';
import 'pointer_router.dart';
import 'widget.dart';

/// Reports the pointer entering and leaving [child], never claiming it: the
/// controls inside receive exactly what they would without the region.
final class HoverRegion extends SingleChildRenderObjectWidget {
  const HoverRegion({
    super.key,
    required this.onHoverChanged,
    super.child,
  });

  final void Function(bool hovered) onHoverChanged;

  @override
  RenderHoverRegion createRenderObject(BuildContext context) =>
      RenderHoverRegion(onHoverChanged: onHoverChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderHoverRegion renderObject,
  ) {
    renderObject.onHoverChanged = onHoverChanged;
  }
}

/// The render node behind [HoverRegion]. It is in the hit path over its
/// whole box - so a gap between a tile's icon and its label still counts -
/// and the router diffs that path on every move, calling
/// [handleHoverChanged] on what the pointer entered and left.
final class RenderHoverRegion extends RenderProxyBox
    implements HoverEventTarget {
  RenderHoverRegion({required this.onHoverChanged});

  void Function(bool hovered) onHoverChanged;

  bool _hovered = false;

  /// Whether the pointer is over the region now.
  bool get isHovered => _hovered;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleHoverChanged(bool hovered) {
    if (hovered == _hovered) return;
    _hovered = hovered;
    onHoverChanged(hovered);
  }
}

/// Builds [builder] again whenever the pointer enters or leaves it - the
/// usual way to draw a hover state on something that is not a control.
final class HoverBuilder extends StatefulWidget {
  const HoverBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

final class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => HoverRegion(
        onHoverChanged: (bool hovered) {
          if (mounted && hovered != _hovered) {
            setState(() => _hovered = hovered);
          }
        },
        child: widget.builder(context, _hovered),
      );
}
