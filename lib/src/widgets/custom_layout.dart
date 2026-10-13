/// [CustomMultiChildLayout] and [LayoutId]: children placed by an
/// application's [MultiChildLayoutDelegate]. See
/// `layout/render_custom_layout.dart`.
library;

import '../layout/render_custom_layout.dart';
import 'element.dart';
import 'widget.dart';

/// Lays [children] out with [delegate]; each child is a [LayoutId].
final class CustomMultiChildLayout extends MultiChildRenderObjectWidget {
  const CustomMultiChildLayout({
    super.key,
    required this.delegate,
    super.children,
  });

  final MultiChildLayoutDelegate delegate;

  @override
  RenderCustomMultiChildLayoutBox createRenderObject(BuildContext context) =>
      RenderCustomMultiChildLayoutBox(delegate: delegate);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderCustomMultiChildLayoutBox renderObject,
  ) =>
      renderObject.delegate = delegate;
}

/// Names a child of a [CustomMultiChildLayout] for its delegate.
final class LayoutId extends ParentDataWidget<MultiChildLayoutParentData> {
  const LayoutId({super.key, required this.id, required super.child});

  final Object id;

  @override
  Type get typicalAncestorWidget => CustomMultiChildLayout;

  @override
  bool applyParentData(MultiChildLayoutParentData parentData) {
    if (parentData.id == id) return false;
    parentData.id = id;
    return true;
  }
}
