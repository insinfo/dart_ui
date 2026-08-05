@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('WebGL 2 context initialization test', () {
    final canvas =
        web.document.createElement('canvas') as web.HTMLCanvasElement;
    final gl = canvas.getContext('webgl2');

    // Most modern browsers including headless Chrome support WebGL2
    expect(gl, isNotNull,
        reason: 'WebGL 2 should be supported in modern browsers.');

    final webgl = gl as web.WebGL2RenderingContext;
    webgl.clearColor(0.0, 1.0, 0.0, 1.0);
    webgl.clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT);
  });
}
