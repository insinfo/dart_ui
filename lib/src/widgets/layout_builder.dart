/// Widgets whose child comes out of a callback instead of a field.
///
/// Three of them, in ascending order of how much machinery they need:
/// [Builder] closes over a [BuildContext] that did not exist yet,
/// [StatefulBuilder] adds a `setState` without a class, and [LayoutBuilder]
/// defers the whole build until layout knows the constraints.
library;

import '../layout/box_constraints.dart';
import '../layout/render_box.dart';
import 'element.dart';
import 'errors.dart';
import 'widget.dart';

/// Builds a subtree with a context that sits *below* the caller's.
///
/// The one-line answer to "I need the `Theme` I just installed" and to "I need
/// a context under this `Navigator`": a [BuildContext] names a position in the
/// element tree, and a widget cannot hand itself a position below its own.
///
/// Identical to Flutter's, including that it is a [StatelessWidget] and so
/// costs one element.
final class Builder extends StatelessWidget {
  const Builder({super.key, required this.builder});

  final Widget Function(BuildContext context) builder;

  @override
  Widget build(BuildContext context) => builder(context);
}

/// A [State] without a class, for a fragment that owns one piece of state.
///
/// Identical to Flutter's, and carries Flutter's warning with it: the
/// `setState` handed to [builder] rebuilds *this* widget only. Mutating state
/// that lives in an enclosing `State` from here updates the enclosing object
/// and redraws nothing else, which reads as a widget that ignores half its
/// input. Use it for state that has no owner other than this fragment - a
/// dialog's checkbox, a hovered row index - and a real [StatefulWidget] for
/// anything a second widget also reads.
final class StatefulBuilder extends StatefulWidget {
  const StatefulBuilder({super.key, required this.builder});

  final Widget Function(
    BuildContext context,
    void Function(void Function()) setState,
  ) builder;

  @override
  State<StatefulBuilder> createState() => _StatefulBuilderState();
}

final class _StatefulBuilderState extends State<StatefulBuilder> {
  @override
  Widget build(BuildContext context) => widget.builder(context, setState);
}

/// The signature of [LayoutBuilder.builder].
typedef LayoutWidgetBuilder = Widget Function(
  BuildContext context,
  BoxConstraints constraints,
);

/// Builds its child from the constraints its parent gave it.
///
/// The widget that makes a responsive layout expressible at all: "one column
/// under 600 px, two above" is a decision about a number that exists only
/// during layout, and every other widget in this framework is built before
/// layout runs.
///
/// ## How it gets to build inside a layout pass
///
/// The build scope settles first, then layout runs; that order is what the
/// frame loop's settle-pass limit protects. So this widget's child cannot be
/// built in the ordinary place - the constraints that decide what it *is* are
/// not known yet - and instead [RenderLayoutBuilder.performLayout] calls back
/// into the element, which reconciles and then settles through
/// [BuildOwner.buildDuringLayout]. That method's comment carries the reasoning
/// and the failure that shaped it.
///
/// ## It rebuilds when the constraints change, and only then
///
/// A `LayoutBuilder` that re-ran its callback every frame would be a
/// performance bug that looks like working code: the picture is right, and the
/// whole subtree is discarded and rebuilt sixty times a second. So the callback
/// runs only when the constraints differ from the ones it last ran under, or
/// when something dirtied this element - a `setState` above it, an inherited
/// dependency, a new `builder` closure from the parent. Layout reaching this
/// node again for an unrelated reason is not one of those cases and does not
/// rebuild anything.
///
/// ## Two honest differences from Flutter
///
///   * **with no child, it takes the smallest size its constraints allow**,
///     where Flutter takes the biggest. Under an unbounded constraint the
///     biggest is infinite, and this framework rejects an infinite size by
///     name - see `InfiniteMeasureError` - rather than storing one and
///     multiplying it into every ancestor;
///   * **intrinsics throw** instead of being answered. `IntrinsicWidth`, a grid
///     `auto` track or a shrink-wrapping flex asks "how wide does your content
///     want to be" *without* offering constraints, and the only way to answer
///     is to run the callback against constraints invented for the question and
///     then keep whichever subtree that produced. Flutter refuses this for the
///     same reason; the difference is only that here the refusal is not
///     debug-only.
final class LayoutBuilder extends RenderObjectWidget {
  const LayoutBuilder({super.key, required this.builder});

  /// Called with the constraints this widget was given. Must not have side
  /// effects outside the subtree it returns: it runs during layout, where a
  /// `setState` on an ancestor cannot be honoured by the frame in flight.
  final LayoutWidgetBuilder builder;

  @override
  LayoutBuilderElement createElement() => LayoutBuilderElement(this);

  @override
  RenderLayoutBuilder createRenderObject(BuildContext context) =>
      RenderLayoutBuilder();
}

/// The element that reconciles a [LayoutBuilder]'s child from inside layout.
///
/// Public because [LayoutBuilder.createElement] returns it and an unspeakable
/// return type is the exact defect `test/architecture/public_surface_test.dart`
/// exists to catch.
final class LayoutBuilderElement extends RenderObjectElement {
  LayoutBuilderElement(LayoutBuilder super.widget);

  Element? _child;

  /// Set whenever something other than the constraints invalidated the child:
  /// a fresh `builder` closure, or a dirty mark from an inherited dependency.
  bool _needsBuild = true;

  BoxConstraints? _previousConstraints;

  @override
  LayoutBuilder get widget => super.widget as LayoutBuilder;

  @override
  RenderLayoutBuilder get renderObject =>
      super.renderObject as RenderLayoutBuilder;

  /// How many times the callback has actually run.
  ///
  /// The observable behind "it rebuilds when the constraints change and not
  /// otherwise", which is a claim about a count and cannot be checked by
  /// looking at the picture.
  int get buildCount => _buildCount;
  int _buildCount = 0;

  @override
  void mount(Element? parent, BuildOwner owner) {
    super.mount(parent, owner);
    renderObject.callback = _rebuildWithConstraints;
  }

  @override
  void update(LayoutBuilder newWidget) {
    super.update(newWidget);
    // A new widget means a new closure, and a closure is opaque: there is no
    // way to tell one that would build the same tree from one that would not.
    _invalidate();
  }

  @override
  void performRebuild() {
    super.performRebuild();
    // The path an inherited dependency takes. Without this, flipping the theme
    // above a LayoutBuilder marks it dirty, the mark is cleared, and the child
    // keeps the theme it was built with until the window is resized.
    _invalidate();
  }

  void _invalidate() {
    _needsBuild = true;
    renderObject.markNeedsLayout();
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    final Element? child = _child;
    if (child != null) visitor(child);
  }

  @override
  void forgetChild(Element child) {
    if (identical(_child, child)) _child = null;
  }

  @override
  void unmount() {
    // Before `super`, which detaches the render object: a callback left on a
    // node that has left the tree would build into an element that is on its
    // way out.
    renderObject.callback = null;
    _child?.unmount();
    _child = null;
    super.unmount();
  }

  void _rebuildWithConstraints(BoxConstraints constraints) {
    if (!mounted) return;
    if (!_needsBuild && constraints == _previousConstraints) return;
    _needsBuild = false;
    _previousConstraints = constraints;
    _buildCount++;
    final BuildOwner owner = this.owner!;
    owner.buildDuringLayout(() {
      // The same containment every other build gets: a builder that throws
      // costs its own subtree and not the window, and the report names the
      // widget path rather than only a stack.
      owner.errorReporter.guard(
        FrameworkPhase.build,
        () => _child = updateChild(_child, widget.builder(this, constraints)),
        widgetPath: debugWidgetPath(),
        context: 'running LayoutBuilder.builder',
      );
    });
  }
}

/// Lays one child out under this node's own constraints, after asking the
/// element what that child should be.
///
/// [callback] is installed by [LayoutBuilderElement] and is the only thing that
/// distinguishes this from a plain proxy box. Null between the render object
/// being created and the element mounting, and again after unmount - both are
/// real states and neither is an error, so it is simply not called.
final class RenderLayoutBuilder extends RenderSingleChildBox {
  RenderLayoutBuilder({super.child});

  /// Run at the top of every [performLayout] whose constraints could matter.
  void Function(BoxConstraints constraints)? callback;

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    // Ahead of everything else: the callback decides whether there *is* a
    // child. Adopting one here marks this node needing layout again, which is
    // a no-op precisely because it is already inside its own layout - see
    // `RenderBox.markNeedsLayout`.
    callback?.call(constraints);
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }

  @override
  double computeMinIntrinsicWidth(double height) => throw _intrinsicError();

  @override
  double computeMaxIntrinsicWidth(double height) => throw _intrinsicError();

  @override
  double computeMinIntrinsicHeight(double width) => throw _intrinsicError();

  @override
  double computeMaxIntrinsicHeight(double width) => throw _intrinsicError();

  StateError _intrinsicError() => StateError(
        'a LayoutBuilder cannot answer an intrinsic query. Its content is a '
        'function of the constraints, and an intrinsic asks how wide the '
        'content wants to be with no constraints offered - so answering would '
        'mean running the builder against a size invented for the question. '
        'Move the LayoutBuilder inside whatever is asking (IntrinsicWidth, '
        'IntrinsicHeight, a Grid auto track, a shrink-wrapping Flex), or give '
        'that ancestor an explicit extent.',
      );
}
