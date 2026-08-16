library;

import '../layout/pipeline.dart';
import '../layout/render_box.dart';
import '../platform/input_events.dart';
import 'actions.dart';
import 'errors.dart';
import 'focus.dart';
import 'keyboard_router.dart';
import 'pointer_router.dart';
import 'semantics.dart';
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
  final PointerRouter _pointerRouter = PointerRouter();
  final KeyboardRouter _keyboardRouter = KeyboardRouter();

  /// Focus for this tree. One per owner, because focus is per window: two
  /// windows each have a focused control and only one of them is active.
  late final FocusManager focusManager = FocusManager(router: _keyboardRouter)
    ..traversalOrderProvider = _visualFocusOrder;

  /// The semantic tree, built on demand from the render tree.
  final SemanticsOwner semanticsOwner = SemanticsOwner();

  /// Application-level shortcuts, consulted after the focused control declines
  /// an event and before traversal claims it.
  ShortcutDispatcher? shortcuts;

  /// Where build failures go.
  ///
  /// Containment, not suppression: a widget whose build throws is left out of
  /// this frame and every other widget still gets one. The alternative - an
  /// exception reaching the frame loop - loses the whole window to one bad
  /// subtree, and loses the error's tree location on the way.
  ErrorReporter errorReporter = defaultErrorReporter;

  final List<Element> _dirtyElements = <Element>[];
  final List<MultiChildRenderObjectElement> _pendingRenderOrder =
      <MultiChildRenderObjectElement>[];
  Element? _rootElement;
  bool _building = false;
  bool _disposed = false;

  static const int _maxBuildPasses = 100;

  Element? get rootElement => _rootElement;

  /// The first render object produced below the (possibly component) root.
  RenderBox? get renderRoot => _renderView.child;

  bool get hasScheduledBuilds => _dirtyElements.isNotEmpty;

  List<Element> get dirtyElements => List<Element>.unmodifiable(_dirtyElements);

  /// Routes a backend pointer event through this owner's current render tree.
  ///
  /// Layout must have been flushed before input is dispatched so hit testing
  /// observes current geometry. Returns false when the point hits no render
  /// node.
  bool dispatchPointerEvent(PointerEvent event) {
    _throwIfDisposed();
    return _pointerRouter.route(event, root: _renderView);
  }

  /// Routes a normalized key event through this tree.
  ///
  /// The order is the whole contract, and it is the order every desktop
  /// toolkit converges on:
  ///
  ///   1. the focused control, which may consume the key entirely;
  ///   2. the application's shortcut map, so Ctrl+S works from inside a text
  ///      field that did not want the key;
  ///   3. focus traversal, so Tab moves even when nothing claimed it.
  ///
  /// Returns false when nothing handled the event, which a backend may use to
  /// let the platform have it - a menu mnemonic, a window accelerator.
  bool dispatchKeyEvent(KeyEvent event) {
    _throwIfDisposed();
    if (_keyboardRouter.route(event)) return true;
    if (shortcuts?.dispatch(event) ?? false) return true;
    return focusManager.handleTraversalKey(event);
  }

  /// Routes translated text through this tree.
  ///
  /// Only step 1 of [dispatchKeyEvent]'s three: text is not a shortcut and not
  /// a traversal command, so the focused control either takes it or nothing
  /// does. The key that produced this text was already offered to the shortcut
  /// map and to traversal on its own way through.
  bool dispatchTextInputEvent(TextInputEvent event) {
    _throwIfDisposed();
    return _keyboardRouter.routeTextInput(event);
  }

  /// Builds the semantic tree for the current render tree.
  ///
  /// Layout must have run: semantics carries bounds, and bounds before layout
  /// would be last frame's.
  SemanticsSnapshot buildSemantics() {
    _throwIfDisposed();
    return semanticsOwner.build(renderRoot);
  }

  /// Builds the semantic tree and reports what changed since the last build.
  SemanticsUpdate updateSemantics() {
    _throwIfDisposed();
    return semanticsOwner.update(renderRoot);
  }

  /// Keyboard targets in paint order, which is widget order.
  ///
  /// The render tree is the only structure that knows this: the element tree
  /// builds by depth and the focus tree is attached in build order, so neither
  /// of them can answer "what comes next visually".
  List<KeyboardEventTarget> _visualFocusOrder() {
    final List<KeyboardEventTarget> targets = <KeyboardEventTarget>[];
    void walk(RenderBox node) {
      if (node is KeyboardEventTarget) targets.add(node as KeyboardEventTarget);
      node.visitChildren(walk);
    }

    final RenderBox? root = renderRoot;
    if (root != null) walk(root);
    return targets;
  }

  KeyboardEventTarget? get focusedTarget => _keyboardRouter.focusedTarget;

  void requestKeyboardFocus(KeyboardEventTarget target) {
    _throwIfDisposed();
    _keyboardRouter.requestFocus(target);
  }

  void clearKeyboardFocus(KeyboardEventTarget target) {
    _throwIfDisposed();
    _keyboardRouter.clearFocus(target);
  }

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

  /// Registers a container whose render children must be put back in widget
  /// order once the current build scope settles.
  void scheduleRenderOrderSync(MultiChildRenderObjectElement element) {
    _throwIfDisposed();
    _pendingRenderOrder.add(element);
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
          if (!element.mounted || !identical(element.owner, this)) continue;
          errorReporter.guard(
            FrameworkPhase.build,
            element.rebuild,
            widgetPath: element.debugWidgetPath(),
            context: 'rebuilding ${element.widget.runtimeType}',
          );
        }
      }
    } finally {
      _building = false;
    }
    // After the tree has settled: every component child that was going to
    // produce a render object has now done so, so the order is knowable.
    while (_pendingRenderOrder.isNotEmpty) {
      final List<MultiChildRenderObjectElement> batch =
          List<MultiChildRenderObjectElement>.of(_pendingRenderOrder);
      _pendingRenderOrder.clear();
      for (final MultiChildRenderObjectElement element in batch) {
        if (element.mounted) element.syncRenderOrder();
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _rootElement?.unmount();
    _rootElement = null;
    _dirtyElements.clear();
    _pendingRenderOrder.clear();
    _keyboardRouter.clearFocusFromTree();
    focusManager.dispose();
    semanticsOwner.reset();
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

  /// Inherited elements visible from here, keyed by widget runtime type.
  ///
  /// Shared by reference with the parent and copied only by
  /// [InheritedElement], so a subtree with no inherited widgets in it costs
  /// one field assignment per element rather than one map per element.
  Map<Type, InheritedElement>? _inheritedElements;

  /// The inherited elements this one is registered with, so that unmounting
  /// can deregister and never leave a defunct element in a notify list.
  Set<InheritedElement>? _dependencies;

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
    _inheritedElements = parent?._inheritedElements;
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
    final Set<InheritedElement>? dependencies = _dependencies;
    if (dependencies != null) {
      for (final InheritedElement dependency in dependencies) {
        dependency._dependents.remove(this);
      }
      _dependencies = null;
    }
    _inheritedElements = null;
    _parent = null;
    _owner = null;
  }

  @override
  T? dependOnInheritedWidgetOfExactType<T extends InheritedWidget>() {
    final InheritedElement? ancestor = _inheritedElements?[T];
    if (ancestor == null) return null;
    (_dependencies ??= <InheritedElement>{}).add(ancestor);
    ancestor._dependents.add(this);
    return ancestor.widget as T;
  }

  @override
  T? getInheritedWidgetOfExactType<T extends InheritedWidget>() =>
      _inheritedElements?[T]?.widget as T?;

  @override
  T? findAncestorWidgetOfExactType<T extends Widget>() {
    for (Element? ancestor = _parent;
        ancestor != null;
        ancestor = ancestor._parent) {
      if (ancestor.widget.runtimeType == T) return ancestor.widget as T;
    }
    return null;
  }

  /// The chain of widget types from the root down to this element.
  ///
  /// The single most useful thing to print with a build failure: a stack trace
  /// names the method, and this names the place in the UI.
  List<String> debugWidgetPath() {
    final List<String> path = <String>[widget.runtimeType.toString()];
    for (Element? ancestor = _parent;
        ancestor != null;
        ancestor = ancestor._parent) {
      path.add(ancestor.widget.runtimeType.toString());
    }
    return path;
  }

  @override
  void visitAncestorElements(bool Function(Element element) visitor) {
    for (Element? ancestor = _parent;
        ancestor != null;
        ancestor = ancestor._parent) {
      if (!visitor(ancestor)) return;
    }
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

  /// Appends the render objects this element contributes to its render parent,
  /// in paint order.
  ///
  /// A component element has none of its own and forwards to its children,
  /// which is what lets a container reconcile a mixed list of component and
  /// render widgets and still know the resulting render order.
  void collectRenderChildren(List<RenderBox> into) =>
      visitChildren((Element child) => child.collectRenderChildren(into));

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

/// Publishes one [InheritedWidget] to the subtree below it.
///
/// Two things happen here that do not happen in any other element. First, the
/// inherited map is *copied* once at mount, so every descendant reads a map
/// that already contains this element - lookup never walks. Second, an update
/// whose [InheritedWidget.updateShouldNotify] answers true marks every
/// registered dependent dirty; the build owner then rebuilds them
/// shallowest-first in the same scope, so a theme change settles in one frame.
final class InheritedElement extends ComponentElement {
  InheritedElement(InheritedWidget super.widget);

  final Set<Element> _dependents = <Element>{};

  @override
  InheritedWidget get widget => super.widget as InheritedWidget;

  /// The elements currently depending on this value. A view for diagnostics
  /// and tests; mutation happens only through dependency registration.
  Set<Element> get dependents => Set<Element>.unmodifiable(_dependents);

  @override
  void mount(Element? parent, BuildOwner owner) {
    super.mount(parent, owner);
    final Map<Type, InheritedElement> visible = <Type, InheritedElement>{
      ...?_inheritedElements
    };
    // Keyed by the concrete widget type, which is what
    // dependOnInheritedWidgetOfExactType asks for. A nested widget of the same
    // type shadows the outer one, as scoping requires.
    visible[widget.runtimeType] = this;
    _inheritedElements = visible;
  }

  @override
  void update(InheritedWidget newWidget) {
    final InheritedWidget oldWidget = widget;
    super.update(newWidget);
    if (newWidget.updateShouldNotify(oldWidget)) notifyDependents();
  }

  /// Marks every dependent for rebuild.
  ///
  /// The list is copied first: a dependent's [Element.markNeedsBuild] may
  /// itself register or drop dependencies, and mutating the set under
  /// iteration is how that turns into a concurrent-modification crash on an
  /// otherwise valid tree.
  void notifyDependents() {
    for (final Element dependent in List<Element>.of(_dependents)) {
      if (dependent.mounted) dependent.markNeedsBuild();
    }
  }

  @override
  void unmount() {
    for (final Element dependent in List<Element>.of(_dependents)) {
      dependent._dependencies?.remove(this);
    }
    _dependents.clear();
    super.unmount();
  }

  @override
  Widget build() => widget.child;
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

  /// Attaches [child] to this element's render object.
  ///
  /// [slot] is the index a container should insert at, and is ignored by
  /// single-child parents. It is passed rather than appended because element
  /// reconciliation may re-order children, and appending would silently
  /// produce a render tree in a different order from the widget tree.
  void insertRenderObjectChild(RenderBox child, {int? slot}) {
    final RenderBox parent = _renderObject;
    if (parent is RenderBoxContainer) {
      final int index = slot ?? parent.childCount;
      parent.insert(child, index: index.clamp(0, parent.childCount));
      return;
    }
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
    if (parent is RenderBoxContainer) {
      parent.remove(child);
      return;
    }
    if (parent is! RenderSingleChildBox || !identical(parent.child, child)) {
      throw StateError('$child is not a render child of $parent');
    }
    parent.child = null;
  }

  /// The render objects this element contributes to a container parent.
  ///
  /// One for a render element; for a component element it is whatever its
  /// subtree produced, which is how `Column(children: [Button(...)])` works
  /// even though `Button` is not itself a render object.
  @override
  void collectRenderChildren(List<RenderBox> into) => into.add(_renderObject);

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

abstract class MultiChildRenderObjectWidget extends RenderObjectWidget {
  const MultiChildRenderObjectWidget({
    super.key,
    this.children = const <Widget>[],
  });

  final List<Widget> children;

  @override
  MultiChildRenderObjectElement createElement() =>
      MultiChildRenderObjectElement(this);
}

/// Reconciles an ordered list of children against an ordered list of widgets.
///
/// The algorithm is the standard two-ended scan, and the reason it is worth
/// more than a positional one is a single case: inserting an item at the front
/// of a list. Positionally, every element after it fails [Widget.canUpdate]
/// against a different widget and the entire list is rebuilt - every state
/// object disposed, every render node recreated, every scroll position lost.
/// With keys and this scan, one element is created and the rest are matched.
final class MultiChildRenderObjectElement extends RenderObjectElement {
  MultiChildRenderObjectElement(MultiChildRenderObjectWidget super.widget);

  List<Element> _children = <Element>[];

  @override
  MultiChildRenderObjectWidget get widget =>
      super.widget as MultiChildRenderObjectWidget;

  /// The child elements in widget order.
  List<Element> get children => List<Element>.unmodifiable(_children);

  @override
  void mount(Element? parent, BuildOwner owner) {
    super.mount(parent, owner);
    _children = _reconcile(const <Element>[], widget.children);
    owner.scheduleRenderOrderSync(this);
  }

  @override
  void update(RenderObjectWidget newWidget) {
    super.update(newWidget);
    _children = _reconcile(_children, widget.children);
    owner!.scheduleRenderOrderSync(this);
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    for (final Element child in _children) {
      visitor(child);
    }
  }

  @override
  void unmount() {
    for (final Element child in _children) {
      child.unmount();
    }
    _children = <Element>[];
    super.unmount();
  }

  /// Makes the render container's child order match the element order.
  ///
  /// Reconciliation attaches new render objects by appending, so an insertion
  /// in the middle lands at the end until this runs. It runs at the *end* of
  /// the build scope rather than inline, because a component child does not
  /// own a render object until its own build has happened - which is a later
  /// pass. Doing it once per settled scope also costs one permutation instead
  /// of one insert-at-index per child.
  void syncRenderOrder() {
    final RenderBox container = renderObject;
    if (container is! RenderBoxContainer) return;
    final List<RenderBox> ordered = <RenderBox>[];
    for (final Element child in _children) {
      child.collectRenderChildren(ordered);
    }
    container.reorderChildren(ordered);
  }

  List<Element> _reconcile(List<Element> oldChildren, List<Widget> newWidgets) {
    final List<Element?> newChildren =
        List<Element?>.filled(newWidgets.length, null);
    int oldStart = 0;
    int newStart = 0;
    int oldEnd = oldChildren.length - 1;
    int newEnd = newWidgets.length - 1;

    // Matching prefix: the common case of "nothing moved".
    while (oldStart <= oldEnd && newStart <= newEnd) {
      final Element child = oldChildren[oldStart];
      if (!Widget.canUpdate(child.widget, newWidgets[newStart])) break;
      newChildren[newStart] = updateChild(child, newWidgets[newStart]);
      oldStart++;
      newStart++;
    }

    // Matching suffix, scanned but not yet updated: updating now would run
    // build callbacks in the wrong order relative to the middle.
    while (oldStart <= oldEnd && newStart <= newEnd) {
      if (!Widget.canUpdate(oldChildren[oldEnd].widget, newWidgets[newEnd])) {
        break;
      }
      oldEnd--;
      newEnd--;
    }

    // The middle: index the surviving keyed elements so a moved child is found
    // by key rather than by position. Unkeyed middle elements cannot be
    // matched across a move - there is nothing to match them by - so they are
    // retired.
    final Map<Key, Element> keyed = <Key, Element>{};
    final List<Element> retired = <Element>[];
    for (int i = oldStart; i <= oldEnd; i++) {
      final Element child = oldChildren[i];
      final Key? key = child.widget.key;
      if (key != null) {
        keyed[key] = child;
      } else {
        retired.add(child);
      }
    }

    for (int i = newStart; i <= newEnd; i++) {
      final Widget newWidget = newWidgets[i];
      Element? match;
      final Key? key = newWidget.key;
      if (key != null) {
        final Element? candidate = keyed.remove(key);
        if (candidate != null &&
            Widget.canUpdate(candidate.widget, newWidget)) {
          match = candidate;
        } else if (candidate != null) {
          retired.add(candidate);
        }
      } else if (retired.isNotEmpty &&
          Widget.canUpdate(retired.first.widget, newWidget)) {
        match = retired.removeAt(0);
      }
      newChildren[i] = updateChild(match, newWidget);
    }

    for (final Element leftover in keyed.values) {
      leftover.unmount();
    }
    for (final Element leftover in retired) {
      leftover.unmount();
    }

    // Finally the suffix, in order, so its builds run after the middle's.
    final int tail = oldChildren.length - 1 - oldEnd;
    for (int i = 0; i < tail; i++) {
      final int newIndex = newWidgets.length - tail + i;
      final int oldIndex = oldChildren.length - tail + i;
      newChildren[newIndex] =
          updateChild(oldChildren[oldIndex], newWidgets[newIndex]);
    }

    return <Element>[
      for (final Element? child in newChildren)
        if (child != null) child,
    ];
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
