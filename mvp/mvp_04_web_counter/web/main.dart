import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:mvp_01_win32_counter/headless.dart';
import 'package:web/web.dart' as web;

void main() async {
  final canvas = web.document.getElementById('canvas') as web.HTMLCanvasElement;
  final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;

  const config = HeadlessConfig(width: 800, height: 600, scale: 1.0);
  final headless = HeadlessBackend(config);
  await headless.initialize();

  // Draw loop
  void draw() {
    headless.render(); // Paint dirty rects
    final bgra = headless.frame.pixels;
    
    // Web requires RGBA
    final rgba = Uint8ClampedList(bgra.length);
    for (int i = 0; i < bgra.length; i += 4) {
      rgba[i] = bgra[i + 2];     // R
      rgba[i + 1] = bgra[i + 1]; // G
      rgba[i + 2] = bgra[i];     // B
      rgba[i + 3] = bgra[i + 3]; // A
    }

    final imageDataClass = globalContext.getProperty('ImageData'.toJS) as JSFunction;
    final imageData = imageDataClass.callAsConstructor(rgba.toJS, 800.toJS, 600.toJS) as JSObject;
    (ctx as JSObject).callMethod('putImageData'.toJS, imageData, 0.toJS, 0.toJS);
  }
  
  draw();

  // Setup input
  canvas.addEventListener('mousemove', (web.MouseEvent e) {
    headless.injectMouseMove(e.offsetX.toInt(), e.offsetY.toInt());
    draw();
  }.toJS);

  canvas.addEventListener('mousedown', (web.MouseEvent e) {
    headless.injectMouseDown(e.offsetX.toInt(), e.offsetY.toInt());
    draw();
  }.toJS);

  canvas.addEventListener('mouseup', (web.MouseEvent e) {
    headless.injectMouseUp(e.offsetX.toInt(), e.offsetY.toInt());
    draw();
  }.toJS);
}
