import 'package:web/web.dart' as web;

void main() {
  final output = web.document.getElementById('output') as web.HTMLDivElement;
  final canvas = web.document.getElementById('canvas') as web.HTMLCanvasElement;

  try {
    final gl = canvas.getContext('webgl2') as web.WebGL2RenderingContext?;

    if (gl == null) {
      output.innerText = 'WebGL 2 context not available.';
      print('WebGL 2 not supported.');
      return;
    }

    // Clear color to Forest Green
    gl.clearColor(0.133, 0.545, 0.133, 1.0);
    gl.clear(web.WebGL2RenderingContext.COLOR_BUFFER_BIT);

    output.innerText = '✅ WebGL 2 context initialized and cleared!';
    print('✅ WebGL 2 initialized.');
  } catch (e) {
    output.innerText = 'Error: $e';
    print('Error: $e');
  }
}
