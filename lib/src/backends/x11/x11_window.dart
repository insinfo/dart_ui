/// One top-level X11 window behind the framework's [NativeWindow] contract.
///
/// Owns window lifecycle, platform events, and a retained PutImage framebuffer
/// when the connection's root visual supports the framework BGRA layout.
library;

import 'dart:async';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/compose_sequences.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/renderer.dart';
import 'x11_connection.dart';
import 'x11_coordinates.dart';
import 'x11_events.dart';
import 'x11_keyboard.dart';
import 'x11_protocol.dart';
import 'x11_surface.dart';

/// How one [WindowKind] is spelled in X11: three decisions, no side effects.
///
/// It is a value rather than a branch inside [X11Window.create] because these
/// three answers are the whole of "X11 honours the kind", and a branch would
/// only be checkable against a live X server with a real window manager - which
/// is exactly the thing this repository cannot run in CI on every platform.
/// As a value it is asserted directly (`x11_window_kind_test.dart`), and the
/// smoke tool reads the same three facts back off the server to prove the
/// wiring between this and `CreateWindow` (`X11_POPUP=` in
/// `tool/x11_backend_smoke.dart`).
///
/// Follows Avalonia's `X11Window` (`referencias/Avalonia/src/Avalonia.X11`),
/// which sets `_overrideRedirect` for every popup and leaves positioning to
/// its own `ManagedPopupPositioner`.
final class X11WindowKindPlan {
  const X11WindowKindPlan._({
    required this.overrideRedirect,
    required this.windowTypeAtom,
    required this.wantsTransientForOwner,
  });

  /// The plan for [kind].
  factory X11WindowKindPlan.of(WindowKind kind) => switch (kind) {
        // An ordinary window: managed, decorated, in the taskbar, and placed
        // by whatever policy the user's window manager has.
        WindowKind.normal => const X11WindowKindPlan._(
            overrideRedirect: false,
            windowTypeAtom: '_NET_WM_WINDOW_TYPE_NORMAL',
            wantsTransientForOwner: false,
          ),
        // A dialog stays managed - it is decorated and it does take activation
        // - and gains only its type and its transient-for. Making a dialog
        // override-redirect would take away the frame the user closes it with.
        WindowKind.dialog => const X11WindowKindPlan._(
            overrideRedirect: false,
            windowTypeAtom: '_NET_WM_WINDOW_TYPE_DIALOG',
            wantsTransientForOwner: true,
          ),
        // A menu. Override-redirect is the only thing on X11 that gives all
        // four of "no frame", "no taskbar entry", "no focus stolen from the
        // owner" and "appears exactly where the framework put it" at once;
        // `_MOTIF_WM_HINTS` alone gives the first and none of the rest.
        WindowKind.popup => const X11WindowKindPlan._(
            overrideRedirect: true,
            windowTypeAtom: '_NET_WM_WINDOW_TYPE_POPUP_MENU',
            wantsTransientForOwner: true,
          ),
        // A tooltip is a popup that additionally must never be focusable, and
        // override-redirect already guarantees that: a window the window
        // manager does not manage is a window it never focuses.
        WindowKind.tooltip => const X11WindowKindPlan._(
            overrideRedirect: true,
            windowTypeAtom: '_NET_WM_WINDOW_TYPE_TOOLTIP',
            wantsTransientForOwner: true,
          ),
      };

  /// Whether `CreateWindow` must carry `override_redirect = 1`.
  ///
  /// True makes the window invisible to the window manager: no decorations,
  /// no taskbar entry, no focus stealing, no placement policy - and therefore
  /// **the client is fully responsible for the position**, since nothing will
  /// nudge the window back onto a monitor or out from under a panel.
  final bool overrideRedirect;

  /// The `_NET_WM_WINDOW_TYPE` atom name, which is set for every kind
  /// including the override-redirect ones: a compositor reads it to choose the
  /// shadow and the animation even for a window no window manager manages.
  final String windowTypeAtom;

  /// Whether `WM_TRANSIENT_FOR` should name the owner, when there is one.
  final bool wantsTransientForOwner;

  /// Whether the window manager should be asked to draw a frame.
  ///
  /// Always false where [overrideRedirect] is true - not as a policy but as a
  /// statement of fact, since an unmanaged window has nobody to decorate it.
  bool get decorated => !overrideRedirect;
}

final class X11Window with DisposableMixin implements NativeWindow {
  X11Window._({
    required X11WindowClient client,
    required this.xcbWindow,
    required NativeWindowId id,
    required double scale,
    required double desktopScale,
    required int pixelWidth,
    required int pixelHeight,
    required bool visible,
    required void Function(X11Window window) onClosed,
  })  : _client = client,
        _cpuClient = client is X11CpuClient ? client as X11CpuClient : null,
        _id = id,
        _scale = scale,
        _desktopScale = desktopScale,
        _visible = visible,
        _onClosed = onClosed,
        _protocol = X11WindowProtocolState(
          xcbWindow: xcbWindow,
          wmProtocols: client.atom('WM_PROTOCOLS'),
          wmDeleteWindow: client.atom('WM_DELETE_WINDOW'),
          netWmState: client.atom('_NET_WM_STATE'),
          wmState: client.atom('WM_STATE'),
          rootWindow: client.root,
        ) {
    _protocol
      ..width = pixelWidth
      ..height = pixelHeight
      ..mapped = visible;
    _rebuildSurface();
  }

  static X11Window create({
    required X11WindowClient client,
    required NativeWindowId id,
    required WindowOptions options,
    required double scale,
    required double desktopScale,
    required void Function(X11Window window) onClosed,
  }) {
    final space = X11CoordinateSpace(originX: 0, originY: 0, scale: scale);
    final width = _clampXcbExtent(
      space.logicalToDevicePixels(options.size.width),
    );
    final height = _clampXcbExtent(
      space.logicalToDevicePixels(options.size.height),
    );
    final position = options.position;
    final x = position == null ? null : (position.dx * scale).round();
    final y = position == null ? null : (position.dy * scale).round();
    final plan = X11WindowKindPlan.of(options.kind);
    // The owner's X id, and only when the owner is one of *our* windows on
    // *this* connection: `WM_TRANSIENT_FOR` naming a window the server does
    // not have is a property a window manager will act on, and it acts by
    // losing the child behind everything.
    final owner = options.owner;
    final transientFor =
        plan.wantsTransientForOwner && owner is X11Window ? owner.xcbWindow : 0;
    final xcbWindow = client.createTopLevelWindow(
      X11TopLevelWindowRequest(
        width: width,
        height: height,
        x: x,
        y: y,
        title: options.title,
        resizable: options.resizable,
        decorated: options.decorated && plan.decorated,
        visible: options.visible,
        overrideRedirect: plan.overrideRedirect,
        windowTypeAtom: plan.windowTypeAtom,
        transientFor: transientFor,
      ),
    );
    return X11Window._(
      client: client,
      xcbWindow: xcbWindow,
      id: id,
      scale: scale,
      desktopScale: desktopScale,
      pixelWidth: width,
      pixelHeight: height,
      visible: options.visible,
      onClosed: onClosed,
    );
  }

  final X11WindowClient _client;
  final X11CpuClient? _cpuClient;
  final NativeWindowId _id;
  final void Function(X11Window window) _onClosed;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();
  final X11PendingWindowEvents _pending = X11PendingWindowEvents();
  final X11WindowProtocolState _protocol;
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];

  X11PutImageSurface? _surface;

  final int xcbWindow;
  final double _scale;
  final double _desktopScale;
  bool _visible;
  bool _closedEventEmitted = false;
  SystemCursor _cursor = SystemCursor.arrow;

  /// The keyboard map this window translates key events with.
  ///
  /// Set by the backend, which owns the one map the whole connection shares -
  /// a keymap is a property of the X server, not of a window, and two windows
  /// holding two copies would disagree the moment the user switches layout.
  /// Starts out empty rather than null, and is replaced by the backend's
  /// shared instance at creation: a window whose map could not be read still
  /// emits every [KeyEvent] with its physical keycode, and simply never emits
  /// text. That is the contract - a backend that cannot translate stays silent
  /// rather than guessing - and a nullable field here would have turned it
  /// into "no keyboard at all".
  X11KeyboardState keyboardState = X11KeyboardState();

  /// Dead keys, from the machine's own Compose table. Null when there is none.
  ///
  /// One engine **per window**, not per connection: the engine holds the
  /// half-finished sequence the user is in the middle of, and sharing it would
  /// let an accent typed in one window finish in another.
  ComposeEngine? composeEngine;

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize => Size(
        _protocol.width / _scale,
        _protocol.height / _scale,
      );

  ({int width, int height}) get pixelSize => (
        width: _protocol.width,
        height: _protocol.height,
      );

  /// The X visual this window was created with.
  ///
  /// Read from the connection rather than remembered from the request because
  /// the request never names one: `createTopLevelWindow` passes the screen's
  /// root visual, and this is the same number, asked of the same object.
  ///
  /// It exists so `X11GlSurface.forWindow` can be told which visual to compare
  /// against the EGL config's. Until it did, the mismatch that makes
  /// `eglCreateWindowSurface` return `EGL_BAD_MATCH` could only be reported as
  /// half a fact - the config's visual, with nothing to compare it to.
  int get visualId => _client.rootVisual;

  @override
  double get renderScale => _scale;

  @override
  double get desktopScale => _desktopScale;

  @override
  WindowState get state => WindowState.normal;

  @override
  List<NativeSurfaceDescriptor> get surfaces {
    final surface = _surface;
    return surface == null
        ? const <NativeSurfaceDescriptor>[]
        : <NativeSurfaceDescriptor>[surface];
  }

  X11PutImageSurface? get cpuSurface => _surface;

  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  /// What the *server* says this window's kind is, or null when it cannot say.
  ///
  /// Three round trips, so it is not for the frame loop; it exists so a smoke
  /// run against a real X server can print what actually landed on the window
  /// rather than the arguments it passed in. See `X11_POPUP=` in
  /// `tool/x11_backend_smoke.dart`.
  X11ServerWindowKind? readServerWindowKind() =>
      _client.readWindowKind(xcbWindow);

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  /// Records a renderer-side failure against this window.
  void recordRenderDiagnostic(BackendDiagnostic diagnostic) =>
      _record(diagnostic);

  /// Surfaces an asynchronous presenter failure on the window event stream.
  void reportError(Object error, StackTrace stackTrace) {
    if (!_events.isClosed) _events.addError(error, stackTrace);
  }

  SystemCursor get cursor => _cursor;

  @override
  void show() {
    throwIfDisposed();
    if (_visible) return;
    _client.mapTopLevelWindow(xcbWindow);
    _visible = true;
  }

  @override
  void hide() {
    throwIfDisposed();
    if (!_visible) return;
    _client.unmapTopLevelWindow(xcbWindow);
    _visible = false;
  }

  @override
  void close() => dispose();

  @override
  void setTitle(String value) {
    throwIfDisposed();
    _client.setTopLevelTitle(xcbWindow, value);
    _client.flush();
  }

  @override
  void setBounds(Rect bounds) {
    throwIfDisposed();
    final space = _coordinateSpace;
    _client.configureTopLevelWindow(
      xcbWindow,
      X11TopLevelBounds(
        x: (bounds.left * _scale).round(),
        y: (bounds.top * _scale).round(),
        width: _clampXcbExtent(
          space.logicalToDevicePixels(bounds.width),
        ),
        height: _clampXcbExtent(
          space.logicalToDevicePixels(bounds.height),
        ),
      ),
    );
  }

  @override
  void setCursor(SystemCursor cursor) {
    throwIfDisposed();
    // Cursor-font resources are intentionally deferred. Remembering the
    // requested cursor keeps the contract deterministic without pretending a
    // native cursor was installed.
    _cursor = cursor;
  }

  @override
  void requestRedraw([Rect? dirtyRect]) {
    throwIfDisposed();
    if (dirtyRect == null) {
      _client.requestTopLevelRedraw(xcbWindow, null);
      return;
    }
    final device = _coordinateSpace.logicalRectToDevice(dirtyRect);
    _client.requestTopLevelRedraw(
      xcbWindow,
      X11RedrawRegion(
        x: device.left.toInt(),
        y: device.top.toInt(),
        width: device.width.toInt(),
        height: device.height.toInt(),
      ),
    );
  }

  /// Uploads the retained CPU framebuffer to the X11 window.
  BackendDiagnostic? present({Rect? damage}) {
    throwIfDisposed();
    final surface = _surface;
    if (surface == null) {
      const failure = BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'no X11 CPU surface to present',
      );
      _record(failure);
      return failure;
    }
    final failure = surface.present(damage: damage);
    if (failure != null) _record(failure);
    return failure;
  }

  @override
  Offset screenToClient(Offset screenPosition) =>
      _coordinateSpace.screenToClient(screenPosition);

  @override
  Offset clientToScreen(Offset clientPosition) =>
      _coordinateSpace.clientToScreen(clientPosition);

  X11CoordinateSpace get _coordinateSpace => X11CoordinateSpace(
        originX: _protocol.originX,
        originY: _protocol.originY,
        scale: _scale,
      );

  /// Accumulates one decoded event. Called only by the owning backend.
  bool handleRawEvent(X11RawEvent raw) {
    if (isDisposed) return false;
    final consumed = X11EventTranslator.apply(raw, _protocol, _pending);
    if (!consumed) return false;
    final pointerEvent = X11EventTranslator.translateCorePointer(
      raw,
      windowId: id,
      generation: generation,
      scale: _scale,
    );
    if (pointerEvent != null) _emit(pointerEvent);
    if (raw.type == xcbKeyPress || raw.type == xcbKeyRelease) {
      X11EventTranslator.translateKey(
        raw,
        windowId: id,
        generation: generation,
        keyboard: keyboardState,
        compose: composeEngine,
        emit: _emit,
      );
    }
    return true;
  }

  /// Resolves coalesced state and emits at most one event of each kind.
  void flushPendingEvents() {
    if (isDisposed || _pending.isEmpty) return;
    if (_pending.originDirty) {
      final translated = _client.translateToRoot(xcbWindow);
      if (translated != null &&
          (translated.x != _protocol.originX ||
              translated.y != _protocol.originY)) {
        _protocol
          ..originX = translated.x
          ..originY = translated.y;
        _pending.moved = true;
      }
      _pending.originDirty = false;
    }
    final destroyed = _pending.destroyed;
    if (_pending.resized || destroyed) {
      _generation.invalidate();
      if (destroyed) {
        _releaseSurface();
      } else {
        _rebuildSurface();
      }
    }
    X11EventTranslator.emitPending(
      _pending,
      windowId: id,
      generation: generation,
      scale: _scale,
      deviceWidth: _protocol.width,
      deviceHeight: _protocol.height,
      originX: _protocol.originX,
      originY: _protocol.originY,
      emit: _emit,
    );
    if (destroyed) _closedEventEmitted = true;
    _pending.reset();
    if (destroyed) dispose();
  }

  void _emit(PlatformWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _rebuildSurface() {
    _releaseSurface();
    final client = _cpuClient;
    if (client == null || !client.supportsBgraPutImage || isDisposed) return;
    if (_protocol.destroyed || _protocol.width <= 0 || _protocol.height <= 0) {
      return;
    }
    try {
      _surface = X11PutImageSurface.create(
        client: client,
        xcbWindow: xcbWindow,
        pixelWidth: _protocol.width,
        pixelHeight: _protocol.height,
        scale: _scale,
        generation: generation,
      );
    } on Object catch (error) {
      _record(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'failed to create X11 PutImage surface',
        detail: '$error',
      ));
    }
  }

  void _releaseSurface() {
    _surface?.dispose();
    _surface = null;
  }

  void _record(BackendDiagnostic diagnostic) {
    if (_diagnostics.length >= 64) _diagnostics.removeAt(0);
    _diagnostics.add(diagnostic);
  }

  @override
  void onDispose() {
    _releaseSurface();
    if (!_protocol.destroyed) {
      _generation.invalidate();
      _client.destroyTopLevelWindow(xcbWindow);
      _protocol.destroyed = true;
      _protocol.mapped = false;
    }
    if (!_closedEventEmitted) {
      _closedEventEmitted = true;
      _emit(WindowClosedEvent(windowId: id, generation: generation));
    }
    _events.close();
    _onClosed(this);
  }

  @override
  String toString() => 'X11Window(id: ${id.value}, '
      'xid: 0x${xcbWindow.toRadixString(16)}, '
      '${_protocol.width}x${_protocol.height}px @ $_scale)';

  // PutImage destinations are signed 16-bit. Keeping framework-requested
  // extents within that range means every band/tile origin is representable.
  static int _clampXcbExtent(int value) => value < 1
      ? 1
      : value > 0x7fff
          ? 0x7fff
          : value;
}
