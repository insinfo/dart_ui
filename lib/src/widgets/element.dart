library;

import '../layout/pipeline.dart';
import '../layout/render_box.dart';
import 'widget.dart';

enum ElementLifecycle { initial, active, defunct }

/// Owns the element tree and drains dirty builds shallowest-first.
final class BuildOwner {
  BuildOwner({required this.pipelineOwner, this.onBuildScheduled}) {
    if (pipelineOwner.root != null) {
      throw StateError('BuildOwner requires an unused PipelineOwner.');
    }
    pipelineOwner.root = _renderView;
  }

  final PipelineOwner pipelineOwner;
  final void Function()? onBuildScheduled;
  final _WidgetRenderView _renderView = _WidgetRenderView();

  final List<Element> _dirtyElements = <Element>[];
  Element? _rootElement;
  bool _building = false;
  bool _disposed = false;

  static const int _maxBuildPasses = 100;

  Element? get rootElement => _rootElement;

  /// The first render object produced below the (possibly component) root.
  RenderBox? get renderRoot => _renderView.child;

  bool get hasScheduledBuilds => _dirtyElements.isNotEmpty;

  List<Element> get dirtyElements => List<Element>.unmodifiable(_dirtyElements);

  /// Mounts or reconciles the root and brings all scheduled builds up to date.
  Element? updateRoot(Widget? widget) {
    _throwIfDisposed();
    final Element? current = _rootElement;
    if (widget == null) {
      current?.unmount();
      _rootElement = null;
      _dirtyElements.clear();
      return null;
    }

    if (current != null && Widget.canUpdate(current.widget, widget)) {
      current.update(widget);
    } else {
      current?.unmount();
      final Element replacement = widget.createElement();
      _rootElement = replacement;
      replacement.mount(null, this);
    }
    buildScope();
    return _rootElement;
  }

  void scheduleBuildFor(Element element) {
    _throwIfDisposed();
    if (!identical(element.owner, this) || !element.mounted) {
      throw StateError('cannot schedule a detached ${element.runtimeType}');
    }
    if (element._inDirtyList) return;
    final bool wasEmpty = _dirtyElements.isEmpty;
    element._inDirtyList = true;
    _dirtyElements.add(element);
    if (wasEmpty && !_building) onBuildScheduled?.call();
  }

  /// Rebuilds until no active dirty element remains.
  void buildScope() {
    _throwIfDisposed();
    if (_building) {
      throw StateError('BuildOwner.buildScope() is not reentrant.');
    }
    _building = true;
    int pass = 0;
    try {
      while (_dirtyElements.isNotEmpty) {
        if (++pass > _maxBuildPasses) {
          throw StateError(
            'widget build did not settle after $_maxBuildPasses passes',
          );
        }
        _dirtyElements.sort(
          (Element a, Element b) => a.depth.compareTo(b.depth),
        );
        final List<Element> batch = List<Element>.of(_dirtyElements);
        _dirtyElements.clear();
        for (final Element element in batch) {
          element._inDirtyList = false;
          if (element.mounted && identical(element.owner, this)) {
            element.rebuild();
          }
        }
      }
    } finally {
      _building = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _rootElement?.unmount();
    _rootElement = null;
    _dirtyElements.clear();
    if (identical(pipelineOwner.root, _renderView)) pipelineOwner.root = null;
    _disposed = true;
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('BuildOwner was used after dispose().');
  }
}

abstract class Element implements BuildContext {
  Element(this.widget);

  @override
  Widget widget;

  Element? _parent;
  BuildOwner? _owner;
  ElementLifecycle _lifecycle = ElementLifecycle.initial;
  int _depth = 0;
  bool _dirty = true;
  bool _inDirtyList = false;

  Element? get parent => _parent;

  BuildOwner? get owner => _owner;

  int get depth => _depth;

  bool get dirty => _dirty;

  bool get builds => true;

  ElementLifecycle get lifecycle => _lifecycle;

  @override
  bool get mounted => _lifecycle == ElementLifecycle.active;

  void mount(Element? parent, BuildOwner owner) {
    if (_lifecycle != ElementLifecycle.initial) {
      throw StateError('$runtimeType can only be mounted once.');
    }
    _parent = parent;
    _owner = owner;
    _depth = parent == null ? 0 : parent.depth + 1;
    _lifecycle = ElementLifecycle.active;
    if (builds) {
      owner.scheduleBuildFor(this);
    } else {
      _dirty = false;
    }
  }

  void unmount() {
    if (_lifecycle != ElementLifecycle.active) {
      throw StateError('$runtimeType is not mounted.');
    }
    _lifecycle = ElementLifecycle.defunct;
    _dirty = false;
    _inDirtyList = false;
    _parent = null;
    _owner = null;
  }

  void update(covariant Widget newWidget) {
    _updateWidget(newWidget);
    markNeedsBuild();
  }

  void _updateWidget(Widget newWidget) {
    if (!mounted) throw StateError('cannot update an unmounted $runtimeType');
    if (!Widget.canUpdate(widget, newWidget)) {
      throw StateError('incompatible widget update for $runtimeType');
    }
    widget = newWidget;
  }

  void markNeedsBuild() {
    if (!mounted) {
      throw StateError('$runtimeType.markNeedsBuild() while not mounted.');
    }
    if (_dirty) return;
    _dirty = true;
    _owner!.scheduleBuildFor(this);
  }

  void rebuild() {
    if (!mounted || !_dirty) return;
    // Clear first: setState during build schedules a distinct, later pass.
    _dirty = false;
    performRebuild();
  }

  void performRebuild();

  void visitChildren(void Function(Element child) visitor) {}

  Element? updateChild(Element? child, Widget? newWidget) {
    if (newWidget == null) {
      child?.unmount();
      return null;
    }
    if (child != null && Widget.canUpdate(child.widget, newWidget)) {
      child.update(newWidget);
      return child;
    }
    child?.unmount();
    final Element replacement = newWidget.createElement();
    replacement.mount(this, _owner!);
    return replacement;
  }
}

abstract class ComponentElement extends Element {
  ComponentElement(super.widget);

  Element? _child;

  Element? get child => _child;

  @override
  void performRebuild() {
    _child = updateChild(_child, build());
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    final Element? child = _child;
    if (child != null) visitor(child);
  }

  @override
  void unmount() {
    _child?.unmount();
    _child = null;
    super.unmount();
  }

  Widget build();
}

final class StatelessElement extends ComponentElement {
  StatelessElement(StatelessWidget super.widget);

  @override
  StatelessWidget get widget => super.widget as StatelessWidget;

  @override
  Widget build() => widget.build(this);
}

final class StatefulElement extends ComponentElement {
  StatefulElement(StatefulWidget super.widget);

  late final State<StatefulWidget> _state;

  State<StatefulWidget> get state => _state;

  @override
  StatefulWidget get widget => super.widget as StatefulWidget;

  @override
  void mount(Element? parent, BuildOwner owner) {
    _state = widget.createState();
    _state
      ..internalWidget = widget
      ..internalElement = this
      ..internalCanSetState = true;
    super.mount(parent, owner);
    _state.initState();
  }

  @override
  void update(StatefulWidget newWidget) {
    final StatefulWidget oldWidget = widget;
    super.update(newWidget);
    _state.internalWidget = newWidget;
    _state.didUpdateWidget(oldWidget);
  }

  @override
  void unmount() {
    // Dispose may inspect widget/context, but setState is already forbidden.
    _state.internalCanSetState = false;
    _state.dispose();
    _state
      ..internalElement = null
      ..internalWidget = null;
    super.unmount();
  }

  @override
  Widget build() => _state.build(this);
}

abstract class RenderObjectWidget extends Widget {
  const RenderObjectWidget({super.key});

  @override
  RenderObjectElement createElement();

  RenderBox createRenderObject(BuildContext context);

  void updateRenderObject(
      BuildContext context, covariant RenderBox renderObject) {}
}

abstract class SingleChildRenderObjectWidget extends RenderObjectWidget {
  const SingleChildRenderObjectWidget({super.key, this.child});

  final Widget? child;

  @override
  SingleChildRenderObjectElement createElement() =>
      SingleChildRenderObjectElement(this);
}

class RenderObjectElement extends Element {
  RenderObjectElement(RenderObjectWidget super.widget);

  @override
  RenderObjectWidget get widget => super.widget as RenderObjectWidget;

  late final RenderBox _renderObject;
  RenderBox get renderObject => _renderObject;

  RenderObjectElement? _renderParent;

  @override
  bool get builds => false;

  @override
  void mount(Element? parent, BuildOwner owner) {
    super.mount(parent, owner);
    _renderObject = widget.createRenderObject(this);
    _attachRenderObject();
  }

  @override
  void update(RenderObjectWidget newWidget) {
    _updateWidget(newWidget);
    widget.updateRenderObject(this, _renderObject);
  }

  @override
  void performRebuild() {}

  @override
  void unmount() {
    _detachRenderObject();
    super.unmount();
  }

  void insertRenderObjectChild(RenderBox child) {
    final RenderBox parent = _renderObject;
    if (parent is! RenderSingleChildBox) {
      throw StateError(
        '${parent.runtimeType} cannot receive a child; use a single-child '
        'RenderBox or a matching multi-child element',
      );
    }
    if (parent.child != null && !identical(parent.child, child)) {
      throw StateError('${parent.runtimeType} already has a render child');
    }
    parent.child = child;
  }

  void removeRenderObjectChild(RenderBox child) {
    final RenderBox parent = _renderObject;
    if (parent is! RenderSingleChildBox || !identical(parent.child, child)) {
      throw StateError('$child is not a render child of $parent');
    }
    parent.child = null;
  }

  void _attachRenderObject() {
    Element? ancestor = parent;
    while (ancestor != null && ancestor is! RenderObjectElement) {
      ancestor = ancestor.parent;
    }
    if (ancestor is RenderObjectElement) {
      _renderParent = ancestor;
      ancestor.insertRenderObjectChild(_renderObject);
      return;
    }
    owner!._renderView.child = _renderObject;
  }

  void _detachRenderObject() {
    final RenderObjectElement? renderParent = _renderParent;
    if (renderParent != null) {
      renderParent.removeRenderObjectChild(_renderObject);
      _renderParent = null;
    } else {
      final _WidgetRenderView? view = owner?._renderView;
      if (identical(view?.child, _renderObject)) view!.child = null;
    }
  }
}

final class SingleChildRenderObjectElement extends RenderObjectElement {
  SingleChildRenderObjectElement(SingleChildRenderObjectWidget super.widget);

  Element? _child;

  @override
  SingleChildRenderObjectWidget get widget =>
      super.widget as SingleChildRenderObjectWidget;

  @override
  void mount(Element? parent, BuildOwner owner) {
    super.mount(parent, owner);
    _child = updateChild(_child, widget.child);
  }

  @override
  void update(SingleChildRenderObjectWidget newWidget) {
    super.update(newWidget);
    _child = updateChild(_child, widget.child);
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    final Element? child = _child;
    if (child != null) visitor(child);
  }

  @override
  void unmount() {
    _child?.unmount();
    _child = null;
    super.unmount();
  }
}

/// Stable root slot between element reconciliation and [PipelineOwner].
final class _WidgetRenderView extends RenderSingleChildBox {
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
}
