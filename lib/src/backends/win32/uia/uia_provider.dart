/// The providers themselves: one COM element per [SemanticsNode].
///
/// `IRawElementProviderSimple` is the minimum a window can answer with, and it
/// is not enough: a client that has only Simple sees one element and no tree,
/// so Narrator reads the window's name and stops. The tree comes from
/// `IRawElementProviderFragment` (navigation, bounds, runtime ids) rooted at a
/// single `IRawElementProviderFragmentRoot`, and both are implemented here.
///
/// ## Two classes, not one
///
/// The root exposes `IRawElementProviderFragmentRoot` and every other node
/// does not, and that is a correctness matter rather than tidiness: UI
/// Automation treats a node that answers a `QueryInterface` for
/// `IRawElementProviderFragmentRoot` as the root of its own fragment. If every
/// node did, the tree would be a thousand fragments with a thousand hosts.
///
/// ## Life after death
///
/// A client of an automation API holds element references across frames and
/// calls them whenever it likes; there is no handshake that says a node is
/// gone. So a provider whose node has left the tree does not become invalid -
/// it becomes **frozen**. It keeps the last [SemanticsNode] it saw and answers
/// `Name`, `ControlType`, `RuntimeId` and `BoundingRectangle` from it, and
/// answers `UIA_E_ELEMENTNOTAVAILABLE` to everything that would need the live
/// tree: navigation, hit testing, and every pattern that would act on the UI.
///
/// The alternative - returning `E_FAIL`, or worse, dereferencing a node that
/// is not there - is a screen reader that stops speaking. Answering by name is
/// the behaviour section 31 asks for and the reason
/// `foundation/lifecycle.dart`'s [GenerationToken] is used rather than a null
/// check: "not published yet" and "published and gone" are different answers
/// and a null cannot tell them apart.
library;

import 'dart:ffi';

import '../../../ffi/com.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../semantics/semantics.dart';
import 'com_server.dart';
import 'uia_constants.dart';
import 'uia_core.dart';
import 'uia_mapping.dart';

/// Client-space logical bounds to desktop-space physical pixels.
///
/// UI Automation speaks one coordinate space and one only: physical pixels
/// with the desktop's origin. The semantic tree speaks logical pixels with the
/// client area's origin. Everything in between - the window's position on the
/// desktop, the monitor's scale factor - is this class, and getting it wrong
/// puts Narrator's highlight rectangle somewhere else on the screen while
/// every other answer stays right, which is a bug that is very hard to see in
/// a test and impossible to miss with a screen magnifier.
final class UiaScreenTransform {
  UiaScreenTransform({
    this.clientOriginX = 0,
    this.clientOriginY = 0,
    this.scale = 1.0,
  });

  /// Where the client area's top-left corner is on the desktop, in physical
  /// pixels. Refreshed from `ClientToScreen`.
  double clientOriginX;
  double clientOriginY;

  /// Logical pixels to physical pixels - the window's DPI over 96.
  double scale;

  /// [bounds], in logical client space, as `[left, top, width, height]` in
  /// physical desktop space.
  List<double> toScreen(Rect bounds) => <double>[
        clientOriginX + bounds.left * scale,
        clientOriginY + bounds.top * scale,
        bounds.width * scale,
        bounds.height * scale,
      ];

  /// Whether the physical desktop point ([x], [y]) falls inside [bounds].
  bool contains(Rect bounds, double x, double y) {
    final List<double> rect = toScreen(bounds);
    return x >= rect[0] &&
        x < rect[0] + rect[2] &&
        y >= rect[1] &&
        y < rect[1] + rect[3];
  }
}

/// Performs a [SemanticsAction] a client asked for.
///
/// Returns whether the action was carried out. See the "declared absent" note
/// on [UiaProviderTree.actionDispatcher]: nothing in this framework can
/// perform one yet, so the default is null and the patterns answer
/// `UIA_E_NOTSUPPORTED` when invoked - having announced themselves honestly
/// beforehand, which is what lets a screen reader say "button" at all.
typedef UiaActionDispatcher = bool Function(
  int nodeId,
  SemanticsAction action, {
  String? value,
});

/// One element: a node id, the tree it belongs to, and the last thing it knew.
final class UiaNodeProvider {
  UiaNodeProvider._({
    required this.tree,
    required this.nodeId,
    required SemanticsNode node,
    required this.isRoot,
    required this.generation,
  }) : _frozen = node;

  final UiaProviderTree tree;
  final int nodeId;
  final bool isRoot;

  /// The tree generation this provider was created in. A provider from an
  /// earlier generation belongs to a window that has gone.
  final int generation;

  SemanticsNode _frozen;

  /// The node as the tree last published it. Never null: a provider is only
  /// created for a node that existed, and it keeps that node afterwards.
  SemanticsNode get node => _frozen;

  bool _alive = true;

  /// Whether the node is still in the published tree **and** the tree itself
  /// still belongs to a live window.
  bool get isAlive => _alive && tree.acceptsGeneration(generation);

  /// The HRESULT for an operation that needs the live tree.
  int get _availability => isAlive ? sOk : uiaErrorElementNotAvailable;

  void _refresh(SemanticsNode node) {
    _frozen = node;
    _alive = true;
  }

  void _freeze() => _alive = false;

  late final ComServerObject<UiaNodeProvider> _object =
      (isRoot ? tree._rootClass : tree._nodeClass).instantiate(this);

  /// The `IRawElementProviderSimple` pointer, which is also this element's
  /// COM identity. Borrowed: the tree owns the reference.
  Pointer<Void> get pointer => _object.pointer;

  /// For the test that has to prove `AddRef` was matched by `Release`.
  int get refCount => _object.refCount;

  @override
  String toString() => 'UiaNodeProvider($nodeId, ${node.role.name}, '
      '${isAlive ? 'live' : 'frozen'})';
}

/// Every element of one window, rebuilt as the semantic tree changes.
///
/// The identity rule this class exists to keep: **a node that survives a
/// rebuild keeps its provider**. A client holds element references and
/// compares them; handing out a new COM object for the same node on every
/// frame would make a screen reader think the whole window was replaced sixty
/// times a second.
final class UiaProviderTree with DisposableMixin {
  UiaProviderTree({
    required this.core,
    required this.hostProviderFor,
    UiaScreenTransform? transform,
  }) : transform = transform ?? UiaScreenTransform();

  final UiaCore core;

  /// Supplies `get_HostRawElementProvider` for the root - in practice
  /// `UiaHostProviderFromHwnd` over the window's HWND, which the bridge owns.
  ///
  /// Returns a pointer the caller owns a reference to, or `nullptr`.
  final Pointer<Void> Function() hostProviderFor;

  final UiaScreenTransform transform;

  /// Installed by whoever can actually perform a [SemanticsAction].
  ///
  /// **Declared absent.** Nothing does yet: `SemanticsConfiguration` declares
  /// the actions a control supports and there is no path in
  /// `lib/src/widgets/` that performs one - no `performAction`, no callback on
  /// [SemanticsOwner]. Until there is, `IInvokeProvider::Invoke` and its
  /// siblings answer `UIA_E_NOTSUPPORTED`, which is the true statement. The
  /// hook is here so that wiring it is one assignment rather than a rewrite.
  UiaActionDispatcher? actionDispatcher;

  final GenerationToken _generation = GenerationToken();
  final Map<int, UiaNodeProvider> _providers = <int, UiaNodeProvider>{};

  SemanticsSnapshot _snapshot = const SemanticsSnapshot(null);
  int? _rootId;

  /// The tree as last published.
  SemanticsSnapshot get snapshot => _snapshot;

  /// Whether work stamped [generation] still belongs to this tree's lifetime.
  bool acceptsGeneration(int generation) =>
      !isDisposed && _generation.accepts(generation);

  /// The root element, or null before the first publish.
  UiaNodeProvider? get root {
    final int? id = _rootId;
    return id == null ? null : _providers[id];
  }

  /// The provider for [id], live or frozen.
  UiaNodeProvider? providerFor(int id) => _providers[id];

  /// How many elements exist. For the teardown test.
  int get providerCount => _providers.length;

  /// Publishes [snapshot], reusing the provider of every node that survived.
  ///
  /// A node that has gone is **not** removed: its provider is frozen and kept,
  /// because a client may still be holding it. It is dropped only when the
  /// tree is disposed, or by [forget] once UI Automation has been told through
  /// `UiaDisconnectProvider` that the element is gone.
  void publish(SemanticsSnapshot snapshot) {
    throwIfDisposed();
    _snapshot = snapshot;
    final Set<int> live = <int>{};
    for (final SemanticsNode node in snapshot.nodes) {
      live.add(node.id);
      final UiaNodeProvider? existing = _providers[node.id];
      if (existing != null &&
          existing.isRoot == (node.id == snapshot.root?.id)) {
        existing._refresh(node);
      } else {
        existing?._freeze();
        _providers[node.id] = UiaNodeProvider._(
          tree: this,
          nodeId: node.id,
          node: node,
          isRoot: node.id == snapshot.root?.id,
          generation: _generation.current,
        );
      }
    }
    for (final MapEntry<int, UiaNodeProvider> entry in _providers.entries) {
      if (!live.contains(entry.key)) entry.value._freeze();
    }
    _rootId = snapshot.root?.id;
  }

  /// Drops a frozen provider, releasing the reference this tree holds.
  ///
  /// Only correct after `UiaDisconnectProvider`, which is what tells UI
  /// Automation to let go of its own references. Calling it earlier does not
  /// crash - the object survives on the client's reference and answers frozen
  /// - but it does leak until the client releases.
  void forget(int nodeId) {
    final UiaNodeProvider? provider = _providers.remove(nodeId);
    provider?._object.dispose();
  }

  /// The node containing the physical desktop point, deepest first.
  UiaNodeProvider? hitTest(double x, double y) {
    final SemanticsNode? root = _snapshot.root;
    if (root == null) return null;
    UiaNodeProvider? found;
    void walk(SemanticsNode node) {
      if (!transform.contains(node.bounds, x, y)) return;
      found = _providers[node.id] ?? found;
      for (final SemanticsNode child in node.children) {
        walk(child);
      }
    }

    walk(root);
    return found;
  }

  /// The focused element, or null when nothing claims focus.
  UiaNodeProvider? get focused {
    for (final SemanticsNode node in _snapshot.nodes) {
      if (node.states.contains(SemanticsState.focused)) {
        return _providers[node.id];
      }
    }
    return null;
  }

  /// The parent of [nodeId] in the published tree.
  UiaNodeProvider? parentOf(int nodeId) {
    final SemanticsNode? root = _snapshot.root;
    if (root == null) return null;
    for (final SemanticsNode node in root.flattened) {
      for (final SemanticsNode child in node.children) {
        if (child.id == nodeId) return _providers[node.id];
      }
    }
    return null;
  }

  /// The sibling [step] places from [nodeId], or null at the end.
  UiaNodeProvider? siblingOf(int nodeId, int step) {
    final UiaNodeProvider? parent = parentOf(nodeId);
    final List<SemanticsNode> siblings =
        parent?.node.children ?? const <SemanticsNode>[];
    final int index =
        siblings.indexWhere((SemanticsNode node) => node.id == nodeId);
    if (index < 0) return null;
    final int target = index + step;
    if (target < 0 || target >= siblings.length) return null;
    return _providers[siblings[target].id];
  }

  @override
  void onDispose() {
    // Invalidate first: a client call that arrives between here and the last
    // release finds every provider frozen rather than half torn down.
    _generation.invalidate();
    for (final UiaNodeProvider provider in _providers.values) {
      provider._freeze();
      provider._object.dispose();
    }
    _providers.clear();
    _rootId = null;
    _snapshot = const SemanticsSnapshot(null);
    _rootClassOrNull?.dispose();
    _nodeClassOrNull?.dispose();
  }

  // -------------------------------------------------------------------------
  // The COM classes
  // -------------------------------------------------------------------------

  // Built on first use and not before. A class is nine vtables and roughly
  // thirty `NativeCallable` trampolines, and most windows are never asked for
  // a provider at all: nothing builds one until a WM_GETOBJECT arrives.
  ComServerClass<UiaNodeProvider>? _nodeClassOrNull;
  ComServerClass<UiaNodeProvider>? _rootClassOrNull;

  ComServerClass<UiaNodeProvider> get _nodeClass =>
      _nodeClassOrNull ??= ComServerClass<UiaNodeProvider>(
        'UiaNodeProvider',
        <ComInterfaceSpec<UiaNodeProvider>>[
          _simpleSpec(),
          _fragmentSpec(),
          ..._patternSpecs(),
        ],
      );

  ComServerClass<UiaNodeProvider> get _rootClass =>
      _rootClassOrNull ??= ComServerClass<UiaNodeProvider>(
        'UiaRootProvider',
        <ComInterfaceSpec<UiaNodeProvider>>[
          _simpleSpec(),
          _fragmentSpec(),
          _fragmentRootSpec(),
          ..._patternSpecs(),
        ],
      );

  // -------------------------------------------------------------------------
  // IRawElementProviderSimple
  // -------------------------------------------------------------------------

  ComInterfaceSpec<UiaNodeProvider> _simpleSpec() =>
      ComInterfaceSpec<UiaNodeProvider>(
        name: 'IRawElementProviderSimple',
        iid: iidIRawElementProviderSimple,
        methods: <ComMethod<UiaNodeProvider>>[
          ComPointerMethod<UiaNodeProvider>(
            'get_ProviderOptions',
            (UiaNodeProvider self, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              out.cast<Int32>().value = providerOptionsServerSideProvider |
                  providerOptionsUseComThreading;
              return sOk;
            },
          ),
          ComIntPointerMethod<UiaNodeProvider>(
            'GetPatternProvider',
            (UiaNodeProvider self, int patternId, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
              slot.value = nullptr;
              if (!self.isAlive) return sOk;
              if (!uiaPatternsFor(self.node).contains(patternId)) return sOk;
              // The element is its own pattern provider, which is the
              // documented shape: the client then QueryInterfaces this
              // pointer for IInvokeProvider and finds it.
              self._object.addRefForClient();
              slot.value = self.pointer;
              return sOk;
            },
          ),
          ComIntPointerMethod<UiaNodeProvider>(
            'GetPropertyValue',
            (UiaNodeProvider self, int propertyId, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Object? value = _propertyValue(self, propertyId);
              core.writeVariant(out, value);
              return sOk;
            },
          ),
          ComPointerMethod<UiaNodeProvider>(
            'get_HostRawElementProvider',
            (UiaNodeProvider self, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
              // Only the fragment root has a host. A child that returned one
              // would be a second element for the same HWND and the tree
              // would have two roots.
              slot.value = self.isRoot ? hostProviderFor() : nullptr;
              return sOk;
            },
          ),
        ],
      );

  /// The value for [propertyId], honouring the frozen state of a dead node.
  Object? _propertyValue(UiaNodeProvider self, int propertyId) {
    if (propertyId == uiaBoundingRectanglePropertyId) {
      return self.isAlive ? transform.toScreen(self.node.bounds) : null;
    }
    if (propertyId == uiaIsOffscreenPropertyId) {
      // A frozen element is, by definition, not on screen. A live one this
      // provider cannot judge - it does not know what clipped it - so it says
      // nothing, which is UI Automation's "unknown".
      return self.isAlive ? null : true;
    }
    if (propertyId == uiaIsEnabledPropertyId && !self.isAlive) return false;
    final Map<int, Object?> properties = uiaPropertiesFor(self.node);
    return properties[propertyId];
  }

  // -------------------------------------------------------------------------
  // IRawElementProviderFragment
  // -------------------------------------------------------------------------

  ComInterfaceSpec<UiaNodeProvider> _fragmentSpec() =>
      ComInterfaceSpec<UiaNodeProvider>(
        name: 'IRawElementProviderFragment',
        iid: iidIRawElementProviderFragment,
        methods: <ComMethod<UiaNodeProvider>>[
          ComIntPointerMethod<UiaNodeProvider>(
            'Navigate',
            (UiaNodeProvider self, int direction, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
              slot.value = nullptr;
              if (!self.isAlive) return self._availability;
              final UiaNodeProvider? target = switch (direction) {
                // The root's parent is the host provider, which UI Automation
                // fetches itself. Answering null here is what says "this is
                // the top of the fragment".
                navigateDirectionParent =>
                  self.isRoot ? null : parentOf(self.nodeId),
                navigateDirectionFirstChild => _childAt(self, 0),
                navigateDirectionLastChild => _childAt(self, -1),
                navigateDirectionNextSibling =>
                  self.isRoot ? null : siblingOf(self.nodeId, 1),
                navigateDirectionPreviousSibling =>
                  self.isRoot ? null : siblingOf(self.nodeId, -1),
                _ => null,
              };
              if (target == null) return sOk;
              target._object.addRefForClient();
              slot.value = target.pointer;
              return sOk;
            },
          ),
          ComPointerMethod<UiaNodeProvider>(
            'GetRuntimeId',
            (UiaNodeProvider self, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
              // UiaAppendRuntimeId tells UI Automation to prefix the host
              // window's own id, which is what makes this unique across the
              // desktop without us knowing anything about the desktop. A
              // frozen element keeps its id: that is how a client recognises
              // the element it was holding.
              slot.value = core.allocateIntArray(
                <int>[uiaAppendRuntimeId, self.nodeId],
              );
              return slot.value == nullptr ? eOutOfMemory : sOk;
            },
          ),
          ComPointerMethod<UiaNodeProvider>(
            'get_BoundingRectangle',
            (UiaNodeProvider self, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Pointer<UiaRect> rect = out.cast<UiaRect>();
              final List<double> screen = transform.toScreen(self.node.bounds);
              // An empty rectangle is UI Automation's "no location", which is
              // the right answer for an element that is no longer laid out.
              rect.ref
                ..left = self.isAlive ? screen[0] : 0
                ..top = self.isAlive ? screen[1] : 0
                ..width = self.isAlive ? screen[2] : 0
                ..height = self.isAlive ? screen[3] : 0;
              return sOk;
            },
          ),
          ComPointerMethod<UiaNodeProvider>(
            'GetEmbeddedFragmentRoots',
            (UiaNodeProvider self, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              // None: this framework draws every control itself, so there is
              // no hosted HWND anywhere in the tree. Answering null is the
              // documented "no embedded roots" and not a stub.
              out.cast<Pointer<Void>>().value = nullptr;
              return sOk;
            },
          ),
          ComSelfMethod<UiaNodeProvider>(
            'SetFocus',
            (UiaNodeProvider self) => _perform(self, SemanticsAction.focus),
          ),
          ComPointerMethod<UiaNodeProvider>(
            'get_FragmentRoot',
            (UiaNodeProvider self, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
              slot.value = nullptr;
              final UiaNodeProvider? rootProvider = root;
              if (rootProvider == null) return self._availability;
              rootProvider._object.addRefForClient();
              slot.value = rootProvider.pointer;
              return sOk;
            },
          ),
        ],
      );

  UiaNodeProvider? _childAt(UiaNodeProvider self, int index) {
    final List<SemanticsNode> children = self.node.children;
    if (children.isEmpty) return null;
    return _providers[children[index < 0 ? children.length - 1 : index].id];
  }

  // -------------------------------------------------------------------------
  // IRawElementProviderFragmentRoot
  // -------------------------------------------------------------------------

  ComInterfaceSpec<UiaNodeProvider> _fragmentRootSpec() =>
      ComInterfaceSpec<UiaNodeProvider>(
        name: 'IRawElementProviderFragmentRoot',
        iid: iidIRawElementProviderFragmentRoot,
        methods: <ComMethod<UiaNodeProvider>>[
          ComPointPointerMethod<UiaNodeProvider>(
            'ElementProviderFromPoint',
            (UiaNodeProvider self, double x, double y, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
              slot.value = nullptr;
              if (!self.isAlive) return self._availability;
              final UiaNodeProvider? target = hitTest(x, y);
              if (target == null) return sOk;
              target._object.addRefForClient();
              slot.value = target.pointer;
              return sOk;
            },
          ),
          ComPointerMethod<UiaNodeProvider>(
            'GetFocus',
            (UiaNodeProvider self, Pointer<Void> out) {
              if (out == nullptr) return ePointer;
              final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
              slot.value = nullptr;
              if (!self.isAlive) return self._availability;
              final UiaNodeProvider? target = focused;
              if (target == null) return sOk;
              target._object.addRefForClient();
              slot.value = target.pointer;
              return sOk;
            },
          ),
        ],
      );

  // -------------------------------------------------------------------------
  // Control patterns
  // -------------------------------------------------------------------------

  List<ComInterfaceSpec<UiaNodeProvider>> _patternSpecs() =>
      <ComInterfaceSpec<UiaNodeProvider>>[
        ComInterfaceSpec<UiaNodeProvider>(
          name: 'IInvokeProvider',
          iid: iidIInvokeProvider,
          methods: <ComMethod<UiaNodeProvider>>[
            ComSelfMethod<UiaNodeProvider>(
              'Invoke',
              (UiaNodeProvider self) =>
                  _perform(self, SemanticsAction.activate),
            ),
          ],
        ),
        ComInterfaceSpec<UiaNodeProvider>(
          name: 'IToggleProvider',
          iid: iidIToggleProvider,
          methods: <ComMethod<UiaNodeProvider>>[
            ComSelfMethod<UiaNodeProvider>(
              'Toggle',
              (UiaNodeProvider self) =>
                  _perform(self, SemanticsAction.activate),
            ),
            ComPointerMethod<UiaNodeProvider>(
              'get_ToggleState',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                out.cast<Int32>().value = uiaToggleStateFor(self.node);
                return sOk;
              },
            ),
          ],
        ),
        ComInterfaceSpec<UiaNodeProvider>(
          name: 'IValueProvider',
          iid: iidIValueProvider,
          methods: <ComMethod<UiaNodeProvider>>[
            ComPointerMethod<UiaNodeProvider>(
              'SetValue',
              (UiaNodeProvider self, Pointer<Void> value) {
                if (value == nullptr) return ePointer;
                return _perform(
                  self,
                  SemanticsAction.setValue,
                  value: _readWideString(value.cast<Uint16>()),
                );
              },
            ),
            ComPointerMethod<UiaNodeProvider>(
              'get_Value',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                out.cast<Pointer<Void>>().value =
                    core.allocateBstr(self.node.value ?? '');
                return sOk;
              },
            ),
            ComPointerMethod<UiaNodeProvider>(
              'get_IsReadOnly',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                final Object? readOnly =
                    uiaPropertiesFor(self.node)[uiaValueIsReadOnlyPropertyId];
                // BOOL, not VARIANT_BOOL: this one is a plain Win32 BOOL and
                // 1 is true. The -1 rule applies inside a VARIANT only.
                out.cast<Int32>().value =
                    !self.isAlive || readOnly != false ? 1 : 0;
                return sOk;
              },
            ),
          ],
        ),
        ComInterfaceSpec<UiaNodeProvider>(
          name: 'ISelectionItemProvider',
          iid: iidISelectionItemProvider,
          methods: <ComMethod<UiaNodeProvider>>[
            ComSelfMethod<UiaNodeProvider>(
              'Select',
              (UiaNodeProvider self) =>
                  _perform(self, SemanticsAction.activate),
            ),
            ComSelfMethod<UiaNodeProvider>(
              'AddToSelection',
              (UiaNodeProvider self) =>
                  _perform(self, SemanticsAction.activate),
            ),
            ComSelfMethod<UiaNodeProvider>(
              'RemoveFromSelection',
              // Nothing in SemanticsAction deselects. Answering "not
              // supported" is the truth; routing it to activate would toggle
              // something the client asked to leave alone.
              (UiaNodeProvider self) => uiaErrorNotSupported,
            ),
            ComPointerMethod<UiaNodeProvider>(
              'get_IsSelected',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                out.cast<Int32>().value =
                    self.isAlive && uiaIsSelected(self.node) ? 1 : 0;
                return sOk;
              },
            ),
            ComPointerMethod<UiaNodeProvider>(
              'get_SelectionContainer',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
                slot.value = nullptr;
                if (!self.isAlive) return self._availability;
                final UiaNodeProvider? container =
                    _selectionContainerOf(self.nodeId);
                if (container == null) return sOk;
                container._object.addRefForClient();
                slot.value = container.pointer;
                return sOk;
              },
            ),
          ],
        ),
        ComInterfaceSpec<UiaNodeProvider>(
          name: 'ISelectionProvider',
          iid: iidISelectionProvider,
          methods: <ComMethod<UiaNodeProvider>>[
            ComPointerMethod<UiaNodeProvider>(
              'GetSelection',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                final Pointer<Pointer<Void>> slot = out.cast<Pointer<Void>>();
                final List<Pointer<Void>> selected = <Pointer<Void>>[];
                if (self.isAlive) {
                  for (final SemanticsNode child in self.node.children) {
                    if (!uiaIsSelected(child)) continue;
                    final UiaNodeProvider? provider = _providers[child.id];
                    if (provider == null) continue;
                    provider._object.addRefForClient();
                    selected.add(provider.pointer);
                  }
                }
                slot.value = core.allocateUnknownArray(selected);
                return slot.value == nullptr ? eOutOfMemory : sOk;
              },
            ),
            ComPointerMethod<UiaNodeProvider>(
              'get_CanSelectMultiple',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                // Declared false rather than guessed: SemanticsState has no
                // "multi-selectable", and a list that says it accepts multiple
                // selections and then does not is worse than one that says no.
                out.cast<Int32>().value = 0;
                return sOk;
              },
            ),
            ComPointerMethod<UiaNodeProvider>(
              'get_IsSelectionRequired',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                out.cast<Int32>().value = 0;
                return sOk;
              },
            ),
          ],
        ),
        ComInterfaceSpec<UiaNodeProvider>(
          name: 'IExpandCollapseProvider',
          iid: iidIExpandCollapseProvider,
          methods: <ComMethod<UiaNodeProvider>>[
            ComSelfMethod<UiaNodeProvider>(
              'Expand',
              (UiaNodeProvider self) =>
                  _perform(self, SemanticsAction.showMenu),
            ),
            ComSelfMethod<UiaNodeProvider>(
              'Collapse',
              (UiaNodeProvider self) => _perform(self, SemanticsAction.dismiss),
            ),
            ComPointerMethod<UiaNodeProvider>(
              'get_ExpandCollapseState',
              (UiaNodeProvider self, Pointer<Void> out) {
                if (out == nullptr) return ePointer;
                out.cast<Int32>().value = uiaExpandCollapseStateFor(self.node);
                return sOk;
              },
            ),
          ],
        ),
      ];

  /// The nearest ancestor that is a selection container.
  UiaNodeProvider? _selectionContainerOf(int nodeId) {
    UiaNodeProvider? candidate = parentOf(nodeId);
    while (candidate != null) {
      if (candidate.node.role == SemanticsRole.list ||
          candidate.node.role == SemanticsRole.menu) {
        return candidate;
      }
      candidate = parentOf(candidate.nodeId);
    }
    return null;
  }

  /// Runs [action] through [actionDispatcher], with the honest HRESULT when
  /// there is nobody to run it.
  int _perform(
    UiaNodeProvider self,
    SemanticsAction action, {
    String? value,
  }) {
    if (!self.isAlive) return uiaErrorElementNotAvailable;
    if (self.node.states.contains(SemanticsState.disabled)) {
      return uiaErrorElementNotEnabled;
    }
    if (!self.node.actions.contains(action)) return uiaErrorNotSupported;
    final UiaActionDispatcher? dispatcher = actionDispatcher;
    if (dispatcher == null) return uiaErrorNotSupported;
    return dispatcher(self.nodeId, action, value: value)
        ? sOk
        : uiaErrorNotSupported;
  }
}

/// A null-terminated UTF-16 string a client passed in.
///
/// Bounded, because a client that passes an unterminated buffer would
/// otherwise walk out of its allocation and into ours. 64 Ki code units is
/// longer than any value a control has.
String _readWideString(Pointer<Uint16> pointer) {
  if (pointer == nullptr) return '';
  const int limit = 65536;
  int end = 0;
  while (end < limit && pointer[end] != 0) {
    end++;
  }
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < end; i++) {
    buffer.writeCharCode(pointer[i]);
  }
  return buffer.toString();
}
