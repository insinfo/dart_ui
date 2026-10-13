/// The window of an iOS application: a `UIWindow` on the scene, whose root
/// view is `DartUiView`, a `UIView` subclass made at runtime.
///
/// Pixels are a BGRA framebuffer shown as the view layer's `contents` (a
/// `CGImage`), the path the in-process macOS backends take; the GPU path
/// (`CAMetalLayer`) comes later. Touches arrive through the view's
/// `touches…:withEvent:` methods, text through `UIKeyInput`, on this thread:
/// the runtime handles the main isolate's messages on the main thread.
library;

import 'dart:async';
import 'dart:ffi';

import '../../ffi/objc_runtime.dart';
import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/input_events.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/framebuffer.dart';
import '../../rendering/renderer.dart';
import '../retained_cpu_window.dart';
import 'ios_uikit.dart';

/// The `kind` the iOS CPU surface reports.
const String iosCpuSurfaceKind = 'ios-cpu';

/// Where text goes while a field holds the keyboard.
abstract interface class IosImeHandler {
  bool get isEnabled;
  void onCommit(String text);
}

final class IosCpuSurface implements RetainedCpuSurface {
  IosCpuSurface._(this._window, this.generation, this.framebuffer, this.scale);

  final IosWindow _window;

  @override
  final int generation;

  @override
  final Framebuffer framebuffer;

  @override
  final double scale;

  @override
  String get kind => iosCpuSurfaceKind;

  @override
  int get pixelWidth => framebuffer.width;

  @override
  int get pixelHeight => framebuffer.height;

  @override
  BackendDiagnostic? present({Rect? damage}) => _window._present(this);
}

final class IosWindow
    with DisposableMixin
    implements NativeWindow, RetainedCpuWindow {
  IosWindow({
    required NativeWindowId id,
    required Pointer<ObjCObject> scene,
    required Pointer<ObjCObject> view,
    required void Function(IosWindow window) onClosed,
    required void Function() onEvent,
  })  : _id = id,
        _view = view,
        _onClosed = onClosed,
        _onEvent = onEvent {
    _window = objcSendPointer1(
        objcSendPointer(objcClass('UIWindow'), objcSelector('alloc')),
        objcSelector('initWithWindowScene:'),
        scene.address);
    _controller =
        objcSendPointer(objcClass('UIViewController'), objcSelector('new'));
    objcSendVoid1(_controller, objcSelector('setView:'), _view.address);
    objcSendVoid1(_view, objcSelector('setMultipleTouchEnabled:'), 1);
    objcSendVoid1(
        _window, objcSelector('setRootViewController:'), _controller.address);
    final Pointer<ObjCObject> screen =
        objcSendPointer(scene, objcSelector('screen'));
    _scale = sendDouble(screen, 'scale');
    _readBounds();
    _rebuildSurface();
  }

  final NativeWindowId _id;
  final Pointer<ObjCObject> _view;
  late final Pointer<ObjCObject> _window;
  late final Pointer<ObjCObject> _controller;
  final void Function(IosWindow window) _onClosed;
  final void Function() _onEvent;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  final Map<int, int> _touchIds = <int, int>{};
  var _nextTouchId = 1;
  double _scale = 1;
  Size _size = Size.zero;
  IosCpuSurface? _surface;
  bool _closedEmitted = false;

  /// The field the keyboard types into, when one is focused.
  IosImeHandler? textInput;

  Pointer<ObjCObject> get view => _view;

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize => _size;

  @override
  double get renderScale => _scale;

  @override
  double get desktopScale => _scale;

  @override
  WindowState get state => WindowState.fullscreen;

  @override
  List<NativeSurfaceDescriptor> get surfaces {
    final IosCpuSurface? surface = _surface;
    return surface == null
        ? const <NativeSurfaceDescriptor>[]
        : <NativeSurfaceDescriptor>[surface];
  }

  @override
  RetainedCpuSurface? get cpuSurface => _surface;

  @override
  void recordRenderDiagnostic(BackendDiagnostic diagnostic) =>
      _diagnostics.add(diagnostic);

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  @override
  void show() {
    if (isDisposed) return;
    objcSendVoid(_window, objcSelector('makeKeyAndVisible'));
    requestRedraw();
  }

  @override
  void hide() {}

  @override
  void close() => dispose();

  @override
  void setTitle(String value) {}

  @override
  void setBounds(Rect bounds) {}

  @override
  void setCursor(SystemCursor cursor) {}

  @override
  void requestRedraw([Rect? dirtyRect]) {
    if (isDisposed) return;
    _emit(WindowExposedEvent(
      windowId: _id,
      generation: _generation.current,
      dirtyRect: dirtyRect,
    ));
  }

  @override
  Offset screenToClient(Offset screenPosition) => screenPosition;

  @override
  Offset clientToScreen(Offset clientPosition) => clientPosition;

  /// Raises or lowers the keyboard: the view is a `UIKeyInput`, and UIKit
  /// shows the keyboard for whichever one is first responder.
  void showKeyboard({required bool show}) {
    if (isDisposed) return;
    objcSendBool(_view,
        objcSelector(show ? 'becomeFirstResponder' : 'resignFirstResponder'));
  }

  // -------------------------------------------------------------------------
  // From the view
  // -------------------------------------------------------------------------

  void layoutChanged() {
    if (isDisposed) return;
    final Size before = _size;
    _readBounds();
    if (_size == before) return;
    _generation.invalidate();
    _rebuildSurface();
    _emit(WindowResizedEvent(
      windowId: _id,
      generation: _generation.current,
      clientSize: _size,
      renderScale: _scale,
    ));
  }

  /// `touches…:withEvent:` - [phase] 0 began, 1 moved, 2 ended, 3 cancelled.
  void touches(int phase, Pointer<ObjCObject> touches) {
    if (isDisposed) return;
    final Duration timestamp = _now();
    for (final Pointer<ObjCObject> touch in setObjects(touches)) {
      final CGPoint at = sendPoint(touch, 'locationInView:', _view);
      final Offset position = Offset(at.x, at.y);
      final int key = touch.address;
      final int pointerId =
          phase == 0 ? (_touchIds[key] = _nextTouchId++) : _touchIds[key] ?? 0;
      final PointerKind kind =
          switch (objcSendUnsigned(touch, objcSelector('type'))) {
        2 => PointerKind.stylus, // UITouchTypePencil
        3 => PointerKind.mouse, // UITouchTypeIndirectPointer
        _ => PointerKind.touch,
      };
      final int generation = _generation.current;
      _emit(switch (phase) {
        0 => PointerDownEvent(
            windowId: _id,
            generation: generation,
            timestamp: timestamp,
            pointerId: pointerId,
            kind: kind,
            logicalPosition: position,
            button: PointerButton.primary,
          ),
        1 => PointerMoveEvent(
            windowId: _id,
            generation: generation,
            timestamp: timestamp,
            pointerId: pointerId,
            kind: kind,
            logicalPosition: position,
          ),
        2 => PointerUpEvent(
            windowId: _id,
            generation: generation,
            timestamp: timestamp,
            pointerId: pointerId,
            kind: kind,
            logicalPosition: position,
            button: PointerButton.primary,
          ),
        _ => PointerCancelEvent(
            windowId: _id,
            generation: generation,
            timestamp: timestamp,
            pointerId: pointerId,
            kind: kind,
            logicalPosition: position,
          ),
      });
      if (phase >= 2) _touchIds.remove(key);
    }
  }

  void insertText(String text) {
    if (isDisposed || text.isEmpty) return;
    final IosImeHandler? ime = textInput;
    if (ime != null && ime.isEnabled) {
      ime.onCommit(text);
      _onEvent();
      return;
    }
    // Return arrives as "\n": a key, like on every other backend.
    if (text == '\n') {
      _key(0x0D);
      return;
    }
    _emit(TextInputEvent(
      windowId: _id,
      generation: _generation.current,
      timestamp: _now(),
      text: text,
    ));
  }

  void deleteBackward() => _key(0x08);

  void _key(int logicalKey) {
    for (final bool down in <bool>[true, false]) {
      final Duration timestamp = _now();
      _emit(down
          ? KeyDownEvent(
              windowId: _id,
              generation: _generation.current,
              timestamp: timestamp,
              physicalKey: logicalKey,
              logicalKey: logicalKey,
            )
          : KeyUpEvent(
              windowId: _id,
              generation: _generation.current,
              timestamp: timestamp,
              physicalKey: logicalKey,
              logicalKey: logicalKey,
            ));
    }
  }

  static final Stopwatch _clock = Stopwatch()..start();
  static Duration _now() => _clock.elapsed;

  // -------------------------------------------------------------------------
  // Surface
  // -------------------------------------------------------------------------

  void _readBounds() {
    final CGRect bounds = sendRect(_view, 'bounds');
    _size = Size(bounds.size.width, bounds.size.height);
  }

  void _rebuildSurface() {
    final int width = (_size.width * _scale).round();
    final int height = (_size.height * _scale).round();
    _surface = width <= 0 || height <= 0
        ? null
        : IosCpuSurface._(
            this,
            _generation.current,
            Framebuffer.allocate(width: width, height: height),
            _scale,
          );
  }

  BackendDiagnostic? _present(IosCpuSurface surface) {
    if (isDisposed || !identical(surface, _surface)) {
      return const BackendDiagnostic.note('stale iOS surface');
    }
    final Framebuffer buffer = surface.framebuffer;
    final Pointer<Void> image = createImage(buffer.pixels,
        width: buffer.width,
        height: buffer.height,
        bytesPerRow: buffer.bytesPerRow);
    if (image == nullptr) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'CGImageCreate failed',
      );
    }
    final Pointer<ObjCObject> layer =
        objcSendPointer(_view, objcSelector('layer'));
    objcSendVoid1(layer, objcSelector('setContents:'), image.address);
    releaseCF(image);
    return null;
  }

  void _emit(PlatformWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
    _onEvent();
  }

  @override
  void onDispose() {
    _generation.invalidate();
    _surface = null;
    if (!_closedEmitted) {
      _closedEmitted = true;
      _emit(WindowClosedEvent(
        windowId: _id,
        generation: _generation.current,
      ));
    }
    unawaited(_events.close());
    _onClosed(this);
  }
}
