library;

import '../geometry/offset.dart';
import 'window_events.dart';

/// Base class for all input events reported by the windowing backend.
sealed class PlatformInputEvent extends PlatformWindowEvent {
  const PlatformInputEvent({
    required super.windowId,
    required super.generation,
    required this.timestamp,
  });

  /// Monotonic timestamp of the event, as reported by the OS.
  final Duration timestamp;
}

enum PointerKind { mouse, touch, stylus }

enum PointerButton { primary, secondary, middle, forward, back }

/// Base class for pointer input (mouse, touch).
sealed class PointerEvent extends PlatformInputEvent {
  const PointerEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required this.pointerId,
    required this.kind,
    required this.logicalPosition,
  });

  /// A stable identifier for this pointer (e.g., touch finger ID). For mice,
  /// this is typically 0.
  final int pointerId;
  final PointerKind kind;

  /// The position in logical units within the client area of the window.
  final Offset logicalPosition;
}

final class PointerDownEvent extends PointerEvent {
  const PointerDownEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
    required this.button,
  });

  final PointerButton button;
}

final class PointerUpEvent extends PointerEvent {
  const PointerUpEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
    required this.button,
  });

  final PointerButton button;
}

final class PointerMoveEvent extends PointerEvent {
  const PointerMoveEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.pointerId,
    required super.kind,
    required super.logicalPosition,
  });
}

/// A physical key transition.
sealed class KeyEvent extends PlatformInputEvent {
  const KeyEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required this.physicalKey,
    required this.logicalKey,
  });

  /// The OS-specific physical scan code.
  final int physicalKey;

  /// The OS-specific logical virtual key code (ignoring modifiers for now).
  final int logicalKey;
}

final class KeyDownEvent extends KeyEvent {
  const KeyDownEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.physicalKey,
    required super.logicalKey,
  });
}

final class KeyUpEvent extends KeyEvent {
  const KeyUpEvent({
    required super.windowId,
    required super.generation,
    required super.timestamp,
    required super.physicalKey,
    required super.logicalKey,
  });
}
