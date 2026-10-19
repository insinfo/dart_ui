/// A slow second click on a selected name enters in-place rename.
library;

import 'dart:async';

import 'package:dart_ui/dart_ui.dart';

class SelectedNameRename extends StatefulWidget {
  const SelectedNameRename(
      {super.key,
      required this.isEligible,
      required this.onRename,
      required this.child});
  final bool Function() isEligible;
  final void Function() onRename;
  final Widget child;
  @override
  State<SelectedNameRename> createState() => _SelectedNameRenameState();
}

class _SelectedNameRenameState extends State<SelectedNameRename> {
  final _clicks = MultiTapCounter();
  Offset? _origin;
  int? _pointer;
  bool _armed = false;
  TimerHandle? _pending;
  Timer? _fallback;

  void _cancel() {
    _pending?.cancel();
    _pending = null;
    _fallback?.cancel();
    _fallback = null;
    _armed = false;
    _origin = null;
    _pointer = null;
  }

  bool get _unmodified =>
      context is Element &&
      ((context as Element).owner?.keyModifiers.isEmpty ?? false) &&
      ((context as Element).owner?.focusManager.isWindowActive ?? false);

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PointerListener(
        onPointerDown: (event) {
          _cancel();
          if (event.button != PointerButton.primary) {
            return;
          }
          final count = _clicks.countTapAt(
              timestamp: event.timestamp,
              position: event.logicalPosition,
              kind: event.kind,
              platformClickCount: event.clickCount);
          _armed = count == 1 && _unmodified && widget.isEligible();
          if (_armed) {
            _origin = event.logicalPosition;
            _pointer = event.pointerId;
          }
        },
        onPointerMove: (event) {
          final origin = _origin;
          if (origin != null &&
              ((event.logicalPosition.dx - origin.dx).abs() > 5 ||
                  (event.logicalPosition.dy - origin.dy).abs() > 5)) {
            _cancel();
          }
        },
        onPointerCancel: (_) => _cancel(),
        onPointerUp: (event) {
          if (!_armed ||
              event.pointerId != _pointer ||
              event.button != PointerButton.primary) {
            return;
          }
          final origin = _origin!;
          final close = (event.logicalPosition.dx - origin.dx).abs() <= 5 &&
              (event.logicalPosition.dy - origin.dy).abs() <= 5;
          _cancel();
          if (!close || !_unmodified || !widget.isEligible()) return;
          void rename() {
            if (mounted && _unmodified && widget.isEligible()) {
              widget.onRename();
            }
          }

          const delay = Duration(milliseconds: 500);
          final dispatcher = GestureScope.of(context);
          if (dispatcher != null) {
            _pending = dispatcher.schedule(delay, rename);
          } else {
            _fallback = Timer(delay, rename);
          }
        },
        child: widget.child,
      );
}
