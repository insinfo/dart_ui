/// Putting a display list on a canvas through WebGL2, with no CPU round trip.
///
/// ## Why this is not `RenderTargetPresenter`
///
/// `window_host.dart` already has a presenter that owns a [RenderDevice] and a
/// [RenderTarget], and at a glance it is what this backend wants. It is not,
/// and the reason is one line of its `present`:
///
/// ```dart
/// rasterizeDisplayList(list, frame.framebuffer, ...);
/// ```
///
/// That is the **CPU** rasteriser writing into the frame's CPU-visible pixels.
/// It is exactly right for the path it was written for - the portable one,
/// where a window offers a memory surface and the renderer fills it - and it is
/// exactly wrong here twice over. `Frame.framebuffer` raises a named
/// [StateError] on a canvas target, because a canvas target has no CPU pixels
/// by design; and even if it had, rasterising on the CPU and uploading the
/// result would make the WebGL2 backend an expensive way to run the software
/// renderer.
///
/// So this presenter hands the display list to the target's own
/// [WebGlCanvasTarget.renderDisplayList], which walks it into the [GpuRasterSink]
/// and issues batches. The pixels are produced on the GPU and never come back.
///
/// ## Resize is not a no-op here, and that is the difference from Win32
///
/// [SurfacePresenter.surfaceResized] documents that a presenter which re-reads
/// the window's surface every frame may legitimately do nothing - which is what
/// the Win32 and X11 CPU presenters do. This one must act, because a
/// [WebGlCanvasTarget] holds its descriptor and would otherwise go on setting a
/// viewport from the old size while the canvas's backing store had already
/// changed. The result of skipping it is not a crash: it is a frame drawn into
/// the corner of a larger canvas, which reads as a layout bug.
library;

import 'dart:async';

import '../../app/window_host.dart';
import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list.dart';
import '../../platform/native_window.dart';
import '../../rendering/gpu/webgl/webgl_backend.dart';
import '../../rendering/gpu/webgl/webgl_canvas_target.dart';
import '../../rendering/gpu/webgl/webgl_surface_descriptor.dart';
import '../../rendering/renderer.dart';

/// Presents display lists to a canvas through a [WebGlCanvasTarget].
final class WebGlCanvasPresenter
    with DisposableMixin
    implements SurfacePresenter {
  WebGlCanvasPresenter._(this._target, this._device);

  /// Opens a WebGL2 context on the canvas [window] offers and binds a presenter
  /// to it.
  ///
  /// Throws [BackendSelectionError] when the window offers no canvas surface or
  /// when the browser refuses a context, because that is the shape
  /// `PresentationPathEntry.attach` is called in and the selection machinery
  /// above it turns the error into a report naming every candidate. Failing
  /// quietly here would produce a blank page with nothing in any log, which is
  /// the outcome section 6.6 exists to prevent.
  static Future<WebGlCanvasPresenter> attach(NativeWindow window) async {
    WebGlCanvasSurfaceDescriptor? chosen;
    for (final NativeSurfaceDescriptor surface in window.surfaces) {
      if (surface is WebGlCanvasSurfaceDescriptor) {
        chosen = surface;
        break;
      }
    }
    if (chosen == null) {
      throw BackendSelectionError(
        requested: WebGlRendererBackend.backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            WebGlRendererBackend.backendName,
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
      WebGlCanvasTarget? target,
      WebGlRenderDevice? device,
      BackendDiagnostic? failure,
    }) opened = WebGlCanvasTarget.open(chosen);
    final WebGlCanvasTarget? target = opened.target;
    final WebGlRenderDevice? device = opened.device;
    if (target == null || device == null) {
      throw BackendSelectionError(
        requested: WebGlRendererBackend.backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult.unsupported(
            WebGlRendererBackend.backendName,
            opened.failure ??
                const BackendDiagnostic(
                  kind: DiagnosticKind.connectionFailed,
                  message: 'the canvas refused a WebGL2 context and said '
                      'nothing about why, which is a bug in this backend',
                ),
          ),
        ],
      );
    }
    return WebGlCanvasPresenter._(target, device);
  }

  final WebGlCanvasTarget _target;
  final WebGlRenderDevice _device;

  WebGlCanvasTarget get target => _target;
  WebGlRenderDevice get device => _device;

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
          message: 'the WebGL2 context was lost before the frame was submitted',
        ),
      );
    }
    // The damage rectangle is deliberately dropped. A canvas is composited
    // whole and the context is created with `preserveDrawingBuffer: false`, so
    // the previous frame's pixels are not even guaranteed to be there to keep -
    // which is why `RendererCapabilities.supportsPartialPresent` answers false.
    // Honouring the damage by scissoring the clear would leave the undamaged
    // region undefined rather than intact.
    return _target.renderDisplayList(
      list,
      clearColor: clearColor,
      deviceTransform: deviceTransform ?? Transform2D.identity,
    );
  }

  /// Reconciles the target with the canvas's new backing-store size.
  ///
  /// Not a no-op, unlike the CPU presenters' - see the library comment.
  @override
  void surfaceResized({
    required int pixelWidth,
    required int pixelHeight,
    required double scale,
  }) {
    if (isDisposed) return;
    _target.resize(pixelWidth, pixelHeight, scale);
  }

  /// Runs the recovery on the device, and says whether it can draw again.
  ///
  /// The honest answer here is usually **false on the first try**, and that is
  /// not a failure of this method. A browser restores a lost context
  /// asynchronously and signals it by firing `webglcontextrestored` on the
  /// canvas; a recovery driven before that event has nothing to rebuild on and
  /// [WebGlRenderDevice.recreateDevice] says so by name. A caller that wants
  /// the context back listens for that event and calls this from the handler.
  @override
  Future<bool> recoverFromDeviceLoss() async {
    if (isDisposed) return false;
    return _device.recreateDevice() == null;
  }

  @override
  void onDispose() {
    _target.dispose();
    _device.dispose();
    // The canvas is not touched: the page created it. See
    // `WebGlCanvasSurfaceDescriptor`'s note on borrowing.
  }
}
