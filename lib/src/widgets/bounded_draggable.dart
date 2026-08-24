import 'dart:math' as math;

import '../geometry/offset.dart';
import '../geometry/size.dart';
import 'basic.dart';
import 'gesture_detector.dart';
import 'widget.dart';

/// Um filho posicionavel por arraste, sempre contido nos limites informados.
///
/// Deve ser usado dentro de um [Stack]. O pai continua responsavel por definir
/// seu tamanho; [bounds] torna a conversao entre coordenadas de dominio (por
/// exemplo, pontos de uma pagina PDF) e pixels do preview explicita.
final class BoundedDraggable extends StatefulWidget {
  const BoundedDraggable({
    super.key,
    required this.position,
    required this.size,
    required this.bounds,
    required this.onPositionChanged,
    required this.child,
    this.enabled = true,
    this.onDragStateChanged,
  });

  final Offset position;
  final Size size;
  final Size bounds;
  final void Function(Offset position) onPositionChanged;
  final Widget child;
  final bool enabled;
  final void Function(bool dragging)? onDragStateChanged;

  /// Restringe [position] ao retangulo em que [size] cabe por inteiro.
  static Offset clampPosition({
    required Offset position,
    required Size size,
    required Size bounds,
  }) {
    final maxX = math.max(0.0, bounds.width - size.width);
    final maxY = math.max(0.0, bounds.height - size.height);
    return Offset(
      position.dx.clamp(0.0, maxX),
      position.dy.clamp(0.0, maxY),
    );
  }

  @override
  State<BoundedDraggable> createState() => _BoundedDraggableState();
}

final class _BoundedDraggableState extends State<BoundedDraggable> {
  late Offset _visualPosition;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _visualPosition = BoundedDraggable.clampPosition(
      position: widget.position,
      size: widget.size,
      bounds: widget.bounds,
    );
  }

  @override
  void didUpdateWidget(covariant BoundedDraggable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging ||
        widget.size != oldWidget.size ||
        widget.bounds != oldWidget.bounds) {
      _visualPosition = BoundedDraggable.clampPosition(
        position: widget.position,
        size: widget.size,
        bounds: widget.bounds,
      );
    }
  }

  void _start() {
    _dragging = true;
    _visualPosition = BoundedDraggable.clampPosition(
      position: widget.position,
      size: widget.size,
      bounds: widget.bounds,
    );
    widget.onDragStateChanged?.call(true);
  }

  void _update(Offset delta) {
    final next = BoundedDraggable.clampPosition(
      position: _visualPosition + delta,
      size: widget.size,
      bounds: widget.bounds,
    );
    if (next == _visualPosition) return;
    setState(() => _visualPosition = next);
    widget.onPositionChanged(next);
  }

  void _end() {
    _dragging = false;
    widget.onDragStateChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    _visualPosition = BoundedDraggable.clampPosition(
      position: _visualPosition,
      size: widget.size,
      bounds: widget.bounds,
    );
    return Positioned(
      left: _visualPosition.dx,
      top: _visualPosition.dy,
      width: widget.size.width,
      height: widget.size.height,
      child: GestureDetector(
        behavior: GestureHitTestBehavior.opaque,
        onPanStart: widget.enabled ? (_) => _start() : null,
        onPanUpdate:
            widget.enabled ? (details) => _update(details.delta) : null,
        onPanEnd: widget.enabled ? (_) => _end() : null,
        onPanCancel: widget.enabled ? _end : null,
        child: widget.child,
      ),
    );
  }
}
