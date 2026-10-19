/// The title bar and resize borders a window draws for itself when the
/// window system will not.
///
/// A Wayland compositor is free to refuse server-side decorations - GNOME's
/// Mutter and Weston both do - and an undecorated toplevel there has no title,
/// no close button and no edge to drag. [ClientDecorationFrame] supplies them
/// from the framework, driven by a [ClientDecoratedWindow]: it draws nothing
/// while the system decorates the window, and switches on the moment the
/// compositor says it will not.
library;

import '../foundation/value_notifier.dart';
import '../graphics/color.dart';
import '../layout/alignment.dart';
import '../layout/edge_insets.dart';
import '../layout/render_flex.dart' show CrossAxisAlignment;
import '../layout/render_proxy_box.dart' show BoxBorder, BoxDecoration;
import '../layout/render_stack.dart' show StackFit;
import '../platform/input_events.dart';
import '../platform/native_window.dart';
import 'basic.dart';
import 'gesture_detector.dart';
import 'hover.dart';
import 'icon.dart';
import 'pointer_listener.dart';
import 'proxy.dart' show Center, DecoratedBox;
import 'semantics_widgets.dart';
import 'theme.dart';
import 'value_listenable_builder.dart';
import 'widget.dart';

/// Wraps [child] in a title bar and resize borders while
/// [ClientDecoratedWindow.clientDecorations] is true.
///
/// The bar moves the window when dragged, toggles maximised on a double
/// click and opens the window system's menu on a right click; its three buttons minimise, toggle maximised and request a close.
/// Hidden title bars use the application's top strip instead of an extra bar.
/// The borders start a compositor resize from the edge or corner under the
/// press. Maximized and fullscreen windows have no resize borders.
final class ClientDecorationFrame extends StatefulWidget {
  const ClientDecorationFrame({
    super.key,
    required this.window,
    required this.child,
    this.titleBarHeight = 32,
    this.resizeBorder = 6,
  });

  final ClientDecoratedWindow window;
  final Widget child;

  /// Height of the drawn title bar in logical pixels.
  final double titleBarHeight;

  /// Width of the invisible resize strips along each edge.
  final double resizeBorder;

  @override
  State<ClientDecorationFrame> createState() => _ClientDecorationFrameState();
}

final class _ClientDecorationFrameState extends State<ClientDecorationFrame> {
  ValueNotifier<bool>? _listened;
  ValueListenable<WindowState>? _caption;
  void _captionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _listen(widget.window.clientDecorations);
    _listenCaption();
  }

  @override
  void didUpdateWidget(ClientDecorationFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.window, widget.window)) {
      _listen(widget.window.clientDecorations);
      _listenCaption();
    }
  }

  @override
  void dispose() {
    _listened?.removeListener(_changed);
    _listened = null;
    _caption?.removeListener(_captionChanged);
    _caption = null;
    super.dispose();
  }

  void _listenCaption() {
    _caption?.removeListener(_captionChanged);
    final window = widget.window;
    _caption = window is ClientCaptionWindow
        ? (window as ClientCaptionWindow).captionState
        : null;
    _caption?.addListener(_captionChanged);
  }

  void _listen(ValueNotifier<bool> notifier) {
    _listened?.removeListener(_changed);
    _listened = notifier..addListener(_changed);
  }

  void _changed(bool _) {
    if (mounted) setState(() {});
  }

  void _toggleMaximized() {
    final ClientDecoratedWindow window = widget.window;
    window.setMaximized(!window.isMaximized);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ClientDecoratedWindow window = widget.window;
    if (!window.clientDecorations.value) return widget.child;
    final ThemeData theme = Theme.of(context);
    final bool maximized = window.isMaximized;
    final bool integrated = window is HiddenTitleBarWindow &&
        (window as HiddenTitleBarWindow).isTitleBarHidden;
    final Widget content = integrated
        ? widget.child
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                height: widget.titleBarHeight,
                child: ColoredBox(
                  color: theme.surfaceRaised,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        // A right click is the window system's menu, as on a
                        // title bar it draws itself; the drag and double click
                        // below only ever see the primary button.
                        child: PointerListener(
                          onPointerDown: (PointerDownEvent event) {
                            if (event.button == PointerButton.secondary) {
                              window.showWindowMenu(event.logicalPosition);
                            }
                          },
                          child: GestureDetector(
                            behavior: GestureHitTestBehavior.opaque,
                            onPanStart: (_) => window.beginMove(),
                            onDoubleTap: (_) => _toggleMaximized(),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  window.title,
                                  color: theme.foreground,
                                  maxLines: 1,
                                  ellipsis: '…',
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (window.canMinimize)
                        _CaptionButton(
                          key: const ValueKey<String>('csd-minimize'),
                          size: widget.titleBarHeight,
                          onPressed: window.minimize,
                          child: Icon(Icons.indeterminate,
                              size: widget.titleBarHeight * 0.45,
                              color: theme.foreground),
                        ),
                      _CaptionButton(
                        key: const ValueKey<String>('csd-maximize'),
                        size: widget.titleBarHeight,
                        onPressed: _toggleMaximized,
                        // Drawn, not a glyph: U+25A1 is missing from the faces a
                        // bare Linux or macOS install falls back to.
                        child: _WindowGlyph(
                          restore: maximized,
                          extent:
                              (widget.titleBarHeight * 0.32).roundToDouble(),
                          color: theme.foreground,
                        ),
                      ),
                      _CaptionButton(
                        key: const ValueKey<String>('csd-close'),
                        size: widget.titleBarHeight,
                        onPressed: window.requestClose,
                        child: Icon(Icons.close,
                            size: widget.titleBarHeight * 0.45,
                            color: theme.foreground),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 1, child: ColoredBox(color: theme.border)),
              Expanded(child: widget.child),
            ],
          );
    if (maximized ||
        (window is NativeWindow &&
            (window as NativeWindow).state == WindowState.fullscreen) ||
        (window is ClientCaptionWindow &&
            !(window as ClientCaptionWindow).canMaximize)) {
      return content;
    }
    final double b = widget.resizeBorder;
    Widget edge(WindowResizeEdge edge) => PointerListener(
          onPointerDown: (_) => window.beginResize(edge),
          child: const SizedBox(),
        );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        content,
        Positioned(left: b, right: b, top: 0, height: b, child: edge(_top)),
        Positioned(
            left: b, right: b, bottom: 0, height: b, child: edge(_bottom)),
        Positioned(top: b, bottom: b, left: 0, width: b, child: edge(_left)),
        Positioned(top: b, bottom: b, right: 0, width: b, child: edge(_right)),
        Positioned(left: 0, top: 0, width: b, height: b, child: edge(_topLeft)),
        Positioned(
            right: 0, top: 0, width: b, height: b, child: edge(_topRight)),
        Positioned(
            left: 0, bottom: 0, width: b, height: b, child: edge(_bottomLeft)),
        Positioned(
            right: 0,
            bottom: 0,
            width: b,
            height: b,
            child: edge(_bottomRight)),
      ],
    );
  }

  static const WindowResizeEdge _top = WindowResizeEdge.top;
  static const WindowResizeEdge _bottom = WindowResizeEdge.bottom;
  static const WindowResizeEdge _left = WindowResizeEdge.left;
  static const WindowResizeEdge _right = WindowResizeEdge.right;
  static const WindowResizeEdge _topLeft = WindowResizeEdge.topLeft;
  static const WindowResizeEdge _topRight = WindowResizeEdge.topRight;
  static const WindowResizeEdge _bottomLeft = WindowResizeEdge.bottomLeft;
  static const WindowResizeEdge _bottomRight = WindowResizeEdge.bottomRight;
}

/// One square caption button: a glyph centred in a tappable box.
///
/// No hover tint: the pointer router reports no enter or exit for a single
/// box, and a tint that never clears is worse than none.
final class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    super.key,
    required this.size,
    required this.onPressed,
    required this.child,
  });

  final double size;
  final void Function() onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: size * 1.4,
          height: size,
          child: Center(child: child),
        ),
      );
}

/// The maximise square, or the restore pair of squares.
final class _WindowGlyph extends StatelessWidget {
  const _WindowGlyph({
    required this.restore,
    required this.extent,
    required this.color,
  });

  final bool restore;
  final double extent;
  final Color color;

  Widget _square(double side) => SizedBox(
        width: side,
        height: side,
        child: DecoratedBox(
          decoration: BoxDecoration(border: BoxBorder(color: color, width: 1)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!restore) return _square(extent);
    final double side = (extent * 0.8).roundToDouble();
    final double shift = extent - side;
    return SizedBox(
      width: extent,
      height: extent,
      child: Stack(
        children: <Widget>[
          Positioned(left: shift, top: 0, child: _square(side)),
          Positioned(left: 0, top: shift, child: _square(side)),
        ],
      ),
    );
  }
}

/// Caption controls for a client title bar. Native hit testing owns their clicks.
final class WindowCaptionControls extends StatelessWidget {
  const WindowCaptionControls({super.key, required this.window});

  final ClientCaptionWindow window;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<WindowState>(
      valueListenable: window.captionState,
      builder: (context, state, _) => _controls(context, state));

  Widget _controls(BuildContext context, WindowState state) {
    final theme = Theme.of(context);
    Widget button(
            String label, Widget Function(Color) glyph, void Function() action,
            {bool close = false, bool enabled = true}) =>
        HoverBuilder(
          builder: (context, hovered) => Semantics(
              label: label,
              button: true,
              enabled: enabled,
              onTap: enabled ? action : null,
              child: GestureDetector(
                behavior: GestureHitTestBehavior.opaque,
                onTap: enabled ? action : null,
                child: SizedBox(
                    width: 46,
                    height: 32,
                    child: ColoredBox(
                        color: hovered && enabled
                            ? (close
                                ? const Color(0xffc42b1c)
                                : theme.hoverSurface)
                            : const Color(0x00000000),
                        child: Center(
                            child: glyph(close && hovered
                                ? const Color(0xffffffff)
                                : theme.foreground)))),
              )),
        );
    return Row(children: <Widget>[
      button(
          'Minimize',
          (color) =>
              SizedBox(width: 10, height: 1, child: ColoredBox(color: color)),
          window.minimize,
          enabled: window.canMinimize),
      button(
          'Maximize',
          (color) => _WindowGlyph(
              restore: state == WindowState.maximised,
              extent: 10,
              color: color),
          window.toggleMaximized,
          enabled: window.canMaximize),
      button('Close', (color) => Icon(Icons.close, size: 20, color: color),
          window.requestClose,
          close: true),
    ]);
  }
}
