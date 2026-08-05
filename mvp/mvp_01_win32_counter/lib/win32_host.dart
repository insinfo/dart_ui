/// Host Win32 do MVP-01.
///
/// Conecta a árvore de widgets Dart (`CounterApp`) à janela Win32 do POC-01:
/// o framebuffer persistente (DIB nativo) é o alvo do canvas, e cada
/// invalidação repinta apenas a região suja e apresenta só essa região via
/// `BitBlt` parcial (POC-01 `presentRegionProvider`).
library;

import 'package:poc_01_win32_window/poc_01_win32_window.dart';

import 'src/core/geometry.dart';
import 'src/render/canvas.dart';
import 'src/ui/counter_app.dart';

/// Host que amarra o `CounterApp` a uma janela Win32.
final class Win32MvpHost {
  Win32MvpHost({this.width = 800, this.height = 600});

  final int width;
  final int height;

  late Win32Window _window;
  CounterApp? _app;

  /// Hook opcional executado ao final de cada paint (útil para smoke tests).
  void Function(Win32MvpHost host)? onFrame;

  /// Região suja repintada no último frame (coordenadas de cliente).
  Rect _lastPaintedDirty = const Rect.fromLTWH(0, 0, 0, 0);
  Rect get lastPaintedDirty => _lastPaintedDirty;

  Win32Window get window => _window;
  CounterApp? get app => _app;

  /// Cria a janela, monta o app e roda o loop de mensagens.
  ///
  /// Retorna apenas após o fechamento da janela (código de saída WM_QUIT).
  int run({String title = 'DartUI MVP-01 — Counter'}) {
    Win32Window.initializeWin32();
    final window =
        Win32Window(framebufferBackend: FramebufferBackend.nativeDib);
    attachTo(window);
    window.create(title: title, width: width, height: height);
    window.show();
    return runMessageLoop();
  }

  /// Anexa o host a uma janela já criada (fios de callbacks e resize).
  ///
  /// Deve ser chamado antes de `create()`, para que o `WM_SIZE` inicial já
  /// monte o app antes do primeiro `WM_PAINT`.
  void attachTo(Win32Window window) {
    _window = window;
    _wireCallbacks();
  }

  void _wireCallbacks() {
    _window.onPaint = (w) {
      _app?.paint();
      _lastPaintedDirty =
          _app?.lastPaintedDirty ?? const Rect.fromLTWH(0, 0, 0, 0);
      onFrame?.call(this);
    };
    _window.onResize = _onResize;
    _window.onClose = (w) => w.close();
    _window.onMouseMove = (w, x, y) {
      _app?.handleMouseMove(x, y);
      w.invalidate();
    };
    _window.onMouseDown = (w, x, y, button) {
      _app?.handleMouseDown(x, y, button);
      w.invalidate();
    };
    _window.onMouseUp = (w, x, y, button) {
      _app?.handleMouseUp(x, y, button);
      w.invalidate();
    };
    _window.onKey = (w, keyCode, isDown) {
      if (isDown) {
        _app?.handleKeyDown(keyCode);
      } else {
        _app?.handleKeyUp(keyCode);
      }
      w.invalidate();
    };
    _window.presentRegionProvider = (w) {
      final dirty = _lastPaintedDirty;
      return (dirty.left, dirty.top, dirty.right, dirty.bottom);
    };
  }

  void _onResize(Win32Window w, int newWidth, int newHeight) {
    final fb = w.framebuffer;
    if (fb == null) return;
    final canvas = Canvas(newWidth, newHeight, fb);
    final app = CounterApp(canvas)..layout();
    app.markFullDirty();
    _app = app;
    _lastPaintedDirty = Rect.fromLTWH(0, 0, newWidth, newHeight);
  }
}
