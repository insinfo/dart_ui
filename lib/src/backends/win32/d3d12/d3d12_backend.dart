/// The Direct3D 12 renderer backend, and the hidden window its tests present
/// to.
///
/// [D3d12RendererBackend] is the entry point selection sees: it answers
/// [probe] with a report naming exactly what is missing on a machine that
/// cannot run it, and [createDevice] with an open [D3d12RenderDevice].
///
/// ## The probe really creates a device
///
/// It would be cheaper to answer from `D3D12CreateDevice(nullptr, 11_0, ...,
/// nullptr)`, which the API accepts as a "can you" question without producing
/// an object. That was rejected for the reason section 6.6 exists: a probe that
/// only asks whether a device *could* exist reports success on a machine where
/// the shader compiler is missing, where the root signature is refused, or
/// where the adapter answers and then fails to create a command queue - and the
/// caller then discovers it after selection has already committed. This probe
/// therefore opens the whole thing, shaders and pipeline states included, and
/// throws it away. It costs tens of milliseconds once per process, and
/// `D3d12Library.open` is cached so the DLLs are opened once.
library;

import 'dart:async';
import 'dart:ffi';

import '../../../foundation/diagnostics.dart';
import '../../../rendering/gpu/d3d12/d3d12_surface_descriptor.dart';
import '../../../rendering/renderer.dart';
import '../win32_api.dart';
import '../win32_constants.dart';
import '../win32_structs.dart';
import 'd3d12_device.dart';

/// The Direct3D 12 renderer backend.
final class D3d12RendererBackend implements RendererBackend {
  const D3d12RendererBackend({this.debugLayer = false});

  static const String backendName = D3d12RenderDevice.backendName;

  /// Whether to enable `ID3D12Debug` before creating the device.
  ///
  /// False by default and never inferred from the Dart VM's assert mode - see
  /// the debug layer section of `d3d12_device.dart` for why that is a decision
  /// rather than an omission.
  final bool debugLayer;

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription: 'Direct3D 12 over DXGI, flip-model swap chains',
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      );

  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor ||
      surface is D3d12WindowSurfaceDescriptor;

  /// Whether Direct3D 12 can run here, and if not, exactly what was missing.
  ///
  /// Never throws - not for a missing DLL, not for a driver that returns
  /// nonsense, not for a bug in this file.
  @override
  BackendProbeResult probe() {
    try {
      return _probe();
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the Direct3D 12 probe threw, which is a bug in the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  BackendProbeResult _probe() {
    final D3d12DeviceAttempt attempt =
        D3d12RenderDevice.open(debugLayer: debugLayer);
    final D3d12RenderDevice? device = attempt.device;
    if (device == null) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: attempt.diagnostics,
      );
    }
    try {
      return BackendProbeResult(
        backendName: backendName,
        supported: true,
        capabilities: const <Capability>{
          Capability.gpuPresentation,
          Capability.vsync,
        },
        diagnostics: <BackendDiagnostic>[
          ...attempt.diagnostics,
          BackendDiagnostic.note(
            'Direct3D 12 on "${device.info.deviceDescription}" at feature '
            'level ${device.featureLevelText}',
          ),
          const BackendDiagnostic.note(
            'this backend draws rectangles, antialiased paths through a '
            'coverage-mask atlas, images and text; it refuses a saveLayer '
            'that needs a real offscreen pass, by name, because it passes no '
            'GpuLayerStack to its sink',
          ),
        ],
      );
    } finally {
      device.dispose();
    }
  }

  @override
  Future<RenderDevice> createDevice() async {
    final D3d12DeviceAttempt attempt =
        D3d12RenderDevice.open(debugLayer: debugLayer);
    final D3d12RenderDevice? device = attempt.device;
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
    return device;
  }
}

/// What [D3d12HiddenWindow.create] found.
final class D3d12HiddenWindowAttempt {
  const D3d12HiddenWindowAttempt(this.window, this.diagnostics);

  final D3d12HiddenWindow? window;
  final List<BackendDiagnostic> diagnostics;
}

/// A top-level window that is never shown, for a swap chain to present into.
///
/// The same trick `Win32GlSurface.hidden` plays, and for the same reason: a
/// swap chain needs a real window, a real window needs a window class and a
/// message loop's worth of ceremony, and a test that wants to prove
/// `CreateSwapChainForHwnd` works should not also have to put something on the
/// operator's screen. A window that is never passed to `ShowWindow` still has
/// a valid handle, a client rectangle and everything DXGI asks of it.
///
/// This lives under `lib/src/backends/win32` because it is the only place in
/// the tree allowed to name a window at all - see
/// `test/architecture/layering_test.dart`.
final class D3d12HiddenWindow {
  D3d12HiddenWindow._(this._api, this.handle, this._className);

  final Win32Api _api;

  /// The window, as the opaque integer everything above this file treats it
  /// as. Goes straight into [D3d12WindowSurfaceDescriptor.nativeHandle].
  final int handle;

  final Pointer<Uint16> _className;
  bool _disposed = false;

  /// Creates the window, or names what stopped it. Never throws.
  static D3d12HiddenWindowAttempt create({
    int width = 64,
    int height = 64,
    String className = 'DartUiD3d12Surface',
  }) {
    final Win32LoadResult load = Win32Api.load();
    final Win32Api? api = load.api;
    if (api == null) return D3d12HiddenWindowAttempt(null, load.diagnostics);
    try {
      return _create(api, width, height, className);
    } on Object catch (error, stack) {
      return D3d12HiddenWindowAttempt(null, <BackendDiagnostic>[
        BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'creating the hidden Direct3D 12 window threw',
          detail: '$error\n$stack',
        ),
      ]);
    }
  }

  static D3d12HiddenWindowAttempt _create(
    Win32Api api,
    int width,
    int height,
    String className,
  ) {
    // `DefWindowProcW` as a *pointer*, not as a Dart callable: the class needs
    // the address of the system's own procedure, and a Dart callback that
    // forwarded to it would add a trampoline for no behaviour. A hidden window
    // never dispatches a message anyway - nothing pumps its queue - so the
    // default procedure is the whole of its behaviour.
    final Pointer<NativeFunction<WndProcNative>> defaultWindowProc =
        DynamicLibrary.open('user32.dll')
            .lookup<NativeFunction<WndProcNative>>('DefWindowProcW');

    final int instance = api.getModuleHandleW(nullptr);
    final Pointer<Uint16> name = api.toUtf16(className);
    final Pointer<WndClassExW> descriptor = api.allocator<WndClassExW>();
    descriptor.ref
      ..cbSize = sizeOf<WndClassExW>()
      ..style = csOwndc | csHredraw | csVredraw
      ..lpfnWndProc = defaultWindowProc
      ..cbClsExtra = 0
      ..cbWndExtra = 0
      ..hInstance = instance
      ..hIcon = 0
      ..hCursor = 0
      ..hbrBackground = 0
      ..lpszMenuName = nullptr
      ..lpszClassName = name
      ..hIconSm = 0;
    final int atom = api.registerClassExW(descriptor);
    api.allocator.free(descriptor);
    if (atom == 0) {
      // "Already registered" is not a failure: a second window in the same
      // process reuses the class, which is why the error code is inspected
      // rather than the return value alone.
      final int error = api.getLastError();
      if (error != _errorClassAlreadyExists) {
        api.heapRelease(name);
        return D3d12HiddenWindowAttempt(null, <BackendDiagnostic>[
          BackendDiagnostic(
            kind: DiagnosticKind.surfaceCreationFailed,
            message: 'the Direct3D 12 window class could not be registered',
            detail: 'GetLastError=$error',
          ),
        ]);
      }
    }

    final Pointer<Uint16> title = api.toUtf16('dart_ui Direct3D 12 surface');
    final int window = api.createWindowExW(
      0,
      name,
      title,
      wsOverlappedWindow,
      0,
      0,
      width,
      height,
      0,
      0,
      instance,
      0,
    );
    api.heapRelease(title);
    if (window == 0) {
      final int error = api.getLastError();
      api.heapRelease(name);
      return D3d12HiddenWindowAttempt(null, <BackendDiagnostic>[
        BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the hidden Direct3D 12 window could not be created',
          detail: 'GetLastError=$error',
        ),
      ]);
    }

    return D3d12HiddenWindowAttempt(
      D3d12HiddenWindow._(api, window, name),
      const <BackendDiagnostic>[],
    );
  }

  /// A descriptor naming this window at [width] by [height] physical pixels.
  D3d12WindowSurfaceDescriptor describe({
    required int width,
    required int height,
    int bufferCount = D3d12WindowSurfaceDescriptor.kDefaultBufferCount,
  }) =>
      D3d12WindowSurfaceDescriptor(
        nativeHandle: handle,
        pixelWidth: width,
        pixelHeight: height,
        bufferCount: bufferCount,
        description: 'hidden test window',
      );

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _api
      ..destroyWindow(handle)
      // The class is deliberately not unregistered: another window of the same
      // class may still be alive in this process, and UnregisterClass would
      // fail for it rather than for this one.
      ..heapRelease(_className);
  }
}

/// `ERROR_CLASS_ALREADY_EXISTS`.
const int _errorClassAlreadyExists = 1410;
