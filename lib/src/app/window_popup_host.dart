/// The [PopupHost] that gives every menu a window of its own.
///
/// The second implementation `widgets/popup_host.dart` was written to make
/// possible, and the reason that seam exists: an [InTreePopupHost] composites
/// into the owner's display list and is therefore bounded by the owner's
/// client area, so a menu near the right edge of the window is *cropped*
/// rather than flipped. This one opens a real [WindowKind.popup] window
/// through [Application.openPopup], which can extend past the owner and be
/// flipped against the monitor's work area instead.
///
/// It lives in `app/` and not in `widgets/` for the reason section 8.2 states:
/// opening a window needs [Application], and the widget layer is not allowed
/// to name the application layer. A widget asks `PopupHost.of(context)` and
/// never learns which of the two it got.
///
/// ## One host per top-level owner, not one per window
///
/// This is the subtlety the design hinges on, and getting it wrong produces a
/// failure that looks like nothing at all until it is fatal.
///
/// Every [ApplicationWindow] builds its own `DartUiApp`, so a popup *window*
/// would naturally publish a host of its own. A submenu opened from inside
/// that popup would then go to that host - whose chain is empty - and so would
/// be opened as a *root* popup of the top-level window, with the parent menu
/// nowhere in its ancestry. On Win32 that is merely wrong ordering. On Wayland
/// it is a protocol error: `xdg_surface.get_popup` requires the parent of an
/// `xdg_popup` to be the immediately preceding popup, and a violation kills
/// the connection - taking every window of the process with it, not just the
/// menu.
///
/// So one host serves a whole chain. Its state - the open handles, the owner,
/// the application - lives in a [_PopupChain] shared by every view of it, and
/// each popup window publishes a *view* that additionally knows which popup it
/// is inside. That view is what makes `open()` with no explicit
/// [PopupSpec.parent] chain onto the enclosing popup rather than restart at
/// the top-level window.
///
/// ## What is asynchronous, and what a caller may therefore assume
///
/// Opening a window is asynchronous - the backend creates it, a presenter
/// attaches to it, a surface is allocated - and [PopupHost.open] is not. So
/// the handle comes back immediately with [PopupHandle.placedRect] null, and
/// the window arrives later.
///
/// The race that invites is real and is the bug this class is most likely to
/// have: a popup closed before its window landed. A hover that moved on before
/// the tooltip opened does exactly that, and the naive implementation leaks a
/// window nobody holds a handle to - an orphan menu floating on the desktop
/// with no way to dismiss it. [_PopupChain._launch] therefore checks the
/// handle twice, once before creating anything and once after, and closes the
/// window it just created when the second check fails.
library;

import 'dart:async';

import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../widgets/element.dart';
import '../widgets/errors.dart';
import '../widgets/popup_host.dart';
import '../widgets/widget.dart';
import 'application.dart';

/// Opens popups as native windows of their own.
///
/// One per top-level owner window; see the library comment for why that is not
/// one per [ApplicationWindow]. Constructed by
/// `Application._popupHostFor`, which is what `DartUiApp` is handed.
final class WindowPopupHost implements PopupHost {
  WindowPopupHost({
    required Application application,
    required ApplicationWindow owner,
  }) : this._(_PopupChain(application: application, owner: owner), null);

  WindowPopupHost._(this._chain, this._enclosing);

  final _PopupChain _chain;

  /// The popup window whose tree publishes *this* view of the host, or null
  /// for the view the owner window publishes.
  ///
  /// The whole reason a view exists. A menu item inside popup P that opens a
  /// submenu passes no [PopupSpec.parent] - it does not know it is in a window
  /// at all - so the host has to supply one, and the only correct answer is P.
  final WindowPopupHandle? _enclosing;

  /// The window every popup of this chain is anchored to and owned by.
  ApplicationWindow get owner => _chain.owner;

  @override
  bool get escapesOwnerWindow => true;

  @override
  int get openCount => _chain.handles.length;

  @override
  PopupHandle? get topmost =>
      _chain.handles.isEmpty ? null : _chain.handles.last;

  /// The open popups, outermost first. Diagnostics and tests.
  List<WindowPopupHandle> get handles =>
      List<WindowPopupHandle>.unmodifiable(_chain.handles);

  @override
  PopupHandle open(PopupSpec spec) {
    // An explicit parent wins; otherwise the popup this tree lives inside is
    // the parent, and only a popup opened from the owner window itself has
    // none. A popup opened from a parent that has since closed is a race and
    // not a caller error - the pointer reached a submenu trigger in the same
    // frame the parent was dismissed - so it opens one level shallower rather
    // than throwing, which is exactly what [InTreePopupHost] does with the
    // same situation.
    PopupHandle? parent = spec.parent ?? _enclosing;
    if (parent != null && !parent.isOpen) parent = null;

    final handle = WindowPopupHandle._(
      chain: _chain,
      spec: spec,
      parent: parent,
    );
    _chain.handles.add(handle);
    unawaited(_chain._launch(handle));
    return handle;
  }

  @override
  void closeAll() {
    // Backwards, so the deepest popup of every chain goes first. Closing a
    // parent would take its children with it anyway - `Application.closeWindow`
    // closes what a window owns - but doing it in this order means each
    // handle's own dismissal runs through its own `close`, and every
    // `onDismiss` fires in the order the user would describe.
    for (final WindowPopupHandle handle
        in List<WindowPopupHandle>.of(_chain.handles).reversed) {
      handle.close();
    }
  }
}

/// The state one popup chain shares across every view of its host.
final class _PopupChain {
  _PopupChain({required this.application, required this.owner});

  final Application application;
  final ApplicationWindow owner;

  /// Open handles, in the order they were opened - so the last one is the
  /// innermost, which is what [PopupHost.topmost] means.
  final List<WindowPopupHandle> handles = <WindowPopupHandle>[];

  /// Opens the window behind [handle], and cancels cleanly if it is closed
  /// while that is in flight.
  ///
  /// The two checks are the whole point; see the library comment.
  Future<void> _launch(WindowPopupHandle handle) async {
    // Give the caller's own turn a chance to finish first. A widget that opens
    // a popup and closes it again in the same event handler - a hover that
    // moved on, a menu that reopened itself - must not cost a window at all,
    // and this is the suspension that lets the first check below see that.
    await Future<void>.value();
    if (!handle.isOpen) {
      handles.remove(handle);
      return;
    }
    if (application.isDisposed || owner.isDisposed) {
      handle._dismiss();
      return;
    }

    final PopupHandle? parent = handle.parent;
    final ApplicationWindow? parentWindow =
        parent is WindowPopupHandle ? parent._window : null;
    if (parent != null && (!parent.isOpen || parentWindow == null)) {
      // The parent closed - or has not landed itself - while this one was in
      // flight. Anchoring to a window that is gone is not recoverable here and
      // a root popup would appear in the wrong place, so this one is dismissed
      // instead. The user sees a submenu that did not open, which is what they
      // asked for by closing its parent.
      handle._dismiss();
      return;
    }

    final PopupSpec spec = handle.spec;
    ApplicationWindow window;
    try {
      window = await application.openPopup(
        owner: owner,
        parentPopup: parentWindow,
        anchorRect: spec.anchorRect,
        content: _PopupContent(handle: handle),
        kind: spec.kind,
        anchorPoint: spec.anchorPoint,
        popupPoint: spec.popupPoint,
        offset: spec.offset,
        adjustments: spec.adjustments,
        constraints: spec.constraints,
        // The popup's own tree publishes a view of this same host that knows
        // it is inside this popup, so a submenu opened from it chains here.
        host: WindowPopupHost._(this, handle),
        onDismissed: handle._onWindowRetired,
      );
    } on Object catch (error, stackTrace) {
      // Contained rather than thrown into whatever turn of the event loop this
      // happens to be: nothing is awaiting this future, so an escape would
      // become an unhandled asynchronous error and take the zone with it. The
      // popup is dismissed - the caller's `onDismiss` fires, so a menu button
      // does not stay stuck in its pressed state - and the failure is reported
      // through the owner's own reporter, where every other contained
      // framework error already goes.
      handle._dismiss();
      if (!owner.isDisposed) {
        owner.buildOwner.errorReporter.report(FrameworkError(
          phase: FrameworkPhase.async,
          cause: error,
          stackTrace: stackTrace,
          context: 'opening a ${spec.kind.name} popup window',
        ));
      }
      return;
    }

    if (!handle.isOpen || application.isDisposed) {
      // Closed while the window was being created. Without this the window is
      // an orphan: on screen, owned by nobody, with no handle left to close
      // it.
      application.closeWindow(window.id);
      return;
    }
    handle._attach(window);
  }

  void forget(WindowPopupHandle handle) => handles.remove(handle);
}

/// One popup that has a window, or is about to have one.
///
/// Public for the reason [InTreePopupHandle] is: a test - and a diagnostic
/// overlay - has a legitimate reason to name the concrete type and read
/// [window] off it, while nothing in the framework's own paths depends on it.
final class WindowPopupHandle implements PopupHandle {
  WindowPopupHandle._({
    required _PopupChain chain,
    required PopupSpec spec,
    required PopupHandle? parent,
  })  : _chain = chain,
        _spec = spec,
        _parent = parent;

  final _PopupChain _chain;
  final PopupHandle? _parent;
  PopupSpec _spec;
  ApplicationWindow? _window;
  bool _open = true;
  bool _dismissedFired = false;

  PopupSpec get spec => _spec;

  /// The window showing this popup, or null before it has landed and after it
  /// has closed.
  ApplicationWindow? get window => _window;

  @override
  bool get isOpen => _open;

  @override
  PopupKind get kind => _spec.kind;

  @override
  PopupHandle? get parent => _parent;

  /// Where the popup ended up, in the **owner window's** logical space.
  ///
  /// Null in all three of the situations [PopupHandle.placedRect] names, and
  /// the third one is not hypothetical here: on a backend with no screen
  /// coordinates the client is never told where its window went, so the answer
  /// is null forever rather than a number that would be a guess. Callers must
  /// handle that; a submenu positioned by reading its parent's rect would work
  /// on Windows and misplace every submenu under a Wayland compositor.
  ///
  /// Computed from the window rather than remembered from the placement, so
  /// that a popup the platform moved - a compositor that slid it, a
  /// `updateAnchor` - reports where it *is* and not where it was asked to go.
  @override
  Rect? get placedRect {
    final ApplicationWindow? window = _window;
    if (!_open || window == null || window.isDisposed) return null;
    if (!_chain.application.hasScreenCoordinates) return null;
    final ApplicationWindow owner = _chain.owner;
    if (owner.isDisposed) return null;
    final origin = owner.nativeWindow
        .screenToClient(window.nativeWindow.clientToScreen(Offset.zero));
    // The platform's own client size and not `host.logicalSize`: the host
    // learns the new size from the resize event, which arrives a pump later,
    // and a popup that reported the provisional rectangle for one turn would
    // be wrong exactly when a caller is most likely to read it.
    final Size size = window.nativeWindow.clientSize;
    return Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
  }

  @override
  void close() => _dismiss();

  @override
  void updateAnchor(Rect anchorRect) {
    if (!_open || anchorRect == _spec.anchorRect) return;
    _spec = _spec.copyWith(anchorRect: anchorRect);
    final ApplicationWindow? window = _window;
    // Before it has landed there is nothing to move: [_PopupChain._launch]
    // reads the spec when it opens the window, and it will read this one.
    if (window == null || window.isDisposed) return;
    window.nativeWindow.setBounds(_chain.application.placePopup(
      owner: _chain.owner,
      anchorRect: anchorRect,
      size: window.nativeWindow.clientSize,
      anchorPoint: _spec.anchorPoint,
      popupPoint: _spec.popupPoint,
      offset: _spec.offset,
      adjustments: _spec.adjustments,
    ));
  }

  @override
  void markNeedsBuild() {
    if (!_open) return;
    final ApplicationWindow? window = _window;
    if (window == null || window.isDisposed) return;
    // A fresh wrapper object with the same builder: the element updates rather
    // than remounting, so state inside the popup survives, and the builder
    // runs again - which is the whole request.
    window.updateRoot(_PopupContent(handle: this));
  }

  void _attach(ApplicationWindow window) => _window = window;

  /// The single point where this popup becomes closed, whatever route got here.
  ///
  /// Idempotent, and it has to be: the routes into dismissal race by design -
  /// an explicit `close`, a press outside, the owner losing activation, a
  /// `popup_done` from the compositor, and the window's own retirement all
  /// describe the same dismissal and more than one of them arrives. The flag
  /// is set *before* the window is closed so that the retirement callback this
  /// triggers re-enters and returns immediately, and `onDismiss` still fires
  /// exactly once, from the outermost call.
  void _dismiss() {
    if (!_open) return;
    _open = false;
    _chain.forget(this);
    final ApplicationWindow? window = _window;
    _window = null;
    if (window != null && !window.isDisposed) {
      // Closes the popups this one owns first; `Application.closeWindow` does
      // that itself, and their handles hear about it through their own
      // retirement callbacks.
      _chain.application.closeWindow(window.id);
    }
    if (!_dismissedFired) {
      _dismissedFired = true;
      _spec.onDismiss?.call();
    }
  }

  void _onWindowRetired() => _dismiss();

  @override
  String toString() => 'WindowPopupHandle(${_spec.kind.name}, '
      '${_open ? 'open' : 'closed'}'
      '${_window == null ? ', not yet placed' : ''})';
}

/// The popup's content, as the window's root widget.
///
/// A widget rather than the builder's result directly, so that the builder
/// runs inside the popup window's own tree - which is where it must run: the
/// `BuildContext` it is handed belongs to that window's [BuildOwner], and a
/// widget built against the owner window's context would be reparented across
/// two dirty lists.
final class _PopupContent extends StatelessWidget {
  const _PopupContent({required this.handle});

  final WindowPopupHandle handle;

  @override
  Widget build(BuildContext context) => handle.spec.builder(context);
}
