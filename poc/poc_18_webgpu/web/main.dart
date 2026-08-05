import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;

@JS('navigator.gpu')
external JSObject? get _gpu;

void main() async {
  final output = web.document.getElementById('output') as web.HTMLDivElement;
  final canvas = web.document.getElementById('canvas') as web.HTMLCanvasElement;

  try {
    if (_gpu.isUndefinedOrNull) {
      output.innerText = 'WebGPU not supported in this browser.';
      print('WebGPU not supported.');
      return;
    }
    final gpuObj = _gpu!;

    final adapterPromise =
        gpuObj.callMethod('requestAdapter'.toJS) as JSPromise?;
    final adapter = await adapterPromise?.toDart;
    if (adapter.isUndefinedOrNull) {
      output.innerText = 'Failed to get WebGPU adapter.';
      print('Failed to get adapter.');
      return;
    }

    final devicePromise =
        (adapter as JSObject).callMethod('requestDevice'.toJS) as JSPromise?;
    final device = await devicePromise?.toDart;

    final context = canvas.getContext('webgpu');
    if (context.isUndefinedOrNull) {
      output.innerText = 'Failed to get WebGPU context from canvas.';
      return;
    }

    final format =
        gpuObj.callMethod('getPreferredCanvasFormat'.toJS) as JSString;

    final config = JSObject();
    config['device'] = device;
    config['format'] = format;
    context!.callMethod('configure'.toJS, config);

    // Create a command encoder
    final encoder = (device as JSObject).callMethod('createCommandEncoder'.toJS)
        as JSObject;
    final textureView =
        context.callMethod('getCurrentTexture'.toJS) as JSObject;
    final view = textureView.callMethod('createView'.toJS) as JSObject;

    final colorAttachment = JSObject();
    colorAttachment['view'] = view;
    colorAttachment['loadOp'] = 'clear'.toJS;
    colorAttachment['storeOp'] = 'store'.toJS;

    final clearValue = JSObject();
    clearValue['r'] = 0.5.toJS;
    clearValue['g'] = 0.0.toJS;
    clearValue['b'] = 0.5.toJS;
    clearValue['a'] = 1.0.toJS;
    colorAttachment['clearValue'] = clearValue;

    final passDescriptor = JSObject();
    final attachmentsArray = JSArray();
    attachmentsArray.setProperty('0'.toJS, colorAttachment);
    passDescriptor['colorAttachments'] = attachmentsArray;

    final pass =
        encoder.callMethod('beginRenderPass'.toJS, passDescriptor) as JSObject;
    pass.callMethod('end'.toJS);

    final commandBuffer = encoder.callMethod('finish'.toJS) as JSObject;
    final queue = (device).getProperty('queue'.toJS) as JSObject;

    final commandArray = JSArray();
    commandArray.setProperty('0'.toJS, commandBuffer);
    queue.callMethod('submit'.toJS, commandArray);

    output.innerText = '✅ WebGPU initialized and cleared!';
    print('✅ WebGPU initialized.');
  } catch (e) {
    output.innerText = 'Error: $e';
    print('Error: $e');
  }
}
