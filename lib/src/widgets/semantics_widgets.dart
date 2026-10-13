/// Describing a widget to assistive technology from the widget tree:
/// Flutter's `Semantics` and `MergeSemantics`.
///
/// The framework's controls describe themselves - a [Button] is a button
/// with its label - because their render objects implement
/// [SemanticsProvider]. A widget an application composes out of a
/// [GestureDetector] and a few boxes has no render object of its own to do
/// that with, and was therefore silent to a screen reader: clickable,
/// visible, and not there. [Semantics] is where such a widget says what it
/// is, and - with [onTap] and the other callbacks - lets the screen reader
/// operate it too, through the same [SemanticsActionTarget] the controls
/// use.
library;

import '../layout/render_proxy_box.dart';
import '../semantics/semantics.dart';
import 'element.dart';
import 'widget.dart';

/// Annotates [child] with what it is to assistive technology.
final class Semantics extends SingleChildRenderObjectWidget {
  const Semantics({
    super.key,
    super.child,
    this.label,
    this.value,
    this.hint,
    this.role,
    this.button = false,
    this.image = false,
    this.header = false,
    this.enabled,
    this.checked,
    this.selected,
    this.expanded,
    this.readOnly = false,
    this.container = false,
    this.onTap,
    this.onIncrease,
    this.onDecrease,
    this.onDismiss,
    this.increasedValue,
    this.decreasedValue,
  });

  final String? label;
  final String? value;
  final String? hint;

  /// The role, when the flags below do not say it; [button] and [image]
  /// are shorthands for the two most common.
  final SemanticsRole? role;
  final bool button;
  final bool image;

  /// A heading: read as a text node, its label being the heading.
  final bool header;

  /// False reads "dimmed"; null says nothing about it.
  final bool? enabled;
  final bool? checked;
  final bool? selected;
  final bool? expanded;
  final bool readOnly;

  /// Whether this node folds its descendants into itself, so a card reads as
  /// one sentence instead of a dozen fragments.
  final bool container;

  final void Function()? onTap;
  final void Function()? onIncrease;
  final void Function()? onDecrease;
  final void Function()? onDismiss;

  /// What [value] becomes after [onIncrease] or [onDecrease], read before
  /// the action is taken.
  final String? increasedValue;
  final String? decreasedValue;

  @override
  RenderSemanticsAnnotations createRenderObject(BuildContext context) =>
      RenderSemanticsAnnotations()..configure(this);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderSemanticsAnnotations renderObject,
  ) =>
      renderObject.configure(this);
}

/// Folds every semantic node below it into one - a row of an icon and two
/// labels read as a single item.
final class MergeSemantics extends StatelessWidget {
  const MergeSemantics({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Semantics(container: true, child: child);
}

/// The render object behind [Semantics]: lays out and paints exactly as its
/// child does, and adds one node to the semantic tree.
final class RenderSemanticsAnnotations extends RenderProxyBox
    implements SemanticsProvider, SemanticsActionTarget {
  RenderSemanticsAnnotations();

  Semantics? _config;

  /// Takes [widget]'s description.
  void configure(Semantics widget) => _config = widget;

  @override
  SemanticsConfiguration describeSemantics() {
    final Semantics c = _config!;
    final SemanticsRole role = c.role ??
        (c.button
            ? SemanticsRole.button
            : c.image
                ? SemanticsRole.image
                : c.header
                    ? SemanticsRole.text
                    : SemanticsRole.generic);
    return SemanticsConfiguration(
      role: role,
      label: c.label,
      value: c.value,
      hint: c.hint,
      states: <SemanticsState>{
        if (c.enabled == false) SemanticsState.disabled,
        if (c.checked == true) SemanticsState.checked,
        if (c.selected == true) SemanticsState.selected,
        if (c.expanded == true) SemanticsState.expanded,
        if (c.readOnly) SemanticsState.readOnly,
      },
      actions: <SemanticsAction>{
        if (c.onTap != null && c.enabled != false) SemanticsAction.activate,
        if (c.onIncrease != null) SemanticsAction.increment,
        if (c.onDecrease != null) SemanticsAction.decrement,
        if (c.onDismiss != null) SemanticsAction.dismiss,
      },
      increasedValue: c.increasedValue,
      decreasedValue: c.decreasedValue,
      mergesDescendants: c.container,
    );
  }

  @override
  bool performSemanticsAction(SemanticsAction action, {String? value}) {
    final Semantics? c = _config;
    if (c == null) return false;
    final void Function()? callback = switch (action) {
      SemanticsAction.activate => c.enabled == false ? null : c.onTap,
      SemanticsAction.increment => c.onIncrease,
      SemanticsAction.decrement => c.onDecrease,
      SemanticsAction.dismiss => c.onDismiss,
      _ => null,
    };
    if (callback == null) return false;
    callback();
    return true;
  }
}
