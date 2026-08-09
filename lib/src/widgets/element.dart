library;

import '../rendering/render_object.dart';
import 'widget.dart';

abstract class Element implements BuildContext {
  Element(this.widget);

  @override
  Widget widget;

  Element? _parent;
  Element? get parent => _parent;

  void mount(Element? parent) {
    _parent = parent;
  }

  void unmount() {
  }

  void update(covariant Widget newWidget) {
    widget = newWidget;
  }

  void markNeedsBuild() {
    // In a real framework, this notifies the BuildOwner.
    // For this vertical slice, we will implement a simple rebuild.
    rebuild();
  }

  void rebuild() {
    performRebuild();
  }

  void performRebuild();

  Element? updateChild(Element? child, Widget? newWidget) {
    if (newWidget == null) {
      if (child != null) {
        child.unmount();
      }
      return null;
    }

    if (child != null) {
      if (Widget.canUpdate(child.widget, newWidget)) {
        child.update(newWidget);
        return child;
      }
      child.unmount();
    }

    final newChild = newWidget.createElement();
    newChild.mount(this);
    return newChild;
  }
}

abstract class ComponentElement extends Element {
  ComponentElement(super.widget);

  Element? _child;

  @override
  void mount(Element? parent) {
    super.mount(parent);
    _firstBuild();
  }

  void _firstBuild() {
    rebuild();
  }

  @override
  void performRebuild() {
    final built = build();
    _child = updateChild(_child, built);
  }

  Widget build();
}

class StatelessElement extends ComponentElement {
  StatelessElement(StatelessWidget super.widget);

  @override
  StatelessWidget get widget => super.widget as StatelessWidget;

  @override
  Widget build() => widget.build(this);
}

class StatefulElement extends ComponentElement {
  StatefulElement(StatefulWidget super.widget);

  late State<StatefulWidget> _state;

  @override
  StatefulWidget get widget => super.widget as StatefulWidget;

  @override
  void mount(Element? parent) {
    _state = widget.createState()
      ..internalWidget = widget
      ..internalElement = this;
    _state.initState();
    super.mount(parent);
  }

  @override
  void update(StatefulWidget newWidget) {
    super.update(newWidget);
    final oldWidget = _state.widget;
    _state.internalWidget = newWidget;
    _state.didUpdateWidget(oldWidget);
    rebuild();
  }

  @override
  void unmount() {
    super.unmount();
    _state.dispose();
    _state.internalElement = null;
    _state.internalWidget = null;
  }

  @override
  Widget build() => _state.build(this);
}

abstract class RenderObjectWidget extends Widget {
  const RenderObjectWidget({super.key});

  @override
  RenderObjectElement createElement();

  RenderObject createRenderObject(BuildContext context);

  void updateRenderObject(
      BuildContext context, covariant RenderObject renderObject) {}
}

abstract class RenderObjectElement extends Element {
  RenderObjectElement(RenderObjectWidget super.widget);

  @override
  RenderObjectWidget get widget => super.widget as RenderObjectWidget;

  late RenderObject _renderObject;
  RenderObject get renderObject => _renderObject;

  @override
  void mount(Element? parent) {
    super.mount(parent);
    _renderObject = widget.createRenderObject(this);
    attachRenderObject();
  }

  @override
  void update(RenderObjectWidget newWidget) {
    super.update(newWidget);
    widget.updateRenderObject(this, _renderObject);
  }

  void attachRenderObject() {
    var ancestor = parent;
    while (ancestor != null && ancestor is! RenderObjectElement) {
      ancestor = ancestor.parent;
    }
    if (ancestor is RenderObjectElement) {
      // Very crude attach logic for the slice.
    }
  }

  @override
  void performRebuild() {
    widget.updateRenderObject(this, _renderObject);
  }
}
