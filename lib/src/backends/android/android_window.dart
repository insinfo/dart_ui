/// The one window an Android activity has, and the buffers it presents.
library;

import 'dart:async';
import 'dart:typed_data';

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
import 'android_host_protocol.dart';
import 'android_input.dart';
import 'android_shared_memory.dart';

/// The `kind` the Android CPU surface reports.
const String androidCpuSurfaceKind = 'android-cpu';

/// Where committed text goes while a field holds the input method.
abstract interface class AndroidImeHandler {
  bool get isEnabled;
  void onCommit(String text);
}

/// What the window needs from the connection to the host.
abstract interface class AndroidHostLink {
  /// Sends a frame; [buffer]'s descriptor travels with it when given.
  void send(Uint8List frame, {AndroidSharedBuffer? buffer});
}

/// Two shared buffers the host copies to its surface in turn.
///
/// The rasterizer draws into the one the host is not reading; [present]
/// names it to the host and flips. RGBA because that is `ARGB_8888`'s byte
/// order in an Android `Bitmap`, so the host copies without swizzling.
final class AndroidCpuSurface implements RetainedCpuSurface {
  AndroidCpuSurface._(this._window, this.generation, this.scale, this._slots);

  final AndroidWindow _window;
  final List<_Slot> _slots;
  int _back = 0;

  @override
  final int generation;

  @override
  final double scale;

  @override
  String get kind => androidCpuSurfaceKind;

  @override
  Framebuffer get framebuffer => _slots[_back].framebuffer;

  @override
  int get pixelWidth => _slots.first.framebuffer.width;

  @override
  int get pixelHeight => _slots.first.framebuffer.height;

  @override
  BackendDiagnostic? present({Rect? damage}) {
    if (!identical(_window._surface, this)) {
      return const BackendDiagnostic.note('stale Android surface');
    }
    final _Slot slot = _slots[_back];
    slot.inFlight = true;
    _window._link.send(AndroidHostEncoder.present(_back));
    // Next frame into the other buffer, unless the host still has it.
    final int other = 1 - _back;
    if (!_slots[other].inFlight) _back = other;
    return null;
  }

  void _presented(int slot) {
    if (slot >= 0 && slot < _slots.length) _slots[slot].inFlight = false;
  }

  void _release() {
    for (final _Slot slot in _slots) {
      slot.buffer.release();
    }
  }
}

final class _Slot {
  _Slot(this.buffer, this.framebuffer);
  final AndroidSharedBuffer buffer;
  final Framebuffer framebuffer;
  bool inFlight = false;
}

/// The activity's surface, as a [NativeWindow].
///
/// One per process: the activity is the window, so there is nothing to
/// move, resize or title except for the task switcher. Sizes arrive from
/// the host in pixels; the framework sees them divided by the density.
final class AndroidWindow
    with DisposableMixin
    implements NativeWindow, RetainedCpuWindow {
  AndroidWindow({
    required NativeWindowId id,
    required AndroidHostLink link,
    required int widthPx,
    required int heightPx,
    required double density,
    required String title,
    required void Function(AndroidWindow window) onClosed,
  })  : _id = id,
        _link = link,
        _widthPx = widthPx,
        _heightPx = heightPx,
        _density = density,
        _onClosed = onClosed {
    setTitle(title);
    _rebuildSurface();
  }

  final NativeWindowId _id;
  final AndroidHostLink _link;
  final void Function(AndroidWindow window) _onClosed;
  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();
  final List<BackendDiagnostic> _diagnostics = <BackendDiagnostic>[];
  int _widthPx;
  int _heightPx;
  double _density;
  AndroidCpuSurface? _surface;
  bool _closedEmitted = false;

  /// The field the keyboard types into, when one is focused. Text the
  /// keyboard commits goes there; without one it is plain typing.
  AndroidImeHandler? textInput;

  List<BackendDiagnostic> get diagnostics =>
      List<BackendDiagnostic>.unmodifiable(_diagnostics);

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize => Size(_widthPx / _density, _heightPx / _density);

  @override
  double get renderScale => _density;

  @override
  double get desktopScale => _density;

  @override
  WindowState get state => WindowState.fullscreen;

  @override
  List<NativeSurfaceDescriptor> get surfaces {
    final AndroidCpuSurface? surface = _surface;
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
  void show() => requestRedraw();

  @override
  void hide() {}

  @override
  void close() => dispose();

  @override
  void setTitle(String value) {
    if (!isDisposed) _link.send(AndroidHostEncoder.title(value));
  }

  /// The activity fills its task: bounds are the host's, not the app's.
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

  /// The activity has no position on a screen the app can see.
  @override
  Offset screenToClient(Offset screenPosition) => screenPosition;

  @override
  Offset clientToScreen(Offset clientPosition) => clientPosition;

  /// Raises or hides the soft keyboard.
  void showKeyboard({required bool show}) {
    if (!isDisposed) _link.send(AndroidHostEncoder.keyboard(show: show));
  }

  // -------------------------------------------------------------------------
  // From the host
  // -------------------------------------------------------------------------

  void handle(AndroidHostEvent event) {
    if (isDisposed) return;
    final int generation = _generation.current;
    switch (event) {
      case AndroidResizedEvent():
        if (event.widthPx == _widthPx &&
            event.heightPx == _heightPx &&
            event.density == _density) {
          requestRedraw();
          return;
        }
        final bool scaleChanged = event.density != _density;
        _widthPx = event.widthPx;
        _heightPx = event.heightPx;
        _density = event.density;
        _generation.invalidate();
        _rebuildSurface();
        if (scaleChanged) {
          _emit(WindowScaleChangedEvent(
            windowId: _id,
            generation: _generation.current,
            renderScale: _density,
            desktopScale: _density,
          ));
        }
        _emit(WindowResizedEvent(
          windowId: _id,
          generation: _generation.current,
          clientSize: clientSize,
          renderScale: _density,
        ));
      case AndroidPresentedEvent():
        _surface?._presented(event.slot);
      case AndroidPointerEvent():
        _pointer(event, generation);
      case AndroidScrollEvent():
        _emit(PointerScrollEvent(
          windowId: _id,
          generation: generation,
          timestamp: _now(),
          pointerId: 0,
          kind: PointerKind.mouse,
          logicalPosition: Offset(event.x / _density, event.y / _density),
          // Android's axes are the content's direction; the framework's
          // deltas are the offset's, like every other backend's.
          scrollDelta: Offset(-event.dx, -event.dy),
          scrollDeltaUnit: ScrollDeltaUnit.lines,
        ));
      case AndroidKeyEvent():
        _key(event, generation);
      case AndroidTextEvent():
        final AndroidImeHandler? ime = textInput;
        if (ime != null && ime.isEnabled) {
          ime.onCommit(event.text);
        } else if (event.text.isNotEmpty) {
          _emit(TextInputEvent(
            windowId: _id,
            generation: generation,
            timestamp: _now(),
            text: event.text,
          ));
        }
      case AndroidFocusEvent():
        _emit(WindowActivationEvent(
          windowId: _id,
          generation: generation,
          activation: event.focused
              ? WindowActivation.activated
              : WindowActivation.deactivated,
        ));
      case AndroidVisibilityEvent():
        if (event.visible) requestRedraw();
      case AndroidBackEvent():
        _emit(WindowCloseRequestedEvent(windowId: _id, generation: generation));
      case AndroidSurfaceLostEvent():
        // Nothing presented now would show; the next resize - the host
        // sends one when a surface comes back - redraws.
        for (final _Slot slot in _surface?._slots ?? const <_Slot>[]) {
          slot.inFlight = false;
        }
      case AndroidHelloEvent() || AndroidUnknownEvent():
        break;
    }
  }

  void _pointer(AndroidPointerEvent event, int generation) {
    final Offset position = Offset(event.x / _density, event.y / _density);
    final PointerKind kind = androidPointerKind(event.toolType);
    final Duration timestamp =
        Duration(microseconds: event.eventTimeNanos ~/ 1000);
    final PointerButton button =
        androidPointerButton(event.toolType, event.buttonState);
    _emit(switch (event.action) {
      AndroidPointerAction.down => PointerDownEvent(
          windowId: _id,
          generation: generation,
          timestamp: timestamp,
          pointerId: event.pointerId,
          kind: kind,
          logicalPosition: position,
          button: button,
        ),
      AndroidPointerAction.move => PointerMoveEvent(
          windowId: _id,
          generation: generation,
          timestamp: timestamp,
          pointerId: event.pointerId,
          kind: kind,
          logicalPosition: position,
        ),
      AndroidPointerAction.up => PointerUpEvent(
          windowId: _id,
          generation: generation,
          timestamp: timestamp,
          pointerId: event.pointerId,
          kind: kind,
          logicalPosition: position,
          button: button,
        ),
      AndroidPointerAction.cancel => PointerCancelEvent(
          windowId: _id,
          generation: generation,
          timestamp: timestamp,
          pointerId: event.pointerId,
          kind: kind,
          logicalPosition: position,
        ),
    });
  }

  void _key(AndroidKeyEvent event, int generation) {
    final Duration timestamp = _now();
    final int logical = androidLogicalKey(event.keyCode);
    final Set<KeyModifier> modifiers = androidKeyModifiers(event.metaState);
    final KeyLocation location = androidKeyLocation(event.keyCode);
    _emit(event.down
        ? KeyDownEvent(
            windowId: _id,
            generation: generation,
            timestamp: timestamp,
            physicalKey: event.keyCode,
            logicalKey: logical,
            modifiers: modifiers,
            isRepeat: event.repeatCount > 0,
            location: location,
          )
        : KeyUpEvent(
            windowId: _id,
            generation: generation,
            timestamp: timestamp,
            physicalKey: event.keyCode,
            logicalKey: logical,
            modifiers: modifiers,
            location: location,
          ));
    if (!event.down) return;
    final String? text = androidKeyText(event.unicodeChar, event.metaState);
    if (text != null) {
      _emit(TextInputEvent(
        windowId: _id,
        generation: generation,
        timestamp: timestamp,
        text: text,
      ));
    }
  }

  static final Stopwatch _clock = Stopwatch()..start();
  static Duration _now() => _clock.elapsed;

  // -------------------------------------------------------------------------
  // Surface
  // -------------------------------------------------------------------------

  void _rebuildSurface() {
    _surface?._release();
    _surface = null;
    if (_widthPx <= 0 || _heightPx <= 0) return;
    final int bytesPerRow = _widthPx * 4;
    final int byteSize = bytesPerRow * _heightPx;
    final List<_Slot> slots = <_Slot>[];
    for (var index = 0; index < 2; index++) {
      final AndroidSharedBuffer buffer =
          AndroidSharedBuffer.create(byteSize, name: 'dart_ui_frame_$index');
      slots.add(_Slot(
        buffer,
        Framebuffer.wrap(
          buffer.bytes,
          width: _widthPx,
          height: _heightPx,
          bytesPerRow: bytesPerRow,
          format: PixelFormat.rgba8888Premultiplied,
        ),
      ));
      _link.send(
        AndroidHostEncoder.surface(
          slot: index,
          widthPx: _widthPx,
          heightPx: _heightPx,
          bytesPerRow: bytesPerRow,
          byteSize: byteSize,
        ),
        buffer: buffer,
      );
    }
    _surface = AndroidCpuSurface._(this, _generation.current, _density, slots);
  }

  void _emit(PlatformWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  void onDispose() {
    _generation.invalidate();
    _surface?._release();
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
