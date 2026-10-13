/// A light-dismiss popup that holds any widget, anchored to another:
/// WinUI's `Flyout` - a date picker's calendar, a colour swatch's picker, a
/// "more options" panel.
///
/// A menu is a column of rows the menu owns the keys of; a tooltip takes no
/// input at all. A flyout is the third thing: arbitrary content that the
/// keyboard goes *into* - the calendar's arrows move its day, a picker's
/// fields type - and that a click outside or Escape puts away.
library;

import '../foundation/change_notifier.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../layout/edge_insets.dart';
import '../layout/render_proxy_box.dart' show BoxBorder, BoxDecoration;
import '../platform/input_events.dart';
import 'basic.dart' show Padding;
import 'element.dart';
import 'focus.dart';
import 'focus_scope.dart';
import 'layout_builder.dart';
import 'menu_anchor.dart' show AnchorProbe, MenuAnchorBox;
import 'popup.dart';
import 'popup_host.dart';
import 'proxy.dart' show DecoratedBox;
import 'theme.dart';
import 'widget.dart';

/// Opens and closes a [Flyout] from outside it.
final class FlyoutController extends ChangeNotifier {
  _FlyoutState? _state;

  void _changed() => notifyListeners();

  bool get isOpen => _state?._handle?.isOpen ?? false;

  void open() => _state?._open();

  void close() => _state?._handle?.close();

  void toggle() => isOpen ? close() : open();
}

/// [builder]'s widget, which opens [content] in a popup below it.
final class Flyout extends StatefulWidget {
  const Flyout({
    super.key,
    required this.builder,
    required this.content,
    this.controller,
    this.anchorPoint = PopupAnchorPoint.bottomLeft,
    this.popupPoint = PopupAnchorPoint.topLeft,
    this.offset = const Offset(0, 4),
    this.padding = const EdgeInsets.all(8),
    this.autofocus = true,
    this.onOpen,
    this.onClose,
  });

  /// The anchor - usually a button whose press calls `controller.open()`.
  final Widget Function(BuildContext context, FlyoutController controller)
      builder;

  /// What the popup shows; built in the popup's own tree, with the anchor's
  /// theme.
  final Widget Function(BuildContext context, FlyoutController controller)
      content;

  final FlyoutController? controller;

  /// Which point of the anchor the popup's [popupPoint] goes to: below its
  /// left edge by default. The positioner flips and slides it to stay on
  /// screen.
  final PopupAnchorPoint anchorPoint;
  final PopupAnchorPoint popupPoint;
  final Offset offset;

  /// Between the popup's frame and [content].
  final EdgeInsets padding;

  /// Whether the content's first control takes the keyboard as the flyout
  /// opens. False for content that names its own - a calendar focuses its
  /// grid, not its "previous month" arrow.
  final bool autofocus;

  final void Function()? onOpen;
  final void Function()? onClose;

  @override
  State<Flyout> createState() => _FlyoutState();
}

final class _FlyoutState extends State<Flyout> {
  final FlyoutController _owned = FlyoutController();
  final MenuAnchorBox _anchor = MenuAnchorBox();
  PopupHandle? _handle;
  PopupHost? _host;
  Theme? _theme;
  bool _disposed = false;

  FlyoutController get _controller => widget.controller ?? _owned;

  @override
  void initState() {
    super.initState();
    _controller._state = this;
  }

  @override
  void didUpdateWidget(Flyout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final FlyoutController previous = oldWidget.controller ?? _owned;
    if (!identical(previous, _controller)) {
      if (identical(previous._state, this)) previous._state = null;
      _controller._state = this;
    }
    _handle?.markNeedsBuild();
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(_controller._state, this)) _controller._state = null;
    // Mounted under the host's layer, not here: nothing else would close it.
    _handle?.close();
    _owned.dispose();
    super.dispose();
  }

  void _open() {
    if (_handle?.isOpen ?? false) return;
    final PopupHost? host = _host;
    if (host == null) {
      throw StateError('a Flyout needs a PopupHost above it; DartUiApp and '
          'every PopupScope install one');
    }
    _handle = host.open(PopupSpec(
      anchorRect: _anchor.globalRect ?? Rect.zero,
      anchorPoint: widget.anchorPoint,
      popupPoint: widget.popupPoint,
      offset: widget.offset,
      builder: _buildContent,
      onDismiss: _dismissed,
    ));
    widget.onOpen?.call();
    _controller._changed();
    if (mounted) setState(() {});
  }

  void _dismissed() {
    _handle = null;
    widget.onClose?.call();
    if (_disposed) return;
    _controller._changed();
    if (mounted) setState(() {});
  }

  Widget _buildContent(BuildContext context) {
    Widget content = _FlyoutFocus(
      onEscape: _controller.close,
      autofocus: widget.autofocus,
      child: Builder(builder: (BuildContext inner) {
        // A popup floats above the window: the raised surface, the large
        // radius and a hairline, as a menu panel paints them.
        final ThemeData theme = Theme.of(inner);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: theme.surfaceRaised,
            border: BoxBorder(color: theme.border, width: 1),
            radius: theme.cornerRadiusLarge,
          ),
          child: Padding(
            padding: widget.padding,
            child: widget.content(inner, _controller),
          ),
        );
      }),
    );
    final Theme? theme = _theme;
    if (theme != null) {
      content = Theme(
        data: theme.data,
        styles: theme.styles,
        resources: theme.resources,
        templates: theme.templates,
        child: content,
      );
    }
    return content;
  }

  @override
  Widget build(BuildContext context) {
    _host = PopupHost.maybeOf(context);
    _theme = Theme.maybeOf(context);
    return AnchorProbe(
      anchor: _anchor,
      child: widget.builder(context, _controller),
    );
  }
}

/// The flyout's content as a focus scope that takes the keyboard as it
/// opens - its first control gets focus - and closes on Escape.
final class _FlyoutFocus extends StatefulWidget {
  const _FlyoutFocus({
    required this.onEscape,
    required this.autofocus,
    required this.child,
  });

  final void Function() onEscape;
  final bool autofocus;
  final Widget child;

  @override
  State<_FlyoutFocus> createState() => _FlyoutFocusState();
}

final class _FlyoutFocusState extends State<_FlyoutFocus> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'flyout');
  BuildOwner? _owner;

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) _scope.requestFocusOnAttach();
    _owner = (context as Element).owner;
    // Ahead of the dialog layer's Escape, and offered under any dialog: a
    // flyout open in a dialog is above it.
    _owner?.addWindowKeyHandler(_escape, modalDepth: 1 << 30, first: true);
  }

  @override
  void dispose() {
    _owner?.removeWindowKeyHandler(_escape);
    _scope.dispose();
    super.dispose();
  }

  bool _escape(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != logicalKeyEscape) {
      return false;
    }
    widget.onEscape();
    return true;
  }

  @override
  Widget build(BuildContext context) =>
      FocusScope(node: _scope, child: widget.child);
}
