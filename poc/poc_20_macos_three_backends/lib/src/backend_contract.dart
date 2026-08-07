import 'dart:async';
import 'dart:typed_data';

import 'backend_policy.dart';

enum MacosBackendState {
  created,
  initializing,
  running,
  stopping,
  stopped,
  failed,
}

class MacosBackendCapabilities {
  const MacosBackendCapabilities({
    required this.appKitSemantics,
    required this.cpuPresentation,
    required this.keyboardInput,
    required this.pointerInput,
    required this.normalShutdown,
  });

  final bool appKitSemantics;
  final bool cpuPresentation;
  final bool keyboardInput;
  final bool pointerInput;
  final bool normalShutdown;
}

class MacosWindowOptions {
  const MacosWindowOptions({
    required this.width,
    required this.height,
    this.title = 'dart_ui',
  })  : assert(width > 0),
        assert(height > 0);

  final int width;
  final int height;
  final String title;
}

class MacosWindow {
  const MacosWindow({required this.id, required this.generation});

  final int id;
  final int generation;
}

class MacosFrame {
  const MacosFrame({
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.bgraPremultiplied,
  });

  final int width;
  final int height;
  final int bytesPerRow;
  final Uint8List bgraPremultiplied;
}

enum MacosInputKind {
  keyDown,
  keyUp,
  pointerMove,
  pointerDown,
  pointerUp,
  scroll
}

class MacosInputEvent {
  const MacosInputEvent({
    required this.kind,
    required this.windowId,
    required this.generation,
    this.x,
    this.y,
    this.keyCode,
  });

  final MacosInputKind kind;
  final int windowId;
  final int generation;
  final double? x;
  final double? y;
  final int? keyCode;
}

abstract interface class MacosWindowBackend {
  MacosBackendKind get kind;
  MacosBackendCapabilities get capabilities;
  MacosBackendState get state;

  Future<void> initialize();
  Future<MacosWindow> createWindow(MacosWindowOptions options);
  Stream<MacosInputEvent> get inputEvents;
  Future<void> present(MacosWindow window, MacosFrame frame);
  Future<void> closeWindow(MacosWindow window);
  Future<void> shutdown();
}

class MacosBackendStateError extends StateError {
  MacosBackendStateError(super.message);
}

/// Shared lifecycle guard for all three implementations.
///
/// Generation numbers prevent callbacks retained by native code from being
/// accepted after shutdown or a future reinitialization.
class MacosBackendLifecycle {
  MacosBackendState _state = MacosBackendState.created;
  int _generation = 0;

  MacosBackendState get state => _state;
  int get generation => _generation;

  void beginInitialize() {
    if (_state != MacosBackendState.created) {
      throw MacosBackendStateError('cannot initialize backend from $_state');
    }
    _state = MacosBackendState.initializing;
    _generation++;
  }

  void finishInitialize() {
    _require(MacosBackendState.initializing, 'finish initialization');
    _state = MacosBackendState.running;
  }

  void failInitialize() {
    _require(MacosBackendState.initializing, 'fail initialization');
    _state = MacosBackendState.failed;
    _generation++;
  }

  /// Returns false when shutdown was already requested or completed.
  bool beginShutdown() {
    if (_state == MacosBackendState.stopping ||
        _state == MacosBackendState.stopped) {
      return false;
    }
    if (_state != MacosBackendState.running &&
        _state != MacosBackendState.failed) {
      throw MacosBackendStateError('cannot stop backend from $_state');
    }
    _state = MacosBackendState.stopping;
    _generation++;
    return true;
  }

  void finishShutdown() {
    _require(MacosBackendState.stopping, 'finish shutdown');
    _state = MacosBackendState.stopped;
  }

  bool acceptsCallback(int callbackGeneration) =>
      _state == MacosBackendState.running && callbackGeneration == _generation;

  void requireRunning(String operation) {
    _require(MacosBackendState.running, operation);
  }

  void _require(MacosBackendState required, String operation) {
    if (_state != required) {
      throw MacosBackendStateError(
        'cannot $operation: expected $required, found $_state',
      );
    }
  }
}
