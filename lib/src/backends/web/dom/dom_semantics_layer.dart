/// The semantic tree, published as real DOM elements that Tab reaches and a
/// screen reader reads.
///
/// ## Where the vocabulary actually came from
///
/// The brief for this backend expected `ContentHint` to say "this span is text"
/// or "this is a button". It does not, and cannot: `graphics/content_hint.dart`
/// declares exactly two axes - [ContentMotionHint] (static, animating,
/// transforming) and [RenderQualityHint] (quality, speed) - and its contract is
/// that "a wrong hint costs performance and never changes the image". It is
/// advice to a rasteriser about caching. There is no role in it, no label, and
/// nothing that could grow one without breaking that contract.
///
/// The vocabulary this backend needs already exists one layer up, in
/// `semantics/semantics.dart`: [SemanticsRole] has `button`, `checkbox`,
/// `radio`, `slider`, `textField`, `listItem`, `menuItem`, `dialog` and nine
/// more; [SemanticsState] has `checked`, `disabled`, `selected`, `expanded`,
/// `required`, `invalid`; [SemanticsNode] carries a label, a value, a hint,
/// bounds in root coordinates, and an **id that is stable across frames**
/// because `SemanticsOwner` keys it by render-object identity. That last
/// property is what makes this layer diffable at all.
///
/// So this backend does not read hints. It reads the semantic tree, and the
/// finding is that the framework had the right answer in the wrong place for a
/// DOM backend to reach: the tree is published to `AccessibilityHost`, and
/// `Application` only registers one when the window is a `NativeHandleWindow` -
/// which a `WebWindow` is not, because a page has no `HWND`. Rather than change
/// the application shell, [DomSemanticsLayer] takes the tree from a callback
/// the embedder supplies. See `dom_presenter.dart`.
///
/// ## What is deliberately *not* here
///
/// Plain text and generic containers produce **no element**. They are already
/// in the visual layer as real text nodes, which a screen reader reads and
/// Ctrl+F finds, and emitting them a second time here would make every
/// paragraph in the page appear twice in the accessibility tree. The cost of
/// that choice is stated rather than hidden: a control's *label* is announced
/// twice, once as the control's accessible name and once as the visual text
/// underneath it. Removing the second would mean marking the visual spans that
/// fall inside a control's bounds `aria-hidden`, which is a geometric guess -
/// and a wrong guess silences text. See the report for the display-list change
/// that would make it exact.
///
/// ## The conflict this layer creates, measured rather than guessed
///
/// There are now **two focus systems** on this page and they do not know about
/// each other. The framework's own lives in the render tree and is driven by key
/// events the `<canvas>` receives; the browser's lives in the DOM and is driven
/// by Tab. Publishing focusable elements here means Tab moves the *browser's*
/// focus off the canvas, and from that moment the canvas receives no key events
/// at all - so a framework-level shortcut stops working until something focuses
/// the canvas again.
///
/// This is not speculation. Driving the real gallery through Playwright, Tab
/// walks `Press 0 -> Toggle -> Check -> Switch -> Low -> Medium -> High` in
/// exactly the published DOM order, correctly skipping the `Disabled` button -
/// because it is a native `<button disabled>` and the browser takes it out of
/// the sequential focus order without being asked. Every one of those steps is
/// a step the canvas did not get.
///
/// Two fixes exist and both are larger than this file. Forwarding every key
/// from a focused semantic element to the canvas double-handles Enter and Space,
/// which this layer already turns into an activation. Driving the framework's
/// focus from the DOM's - `focusin` here calling the framework's focus manager -
/// is the right answer and needs a seam the framework does not currently expose.
/// Until one of them lands, the honest description is: **on this path, Tab is
/// the browser's and the framework's keyboard shortcuts are the canvas's, and
/// they take turns.**
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../../geometry/rect.dart';
import '../../../semantics/semantics.dart';

/// A published semantic node the layer is holding on to.
final class _SemanticSlot {
  _SemanticSlot(this.element, this.id, this.tag);

  final web.Element element;
  final int id;

  /// The tag the role mapped to. A node whose role changes enough to want a
  /// different tag is replaced rather than relabelled, for the reason
  /// `dom_scene.dart` gives: an element is never mutated into a different kind
  /// of thing.
  final String tag;

  final Map<String, String> attributes = <String, String>{};
  Rect? bounds;
  final List<_SemanticSlot> children = <_SemanticSlot>[];

  void setAttribute(String name, String? value) {
    if (value == null) {
      if (attributes.remove(name) != null) element.removeAttribute(name);
      return;
    }
    if (attributes[name] == value) return;
    attributes[name] = value;
    element.setAttribute(name, value);
  }
}

/// Turns a [SemanticsSnapshot] into a focusable, readable DOM subtree.
final class DomSemanticsLayer {
  DomSemanticsLayer(this.root);

  /// The element the published tree lives under. Owned by the caller.
  final web.Element root;

  /// Where an activation from the keyboard goes.
  ///
  /// The layer never performs an action itself: `SemanticsOwner.performAction`
  /// refuses an action the last published snapshot did not declare, which is
  /// the check that keeps the DOM from being able to press a button the
  /// framework never offered. The embedder wires this to that call and then
  /// requests a frame.
  void Function(int nodeId, SemanticsAction action)? onAction;

  final Map<int, _SemanticSlot> _byId = <int, _SemanticSlot>{};
  final List<_SemanticSlot> _topLevel = <_SemanticSlot>[];

  /// The JS callbacks this layer installed, kept so they can be removed.
  ///
  /// A `JSFunction` created from a Dart closure is a fresh object every time it
  /// is converted, so `removeEventListener` needs the *same* one back. Losing
  /// it means a listener that outlives its element, which on a long-running
  /// page is how a detached DOM subtree stays reachable forever.
  final Map<int, JSFunction> _clickHandlers = <int, JSFunction>{};

  int get publishedNodeCount => _byId.length;

  /// Reconciles the published tree against [snapshot].
  ///
  /// Diffed by [SemanticsNode.id] rather than by position, which is the whole
  /// reason the ids are stable: a control that moved in the tree keeps its
  /// element, and therefore keeps the focus a user had put on it. A positional
  /// diff would move focus to whatever landed in the same slot.
  void update(SemanticsSnapshot snapshot) {
    final Set<int> survivors = <int>{};
    final SemanticsNode? rootNode = snapshot.root;
    if (rootNode == null) {
      _prune(survivors);
      _reorder(root, const <_SemanticSlot>[]);
      _topLevel.clear();
      return;
    }

    final List<_SemanticSlot> published = <_SemanticSlot>[];
    _visit(rootNode, null, root, published, survivors);
    _reorder(root, published);
    _topLevel
      ..clear()
      ..addAll(published);
    _prune(survivors);
  }

  void _visit(
    SemanticsNode node,
    Rect? parentBounds,
    web.Element parentElement,
    List<_SemanticSlot> into,
    Set<int> survivors,
  ) {
    final ({String tag, String? role})? mapped = _mapRole(node.role);
    if (mapped == null) {
      // Transparent: a generic container or a run of plain text contributes
      // nothing here, and its children attach to whatever this node's parent
      // was filling. Same rule `SemanticsOwner._visit` uses for a render object
      // with no configuration, and for the same reason - a node that says
      // nothing should not be in the tree a screen reader walks.
      for (final SemanticsNode child in node.children) {
        _visit(child, parentBounds, parentElement, into, survivors);
      }
      return;
    }

    survivors.add(node.id);
    _SemanticSlot? slot = _byId[node.id];
    if (slot == null || slot.tag != mapped.tag) {
      if (slot != null) _detach(slot);
      slot = _SemanticSlot(
        web.document.createElement(mapped.tag),
        node.id,
        mapped.tag,
      );
      _byId[node.id] = slot;
      _install(slot);
    }
    into.add(slot);

    _applyGeometry(slot, node.bounds, parentBounds);
    _applyRole(slot, mapped.role, node);

    final List<_SemanticSlot> children = <_SemanticSlot>[];
    for (final SemanticsNode child in node.children) {
      _visit(child, node.bounds, slot.element, children, survivors);
    }
    _reorder(slot.element, children);
    slot.children
      ..clear()
      ..addAll(children);
  }

  /// Positions [slot] at [bounds], expressed relative to [parentBounds].
  ///
  /// Relative because the DOM is nested and a nested absolutely-positioned
  /// element resolves against its nearest positioned ancestor, which is its
  /// parent slot. Writing root-space coordinates into a nested element would
  /// compound every offset down the tree - the classic symptom being that the
  /// deeper a control sits, the further down the page its focus ring appears.
  void _applyGeometry(_SemanticSlot slot, Rect bounds, Rect? parentBounds) {
    if (slot.bounds == bounds) return;
    slot.bounds = bounds;
    final double left = bounds.left - (parentBounds?.left ?? 0);
    final double top = bounds.top - (parentBounds?.top ?? 0);
    // `pointer-events: none` on every one of them, unconditionally. The
    // framework owns the pointer - see `DomPointerPolicy` - and a transparent
    // overlay that swallowed clicks would make the application unusable while
    // looking perfectly correct. The keyboard is a different matter: `tabindex`
    // does not need the pointer, which is exactly why this layer can give real
    // focus without taking input away.
    slot.element.setAttribute(
      'style',
      'position:absolute;pointer-events:none;background:transparent;'
          'border:0;padding:0;margin:0;font:inherit;color:transparent;'
          'left:${_px(left)};top:${_px(top)};'
          'width:${_px(bounds.width)};height:${_px(bounds.height)}',
    );
  }

  void _applyRole(_SemanticSlot slot, String? role, SemanticsNode node) {
    slot
      ..setAttribute('role', role)
      ..setAttribute('aria-label', node.label)
      ..setAttribute('data-dartui-semantics-id', '${node.id}')
      // A native `<button>` is focusable without one; everything else is a div
      // and would never be reached by Tab. -1 for a node that declares no
      // focus action, so it is programmatically focusable and out of the tab
      // order, which is the right answer for a container.
      ..setAttribute(
        'tabindex',
        slot.tag == 'button'
            ? null
            : (node.actions.contains(SemanticsAction.focus) ||
                    node.actions.contains(SemanticsAction.activate))
                ? '0'
                : '-1',
      )
      ..setAttribute('aria-disabled',
          node.states.contains(SemanticsState.disabled) ? 'true' : null)
      ..setAttribute('aria-checked', _checkedOf(node))
      ..setAttribute('aria-selected',
          node.states.contains(SemanticsState.selected) ? 'true' : null)
      ..setAttribute('aria-expanded',
          node.states.contains(SemanticsState.expanded) ? 'true' : null)
      ..setAttribute('aria-readonly',
          node.states.contains(SemanticsState.readOnly) ? 'true' : null)
      ..setAttribute('aria-required',
          node.states.contains(SemanticsState.required) ? 'true' : null)
      ..setAttribute('aria-invalid',
          node.states.contains(SemanticsState.invalid) ? 'true' : null)
      ..setAttribute('aria-modal',
          node.states.contains(SemanticsState.modal) ? 'true' : null)
      ..setAttribute('aria-valuetext', node.value)
      ..setAttribute('aria-description', node.hint);
    if (slot.tag == 'button') {
      // Type is not decoration: a `<button>` with no type inside a form is a
      // submit button, and pressing Enter on it would navigate the page away.
      slot.setAttribute('type', 'button');
      slot.setAttribute(
        'disabled',
        node.states.contains(SemanticsState.disabled) ? '' : null,
      );
    }
  }

  /// `aria-checked` for the tri-state controls, and null for everything else.
  ///
  /// `mixed` is a real third value rather than a shade of true: a tri-state
  /// checkbox announced as "checked" tells the user the wrong thing about what
  /// pressing it will do.
  static String? _checkedOf(SemanticsNode node) {
    if (node.states.contains(SemanticsState.mixed)) return 'mixed';
    if (node.states.contains(SemanticsState.checked)) return 'true';
    switch (node.role) {
      case SemanticsRole.checkbox:
      case SemanticsRole.radio:
      case SemanticsRole.toggleButton:
        return 'false';
      default:
        return null;
    }
  }

  /// Puts [children] in tree order under [parent], moving only what moved.
  ///
  /// Reading order and tab order are both DOM order, so this is not cosmetic:
  /// it is the whole of "Tab moves focus in the right order". `insertBefore` on
  /// a node that is already in the right place is skipped, because re-inserting
  /// a focused element blurs it in some engines - which would make Tab
  /// unusable on any page that redraws while the user is tabbing.
  void _reorder(web.Element parent, List<_SemanticSlot> children) {
    web.Node? expected = parent.firstChild;
    for (final _SemanticSlot child in children) {
      if (identical(child.element, expected)) {
        expected = expected!.nextSibling;
        continue;
      }
      parent.insertBefore(child.element, expected);
    }
    while (expected != null) {
      final web.Node? next = expected.nextSibling;
      parent.removeChild(expected);
      expected = next;
    }
  }

  void _install(_SemanticSlot slot) {
    final JSFunction handler = ((web.Event event) {
      event.preventDefault();
      onAction?.call(slot.id, SemanticsAction.activate);
    }).toJS;
    _clickHandlers[slot.id] = handler;
    // `click` rather than `keydown`, because a `<button>` already turns Enter
    // and Space into a click and a `[role=button]` div does not - so a single
    // listener here plus the keydown bridge below covers both without the two
    // ever firing twice for one press.
    slot.element.addEventListener('click', handler);
    if (slot.tag != 'button') {
      slot.element.addEventListener('keydown', _keydown);
    }
  }

  late final JSFunction _keydown = ((web.KeyboardEvent event) {
    if (event.key != 'Enter' && event.key != ' ') return;
    final web.Element? target = event.currentTarget as web.Element?;
    final String? id = target?.getAttribute('data-dartui-semantics-id');
    if (id == null) return;
    final int? nodeId = int.tryParse(id);
    if (nodeId == null) return;
    event.preventDefault();
    onAction?.call(nodeId, SemanticsAction.activate);
  }).toJS;

  void _detach(_SemanticSlot slot) {
    final JSFunction? handler = _clickHandlers.remove(slot.id);
    if (handler != null) {
      slot.element.removeEventListener('click', handler);
    }
    if (slot.tag != 'button') {
      slot.element.removeEventListener('keydown', _keydown);
    }
    slot.element.remove();
  }

  void _prune(Set<int> survivors) {
    final List<int> dead = <int>[
      for (final int id in _byId.keys)
        if (!survivors.contains(id)) id,
    ];
    for (final int id in dead) {
      final _SemanticSlot? slot = _byId.remove(id);
      if (slot != null) _detach(slot);
    }
  }

  /// Drops everything, so a presenter can be disposed without leaving
  /// listeners on elements the page still owns.
  void clear() {
    for (final _SemanticSlot slot in _byId.values.toList()) {
      _detach(slot);
    }
    _byId.clear();
    _topLevel.clear();
  }
}

/// The tag and ARIA role one [SemanticsRole] publishes as, or null when it
/// publishes nothing.
///
/// Null is the interesting entry. [SemanticsRole.generic] and
/// [SemanticsRole.text] return it because the visual layer already carries
/// their content as real text; see the library comment.
({String tag, String? role})? _mapRole(SemanticsRole role) {
  switch (role) {
    case SemanticsRole.generic:
    case SemanticsRole.text:
      return null;
    // A native element, not `[role=button]`, and the difference is real: a
    // `<button>` is focusable, activatable with Enter *and* Space, exposed to
    // every assistive technology including the ones that predate ARIA, and
    // recognised by browser features such as caret browsing. A div wearing a
    // role gets none of that for free.
    case SemanticsRole.button:
      return (tag: 'button', role: null);
    case SemanticsRole.toggleButton:
      return (tag: 'button', role: null);
    case SemanticsRole.checkbox:
      return (tag: 'div', role: 'checkbox');
    case SemanticsRole.radio:
      return (tag: 'div', role: 'radio');
    case SemanticsRole.slider:
      return (tag: 'div', role: 'slider');
    case SemanticsRole.progressBar:
      return (tag: 'div', role: 'progressbar');
    case SemanticsRole.textField:
      return (tag: 'div', role: 'textbox');
    case SemanticsRole.list:
      return (tag: 'div', role: 'list');
    case SemanticsRole.listItem:
      return (tag: 'div', role: 'listitem');
    case SemanticsRole.menu:
      return (tag: 'div', role: 'menu');
    case SemanticsRole.menuItem:
      return (tag: 'div', role: 'menuitem');
    case SemanticsRole.dialog:
      return (tag: 'div', role: 'dialog');
    case SemanticsRole.tooltip:
      return (tag: 'div', role: 'tooltip');
    case SemanticsRole.scrollView:
      return (tag: 'div', role: 'group');
    case SemanticsRole.image:
      return (tag: 'div', role: 'img');
  }
}

String _px(double value) {
  final double rounded = (value * 100).roundToDouble() / 100;
  if (rounded == rounded.truncateToDouble() && rounded.abs() < 1e9) {
    return '${rounded.toInt()}px';
  }
  return '${rounded}px';
}
