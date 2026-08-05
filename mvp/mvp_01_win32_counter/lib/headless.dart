/// Backend headless do MVP-01.
///
/// Janela virtual (framebuffer BGRA em memória) com input injetável e
/// estatísticas de dirty rect. Roda em qualquer plataforma, sem sistema de
/// janelas — é a base dos testes automatizados do vertical slice.
library;

import 'dart:typed_data';

import 'src/core/geometry.dart';
import 'src/ppm_writer.dart';
import 'src/render/canvas.dart';
import 'src/ui/counter_app.dart';

final class HeadlessConfig {
  const HeadlessConfig({this.width = 800, this.height = 600, this.scale = 1.0})
      : assert(width > 0),
        assert(height > 0),
        assert(scale > 0);

  final int width;
  final int height;
  final double scale;
}

/// Resultado imutável de uma captura headless em BGRA8888.
final class HeadlessScreenshot {
  HeadlessScreenshot(this.width, this.height, Uint8List source)
      : pixels = Uint8List.fromList(source);

  final int width;
  final int height;
  final Uint8List pixels;

  int pixelAt(int x, int y) {
    final offset = (y * width + x) * 4;
    return pixels[offset] |
        (pixels[offset + 1] << 8) |
        (pixels[offset + 2] << 16) |
        (pixels[offset + 3] << 24);
  }

  /// Hash FNV-1a 32-bit estável para golden tests e diagnóstico (compatível Web/JS).
  int get checksum {
    var hash = 0x811c9dc5;
    for (final byte in pixels) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// Salva uma captura simples em PPM (RGB), formato sem dependência externa.
  Future<void> savePpm(String path) async {
    final output = BytesBuilder();
    output.add(<int>[
      ...'P6\n$width $height\n255\n'.codeUnits,
    ]);
    final rgb = Uint8List(width * height * 3);
    var target = 0;
    for (var i = 0; i < pixels.length; i += 4) {
      rgb[target++] = pixels[i + 2];
      rgb[target++] = pixels[i + 1];
      rgb[target++] = pixels[i];
    }
    output.add(rgb);
    await writePpm(path, output.takeBytes());
  }
}

/// Backend virtual do MVP-04.
///
/// Mantém a árvore do MVP-01 sem janela nativa e expõe input/captura para
/// testes multiplataforma e golden tests determinísticos.
final class HeadlessBackend {
  HeadlessBackend(this.config);

  final HeadlessConfig config;
  late final HeadlessFrame _frame;
  bool _initialized = false;

  CounterApp get app {
    _checkInitialized();
    return _frame.app;
  }

  HeadlessFrame get frame {
    _checkInitialized();
    return _frame;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    // A escala fica explícita no contrato; o MVP renderiza pixels físicos.
    _frame = HeadlessFrame(
      (config.width * config.scale).round(),
      (config.height * config.scale).round(),
    );
    _frame.renderFull();
    _initialized = true;
  }

  void injectMouseMove(int x, int y) {
    _checkInitialized();
    _frame.injectMouseMove(x, y);
  }

  void injectMouseDown(int x, int y) {
    _checkInitialized();
    _frame.injectMouseDown(x, y);
  }

  void injectMouseUp(int x, int y) {
    _checkInitialized();
    _frame.injectMouseUp(x, y);
  }

  void injectKeyDown(int virtualKey) {
    _checkInitialized();
    _frame.injectKeyDown(virtualKey);
  }

  void injectKeyUp(int virtualKey) {
    _checkInitialized();
    _frame.injectKeyUp(virtualKey);
  }

  Rect render() {
    _checkInitialized();
    return _frame.render();
  }

  HeadlessScreenshot captureScreenshot() {
    _checkInitialized();
    _frame.render();
    return HeadlessScreenshot(_frame.width, _frame.height, _frame.pixels);
  }

  void dispose() {
    _initialized = false;
  }

  void _checkInitialized() {
    if (!_initialized) {
      throw StateError('HeadlessBackend.initialize() must be called first.');
    }
  }
}

final class HeadlessFrame {
  HeadlessFrame(this.width, this.height) {
    _pixels = Uint8List(width * height * 4);
    canvas = Canvas(width, height, _pixels);
    app = CounterApp(canvas)..layout();
  }

  final int width;
  final int height;
  late final Uint8List _pixels;
  late final Canvas canvas;
  late final CounterApp app;

  /// Pixels BGRA atuais (view direta do framebuffer).
  Uint8List get pixels => _pixels;

  /// Cor BGRA empacotada no pixel (x, y).
  int pixelAt(int x, int y) {
    final offset = (y * width + x) * 4;
    return _pixels[offset] |
        (_pixels[offset + 1] << 8) |
        (_pixels[offset + 2] << 16) |
        (_pixels[offset + 3] << 24);
  }

  /// Pinta a região suja acumulada (partial raster) e devolve a região
  /// efetivamente repintada.
  Rect render() {
    app.paint();
    return app.lastPaintedDirty;
  }

  void renderFull() {
    app.markFullDirty();
    app.paint();
  }

  // ---- Input sintético ----------------------------------------------------

  void injectMouseMove(int x, int y) => app.handleMouseMove(x, y);
  void injectMouseDown(int x, int y) => app.handleMouseDown(x, y, 0);
  void injectMouseUp(int x, int y) => app.handleMouseUp(x, y, 0);
  void injectKeyDown(int vk) => app.handleKeyDown(vk);
  void injectKeyUp(int vk) => app.handleKeyUp(vk);

  // ---- Estatísticas --------------------------------------------------------

  int get paintCount => app.paintCount;
  int get dirtyCount => app.dirtyCount;
}
