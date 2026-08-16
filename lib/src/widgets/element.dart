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

/// Where an element is in its life.
///
/// [inactive] is the state that makes a [GlobalKey] move possible. When a
/// parent stops listing a child, the child is not destroyed on the spot: it is
/// detached from the render tree, parked for the rest of the build scope, and
/// only unmounted once the scope settles without anyone claiming it. Without
/// that window, moving a subtree would depend on whether the destination
/// happened to be reconciled before the source - and half the time the state
/// would already be disposed by the time the new parent asked for it.
enum ElementLifecycle { initial, active, inactive, defunct }

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

  /// Parent-data widgets whose per-child configuration has not been written
  /// onto a render object yet. Drained once the build scope settles, for the
  /// same reason [_pendingRenderOrder] is: the render object a
  /// `Expanded(child: SomeStatefulThing())` configures does not exist until
  /// that child's own build has run, which is a later pass.
  final List<ParentDataElement<BoxParentData>> _pendingParentData =
      <ParentDataElement<BoxParentData>>[];

  /// Elements detached from the tree during this build scope and not yet
  /// unmounted. See [ElementLifecycle.inactive].
  final List<Element> _inactiveElements = <Element>[];

  /// Global keys taken by an element during this build scope, so that a second
  /// widget claiming the same key is a named error rather than a registry that
  /// answers with whichever build ran last.
  final Map<GlobalKey<State<StatefulWidget>>, Element> _claimedGlobalKeys =
      <GlobalKey<State<StatefulWidget>>, Element>{};

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

  /// Registers a [ParentDataWidget] whose configuration must reach a render
  /// object once the current build scope settles.
  void scheduleParentDataSync(ParentDataElement<BoxParentData> element) {
    _throwIfDisposed();
    _pendingParentData.add(element);
  }

  /// Records that [claimant] now carries [key], and rejects a second claim.
  ///
  /// "Second claim in the same build scope, by an element that is still
  /// active" is the precise condition. A claim left over from an earlier scope
  /// is not a conflict - that is the ordinary case of an element keeping its
  /// key from frame to frame - and neither is a claim whose element has since
  /// been detached, which is what a widget swapping type under a global key
  /// looks like from here.
  void _claimGlobalKey(GlobalKey<State<StatefulWidget>> key, Element claimant) {
    final Element? previous = _claimedGlobalKeys[key];
    if (previous != null && previous._lifecycle == ElementLifecycle.active) {
      throw DuplicateGlobalKeyError(
        key: key,
        firstPath: previous.debugWidgetPath(),
        secondPath: claimant.debugWidgetPath(),
      );
    }
    _claimedGlobalKeys[key] = claimant;
    key.internalRegister(claimant);
  }

  /// Hands [newParent] the existing element carrying [key], if there is one it
  /// may legally reuse.
  ///
  /// This is the whole of "moving a subtree keeps its state": the element is
  /// taken away from wherever it currently sits - in the tree or in the
  /// inactive list - its render objects are unplugged and plugged in under the
  /// new render parent, and its depth and inherited scope are recomputed.
  /// Nothing in it is rebuilt that did not have to be.
  ///
  /// Returns null when the key names nothing reusable, in which case the caller
  /// creates a fresh element and the state is genuinely lost - as it must be,
  /// because a different widget type is a different thing.
  Element? _retakeGlobalKey(
    GlobalKey<State<StatefulWidget>> key,
    Widget newWidget,
    Element newParent,
  ) {
    final Element? candidate = key.currentElement;
    if (candidate == null ||
        candidate._lifecycle == ElementLifecycle.defunct ||
        !identical(candidate._owner, this) ||
        !Widget.canUpdate(candidate.widget, newWidget)) {
      return null;
    }
    // Refuse to make an element its own descendant: the resulting cycle would
    // be found much later, as a stack overflow in a visitor.
    for (Element? ancestor = newParent;
        ancestor != null;
        ancestor = ancestor._parent) {
      if (identical(ancestor, candidate)) return null;
    }
    _claimGlobalKey(key, candidate);
    _inactiveElements.remove(candidate);
    // Unconditionally, even for an inactive candidate: its old parent still
    // lists it, and would unmount it on the way out.
    candidate._parent?.forgetChild(candidate);
    candidate._retakeInto(newParent);
    return candidate;
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
    // The tree has settled, so three things are finally knowable and none of
    // them was knowable mid-scope. In order:
    try {
      // 1. Which detached elements nobody reclaimed. Done first so that the
      //    two passes below never look at a subtree that is on its way out.
      _flushInactive();
      // 2. Which render object each parent-data widget was configuring: a
      //    component child owns none until its own build has run.
      _flushParentData();
      // 3. What the render child order is, for the same reason.
      _flushRenderOrder();
    } finally {
      // A scope that threw still ends the reservation window; leaving claims
      // behind would turn one failure into a spurious duplicate on the next
      // frame.
      _claimedGlobalKeys.clear();
    }
  }

  /// Unmounts everything detached during this scope that was not reclaimed.
  void _flushInactive() {
    while (_inactiveElements.isNotEmpty) {
      final List<Element> batch = List<Element>.of(_inactiveElements);
      _inactiveElements.clear();
      for (final Element element in batch) {
        // A reclaimed element is active again and must survive.
        if (element._lifecycle == ElementLifecycle.inactive) element.unmount();
      }
    }
  }

  void _flushParentData() {
    while (_pendingParentData.isNotEmpty) {
      final List<ParentDataElement<BoxParentData>> batch =
          List<ParentDataElement<BoxParentData>>.of(_pendingParentData);
      _pendingParentData.clear();
      for (final ParentDataElement<BoxParentData> element in batch) {
        if (element.mounted) element.applyParentData();
      }
    }
  }

  void _flushRenderOrder() {
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
    _pendingParentData.clear();
    _claimedGlobalKeys.clear();
    for (final Element element in List<Element>.of(_inactiveElements)) {
      if (element._lifecycle == ElementLifecycle.inactive) element.unmount();
    }
    _inactiveElements.clear();
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
    final Key? key = widget.key;
    if (key is GlobalKey) owner._claimGlobalKey(key, this);
    if (builds) {
      owner.scheduleBuildFor(this);
    } else {
      _dirty = false;
    }
  }

  void unmount() {
    if (_lifecycle == ElementLifecycle.defunct ||
        _lifecycle == ElementLifecycle.initial) {
      throw StateError('$runtimeType is not mounted.');
    }
    final Key? key = widget.key;
    if (key is GlobalKey) key.internalUnregister(this);
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
      deactivateChild(child);
      return null;
    }
    // The identical-widget short circuit, and what it is worth.
    //
    // [Element.update] ends in an unconditional `markNeedsBuild()`, so without
    // this a parent that rebuilt dragged its whole subtree with it whether or
    // not anything below had changed. That made a claim this framework makes
    // elsewhere untrue: an `InheritedWidget`'s dependency set decided who was
    // *notified*, while in practice everyone was *rebuilt*. Changing the locale
    // rebuilt the screen; so did a `setState` three levels up.
    //
    // `identical` and not `==`: two widgets that compare equal may still be
    // different instances holding different closures, and a `const` widget -
    // which is the case that matters, because a `const` subtree is rebuilt into
    // the same instance every time - is identical by construction. Using `==`
    // would also run user-defined operators during layout-critical work.
    //
    // The one thing this must not swallow is a child that is dirty for its own
    // reasons: its own `setState`, or an inherited dependency that changed.
    // It does not. Both of those already put the element in the owner's dirty
    // list through `markNeedsBuild`, and returning early here leaves it there,
    // so the same `buildScope` rebuilds it. What is skipped is only the
    // *parent-driven* rebuild of a subtree the parent did not change.
    //
    // Skipping `update` also skips its overrides, which is correct in each
    // case rather than merely tolerable: `StatefulElement.didUpdateWidget`
    // would be handed a widget identical to the one it already has,
    // `InheritedElement.updateShouldNotify(w, w)` cannot honestly answer true,
    // and a `ParentDataWidget` that did not change writes the same parent data.
    // A render object that appears *later* under a stable `ParentDataWidget`
    // is a different case and is handled where it happens, in
    // `_attachRenderObject`.
    if (child != null && identical(child.widget, newWidget)) {
      return child;
    }
    if (child != null && Widget.canUpdate(child.widget, newWidget)) {
      child.update(newWidget);
      return child;
    }
    // The old occupant goes first even when a retake is about to succeed: a
    // single-child render parent has exactly one slot, and the incoming render
    // object cannot be plugged in while the outgoing one is still in it.
    deactivateChild(child);
    final Key? key = newWidget.key;
    if (key is GlobalKey) {
      final Element? retaken = _owner!._retakeGlobalKey(key, newWidget, this);
      if (retaken != null) {
        retaken.update(newWidget);
        return retaken;
      }
    }
    final Element replacement = newWidget.createElement();
    replacement.mount(this, _owner!);
    return replacement;
  }

  // -------------------------------------------------------------------------
  // Detaching, reclaiming and reparenting
  // -------------------------------------------------------------------------

  /// Detaches [child] from the tree without destroying it yet.
  ///
  /// The child's render objects come out immediately - otherwise a container
  /// that reordered its remaining children would be handed a render list that
  /// still contains this one - but its [State] survives until the build scope
  /// settles, so a global key elsewhere in the same frame can still claim it.
  void deactivateChild(Element? child) => child?._deactivate();

  void _deactivate() {
    if (_lifecycle != ElementLifecycle.active) return;
    detachRenderObjects();
    _markInactive();
    _owner!._inactiveElements.add(this);
  }

  void _markInactive() {
    _lifecycle = ElementLifecycle.inactive;
    visitChildren((Element child) => child._markInactive());
  }

  /// Removes [child] from this element's record of its children, leaving the
  /// child itself intact.
  ///
  /// Called when a global key hands the child to a different parent. The
  /// default is a no-op because a childless element has nothing to forget;
  /// every element that stores children overrides it, and an element that
  /// forgot to would keep unmounting a child it no longer owns.
  void forgetChild(Element child) {}

  /// Unplugs the render objects this element's subtree contributes to its
  /// render parent.
  ///
  /// Stops at each [RenderObjectElement]: that node's own render subtree moves
  /// with it and is not disassembled.
  void detachRenderObjects() =>
      visitChildren((Element child) => child.detachRenderObjects());

  /// The inverse of [detachRenderObjects].
  void attachRenderObjects() =>
      visitChildren((Element child) => child.attachRenderObjects());

  /// Re-registers every [ParentDataWidget] in this subtree, whose target render
  /// parent may have changed underneath it.
  void rescheduleParentData() =>
      visitChildren((Element child) => child.rescheduleParentData());

  /// Moves this element, and everything under it, to a new parent.
  void _retakeInto(Element parent) {
    detachRenderObjects();
    _parent = parent;
    _owner = parent._owner;
    _refreshSubtree(parent._depth + 1, parent._inheritedElements);
    attachRenderObjects();
    rescheduleParentData();
  }

  /// Recomputes the two things a move invalidates for a whole subtree: how
  /// deep it now sits, and which inherited widgets are visible from it.
  void _refreshSubtree(int depth, Map<Type, InheritedElement>? inherited) {
    _depth = depth;
    _lifecycle = ElementLifecycle.active;
    _adoptInheritedScope(inherited);
    if (_dirty) _owner!.scheduleBuildFor(this);
    visitChildren((Element child) {
      child._owner = _owner;
      child._refreshSubtree(depth + 1, _inheritedElements);
    });
  }

  /// Takes [incoming] as the set of inherited widgets visible here, dropping
  /// any dependency that the move put out of scope.
  ///
  /// A dependency that survived - the same [InheritedElement] is still the one
  /// publishing that type - costs nothing. One that did not is deregistered and
  /// the element is marked for rebuild, because it is currently displaying a
  /// value it can no longer see.
  void _adoptInheritedScope(Map<Type, InheritedElement>? incoming) {
    _inheritedElements = incoming;
    final Set<InheritedElement>? dependencies = _dependencies;
    if (dependencies == null || dependencies.isEmpty) return;
    final List<InheritedElement> stale = <InheritedElement>[];
    for (final InheritedElement dependency in dependencies) {
      if (!identical(incoming?[dependency.widget.runtimeType], dependency)) {
        stale.add(dependency);
      }
    }
    if (stale.isEmpty) return;
    for (final InheritedElement dependency in stale) {
      dependency._dependents.remove(this);
      dependencies.remove(dependency);
    }
    markNeedsBuild();
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
  void forgetChild(Element child) {
    if (identical(_child, child)) _child = null;
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

  /// Republishes this value on top of whatever the new location inherits.
  ///
  /// Without this override a moved [InheritedWidget] would vanish from its own
  /// subtree: the map it hands its descendants would be its new parent's,
  /// which does not contain it.
  @override
  void _adoptInheritedScope(Map<Type, InheritedElement>? incoming) {
    super._adoptInheritedScope(incoming);
    _inheritedElements = <Type, InheritedElement>{
      ...?incoming,
      widget.runtimeType: this,
    };
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

/// Configures how the *parent* of its child treats that child.
///
/// The third kind of widget, next to component and render-object widgets, and
/// the only one that produces neither a render object nor a subtree of its own.
/// It exists because some layout inputs do not belong to a child: a flex factor
/// is not a property of a button, it is a property of the row's opinion about
/// that button. Putting it on the button would mean every widget in the
/// framework carries a `flex` field that only means something under one parent.
///
/// The plumbing is the interesting part. A parent-data widget writes into the
/// [BoxParentData] the render parent installed on the child, which means:
///
///   * it must find that render parent - by walking *up* the element tree from
///     itself to the nearest [RenderObjectElement], since component widgets in
///     between are transparent to the render tree and so must be transparent
///     here;
///   * it must dirty that parent rather than the child. The child's own layout
///     did not change; the parent's division of space did. Marking the child
///     would in general stop at the child, because a child under tight
///     constraints is a relayout boundary and the mark would never reach the
///     node that actually has to redo its arithmetic;
///   * it must be applied after the build scope settles, because
///     `Expanded(child: SomeStatefulThing())` has no render object to configure
///     until that child's own build has run - which is a later pass.
///
/// [T] is the parent-data type this widget knows how to fill in, and it is
/// what makes a misplaced one a named failure: a child of a [Flex] carries
/// `FlexParentData`, a child of a `Stack` carries `StackParentData`, and an
/// `Expanded` that finds the wrong one says so, naming both widgets, instead of
/// throwing a cast error from inside a layout pass three frames later.
abstract class ParentDataWidget<T extends BoxParentData> extends Widget {
  const ParentDataWidget({super.key, required this.child});

  final Widget child;

  @override
  ParentDataElement<T> createElement() => ParentDataElement<T>(this);

  /// The widget class that installs a [T] on its children, named in the error
  /// message when this one is found somewhere else. Diagnostics only - the
  /// check itself is on the parent data, so a subclass or a custom container
  /// that installs the right record is accepted.
  Type get typicalAncestorWidget;

  /// Writes this widget's configuration into [parentData].
  ///
  /// Returns whether anything actually changed. Returning false is not an
  /// optimisation detail: it is what keeps a rebuild that re-declares the same
  /// `flex: 2` from dirtying the row's layout, and therefore what keeps a
  /// `setState` in a leaf from costing a relayout of the whole toolbar.
  bool applyParentData(T parentData);
}

/// Carries one [ParentDataWidget]'s configuration to a render object.
///
/// Transparent in every other respect: it builds its child and contributes no
/// render object, so `Row(children: [Expanded(child: Button())])` reconciles,
/// paints and hit tests exactly as `Row(children: [Button()])` would.
final class ParentDataElement<T extends BoxParentData>
    extends ComponentElement {
  ParentDataElement(ParentDataWidget<T> super.widget);

  @override
  ParentDataWidget<T> get widget => super.widget as ParentDataWidget<T>;

  @override
  Widget build() => widget.child;

  @override
  void mount(Element? parent, BuildOwner owner) {
    super.mount(parent, owner);
    owner.scheduleParentDataSync(this);
  }

  @override
  void update(covariant ParentDataWidget<T> newWidget) {
    super.update(newWidget);
    owner!.scheduleParentDataSync(this);
  }

  @override
  void rescheduleParentData() {
    owner?.scheduleParentDataSync(this);
    super.rescheduleParentData();
  }

  /// The render object this widget's subtree contributes to its render parent.
  ///
  /// Zero of them while the child is still a component that has not built yet,
  /// which is the case [BuildOwner] defers around; more than one is impossible,
  /// because a component element has exactly one child.
  List<RenderBox> get targets {
    final List<RenderBox> found = <RenderBox>[];
    collectRenderChildren(found);
    return found;
  }

  /// The render-object element that owns the parent data being written.
  RenderObjectElement? get renderAncestor {
    for (Element? ancestor = parent;
        ancestor != null;
        ancestor = ancestor.parent) {
      if (ancestor is RenderObjectElement) return ancestor;
    }
    return null;
  }

  /// Writes the configuration through, and dirties the render *parent* of each
  /// configured node.
  void applyParentData() {
    final List<RenderBox> targets = this.targets;
    if (targets.isEmpty) return;
    for (final RenderBox target in targets) {
      final BoxParentData? data = target.parentData;
      final T? typed = data is T ? data : null;
      if (typed == null) {
        throw ParentDataError(
          parentDataWidget: widget.runtimeType,
          expectedParentData: T,
          expectedAncestor: widget.typicalAncestorWidget,
          actualAncestor: renderAncestor?.widget.runtimeType,
          actualParentData: data?.runtimeType,
          widgetPath: debugWidgetPath(),
        );
      }
      if (!widget.applyParentData(typed)) continue;
      // The parent, not the target: the target's own geometry is unchanged,
      // and a target under tight constraints is a relayout boundary that would
      // swallow the mark before it reached the node that has to redo the
      // division of space.
      target.parent?.markNeedsLayout();
    }
  }
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
  void performRebuild() {
    // A render object element that is rebuilt has to push its widget into its
    // render object. This was empty, and the emptiness was invisible for as
    // long as `updateChild` rebuilt every child unconditionally: the parent
    // always reached [update], and [update] does this same call, so the only
    // path that ever ran was the parent-driven one.
    //
    // The path that did *not* run is the one that matters for an
    // `InheritedWidget`. `Directionality.maybeOf` registers a dependency, so
    // flipping the ambient direction marks every dependent `Flex` dirty - and
    // a dirty render object element whose `performRebuild` does nothing keeps
    // the direction it was built with. The dependency machinery worked and
    // then dropped the result on the floor.
    //
    // Calling it here can repeat the call in the frame where a widget both
    // changed and was marked dirty. That is a redundant write of the same
    // properties, not a second effect: `updateRenderObject` is a setter run,
    // and every setter in the render tree already compares before marking
    // anything needing layout or paint.
    widget.updateRenderObject(this, _renderObject);
  }

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

  /// This node's own render object comes out; its subtree stays plugged into
  /// it, because the subtree travels with it.
  @override
  void detachRenderObjects() => _detachRenderObject();

  @override
  void attachRenderObjects() => _attachRenderObject();

  void _attachRenderObject() {
    Element? ancestor = parent;
    // Every parent-data widget between here and the render parent configures
    // *this* render object, and none of them knows that it just appeared: a
    // `setState` that swaps the widget inside an `Expanded` builds a brand new
    // render object with default parent data and never rebuilds the `Expanded`
    // above it. Collecting them on the way up is what keeps the flex factor
    // attached to the child rather than to the frame it was introduced in.
    while (ancestor != null && ancestor is! RenderObjectElement) {
      if (ancestor is ParentDataElement<BoxParentData>) {
        owner!.scheduleParentDataSync(ancestor);
      }
      ancestor = ancestor.parent;
    }
    if (ancestor is RenderObjectElement) {
      _renderParent = ancestor;
      ancestor.insertRenderObjectChild(_renderObject);
      // Appended, which is only the right position by luck. The container has
      // not necessarily reconciled in this scope - a `setState` deep inside one
      // of its component children can produce a brand new render object without
      // the container hearing about it - so the order has to be re-derived from
      // here rather than only where a child list was rebuilt.
      if (ancestor is MultiChildRenderObjectElement) {
        owner!.scheduleRenderOrderSync(ancestor);
      }
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
  void forgetChild(Element child) {
    if (identical(_child, child)) _child = null;
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
    // A copy, because reconciliation can reach [forgetChild] on this very
    // element - a global key elsewhere in the tree claiming one of these
    // children - and mutating the list being indexed would shift every
    // position after it.
    _children = _reconcile(List<Element>.of(_children), widget.children);
    owner!.scheduleRenderOrderSync(this);
  }

  @override
  void visitChildren(void Function(Element child) visitor) {
    for (final Element child in _children) {
      visitor(child);
    }
  }

  @override
  void forgetChild(Element child) => _children.remove(child);

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

    // Detached rather than destroyed: a global key later in this same build
    // scope may still claim one of them. Whatever is left over when the scope
    // settles is unmounted then.
    for (final Element leftover in keyed.values) {
      deactivateChild(leftover);
    }
    for (final Element leftover in retired) {
      deactivateChild(leftover);
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

/// The element-tree violations that get a name instead of a cast failure.
///
/// Same reasoning as `layout_errors.dart`: a test asserts on a type, a
/// development overlay renders one specially, and a bug report that says
/// `ParentDataError` is worth more than one that says
/// `type 'StackParentData' is not a subtype of type 'FlexParentData'` from
/// inside a layout pass that ran two frames after the mistake was made. They
/// extend [Error] because none of them is a condition an application can
/// handle - every one is a tree that was built wrong.
sealed class ElementError extends Error {
  ElementError(this.message);

  /// What went wrong, in prose, already naming the widgets involved.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A [ParentDataWidget] was found somewhere its configuration means nothing.
///
/// The canonical case is an `Expanded` that is not inside a `Row` or `Column`.
/// The message names *both* ends of the mistake - the parent-data widget and
/// the render ancestor that was actually there - because either one alone
/// leaves the reader hunting: "Expanded is misplaced" does not say where it
/// ended up, and "Stack got the wrong child" does not say which one.
final class ParentDataError extends ElementError {
  ParentDataError({
    required this.parentDataWidget,
    required this.expectedParentData,
    required this.expectedAncestor,
    required this.actualAncestor,
    required this.actualParentData,
    required this.widgetPath,
  }) : super(
          '$parentDataWidget writes $expectedParentData, which only a '
          '$expectedAncestor installs on its children, but '
          '${actualAncestor == null ? 'this one has no render ancestor at all '
              '(it installs ${actualParentData ?? 'nothing'})' : 'the nearest '
              'render ancestor here is a $actualAncestor, which installs '
              '${actualParentData ?? 'nothing'}'}. '
          'Put the $parentDataWidget directly inside a $expectedAncestor'
          '${actualAncestor == null ? '' : ', or use the parent-data widget '
              'that $actualAncestor reads'}.\n'
          '  at: ${widgetPath.reversed.join(' < ')}',
        );

  /// The misplaced widget's type, for example `Expanded`.
  final Type parentDataWidget;

  /// The per-child record it knows how to fill in.
  final Type expectedParentData;

  /// The widget type that would have installed that record.
  final Type expectedAncestor;

  /// The render ancestor that was actually there, or null when the widget was
  /// not under one at all.
  final Type? actualAncestor;

  /// The per-child record that ancestor installed, or null when the child has
  /// no render parent.
  final Type? actualParentData;

  /// The chain of widget types from the root down to the misplaced widget.
  final List<String> widgetPath;
}

/// Two live widgets claimed the same [GlobalKey].
///
/// A global key is an identity, and an identity that names two things names
/// neither. Detected at the moment the second widget claims it, which is the
/// only moment at which both locations are still known; found later - when
/// `currentState` answers with whichever build ran last - it is indistinguish-
/// able from a state bug in the widget itself.
final class DuplicateGlobalKeyError extends ElementError {
  DuplicateGlobalKeyError({
    required this.key,
    required this.firstPath,
    required this.secondPath,
  }) : super(
          'the same $key was claimed by two widgets in one build. A global key '
          'is an identity: it names the element a dialog reaches for and the '
          'subtree a move preserves, and it cannot name two of them.\n'
          '  first:  ${firstPath.reversed.join(' < ')}\n'
          '  second: ${secondPath.reversed.join(' < ')}',
        );

  final GlobalKey<State<StatefulWidget>> key;

  /// Widget path of the element that already held the key.
  final List<String> firstPath;

  /// Widget path of the element that tried to take it.
  final List<String> secondPath;
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
