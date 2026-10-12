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
import '../layout/render_stack.dart' show StackFit;
import '../platform/input_events.dart';
import '../platform/native_window.dart';
import 'basic.dart';
import 'gesture_detector.dart';
import 'icon.dart';
import 'pointer_listener.dart';
import 'proxy.dart' show Center;
import 'theme.dart';
import 'widget.dart';

/// Wraps [child] in a title bar and resize borders while
/// [ClientDecoratedWindow.clientDecorations] is true.
///
/// The bar moves the window when dragged, toggles maximised on a double
/// click and opens the window system's menu on a right click; its three buttons minimise, toggle maximised and request a close.
/// The borders start a compositor resize from the edge or corner under the
/// press. A maximised window has no borders, since it has nothing to resize.
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

  @override
  void initState() {
    super.initState();
    _listen(widget.window.clientDecorations);
  }

  @override
  void didUpdateWidget(ClientDecorationFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.window, widget.window)) {
      _listen(widget.window.clientDecorations);
    }
  }

  @override
  void dispose() {
    _listened?.removeListener(_changed);
    _listened = null;
    super.dispose();
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
    final Widget content = Column(
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
                        padding: const EdgeInsets.symmetric(horizontal: 12),
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
                _CaptionButton(
                  key: const ValueKey<String>('csd-minimize'),
                  icon: Icons.indeterminate,
                  size: widget.titleBarHeight,
                  color: theme.foreground,
                  onPressed: window.minimize,
                ),
                _CaptionButton(
                  key: const ValueKey<String>('csd-maximize'),
                  icon: maximized ? _restoreGlyph : _maximizeGlyph,
                  size: widget.titleBarHeight,
                  color: theme.foreground,
                  onPressed: _toggleMaximized,
                ),
                _CaptionButton(
                  key: const ValueKey<String>('csd-close'),
                  icon: Icons.close,
                  size: widget.titleBarHeight,
                  color: theme.foreground,
                  onPressed: window.requestClose,
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: 1, child: ColoredBox(color: theme.border)),
        Expanded(child: widget.child),
      ],
    );
    if (maximized) return content;
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

  /// `U+25A1` WHITE SQUARE - maximise.
  static const IconData _maximizeGlyph = IconData(0x25A1);

  /// `U+29C9` TWO JOINED SQUARES - restore.
  static const IconData _restoreGlyph = IconData(0x29C9);
}

/// One square caption button: a glyph centred in a tappable box.
///
/// No hover tint: the pointer router reports no enter or exit for a single
/// box, and a tint that never clears is worse than none.
final class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    super.key,
    required this.icon,
    required this.size,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final double size;
  final Color color;
  final void Function() onPressed;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          width: size * 1.4,
          height: size,
          child: Center(
            child: Icon(icon, size: size * 0.45, color: color),
          ),
        ),
      );
}
