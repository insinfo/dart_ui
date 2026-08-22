/// Putting a display list on a canvas through WebGPU, with no CPU round trip.
///
/// The WebGPU twin of `web_gl_presenter.dart`, and that file's two arguments
/// carry over whole: this is not `RenderTargetPresenter`, because that
/// presenter's `present` runs the CPU rasteriser into `Frame.framebuffer` and
/// a canvas target has no CPU pixels by design; and `surfaceResized` is not a
/// no-op, because the target holds its descriptor and would otherwise set a
/// viewport for a canvas whose backing store has already changed.
///
/// ## Where this presenter sits in the selection, and how the fallback works
///
/// This entry is meant to be listed *before* the WebGL2 one, and the fallback
/// is the selection machinery's, not this file's: `Application.openWindow`
/// catches an attach that throws, records the failure against this path's
/// name, re-runs selection and attaches the next candidate. What this file
/// contributes is the part only it can get right - the order of operations
/// inside [attach]. Everything the browser can refuse asynchronously (the
/// adapter, the device, the renderer objects) is asked *before* the canvas is
/// touched, so a refusal leaves the element virgin and
/// `WebGlCanvasPresenter.attach` still gets its `webgl2` context from the
/// same canvas. See `WebGpuCanvasTarget.open` for the numbered order and
/// `webgpu_interop.dart` for the `getContext` fact it rests on.
///
/// ## Recovery is asynchronous here, and that is the API's shape
///
/// A lost WebGL context is restored in place and signalled by an event; a
/// lost `GPUDevice` never comes back, and its replacement can only be
/// requested through promises. So [recoverFromDeviceLoss] - which is async in
/// the [SurfacePresenter] contract precisely for backends like this one -
/// awaits a fresh adapter and device, stages the answer on the device with
/// `stageReplacementDevice`, and then drives the standard eight-step recovery
/// through a [GpuRecoveryCoordinator], which rebuilds the shared pipeline
/// objects, reconfigures the canvas context and repopulates every target
/// resource in the order `gpu_recovery.dart` argues for.
library;

import 'dart:async';

import '../../app/window_host.dart';
import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list.dart';
import '../../platform/native_window.dart';
import '../../rendering/gpu/gpu_recovery.dart';
import '../../rendering/gpu/webgpu/webgpu_backend.dart';
import '../../rendering/gpu/webgpu/webgpu_canvas_target.dart';
import '../../rendering/gpu/webgpu/webgpu_interop.dart';
import '../../rendering/gpu/webgpu/webgpu_surface_descriptor.dart';
import '../../rendering/renderer.dart';

/// Presents display lists to a canvas through a [WebGpuCanvasTarget].
final class WebGpuCanvasPresenter
    with DisposableMixin
    implements SurfacePresenter {
  WebGpuCanvasPresenter._(this._target, this._device)
      : _recovery = GpuRecoveryCoordinator(host: _device);

  /// Requests a WebGPU device, configures the canvas [window] offers, and
  /// binds a presenter to it.
  ///
  /// Throws [BackendSelectionError] when the window offers no WebGPU canvas
  /// surface or when the browser refuses anywhere along the chain, because
  /// that is the shape `PresentationPathEntry.attach` is called in and the
  /// selection machinery above turns the error into a report naming every
  /// candidate - which for this backend is also what makes the WebGL2
  /// fallback automatic rather than silent.
  static Future<WebGpuCanvasPresenter> attach(NativeWindow window) async {
    WebGpuCanvasSurfaceDescriptor? chosen;
    for (final NativeSurfaceDescriptor surface in window.surfaces) {
      if (surface is WebGpuCanvasSurfaceDescriptor) {
        chosen = surface;
        break;
      }
    }
    if (chosen == null) {
      throw BackendSelectionError(
        requested: WebGpuRendererBackend.backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            WebGpuRendererBackend.backendName,
            BackendDiagnostic(
              kind: DiagnosticKind.surfaceCreationFailed,
              message: 'this window offers no canvas to draw on',
              detail: window.surfaces.isEmpty
                  ? 'the window offers no surfaces at all, which is what a '
                      'closed window reports'
                  : 'offered: ${window.surfaces.map(
                        (NativeSurfaceDescriptor s) => s.kind,
                      ).join(', ')}',
            ),
          ),
        ],
      );
    }

    final ({
      WebGpuCanvasTarget? target,
      WebGpuRenderDevice? device,
      BackendDiagnostic? failure,
    }) opened = await WebGpuCanvasTarget.open(chosen);
    final WebGpuCanvasTarget? target = opened.target;
    final WebGpuRenderDevice? device = opened.device;
    if (target == null || device == null) {
      throw BackendSelectionError(
        requested: WebGpuRendererBackend.backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            WebGpuRendererBackend.backendName,
            opened.failure ??
                const BackendDiagnostic(
                  kind: DiagnosticKind.connectionFailed,
                  message: 'the browser refused a WebGPU device and said '
                      'nothing about why, which is a bug in this backend',
                ),
          ),
        ],
      );
    }
    return WebGpuCanvasPresenter._(target, device);
  }

  final WebGpuCanvasTarget _target;
  final WebGpuRenderDevice _device;
  final GpuRecoveryCoordinator _recovery;

  WebGpuCanvasTarget get target => _target;
  WebGpuRenderDevice get device => _device;

  @override
  RendererInfo get info => _device.info;

  @override
  bool get isDeviceLost => _device.isLost;

  @override
  Future<PresentResult> present(
    DisplayList list, {
    int? clearColor,
    Transform2D? deviceTransform,
    Rect? damage,
  }) async {
    throwIfDisposed();
    if (_device.isLost) {
      return const PresentResult(
        status: PresentStatus.deviceLost,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the GPUDevice was lost before the frame was submitted',
        ),
      );
    }
    // The damage rectangle is deliberately dropped, for the WebGL presenter's
    // reason: a canvas is composited whole, the swap texture starts each task
    // undefined, and `supportsPartialPresent` answers false accordingly.
    return _target.renderDisplayList(
      list,
      clearColor: clearColor,
      deviceTransform: deviceTransform ?? Transform2D.identity,
    );
  }

  /// Reconciles the target with the canvas's new backing-store size.
  ///
  /// Not a no-op, unlike the CPU presenters' - see `web_gl_presenter.dart`.
  @override
  void surfaceResized({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  }) {
    if (isDisposed) return;
    _target.resize(pixelWidth, pixelHeight, scale);
  }

  /// Requests a fresh device, stages it, and runs the standard recovery.
  ///
  /// Returns false when the browser answered no adapter or device - the
  /// machine may genuinely have lost its GPU - or when the coordinator's
  /// policy has given up. Unlike the WebGL presenter there is no event to
  /// wait for before trying: a new `requestDevice` is answerable the moment
  /// the loss is observed, so this method does the whole job in one call.
  @override
  Future<bool> recoverFromDeviceLoss() async {
    if (isDisposed) return false;
    if (!_device.isLost) return true;
    final ({
      GPU? gpu,
      GPUAdapter? adapter,
      GPUDevice? device,
      BackendDiagnostic? failure,
    }) answer = await WebGpuRendererBackend.requestDevice();
    final GPUDevice? replacement = answer.device;
    if (replacement == null) {
      // No replacement to build on. The device stays lost, the reason stays
      // recorded, and the caller tears down rather than spinning - which is
      // exactly what SurfacePresenter.recoverFromDeviceLoss documents.
      return false;
    }
    _device.stageReplacementDevice(
      replacement,
      deviceDescription: describeWebGpuAdapter(answer.adapter),
    );
    final GpuRecoveryReport report = _recovery.recover();
    return report.status == GpuRecoveryStatus.recovered ||
        report.status == GpuRecoveryStatus.recoveredWithLosses ||
        report.status == GpuRecoveryStatus.notLost;
  }

  @override
  void onDispose() {
    _target.dispose();
    _device.dispose();
    // The canvas is not touched: the page created it. See
    // `WebGpuCanvasSurfaceDescriptor`'s note on borrowing.
  }
}
