/// A window backed by a `<canvas>` element, and the DOM listeners that feed it.
///
/// This is the thin half of the web backend's input path. The other half -
/// every rule about which DOM property may become text and what a numeric
/// keypad does - is in `dom_input_translation.dart`, in pure Dart with no DOM
/// types in any signature, so `dart test` on a Linux container exercises it on
/// the VM. This file is the part that genuinely needs a browser, and it is kept
/// as small as that split allows: it reads properties off events and calls in
/// there.
///
/// ## What a "window" is on a page
///
/// There is no window here in the sense Win32 or X11 mean. A page cannot create
/// a top-level window, cannot position one, and must not try - `window.open` is
/// a popup, which browsers block and users resent. So [WebWindow] wraps a
/// `<canvas>` the page already has (or one it appends to a host element), and
/// answers the [NativeWindow] contract about *that*:
///
///   * [clientSize] is the canvas's CSS size in logical units, which is what
///     the page's layout decided.
///   * [renderScale] is `devicePixelRatio`, and the backing store is sized to
///     `clientSize * renderScale`. That is the whole HiDPI story on the web,
///     and it is why the two are separate fields rather than one.
///   * [setBounds], [setTitle] and [setCursor] do the honest browser
///     equivalents - a CSS size, `document.title`, a CSS `cursor` - and
///     [setBounds]'s position component is ignored with a comment saying so,
///     because a page cannot move itself on the desktop and pretending
///     otherwise would be a silent no-op.
///   * [close] removes the listeners and stops the stream. It does not remove
///     the canvas: the page created it.
///
/// ## The rule this file exists to obey
///
/// **Text comes from `beforeinput` and from `KeyboardEvent.key`. Never from
/// `code`, never from `keyCode`.** Those two are hardware identity and feed
/// [KeyEvent] only, where a shortcut table reads them.
///
/// The bug that rule comes from is real and this platform reproduces it
/// exactly: `VK_NUMPAD1` is 0x61, `String.fromCharCode(0x61)` is `a`, and a
/// backend that derived text from the virtual key typed `a` when the user
/// pressed the keypad's `1`. On the web `KeyboardEvent.keyCode` for `Numpad1`
/// is *also* 97. Nothing about running in a browser fixes it. See
/// `dom_input_translation.dart`, which is where the refusal is implemented and
/// where it is unit-tested without a browser.
///
/// ## Which of the two text sources is used, and how the choice is made
///
/// Both exist because neither is sufficient alone:
///
///   * **`beforeinput`** is the only source that survives an input method. It
///     is the browser's own answer after the layout, the dead-key state machine
///     and any IME have had their say. But it only fires at a *focused editable
///     element*, and an application drawing its own text field into a canvas
///     has none.
///   * **`KeyboardEvent.key`** works with nothing focused, but an IME never
///     reports through it - it reports `Process` - so it cannot be the primary.
///
/// The choice between them is made by [isTextInputActive], which the
/// application sets through [startTextInput] and [stopTextInput], and it is a
/// *state*, not a race. That matters: the DOM fires `keydown` **before**
/// `beforeinput`, so a backend that tried to decide per keystroke - "emit the
/// fallback unless a `beforeinput` is about to arrive" - would be guessing at
/// the future, and the two obvious implementations of that guess produce either
/// a doubled character or a dropped one. Asking a flag that was set before the
/// keystroke has neither failure.
///
/// When text input is active a hidden, focused editable element exists,
/// `beforeinput` fires on it, and `keydown` emits **no text at all**. When it
/// is not, there is no editable element, `beforeinput` cannot fire, and
/// `keydown` uses the conservative [webKeyboardTextFromKey] fallback. Either
/// way exactly one source is live.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/size.dart';
import '../../platform/input_events.dart';
import '../../platform/native_window.dart';
import '../../platform/window_events.dart';
import '../../rendering/gpu/webgl/webgl_surface_descriptor.dart';
import '../../rendering/renderer.dart';
import 'dom_input_translation.dart';

/// The CSS `cursor` keyword each [SystemCursor] maps to.
///
/// A table rather than a switch at the call site so the whole mapping is
/// readable at once, and because two of them are worth explaining:
/// [SystemCursor.resizeDiagonalDown] is `nwse-resize` (north-west to
/// south-east, the cursor for a top-left or bottom-right corner) and
/// [SystemCursor.resizeDiagonalUp] is `nesw-resize`. Getting the pair the wrong
/// way round is invisible in a screenshot and immediately wrong under the hand.
const Map<SystemCursor, String> kWebCursorNames = <SystemCursor, String>{
  SystemCursor.arrow: 'default',
  SystemCursor.text: 'text',
  SystemCursor.hand: 'pointer',
  SystemCursor.resizeHorizontal: 'ew-resize',
  SystemCursor.resizeVertical: 'ns-resize',
  SystemCursor.resizeDiagonalDown: 'nwse-resize',
  SystemCursor.resizeDiagonalUp: 'nesw-resize',
  SystemCursor.wait: 'wait',
  SystemCursor.crosshair: 'crosshair',
  SystemCursor.notAllowed: 'not-allowed',
};

/// A [NativeWindow] over one `<canvas>` element.
final class WebWindow with DisposableMixin implements NativeWindow {
  WebWindow._({
    required NativeWindowId id,
    required this.canvas,
    required this.ownsCanvas,
    required String title,
  })  : _id = id,
        _title = title {
    _attachListeners();
    // The canvas has to be focusable or it will never receive a key event: the
    // DOM only delivers keyboard events to the focused element, and an element
    // with no `tabindex` cannot be focused at all. -1 rather than 0 keeps it
    // out of the document's tab order, which is right for an element that is a
    // whole application rather than one control in a form.
    if (!canvas.hasAttribute('tabindex')) {
      canvas.setAttribute('tabindex', '-1');
    }
    // Touch on a canvas otherwise scrolls and pinch-zooms the page, and the
    // pointer events that would have described the gesture are cancelled part
    // way through. `touch-action: none` is what tells the browser this element
    // handles its own gestures; setting it in CSS is the only way to say so -
    // preventDefault on the pointer event is too late by then.
    canvas.style.touchAction = 'none';
    _syncSizeFromDom();
  }

  /// Wraps [canvas], which the page owns.
  ///
  /// The canvas is **borrowed**: [close] and [dispose] remove this window's
  /// listeners and leave the element exactly where the page put it. That is the
  /// same ownership rule `WebGlCanvasSurfaceDescriptor` states, and it is the
  /// only one that composes with an application that also uses the DOM.
  static WebWindow wrap(
    web.HTMLCanvasElement canvas, {
    NativeWindowId id = const NativeWindowId(1),
    String title = 'dart_ui',
  }) =>
      WebWindow._(id: id, canvas: canvas, ownsCanvas: false, title: title);

  /// Creates a canvas inside [host] and wraps it.
  ///
  /// [ownsCanvas] is true for the result, so [close] removes the element it
  /// made - the symmetric rule to [wrap]'s. The canvas is given a CSS size of
  /// [size] in logical units and a backing store of that times the device pixel
  /// ratio; see [_syncSizeFromDom] for why the two are always set together.
  static WebWindow createIn(
    web.Element host, {
    required Size size,
    NativeWindowId id = const NativeWindowId(1),
    String title = 'dart_ui',
  }) {
    final web.HTMLCanvasElement canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    canvas.style
      ..width = '${size.width}px'
      ..height = '${size.height}px'
      ..display = 'block';
    host.append(canvas);
    return WebWindow._(id: id, canvas: canvas, ownsCanvas: true, title: title);
  }

  /// The element this window draws into and listens on.
  final web.HTMLCanvasElement canvas;

  /// Whether [close] should remove [canvas] from the document.
  final bool ownsCanvas;

  final NativeWindowId _id;
  String _title;

  final GenerationToken _generation = GenerationToken();
  final StreamController<PlatformWindowEvent> _events =
      StreamController<PlatformWindowEvent>.broadcast();

  Size _clientSize = const Size(0, 0);
  double _renderScale = 1;

  /// The time origin every event timestamp is measured from.
  ///
  /// `DOMHighResTimeStamp` is already milliseconds since the page's time
  /// origin, monotonic, and the same origin for every event on the page - which
  /// is exactly what [PlatformInputEvent.timestamp] asks for. It is converted
  /// to microseconds rather than milliseconds because [Duration] has no
  /// fractional part and a millisecond-resolution timestamp would quantise away
  /// the sub-frame precision a gesture recogniser uses to compute velocity.
  static Duration _timestampOf(num domHighResMilliseconds) =>
      Duration(microseconds: (domHighResMilliseconds * 1000).round());

  @override
  NativeWindowId get id => _id;

  @override
  int get generation => _generation.current;

  @override
  Size get clientSize => _clientSize;

  @override
  double get renderScale => _renderScale;

  /// The same number as [renderScale] on the web, and separate anyway.
  ///
  /// A browser exposes exactly one scale - `devicePixelRatio` - and no
  /// equivalent of the desktop's text-size setting, so there is nothing else to
  /// report here. The field stays distinct because the *contract* distinguishes
  /// them and a caller written against a mixed-DPI desktop must go on
  /// compiling; answering the same number is the honest answer for this
  /// platform, not a conflation.
  @override
  double get desktopScale => _renderScale;

  /// Always [WindowState.normal].
  ///
  /// A page has no minimised or maximised state to report. Fullscreen is a real
  /// browser capability, but it belongs to an element rather than to a window
  /// and is entered by a user gesture through the Fullscreen API; reporting it
  /// here would mean claiming a state this class does not manage.
  @override
  WindowState get state => WindowState.normal;

  /// The one surface a canvas offers.
  ///
  /// Only a WebGL2 descriptor, and no CPU one. That is not an omission: a
  /// canvas can hold exactly one context for its lifetime, so offering both a
  /// GPU and a CPU surface would be offering a choice that cannot be taken
  /// twice - asking for the second after the first would return null and read
  /// as a driver failure. A page that wants CPU rasterisation puts a
  /// `2d` context on its own canvas; this backend is the GPU one.
  @override
  List<NativeSurfaceDescriptor> get surfaces => isDisposed
      ? const <NativeSurfaceDescriptor>[]
      : <NativeSurfaceDescriptor>[
          WebGlCanvasSurfaceDescriptor(
            canvas: canvas,
            generation: _generation,
            scale: _renderScale,
          ),
        ];

  @override
  Stream<PlatformWindowEvent> get events => _events.stream;

  /// Makes the canvas visible and focuses it.
  ///
  /// The focus is the part that matters and the part that is easy to leave out:
  /// an unfocused canvas receives pointer events but no key events at all, so a
  /// window that showed without focusing would look like a keyboard that had
  /// stopped working.
  @override
  void show() {
    throwIfDisposed();
    canvas.style.display = 'block';
    canvas.focus();
    _emit(WindowActivationEvent(
      windowId: _id,
      generation: generation,
      activation: WindowActivation.activated,
    ));
  }

  @override
  void hide() {
    throwIfDisposed();
    canvas.style.display = 'none';
  }

  @override
  void close() {
    if (isDisposed) return;
    _emit(WindowClosedEvent(windowId: _id, generation: generation));
    dispose();
  }

  @override
  void setTitle(String value) {
    throwIfDisposed();
    _title = value;
    // The tab's title is the closest thing a page has to a window title, and it
    // is genuinely global: a second WebWindow calling this overwrites the
    // first. Documented rather than guarded, because a page with two canvases
    // still has one tab and there is no per-element title to set instead.
    web.document.title = value;
  }

  String get title => _title;

  /// Resizes the canvas. **The position is ignored.**
  ///
  /// A page cannot move itself on the desktop, and there is no browser API that
  /// would let it. Silently accepting `bounds.left` and `bounds.top` and doing
  /// nothing with them would be the quiet failure section 6.6 forbids, so it is
  /// stated here instead: only the size is honoured, and a caller that needs to
  /// position the canvas within the page does it with CSS on the host element,
  /// which is the page's layout decision rather than the window's.
  @override
  void setBounds(Rect bounds) {
    throwIfDisposed();
    canvas.style
      ..width = '${bounds.width}px'
      ..height = '${bounds.height}px';
    _syncSizeFromDom();
  }

  @override
  void setCursor(SystemCursor cursor) {
    throwIfDisposed();
    canvas.style.cursor = kWebCursorNames[cursor] ?? 'default';
  }

  /// Asks for a repaint by emitting [WindowExposedEvent].
  ///
  /// The frame is not scheduled here. A browser's frame clock is
  /// `requestAnimationFrame`, which is the application's scheduler to drive -
  /// this reports "something needs redrawing", and the frame loop above decides
  /// when. A window that called `requestAnimationFrame` itself would be a
  /// second clock competing with that one, and two of them produce a frame
  /// budget nobody can account for.
  @override
  void requestRedraw([Rect? dirtyRect]) {
    throwIfDisposed();
    _emit(WindowExposedEvent(
      windowId: _id,
      generation: generation,
      dirtyRect: dirtyRect,
    ));
  }

  @override
  Offset screenToClient(Offset screenPosition) {
    final web.DOMRect box = canvas.getBoundingClientRect();
    // `screenX`/`screenY` are relative to the user's screen and the bounding
    // box is relative to the viewport, so the page's own scroll and the
    // browser's chrome both sit between them. `window.screenX` plus the scroll
    // offset is the bridge.
    return Offset(
      screenPosition.dx - box.x - web.window.screenX - web.window.scrollX,
      screenPosition.dy - box.y - web.window.screenY - web.window.scrollY,
    );
  }

  @override
  Offset clientToScreen(Offset clientPosition) {
    final web.DOMRect box = canvas.getBoundingClientRect();
    return Offset(
      clientPosition.dx + box.x + web.window.screenX + web.window.scrollX,
      clientPosition.dy + box.y + web.window.screenY + web.window.scrollY,
    );
  }

  // -------------------------------------------------------------------
  // Size and scale
  // -------------------------------------------------------------------

  /// Reads the canvas's CSS size and the device pixel ratio, and reconciles the
  /// backing store with them.
  ///
  /// The three numbers a canvas has are routinely confused and only one of them
  /// is the framebuffer:
  ///
  ///   * `getBoundingClientRect()` is the **CSS size**, in logical units. This
  ///     is [clientSize] and it is what the page's layout produced.
  ///   * `devicePixelRatio` is [renderScale].
  ///   * `canvas.width`/`canvas.height` are the **backing store**, in physical
  ///     pixels, and they are what a renderer allocates and sets a viewport
  ///     from. They are *not* set by CSS and do not follow it: a canvas left at
  ///     its default 300x150 backing store inside a 1200x800 CSS box is
  ///     stretched by the compositor, which is the classic "everything is
  ///     blurry" bug.
  ///
  /// So this multiplies the first by the second and writes the third. Assigning
  /// `width`/`height` also *clears* the drawing buffer, which is why it is done
  /// only when the value actually changes - doing it unconditionally would blank
  /// the canvas on every frame that asked for its size.
  ///
  /// Bumps the [GenerationToken] when anything changed, which is what makes a
  /// frame recorded for the old size get dropped instead of drawn stretched.
  void _syncSizeFromDom() {
    final web.DOMRect box = canvas.getBoundingClientRect();
    final double ratio = web.window.devicePixelRatio;
    // A canvas that is display:none, or not yet laid out, measures 0x0. Its
    // backing store must not be set to zero - a zero-sized drawing buffer makes
    // every WebGL call that references it fail - so the previous size is kept
    // and the reconcile is left for the next call, when layout has run.
    final double cssWidth = box.width > 0 ? box.width : _clientSize.width;
    final double cssHeight = box.height > 0 ? box.height : _clientSize.height;
    final Size clientSize = Size(cssWidth, cssHeight);
    final int pixelWidth = (cssWidth * ratio).round();
    final int pixelHeight = (cssHeight * ratio).round();

    final bool sizeChanged = clientSize != _clientSize;
    final bool scaleChanged = ratio != _renderScale;
    if (!sizeChanged && !scaleChanged) return;

    _clientSize = clientSize;
    _renderScale = ratio;

    if (pixelWidth > 0 &&
        pixelHeight > 0 &&
        (canvas.width != pixelWidth || canvas.height != pixelHeight)) {
      canvas
        ..width = pixelWidth
        ..height = pixelHeight;
    }
    _generation.invalidate();

    if (scaleChanged) {
      _emit(WindowScaleChangedEvent(
        windowId: _id,
        generation: generation,
        renderScale: ratio,
        desktopScale: ratio,
      ));
    }
    if (sizeChanged) {
      _emit(WindowResizedEvent(
        windowId: _id,
        generation: generation,
        clientSize: clientSize,
        renderScale: ratio,
      ));
    }
  }

  /// Re-reads the canvas's size from the DOM, emitting events if it changed.
  ///
  /// Public because the page's layout is not this class's to observe: a
  /// `ResizeObserver` is one way, a `window.onresize` handler another, and an
  /// application that resizes its own container knows without either. Whoever
  /// knows calls this. [WebWindowingBackend] wires a `ResizeObserver` for the
  /// windows it creates, which covers the common case.
  void syncSize() {
    if (isDisposed) return;
    _syncSizeFromDom();
  }

  // -------------------------------------------------------------------
  // Text input mode
  // -------------------------------------------------------------------

  /// Whether an editable element is focused and `beforeinput` is the text
  /// source. See the library comment for why this is a state and not a race.
  bool get isTextInputActive => _textInputHost != null;

  web.HTMLElement? _textInputHost;

  /// Starts routing text through a hidden editable element.
  ///
  /// Called when the application focuses a text field it is drawing itself. The
  /// element is what makes an input method possible at all: an IME needs
  /// somewhere to compose, and a canvas is not somewhere. It is positioned off
  /// the visible area rather than given `display: none`, because a hidden
  /// element cannot be focused and an unfocused one receives nothing.
  ///
  /// While this is active, `keydown` emits no text - every character arrives
  /// through `beforeinput` instead, which is the only path an IME's output can
  /// take.
  void startTextInput() {
    throwIfDisposed();
    if (_textInputHost != null) return;
    final web.HTMLElement host =
        web.document.createElement('div') as web.HTMLElement;
    host
      ..setAttribute('contenteditable', 'true')
      // Off-screen rather than hidden: an element with `display: none` or
      // `visibility: hidden` cannot take focus, and an unfocused element gets
      // no `beforeinput` at all.
      ..style.position = 'absolute'
      ..style.left = '-9999px'
      ..style.top = '0'
      ..style.width = '1px'
      ..style.height = '1px'
      ..style.opacity = '0'
      // Off, all four: an application drawing its own text field does its own
      // correction, and a browser that autocapitalised or autocorrected on top
      // would insert text the application never saw a keystroke for.
      ..setAttribute('autocapitalize', 'off')
      ..setAttribute('autocorrect', 'off')
      ..setAttribute('autocomplete', 'off')
      ..setAttribute('spellcheck', 'false');
    web.document.body?.append(host);
    host
      ..addEventListener('beforeinput', _onBeforeInput)
      ..addEventListener('keydown', _onKeyDown)
      ..addEventListener('keyup', _onKeyUp)
      ..focus();
    _textInputHost = host;
  }

  /// Stops routing text through the hidden element and returns focus to the
  /// canvas.
  ///
  /// The assembler is not reset here because there is none: `beforeinput` hands
  /// over whole strings rather than the UTF-16 drip Win32 and X11 deliver, so
  /// [sanitiseWebTextInput] applies the two rules over a string and nothing is
  /// ever held between events.
  void stopTextInput() {
    final web.HTMLElement? host = _textInputHost;
    if (host == null) return;
    _textInputHost = null;
    host
      ..removeEventListener('beforeinput', _onBeforeInput)
      ..removeEventListener('keydown', _onKeyDown)
      ..removeEventListener('keyup', _onKeyUp)
      ..remove();
    if (!isDisposed) canvas.focus();
  }

  // -------------------------------------------------------------------
  // DOM listeners
  // -------------------------------------------------------------------

  late final JSFunction _onPointerDown = _pointerDown.toJS;
  late final JSFunction _onPointerUp = _pointerUp.toJS;
  late final JSFunction _onPointerMove = _pointerMove.toJS;
  late final JSFunction _onPointerCancel = _pointerCancel.toJS;
  late final JSFunction _onWheel = _wheel.toJS;
  late final JSFunction _onKeyDown = _keyDown.toJS;
  late final JSFunction _onKeyUp = _keyUp.toJS;
  late final JSFunction _onBeforeInput = _beforeInput.toJS;
  late final JSFunction _onFocus = _focus.toJS;
  late final JSFunction _onBlur = _blur.toJS;
  late final JSFunction _onContextMenu = _contextMenu.toJS;

  void _attachListeners() {
    canvas
      ..addEventListener('pointerdown', _onPointerDown)
      ..addEventListener('pointerup', _onPointerUp)
      ..addEventListener('pointermove', _onPointerMove)
      ..addEventListener('pointercancel', _onPointerCancel)
      ..addEventListener('keydown', _onKeyDown)
      ..addEventListener('keyup', _onKeyUp)
      ..addEventListener('focus', _onFocus)
      ..addEventListener('blur', _onBlur)
      ..addEventListener('contextmenu', _onContextMenu)
      // Not passive. The default for `wheel` on a page is passive, which makes
      // `preventDefault` a no-op and lets the page scroll underneath an
      // application that is handling the scroll itself. Saying `passive: false`
      // is the only way to keep the wheel.
      ..addEventListener('wheel', _onWheel, _listenerOptions(passive: false));
  }

  void _detachListeners() {
    canvas
      ..removeEventListener('pointerdown', _onPointerDown)
      ..removeEventListener('pointerup', _onPointerUp)
      ..removeEventListener('pointermove', _onPointerMove)
      ..removeEventListener('pointercancel', _onPointerCancel)
      ..removeEventListener('keydown', _onKeyDown)
      ..removeEventListener('keyup', _onKeyUp)
      ..removeEventListener('focus', _onFocus)
      ..removeEventListener('blur', _onBlur)
      ..removeEventListener('contextmenu', _onContextMenu)
      ..removeEventListener('wheel', _onWheel);
  }

  static JSObject _listenerOptions({required bool passive}) =>
      _AddEventListenerOptions(passive: passive);

  // ---- pointer ----

  /// The position of a pointer event in this window's logical units.
  ///
  /// `offsetX`/`offsetY` are already relative to the target element's padding
  /// box and already in CSS pixels, which is exactly [PointerEvent.
  /// logicalPosition]'s contract - logical units within the client area. They
  /// are **not** multiplied by [renderScale]: doing so would produce physical
  /// pixels, which is what the *renderer* works in and what a hit test must
  /// never see, and on a HiDPI screen every touch would land at twice its
  /// distance from the top-left corner.
  Offset _positionOf(web.PointerEvent event) =>
      Offset(event.offsetX.toDouble(), event.offsetY.toDouble());

  void _pointerDown(web.PointerEvent event) {
    if (isDisposed) return;
    final PointerButton? button = webPointerButton(event.button);
    if (button == null) return;
    // Capture, so a drag that leaves the canvas still reports its moves and its
    // release here. Without it a press that ends outside the element produces
    // no `pointerup` at all and the gesture is left open forever - the drag
    // that sticks to the cursor, which is the single most common bug in
    // canvas-based input.
    try {
      canvas.setPointerCapture(event.pointerId);
    } on Object {
      // A synthetic event from a driver may carry a pointer id the element
      // never saw, and capturing it throws. The press is still real.
    }
    // The canvas is focusable but a click does not focus it in every browser,
    // and an unfocused canvas gets no key events.
    if (!isTextInputActive) canvas.focus();
    _emit(PointerDownEvent(
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      pointerId: event.pointerId,
      kind: webPointerKind(event.pointerType),
      logicalPosition: _positionOf(event),
      button: button,
      clickCount: webClickCount(event.detail),
    ));
  }

  void _pointerUp(web.PointerEvent event) {
    if (isDisposed) return;
    final PointerButton? button = webPointerButton(event.button);
    if (button == null) return;
    try {
      canvas.releasePointerCapture(event.pointerId);
    } on Object {
      // Releasing a capture that was never taken is not an error worth
      // propagating out of an event handler.
    }
    _emit(PointerUpEvent(
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      pointerId: event.pointerId,
      kind: webPointerKind(event.pointerType),
      logicalPosition: _positionOf(event),
      button: button,
    ));
  }

  void _pointerMove(web.PointerEvent event) {
    if (isDisposed) return;
    _emit(PointerMoveEvent(
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      pointerId: event.pointerId,
      kind: webPointerKind(event.pointerType),
      logicalPosition: _positionOf(event),
    ));
  }

  /// `pointercancel`: the browser took the gesture away.
  ///
  /// It fires when the user agent decides the pointer will no longer produce
  /// events - a touch became a browser gesture, the device was disconnected. It
  /// is exactly what [PointerCancelEvent] documents, and translating it to a
  /// [PointerUpEvent] instead would complete a gesture the user abandoned.
  void _pointerCancel(web.PointerEvent event) {
    if (isDisposed) return;
    _emit(PointerCancelEvent(
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      pointerId: event.pointerId,
      kind: webPointerKind(event.pointerType),
      logicalPosition: _positionOf(event),
    ));
  }

  void _wheel(web.WheelEvent event) {
    if (isDisposed) return;
    // The page must not scroll under an application that is handling the
    // scroll. This is why the listener is registered non-passively.
    event.preventDefault();
    final ({Offset delta, ScrollDeltaUnit unit}) scroll = webScrollDelta(
      deltaX: event.deltaX,
      deltaY: event.deltaY,
      deltaMode: event.deltaMode,
    );
    _emit(PointerScrollEvent(
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      pointerId: 0,
      kind: PointerKind.mouse,
      logicalPosition:
          Offset(event.offsetX.toDouble(), event.offsetY.toDouble()),
      scrollDelta: scroll.delta,
      scrollDeltaUnit: scroll.unit,
    ));
  }

  // ---- keyboard ----

  /// `keydown`: the hardware half, and - only when no editable is focused - the
  /// conservative text fallback.
  ///
  /// The [KeyDownEvent] carries `code` as the physical key (through the HID
  /// table) and `keyCode` as the logical one. **Neither becomes text.** See the
  /// library comment and `dom_input_translation.dart` for the bug that rule
  /// exists to prevent.
  void _keyDown(web.KeyboardEvent event) {
    if (isDisposed) return;
    final Set<KeyModifier> modifiers = webKeyModifiers(
      shift: event.shiftKey,
      control: event.ctrlKey,
      alt: event.altKey,
      meta: event.metaKey,
      capsLock: event.getModifierState('CapsLock'),
      numLock: event.getModifierState('NumLock'),
      scrollLock: event.getModifierState('ScrollLock'),
    );
    _emit(webKeyEventFrom(
      isDown: true,
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      code: event.code,
      keyCode: event.keyCode,
      domLocation: event.location,
      modifiers: modifiers,
      isRepeat: event.repeat,
    ));

    // The fallback, and only when nothing editable is focused. With text input
    // active this keystroke's character is about to arrive through
    // `beforeinput`, and emitting it here as well would type it twice.
    if (isTextInputActive) return;
    final String? text = webKeyboardTextFromKey(
      key: event.key,
      control: event.ctrlKey,
      meta: event.metaKey,
    );
    if (text == null) return;
    _emit(TextInputEvent(
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      text: text,
    ));
  }

  void _keyUp(web.KeyboardEvent event) {
    if (isDisposed) return;
    _emit(webKeyEventFrom(
      isDown: false,
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      code: event.code,
      keyCode: event.keyCode,
      domLocation: event.location,
      modifiers: webKeyModifiers(
        shift: event.shiftKey,
        control: event.ctrlKey,
        alt: event.altKey,
        meta: event.metaKey,
        capsLock: event.getModifierState('CapsLock'),
        numLock: event.getModifierState('NumLock'),
        scrollLock: event.getModifierState('ScrollLock'),
      ),
    ));
  }

  /// `beforeinput`: the primary text source, and the only one an IME reaches.
  ///
  /// The event is cancelled with `preventDefault` because the hidden editable
  /// must never actually accumulate the text: it exists to give an input method
  /// somewhere to compose, and a `div` that filled up with everything the user
  /// has ever typed would grow without bound and would start reporting
  /// selections and deletions against content the application does not have.
  ///
  /// `insertCompositionText` is deliberately *not* cancelled: an IME needs its
  /// in-progress composition to stay in the element or it cannot show the
  /// candidate it is composing. That is why the check is on the input type
  /// rather than unconditional.
  void _beforeInput(web.InputEvent event) {
    if (isDisposed) return;
    final String inputType = event.inputType;
    final String? text = webTextFromBeforeInput(
      inputType: inputType,
      data: event.data,
    );
    if (inputType != 'insertCompositionText') {
      event.preventDefault();
      // The element is emptied so a composition that did land cannot be
      // re-reported by the next event's selection.
      _textInputHost?.textContent = '';
    }
    if (text == null) return;
    _emit(TextInputEvent(
      windowId: _id,
      generation: generation,
      timestamp: _timestampOf(event.timeStamp),
      text: text,
    ));
  }

  // ---- focus ----

  void _focus(web.Event event) {
    if (isDisposed) return;
    _emit(WindowActivationEvent(
      windowId: _id,
      generation: generation,
      activation: WindowActivation.activated,
    ));
  }

  void _blur(web.Event event) {
    if (isDisposed) return;
    _emit(WindowActivationEvent(
      windowId: _id,
      generation: generation,
      activation: WindowActivation.deactivated,
    ));
  }

  /// Suppresses the browser's context menu so a right-click reaches the
  /// application.
  ///
  /// The `pointerdown` for button 2 has already been reported by the time this
  /// runs, so an application that wants a context menu draws its own. Letting
  /// the browser's appear as well would put a menu over the application's on
  /// every right-click.
  void _contextMenu(web.Event event) => event.preventDefault();

  void _emit(PlatformWindowEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  @override
  void onDispose() {
    _detachListeners();
    stopTextInput();
    // The canvas is removed only when this window made it. A wrapped canvas
    // belongs to the page.
    if (ownsCanvas) canvas.remove();
    _events.close();
  }
}

/// The `AddEventListenerOptions` dictionary.
///
/// An extension type with an `external factory` rather than an untyped object,
/// for the reason `webgl_surface_descriptor.dart` gives about the WebGL context
/// attributes: a misspelled key here would compile and silently leave the
/// listener passive, which is precisely the failure that lets the page scroll
/// under an application handling its own wheel.
/// Only `passive` is declared. `capture` and `once` are real members of the
/// dictionary and are left out because nothing here sets them: an unused
/// optional parameter is a lint, and adding one back is a one-line change at
/// the point a listener actually needs it.
extension type _AddEventListenerOptions._(JSObject _) implements JSObject {
  external factory _AddEventListenerOptions({bool passive});
}

/// The windowing backend for a browser.
///
/// ## What `pumpEvents` does here, and why it returns true
///
/// Every other backend in this repository owns a message loop:
/// `PeekMessage`/`DispatchMessage` on Win32, `xcb_poll_for_event` on X11. A
/// browser has neither, because the browser *is* the message loop - DOM events
/// are delivered to the listeners this backend registered, on the page's own
/// event loop, whether or not anybody calls anything.
///
/// So [pumpEvents] drains nothing and returns true. Returning false would mean
/// "the platform asked the application to stop", and a page is never asked: a
/// tab closing tears the whole isolate down without running any Dart. The
/// method exists to satisfy the interface and to let one frame-loop
/// implementation drive every backend, which is worth more than a method that
/// throws `UnsupportedError` on one platform out of four.
final class WebWindowingBackend implements WindowingBackend {
  WebWindowingBackend();

  static const String backendName = 'web';

  @override
  String get name => backendName;

  final List<WebWindow> _windows = <WebWindow>[];
  bool _initialised = false;

  /// The observers watching each window's canvas for a layout change.
  ///
  /// A `ResizeObserver` rather than `window.onresize`: the latter fires only
  /// when the *viewport* changes, and a canvas inside a flex or grid container
  /// can be resized by a sibling appearing without the viewport moving at all.
  /// That is the resize a renderer must not miss, because it is the one that
  /// leaves the backing store at the old size and the picture stretched.
  final Map<WebWindow, web.ResizeObserver> _observers =
      <WebWindow, web.ResizeObserver>{};

  /// Whether this backend can run here.
  ///
  /// Checks for a `document`, which is the one thing that distinguishes a page
  /// from the other JavaScript environments this code could be compiled into -
  /// a worker, or Node. A worker has `self` and no `document`, and every
  /// listener this backend registers would throw there.
  @override
  BackendProbeResult probe() {
    try {
      // Touching `document.documentElement` rather than testing for the
      // property: in a worker the global `document` is undefined, and reaching
      // through it raises a JavaScript TypeError that the catch below turns
      // into the named refusal. A property test would need
      // `dart:js_interop_unsafe`, which buys an untyped lookup for no extra
      // certainty - the thing that has to work is the dereference, so the
      // dereference is what is tried.
      if (web.document.documentElement == null) {
        return BackendProbeResult.unsupported(
          backendName,
          const BackendDiagnostic(
            kind: DiagnosticKind.unsupportedPlatform,
            message: 'there is no document, so there is no page to draw on',
            detail: 'this looks like a worker or a non-browser JavaScript '
                'host. The web backend needs a DOM: it wraps a canvas element '
                'and registers listeners on it',
          ),
        );
      }
      return BackendProbeResult(
        backendName: backendName,
        supported: true,
        capabilities: const <Capability>{
          Capability.window,
          // Several canvases on one page, which is the honest reading of
          // "several windows at once" here.
          Capability.multipleWindows,
          Capability.gpuPresentation,
        },
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.note(
            'a document is present',
            detail: 'device pixel ratio ${web.window.devicePixelRatio}',
          ),
        ],
      );
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the web backend probe threw, which is a bug in the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  @override
  Future<void> initialize() async => _initialised = true;

  @override
  Future<void> shutdown() async {
    if (!_initialised) return;
    for (final WebWindow window in List<WebWindow>.of(_windows)) {
      window.close();
    }
    _windows.clear();
    _initialised = false;
  }

  /// Creates a canvas in `document.body` and wraps it.
  ///
  /// [WindowOptions.position] is ignored, for the reason [WebWindow.setBounds]
  /// gives: a page cannot place itself on the desktop. [WindowOptions.decorated]
  /// and [WindowOptions.resizable] are ignored too - a canvas has no title bar
  /// to remove and no border to grab - and they are ignored *loudly*, in this
  /// comment, rather than quietly honoured as no-ops.
  @override
  Future<WebWindow> createWindow(WindowOptions options) async {
    if (!_initialised) {
      throw StateError('initialize() must be called before createWindow()');
    }
    final web.Element? host = web.document.body;
    if (host == null) {
      throw StateError(
        'the document has no body to put a canvas in. This happens when the '
        'script runs in <head> without `defer`; move the entrypoint or add '
        'the attribute',
      );
    }
    final WebWindow window = WebWindow.createIn(
      host,
      size: options.size,
      id: NativeWindowId(_windows.length + 1),
      title: options.title,
    );
    _windows.add(window);
    web.document.title = options.title;
    if (options.visible) window.show();
    _observe(window);
    return window;
  }

  void _observe(WebWindow window) {
    // The entries are deliberately unread. Each carries the new box the
    // observer measured, and using it would mean trusting a second source for
    // the canvas's size - `contentRect` is the *content box*, which is not
    // `getBoundingClientRect()` on an element with a border or padding, and the
    // two would disagree the first time a page styled the canvas. `syncSize`
    // re-reads the one number this class already treats as authoritative.
    final web.ResizeObserver observer = web.ResizeObserver(
      (JSArray<web.ResizeObserverEntry> entries, web.ResizeObserver observer) {
        window.syncSize();
      }.toJS,
    );
    observer.observe(window.canvas);
    _observers[window] = observer;
  }

  @override
  List<WebWindow> get windows => List<WebWindow>.unmodifiable(_windows);

  /// A no-op that answers true. See the class comment: the browser owns the
  /// event loop and never asks a page to stop.
  @override
  bool pumpEvents({Duration timeout = Duration.zero}) => true;

  /// A no-op.
  ///
  /// There is nothing to wake: [pumpEvents] never blocks, because it never
  /// waits for anything. A backend whose pump does not block has no use for the
  /// call that unblocks it, and throwing here would break a frame loop written
  /// against the interface for no gain.
  @override
  void wake() {}

  /// Stops observing and forgets [window]. Called by an owner that closed one
  /// window without shutting the backend down.
  void forget(WebWindow window) {
    _observers.remove(window)?.disconnect();
    _windows.remove(window);
  }
}
