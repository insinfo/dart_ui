/// `ErrorWidget`: what stands in for a subtree whose build threw.
library;

import '../foundation/constants.dart';
import '../foundation/error_details.dart';
import '../geometry/offset.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../layout/box_constraints.dart';
import '../layout/edge_insets.dart';
import '../layout/render_box.dart';
import 'basic.dart' show Padding, Text;
import 'element.dart';
import 'keys.dart';
import 'widget.dart';

/// Builds the widget shown in place of a failed build; see
/// [ErrorWidget.builder].
typedef ErrorWidgetBuilder = Widget Function(FlutterErrorDetails details);

/// A box that fills its space and shows an error message, used by the
/// framework where a widget's `build` threw.
///
/// As in Flutter, a component element whose build throws gets
/// `ErrorWidget.builder(details)` as its child; the default builder makes
/// one of these. Replace [builder] to show something friendlier in a
/// release build:
///
/// ```dart
/// ErrorWidget.builder = (FlutterErrorDetails details) =>
///     const Center(child: Text('Something went wrong'));
/// ```
///
/// The error is still recorded by the window's `ErrorReporter` (and passed
/// to `ApplicationOptions.onError`), and the rest of the window keeps
/// running. Differences from Flutter: the box is a red panel with the
/// message in the ambient UI font rather than Flutter's yellow-on-red
/// monospace text, and in a release build ([kReleaseMode]) it is a plain
/// grey panel with no text, which is what Flutter shows there too.
class ErrorWidget extends StatelessWidget {
  /// A box describing [exception].
  ErrorWidget(Object exception)
      : message = _stringify(exception),
        _flutterError = exception,
        super(key: UniqueKey());

  /// A box with an explicit [message], and the [error] it came from if any.
  ErrorWidget.withDetails({this.message = '', Object? error})
      : _flutterError = error,
        super(key: UniqueKey());

  /// What the framework calls to build the stand-in for a failed build.
  ///
  /// A static, process-wide hook, exactly like Flutter's.
  static ErrorWidgetBuilder builder = _defaultErrorWidgetBuilder;

  /// The text the box shows (empty in a release build).
  final String message;

  final Object? _flutterError;

  static Widget _defaultErrorWidgetBuilder(FlutterErrorDetails details) {
    if (kReleaseMode) return ErrorWidget.withDetails(error: details.exception);
    return ErrorWidget.withDetails(
      message: details.toString(),
      error: details.exception,
    );
  }

  static String _stringify(Object? exception) {
    try {
      return exception.toString();
    } on Object {
      // The exception's own toString threw; say so instead of failing again.
      return 'Error';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool showText = message.isNotEmpty;
    return _ErrorBox(
      color: showText ? const Color(0xF0900000) : const Color(0xF0C0C0C0),
      child: showText
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                message,
                softWrap: true,
                breakWords: true,
                fontSize: 14,
                color: const Color(0xFFFFFF66),
              ),
            )
          : null,
    );
  }

  @override
  String toString() => 'ErrorWidget(${_flutterError ?? message})';
}

final class _ErrorBox extends SingleChildRenderObjectWidget {
  const _ErrorBox({required this.color, super.child});

  final Color color;

  @override
  _RenderErrorBox createRenderObject(BuildContext context) =>
      _RenderErrorBox(color);

  @override
  void updateRenderObject(BuildContext context, _RenderErrorBox renderObject) {
    renderObject.color = color;
  }
}

/// Fills the space it is given - capped, like Flutter's `RenderErrorBox`, so
/// an unbounded parent still gets a finite box - and lays the message out
/// inside it.
final class _RenderErrorBox extends RenderSingleChildBox {
  _RenderErrorBox(this._color);

  static const double _maxExtent = 100000;

  Color _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    size = constraints.constrain(const Size(_maxExtent, _maxExtent));
    child?.layout(BoxConstraints.loose(size), parentUsesSize: true);
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    list.drawRectangle(
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      list.addPaint(colorArgb: _color.value),
    );
    super.paint(list, offset);
  }
}
