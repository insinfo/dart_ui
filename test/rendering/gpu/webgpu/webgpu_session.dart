@TestOn('browser')

/// One WebGPU device, opened once, shared by every test file in this
/// directory.
///
/// The shape `test/rendering/gpu/webgl/webgl_session.dart` established, and
/// its skip contract holds here word for word: `@TestOn('browser')` keeps
/// these files out of the plain `dart test` CI run entirely, and within a
/// browser [skipReason] is a **string**, non-null whenever the device could
/// not be opened, so a run that skipped says why instead of looking like a
/// run that passed.
///
/// The second half of that contract is more likely to fire here than on
/// WebGL2, and that is worth knowing before reading a skipped run: WebGPU
/// ships behind flags or blocklists on more configurations than WebGL2 does,
/// `dart test -p chrome` runs a browser that may have neither the flag nor a
/// GPU, and every one of those produces a named skip - which is also
/// precisely the situation the production fallback to WebGL2 exists for.
///
/// Where the WebGL session is synchronous, [open] is a `Future`: everything
/// WebGPU can refuse, it refuses through a promise. Test files await it in
/// `setUpAll`.
library;

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_backend.dart';
import 'package:dart_ui/src/rendering/gpu/webgpu/webgpu_interop.dart';
import 'package:test/test.dart';

/// A WebGPU device with no canvas behind it, or the reason there is none.
final class WebGpuSession {
  WebGpuSession._(this.device, this.skipReason);

  /// Null when the device could not be opened. [skipReason] says why.
  final WebGpuRenderDevice? device;

  /// Null when the device opened. A string when it did not, so a run with no
  /// WebGPU reports what was missing rather than passing quietly.
  final String? skipReason;

  /// Opens a device, or records why it could not.
  ///
  /// No canvas is involved: the device is opened the way
  /// `WebGpuRendererBackend.createDevice` opens one, and the canvas-target
  /// tests open their own detached canvas next to it. Never throws - a
  /// browser without WebGPU is a skip, not an error.
  static Future<WebGpuSession> open() async {
    try {
      final ({
        GPU? gpu,
        GPUAdapter? adapter,
        GPUDevice? device,
        BackendDiagnostic? failure,
      }) answer = await WebGpuRendererBackend.requestDevice();
      if (answer.device == null || answer.gpu == null) {
        return WebGpuSession._(
          null,
          'no WebGPU device: ${answer.failure ?? 'no reason recorded, which '
              'is a bug in requestDevice'}',
        );
      }
      final ({WebGpuRenderDevice? device, BackendDiagnostic? failure}) opened =
          WebGpuRenderDevice.adoptDevice(
        answer.device!,
        surfaceFormat: answer.gpu!.getPreferredCanvasFormat(),
        deviceDescription: describeWebGpuAdapter(answer.adapter),
      );
      final WebGpuRenderDevice? device = opened.device;
      if (device == null) {
        return WebGpuSession._(
          null,
          'WebGPU answered a device but refused the renderer objects: '
          '${opened.failure}',
        );
      }
      return WebGpuSession._(device, null);
    } on Object catch (error) {
      return WebGpuSession._(null, 'opening the session threw: $error');
    }
  }

  void close() {
    device?.dispose();
  }
}
