/// The Direct2D renderer backend: probe, device, and target creation.
///
/// The same three-level shape as every other renderer in this repository,
/// because `renderer.dart` defines it: [D2dRendererBackend] answers "does
/// this machine have Direct2D", [D2dRenderDevice] is an open factory, and the
/// targets in `d2d_targets.dart` are the pixels of one surface.
///
/// ## Where Direct2D sits in the selection order
///
/// Registered *after* the Direct3D 11 batcher and the OpenGL path and before
/// the GDI CPU presenter - see `default_platform_resolver.dart`. That is a
/// deliberately conservative rank for a new backend: the default picture on a
/// stock Windows machine does not change, while `--presentation=direct2d`
/// (or `DART_UI_PRESENTATION=direct2d`) selects it by name and a machine
/// where the D3D11 and GL probes fail gets it as the accelerated fallback
/// before the CPU. Direct2D rasterises paths, strokes and gradients in the
/// driver at GPU quality - the capabilities the roadmap's section 13.12 lists
/// - so the rank is expected to rise once the differential suite has argued
/// for it; the registration point is one line.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../rendering/framebuffer.dart';
import '../../../rendering/renderer.dart';
import '../d3d12/d3d12_com.dart';
import 'd2d1_interfaces.dart';
import 'd2d1_library.dart';
import 'd2d1_structs.dart';
import 'd2d_targets.dart';

/// Creates an `ID2D1Factory`, or reports why not.
///
/// Shared by the probe and the device so the two can never disagree about
/// what "Direct2D works here" means. The caller owns the returned factory.
({D2dFactory? factory, BackendDiagnostic? failure}) _createFactory(
    D2d1Library library) {
  final Allocator alloc = library.allocator;
  final Pointer<Guid> iid = alloc.allocate<Guid>(sizeOf<Guid>());
  writeGuid(iid, D2d1Iids.factory);
  final Pointer<Pointer<Void>> out =
      alloc.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
  final int hr = library.createFactory(
      d2d1FactoryTypeSingleThreaded, iid, nullptr, out);
  final Pointer<Void> raw = out.value;
  alloc
    ..free(iid)
    ..free(out);
  if (comFailed(hr) || raw == nullptr) {
    return (
      factory: null,
      failure: BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'D2D1CreateFactory failed',
        detail: d2dHresultText(hr),
      ),
    );
  }
  return (factory: D2dFactory(raw), failure: null);
}

/// The Direct2D API as a whole, on this machine.
final class D2dRendererBackend implements RendererBackend {
  const D2dRendererBackend();

  /// Stable identifier; selection policy matches on it, rendering code never.
  static const String backendName = 'direct2d';

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription: 'Direct2D 1.0 over d2d1.dll',
        rasterizationApproach: RasterizationApproach.custom,
      );

  @override
  BackendProbeResult probe() {
    if (!Platform.isWindows) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'Direct2D exists only on Windows; this is '
              '${Platform.operatingSystem}',
        ),
      );
    }
    final D2d1LibraryLoad load = D2d1Library.open();
    final D2d1Library? library = load.library;
    if (library == null) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: load.diagnostics,
      );
    }
    // The DLL loading proves nothing about the runtime; creating and
    // releasing a factory is the cheapest call that does.
    final ({D2dFactory? factory, BackendDiagnostic? failure}) attempt =
        _createFactory(library);
    final D2dFactory? factory = attempt.factory;
    if (factory == null) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: <BackendDiagnostic>[attempt.failure!],
      );
    }
    factory.release();
    return BackendProbeResult(
      backendName: backendName,
      supported: true,
      capabilities: const <Capability>{Capability.gpuPresentation},
      diagnostics: const <BackendDiagnostic>[
        BackendDiagnostic.note(
          'Direct2D factory created; HWND render targets present without a '
          'CPU round trip',
        ),
      ],
    );
  }

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is Win32D2dSurfaceDescriptor;

  @override
  Future<RenderDevice> createDevice() {
    final D2dDeviceAttempt attempt = D2dRenderDevice.open();
    final D2dRenderDevice? device = attempt.device;
    if (device == null) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: attempt.diagnostics,
          ),
        ],
      );
    }
    return Future<RenderDevice>.value(device);
  }
}

/// What [D2dRenderDevice.open] produced, whether or not it succeeded.
final class D2dDeviceAttempt {
  const D2dDeviceAttempt({required this.device, required this.diagnostics});

  /// Null when Direct2D would not open; [diagnostics] says why.
  final D2dRenderDevice? device;

  final List<BackendDiagnostic> diagnostics;

  String get failureText => diagnostics.join('; ');
}

/// An open Direct2D factory.
///
/// "Device" is a loose fit for classic Direct2D - the driver device lives
/// behind each render target - but the contract's shape holds: the factory
/// outlives every target, targets die with their windows, and a
/// `D2DERR_RECREATE_TARGET` from any target marks the whole device lost so
/// the presenter rebuilds the stack, which is the one recovery Direct2D
/// documents.
final class D2dRenderDevice with DisposableMixin implements RenderDevice {
  D2dRenderDevice._({required D2d1Library library, required D2dFactory factory})
      : _library = library,
        _factory = factory;

  /// Opens a device synchronously, reporting failure as data.
  ///
  /// Everything Direct2D needs is a DLL load and one factory call, so there
  /// is nothing to await; [D2dRendererBackend.createDevice] wraps this for
  /// the async contract and tests call it directly, the way
  /// `D3d12RenderDevice.open` is called.
  static D2dDeviceAttempt open() {
    final D2d1LibraryLoad load = D2d1Library.open();
    final D2d1Library? library = load.library;
    if (library == null) {
      return D2dDeviceAttempt(device: null, diagnostics: load.diagnostics);
    }
    final ({D2dFactory? factory, BackendDiagnostic? failure}) attempt =
        _createFactory(library);
    final D2dFactory? factory = attempt.factory;
    if (factory == null) {
      return D2dDeviceAttempt(
        device: null,
        diagnostics: <BackendDiagnostic>[attempt.failure!],
      );
    }
    return D2dDeviceAttempt(
      device: D2dRenderDevice._(library: library, factory: factory),
      diagnostics: const <BackendDiagnostic>[],
    );
  }

  final D2d1Library _library;
  final D2dFactory _factory;
  bool _lost = false;

  @override
  RendererInfo get info => const D2dRendererBackend().info;

  @override
  RendererCapabilities get capabilities => const RendererCapabilities(
        supportsPartialPresent: false,
        supportsMsaa: false,
        supportsCompute: false,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        // The documented ID2D1RenderTarget bitmap limit for feature level
        // 10.0 hardware; older hardware reports less at run time, and this
        // number is advisory metadata, not an allocation this backend makes.
        maxTextureSize: 8192,
        formats: <PixelFormat>{PixelFormat.bgra8888Premultiplied},
      );

  @override
  bool get isLost => _lost;

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is Win32D2dSurfaceDescriptor) {
      return D2dHwndWindowTarget(
        factory: _factory,
        library: _library,
        surface: surface,
        backendName: D2dRendererBackend.backendName,
        onDeviceLost: () => _lost = true,
      );
    }
    throw UnsupportedCapabilityError(
      backendName: D2dRendererBackend.backendName,
      capability: Capability.gpuPresentation,
      detail: 'no target for surface kind "${surface.kind}" '
          '(${surface.runtimeType}); this device presents to '
          'Win32D2dSurfaceDescriptor windows, and offscreen work goes '
          'through D2dOffscreenSurface, which owns its own DIB',
    );
  }

  /// Builds an offscreen readback surface on this device's factory. Not part
  /// of the [RenderDevice] contract; tests and image export use it.
  D2dOffscreenSurface createOffscreenSurface({
    required int width,
    required int height,
  }) {
    throwIfDisposed();
    return D2dOffscreenSurface(
      factory: _factory,
      library: _library,
      width: width,
      height: height,
      backendName: D2dRendererBackend.backendName,
    );
  }

  @override
  void onDispose() {
    _factory.release();
  }
}
