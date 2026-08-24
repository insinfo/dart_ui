/// Efficient repaint-only signal and spectrum visualizations.
library;

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/size.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_opcodes.dart' show paintStyleStroke;
import '../layout/render_box.dart';
import 'element.dart';
import 'semantics.dart';
import 'widget.dart';

/// Draws normalized time-domain samples as one continuous oscilloscope line.
///
/// Mutating [samples] in place is supported. Increment [revision] to request a
/// repaint without replacing the list; this avoids allocating a list for each
/// realtime telemetry frame.
final class SignalPlot extends RenderObjectWidget {
  const SignalPlot({
    super.key,
    required this.samples,
    this.revision = 0,
    this.lineColor = const Color(0xFF9CFF35),
    this.gridColor = const Color(0x332D5477),
    this.backgroundColor = const Color(0x00000000),
    this.strokeWidth = 1.5,
    this.semanticLabel = 'Visualização da forma de onda',
  });

  final List<double> samples;
  final int revision;
  final Color lineColor;
  final Color gridColor;
  final Color backgroundColor;
  final double strokeWidth;
  final String semanticLabel;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderSignalPlot createRenderObject(BuildContext context) =>
      RenderSignalPlot()
        ..samples = samples
        ..revision = revision
        ..lineColor = lineColor
        ..gridColor = gridColor
        ..backgroundColor = backgroundColor
        ..strokeWidth = strokeWidth
        ..semanticLabel = semanticLabel;

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSignalPlot renderObject,
  ) {
    renderObject
      ..samples = samples
      ..revision = revision
      ..lineColor = lineColor
      ..gridColor = gridColor
      ..backgroundColor = backgroundColor
      ..strokeWidth = strokeWidth
      ..semanticLabel = semanticLabel;
  }
}

final class RenderSignalPlot extends RenderBox implements SemanticsProvider {
  List<double> _samples = const <double>[];
  int _revision = 0;
  Color _lineColor = const Color(0xFF9CFF35);
  Color _gridColor = const Color(0x332D5477);
  Color _backgroundColor = const Color(0x00000000);
  double _strokeWidth = 1.5;
  String _semanticLabel = 'Visualização da forma de onda';

  set samples(List<double> value) {
    if (identical(value, _samples)) return;
    _samples = value;
    markNeedsPaint();
  }

  set revision(int value) {
    if (value == _revision) return;
    _revision = value;
    markNeedsPaint();
  }

  set lineColor(Color value) {
    if (value == _lineColor) return;
    _lineColor = value;
    markNeedsPaint();
  }

  set gridColor(Color value) {
    if (value == _gridColor) return;
    _gridColor = value;
    markNeedsPaint();
  }

  set backgroundColor(Color value) {
    if (value == _backgroundColor) return;
    _backgroundColor = value;
    markNeedsPaint();
  }

  set strokeWidth(double value) {
    if (value == _strokeWidth) return;
    _strokeWidth = value;
    markNeedsPaint();
  }

  set semanticLabel(String value) => _semanticLabel = value;

  @override
  void performLayout() => size = constraints.constrain(const Size(520, 260));

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    if (_backgroundColor.alpha != 0) {
      list.drawRect(
        offset.dx,
        offset.dy,
        offset.dx + size.width,
        offset.dy + size.height,
        list.addPaint(colorArgb: _backgroundColor.value),
      );
    }
    final int gridPaint = list.addPaint(colorArgb: _gridColor.value);
    final double middle = offset.dy + size.height / 2;
    list.drawRect(
      offset.dx,
      middle,
      offset.dx + size.width,
      middle + 1,
      gridPaint,
    );
    for (int division = 1; division < 4; division++) {
      final double x = offset.dx + size.width * division / 4;
      list.drawRect(x, offset.dy, x + 1, offset.dy + size.height, gridPaint);
    }
    if (_samples.length < 2) return;
    final double amplitude = size.height * 0.46;
    final PathBuilder path = PathBuilder();
    for (int index = 0; index < _samples.length; index++) {
      final double x = offset.dx + size.width * index / (_samples.length - 1);
      final double sample = _samples[index].clamp(-1.0, 1.0);
      final double y = middle - sample * amplitude;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final int pathId = list.addPath(path.build());
    list.drawPath(
      pathId,
      list.addPaint(
        colorArgb: _lineColor.withAlpha(54).value,
        style: paintStyleStroke,
        strokeWidth: _strokeWidth + 3,
        antiAlias: true,
      ),
    );
    list.drawPath(
      pathId,
      list.addPaint(
        colorArgb: _lineColor.value,
        style: paintStyleStroke,
        strokeWidth: _strokeWidth,
        antiAlias: true,
      ),
    );
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.image,
        label: _semanticLabel,
      );
}

/// Draws a complete normalized spectrum in one render object.
///
/// Unlike a row containing one layout widget per band, changing [revision]
/// only repaints this object. This is the appropriate path for 30/60 FPS
/// meters driven by realtime audio telemetry.
final class SpectrumBars extends RenderObjectWidget {
  const SpectrumBars({
    super.key,
    required this.values,
    this.revision = 0,
    this.lowColor = const Color(0xFF4EEC4B),
    this.highColor = const Color(0xFF2FB7FF),
    this.backgroundColor = const Color(0x00000000),
    this.gap = 2,
    this.semanticLabel = 'Visualização do espectro de áudio',
  });

  final List<double> values;
  final int revision;
  final Color lowColor;
  final Color highColor;
  final Color backgroundColor;
  final double gap;
  final String semanticLabel;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderSpectrumBars createRenderObject(BuildContext context) =>
      RenderSpectrumBars()
        ..values = values
        ..revision = revision
        ..lowColor = lowColor
        ..highColor = highColor
        ..backgroundColor = backgroundColor
        ..gap = gap
        ..semanticLabel = semanticLabel;

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSpectrumBars renderObject,
  ) {
    renderObject
      ..values = values
      ..revision = revision
      ..lowColor = lowColor
      ..highColor = highColor
      ..backgroundColor = backgroundColor
      ..gap = gap
      ..semanticLabel = semanticLabel;
  }
}

final class RenderSpectrumBars extends RenderBox implements SemanticsProvider {
  List<double> _values = const <double>[];
  List<int> _colors = const <int>[];
  int _revision = 0;
  Color _lowColor = const Color(0xFF4EEC4B);
  Color _highColor = const Color(0xFF2FB7FF);
  Color _backgroundColor = const Color(0x00000000);
  double _gap = 2;
  String _semanticLabel = 'Visualização do espectro de áudio';

  set values(List<double> value) {
    if (identical(value, _values)) return;
    _values = value;
    _rebuildColors();
    markNeedsPaint();
  }

  set revision(int value) {
    if (value == _revision) return;
    _revision = value;
    markNeedsPaint();
  }

  set lowColor(Color value) {
    if (value == _lowColor) return;
    _lowColor = value;
    _rebuildColors();
    markNeedsPaint();
  }

  set highColor(Color value) {
    if (value == _highColor) return;
    _highColor = value;
    _rebuildColors();
    markNeedsPaint();
  }

  set backgroundColor(Color value) {
    if (value == _backgroundColor) return;
    _backgroundColor = value;
    markNeedsPaint();
  }

  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsPaint();
  }

  set semanticLabel(String value) => _semanticLabel = value;

  void _rebuildColors() {
    _colors = List<int>.generate(_values.length, (int index) {
      final double amount =
          _values.length <= 1 ? 0 : index / (_values.length - 1);
      return Color.lerp(_lowColor, _highColor, amount)!.value;
    }, growable: false);
  }

  @override
  void performLayout() => size = constraints.constrain(const Size(520, 260));

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    if (_backgroundColor.alpha != 0) {
      list.drawRect(
        offset.dx,
        offset.dy,
        offset.dx + size.width,
        offset.dy + size.height,
        list.addPaint(colorArgb: _backgroundColor.value),
      );
    }
    if (_values.isEmpty) return;
    final double gap = _gap.clamp(0.0, size.width);
    final double available = size.width - gap * (_values.length - 1);
    final double barWidth = available > 0 ? available / _values.length : 1;
    for (int index = 0; index < _values.length; index++) {
      final double level = _values[index].clamp(0.0, 1.0);
      final double height = 4 + level * (size.height - 4);
      final double left = offset.dx + index * (barWidth + gap);
      list.drawRect(
        left,
        offset.dy + size.height - height,
        left + barWidth,
        offset.dy + size.height,
        list.addPaint(colorArgb: _colors[index]),
      );
    }
  }

  @override
  SemanticsConfiguration describeSemantics() => SemanticsConfiguration(
        role: SemanticsRole.image,
        label: _semanticLabel,
      );
}
