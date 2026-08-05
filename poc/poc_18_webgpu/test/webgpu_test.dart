@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:test/test.dart';

@JS('navigator.gpu')
external JSObject? get _gpu;

void main() {
  test('WebGPU initialization test', () async {
    if (_gpu.isUndefinedOrNull) {
      print(
          'WebGPU not supported in this test runner. (Headless Chrome might need specific flags)');
      return;
    }

    final gpuObj = _gpu!;
    final adapterPromise =
        gpuObj.callMethod('requestAdapter'.toJS) as JSPromise?;
    final adapter = await adapterPromise?.toDart;

    if (adapter.isUndefinedOrNull) {
      print(
          'WebGPU Adapter returned null. This is expected in Headless Chrome without special flags. Skipping device test.');
      return;
    }

    final devicePromise =
        (adapter as JSObject).callMethod('requestDevice'.toJS) as JSPromise?;
    final device = await devicePromise?.toDart;

    expect(device.isUndefinedOrNull, isFalse,
        reason: 'WebGPU Device should not be null');
  });
}
