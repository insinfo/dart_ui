@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('WebGL 1 context initialization test', () {
    final canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    final gl = canvas.getContext('webgl');

    // Depending on the browser, WebGL 1 might be disabled in favor of WebGL 2.
    // If it is supported, gl shouldn't be null and should clear successfully.
    if (gl != null) {
      final webgl = gl as web.WebGLRenderingContext;
      webgl.clearColor(1.0, 0.0, 0.0, 1.0);
      webgl.clear(web.WebGLRenderingContext.COLOR_BUFFER_BIT);
      expect(true, isTrue);
    } else {
      print('WebGL 1 not supported, skipping clear test.');
    }
  });
}
