import 'package:web/web.dart' as web;

void main() {
  final output = web.document.getElementById('output') as web.HTMLDivElement;
  final canvas = web.document.getElementById('canvas') as web.HTMLCanvasElement;

  try {
    final gl = canvas.getContext('webgl') as web.WebGLRenderingContext?;

    if (gl == null) {
      output.innerText =
          'WebGL 1 context not available (Expected behavior in modern browsers with WebGPU/WebGL2 only).';
      print('WebGL 1 not supported or disabled.');
      return;
    }

    // Clear color to Cornflower Blue
    gl.clearColor(0.392, 0.584, 0.929, 1.0);
    gl.clear(web.WebGLRenderingContext.COLOR_BUFFER_BIT);

    output.innerText = '✅ WebGL 1 context initialized and cleared!';
    print('✅ WebGL 1 initialized.');
  } catch (e) {
    output.innerText = 'Error: $e';
    print('Error: $e');
  }
}
