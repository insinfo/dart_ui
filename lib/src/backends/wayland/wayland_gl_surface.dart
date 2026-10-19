/// EGL/GBM rendering presented through linux-dmabuf, without a pixel readback.
/// The raw Wayland transport owns protocol IDs; GBM owns the exported storage.
library;

import 'dart:ffi';
import 'dart:io';

import '../../foundation/diagnostics.dart';
import '../../foundation/lifecycle.dart';
import '../../rendering/gpu/gl/gl_backend.dart';
import '../../rendering/gpu/gl/gl_bindings.dart';
import '../../rendering/gpu/gl/gl_context.dart';
import '../../rendering/gpu/gl/gl_surface_descriptor.dart';
import 'wayland_dma_buf.dart';
import 'wayland_window.dart';

/// One native GPU swapchain for a Wayland surface. GBM buffers stay locked
/// until wl_buffer.release, including across resizes and window teardown.
final class WaylandGlSurface implements GlSwapChain {
  WaylandGlSurface._(this.window, this._gbm, this.context, this._egl,
      this.glLibrary, this._current) {
    _generations.add(_current);
  }

  final WaylandWindow? window;
  final _GbmApi _gbm;
  final GlContext context;
  final GlSwapChain _egl;
  final DynamicLibrary glLibrary;
  _GbmGeneration _current;
  final List<_GbmGeneration> _generations = <_GbmGeneration>[];
  bool _disposed = false;
  BackendDiagnostic? lastFailure;
  bool _waitingForBuffer = false;
  int submittedFrames = 0;
  int importedBuffers = 0;
  int releasedBuffers = 0;
  int get liveGenerations => _generations.length;

  static BackendProbeResult probe() {
    if (!Platform.isLinux) {
      return BackendProbeResult(
          backendName: 'opengl',
          supported: false,
          diagnostics: const <BackendDiagnostic>[
            BackendDiagnostic(
                kind: DiagnosticKind.unsupportedPlatform,
                message: 'Wayland GBM presentation requires Linux')
          ]);
    }
    WaylandGlSurface? surface;
    GlRenderDevice? device;
    try {
      surface = _open(null);
      device =
          GlRendererBackend.adoptContext(surface.context, surface.glLibrary);
      return BackendProbeResult(
          backendName: 'opengl',
          supported: true,
          capabilities: const <Capability>{
            Capability.gpuPresentation,
            Capability.vsync
          },
          diagnostics: <BackendDiagnostic>[
            BackendDiagnostic.note(
                'EGL/GBM with linux-dmabuf: ${device.info.deviceDescription}')
          ]);
    } on Object catch (error) {
      return BackendProbeResult(
          backendName: 'opengl',
          supported: false,
          diagnostics: <BackendDiagnostic>[
            BackendDiagnostic(
                kind: DiagnosticKind.incompatibleDevice,
                message: 'Wayland OpenGL presentation is unavailable',
                detail: '$error')
          ]);
    } finally {
      device?.dispose();
      surface?.dispose();
    }
  }

  static WaylandGlSurface forWindow(WaylandWindow window) {
    if (!(window.dmaBufClient?.supportsDmaBuf ?? false)) {
      throw StateError('The Wayland compositor does not offer linux-dmabuf v3');
    }
    final surface = _open(window);
    try {
      // Validate import before attachment succeeds. Cached imports are reused;
      // roundtrips are paid only for a new GBM BO, never for each frame.
      if (!surface._egl.swapBuffers()) {
        throw StateError('Initial GBM swap failed');
      }
      final bo = surface._gbm.lockFrontBuffer(surface._current.surface);
      if (bo == nullptr) {
        throw StateError('GBM returned no initial front buffer');
      }
      surface._current.locked.add(bo.address);
      try {
        surface._import(surface._current, bo);
      } finally {
        surface._unlock(surface._current, bo);
      }
      return surface;
    } on Object {
      surface.dispose();
      rethrow;
    }
  }

  static WaylandGlSurface _open(WaylandWindow? window) {
    final gbm = _GbmApi.open();
    _GbmGeneration? generation;
    GlContext? context;
    try {
      final pixels = window?.pixelSize ?? (width: 16, height: 16);
      generation = gbm.createSurface(pixels.width, pixels.height);
      final load = GlLibrary.open();
      if (!load.isLoaded) throw StateError('OpenGL library: ${load.error}');
      final attempt = const GlContextFactory().createForWindowSurface(
        nativeWindow: generation.surface.address,
        nativeDisplay: gbm.device.address,
        eglPlatform: 0x31d7, // EGL_PLATFORM_GBM_KHR
        nativeVisualId: drmFormatArgb8888,
        glLibrary: load.library!,
      );
      context = attempt.context;
      if (context == null || attempt.swapChain == null) {
        throw StateError(attempt.diagnostics.join('\n'));
      }
      return WaylandGlSurface._(
          window, gbm, context, attempt.swapChain!, load.library!, generation);
    } on Object {
      context?.dispose();
      if (generation != null) gbm.destroySurface(generation.surface);
      gbm.dispose();
      rethrow;
    }
  }

  GlWindowSurfaceDescriptor describeSurface(
          {required int pixelWidth,
          required int pixelHeight,
          required double scale}) =>
      GlWindowSurfaceDescriptor(
          generation: window?.surfaceGenerationToken ?? GenerationToken(),
          nativeHandle: _current.surface.address,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
          scale: scale,
          swapChain: this);

  int _import(_GbmGeneration generation, Pointer<Void> bo) {
    final cached = generation.buffers[bo.address];
    if (cached != null) return cached;
    final client = window!.dmaBufClient!;
    final count = _gbm.planeCount(bo);
    if (count < 1 || count > 4) {
      throw StateError('Unsupported GBM plane count: $count');
    }
    final format = _gbm.format(bo);
    final actualModifier = _gbm.modifier(bo);
    final modifier = client.supportsDmaBufFormat(format, actualModifier)
        ? actualModifier
        : drmFormatModInvalid;
    final planes = <WaylandDmaBufPlane>[];
    try {
      for (var index = 0; index < count; index++) {
        final fd = _gbm.fdForPlane(bo, index);
        if (fd < 0) throw StateError('Could not export GBM plane $index');
        planes.add(WaylandDmaBufPlane(
            fd: fd,
            stride: _gbm.strideForPlane(bo, index),
            offset: _gbm.offset(bo, index),
            modifier: modifier));
      }
      final buffer = client.importDmaBuf(
          width: generation.width,
          height: generation.height,
          format: format,
          planes: planes,
          onRelease: () {
            releasedBuffers++;
            _unlock(generation, bo);
          });
      importedBuffers++;
      generation.buffers[bo.address] = buffer;
      return buffer;
    } finally {
      for (final plane in planes) {
        _gbm.closeFd(plane.fd);
      }
    }
  }

  void _unlock(_GbmGeneration generation, Pointer<Void> bo) {
    if (!generation.locked.remove(bo.address)) return;
    _gbm.releaseBuffer(generation.surface, bo);
    _collect(generation);
    if (_waitingForBuffer && !_disposed && !generation.retired) {
      _waitingForBuffer = false;
      window?.requestRedraw();
    }
  }

  void _retire(_GbmGeneration generation) {
    generation.retired = true;
    for (final id in generation.buffers.values) {
      window?.dmaBufClient?.destroyDmaBuf(id);
    }
    _collect(generation);
  }

  void _collect(_GbmGeneration generation) {
    if (!generation.retired ||
        generation.locked.isNotEmpty ||
        generation.destroyed) {
      return;
    }
    generation.destroyed = true;
    _gbm.destroySurface(generation.surface);
    _generations.remove(generation);
    if (_disposed && _generations.isEmpty) _gbm.dispose();
  }

  @override
  bool get isPresentable => !_disposed && !(window?.isDisposed ?? false);

  @override
  bool swapBuffers() {
    if (!isPresentable || window == null) return false;
    final owner = window!;
    if (!owner.isConfigured) return true;
    if (owner.isFrameThrottled) {
      owner.deferGpuFrame();
      return true;
    }
    if (_gbm.hasFreeBuffers(_current.surface) == 0) {
      _waitingForBuffer = true;
      return true;
    }
    if (!_egl.swapBuffers()) return false;
    final generation = _current;
    final bo = _gbm.lockFrontBuffer(generation.surface);
    if (bo == nullptr) return false;
    generation.locked.add(bo.address);
    try {
      final id = _import(generation, bo);
      if (!owner.presentDmaBuf(id, generation.width, generation.height)) {
        _unlock(generation, bo);
        return false;
      }
      submittedFrames++;
      return true;
    } on Object catch (error) {
      _unlock(generation, bo);
      lastFailure = BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'Wayland GPU buffer presentation failed',
          detail: '$error');
      return false;
    }
  }

  @override
  bool setSwapInterval(int interval) {
    // GBM has no display vblank. wl_surface.frame supplies presentation pacing.
    return _egl.setSwapInterval(0);
  }

  @override
  BackendDiagnostic? reconfigure(
      {required int pixelWidth, required int pixelHeight}) {
    if (_current.width == pixelWidth && _current.height == pixelHeight) {
      return null;
    }
    if (!isPresentable) {
      return const BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'Wayland GPU surface is closed');
    }
    _GbmGeneration? replacement;
    try {
      replacement = _gbm.createSurface(pixelWidth, pixelHeight);
      final reconfigurer = context as GlWindowSurfaceReconfigurer;
      final failure =
          reconfigurer.replaceNativeWindow(replacement.surface.address);
      if (failure != null) {
        _gbm.destroySurface(replacement.surface);
        return failure;
      }
      final old = _current;
      _current = replacement;
      _generations.add(replacement);
      _retire(old);
      return null;
    } on Object catch (error) {
      if (replacement != null && !identical(_current, replacement)) {
        _gbm.destroySurface(replacement.surface);
      }
      return BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'Could not resize the Wayland GPU surface',
          detail: '$error');
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    context.dispose();
    for (final generation in List<_GbmGeneration>.of(_generations)) {
      _retire(generation);
    }
  }
}

final class _GbmGeneration {
  _GbmGeneration(this.surface, this.width, this.height);
  final Pointer<Void> surface;
  final int width;
  final int height;
  final Map<int, int> buffers = <int, int>{};
  final Set<int> locked = <int>{};
  bool retired = false;
  bool destroyed = false;
}

final class _GbmApi {
  _GbmApi(this.library, this.libc, this.heap, this.fd, this.device);
  final DynamicLibrary library;
  final DynamicLibrary libc;
  final NativeHeap heap;
  final int fd;
  final Pointer<Void> device;
  bool _disposed = false;

  static _GbmApi open() {
    if (!Platform.isLinux) throw UnsupportedError('GBM requires Linux');
    final library = DynamicLibrary.open('libgbm.so.1');
    final libc = DynamicLibrary.open('libc.so.6');
    final heap = NativeHeap.tryBind(libc)!;
    final openFd = libc.lookupFunction<Int32 Function(Pointer<Uint8>, Int32),
        int Function(Pointer<Uint8>, int)>('open');
    final close =
        libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
    final create = library.lookupFunction<Pointer<Void> Function(Int32),
        Pointer<Void> Function(int)>('gbm_create_device');
    final nodes = Directory('/dev/dri')
        .listSync()
        .where((e) => e.path.split('/').last.startsWith('renderD'))
        .map((e) => e.path)
        .toList()
      ..sort();
    for (final node in nodes) {
      final name = heap.allocateUtf8(node);
      final fd = openFd(name, 2 | 0x80000); // O_RDWR | O_CLOEXEC
      heap.release(name);
      if (fd < 0) continue;
      final device = create(fd);
      if (device != nullptr) return _GbmApi(library, libc, heap, fd, device);
      close(fd);
    }
    throw StateError('No DRM render node could be opened for GBM');
  }

  late final _createSurface = library.lookupFunction<
      Pointer<Void> Function(Pointer<Void>, Uint32, Uint32, Uint32, Uint32),
      Pointer<Void> Function(
          Pointer<Void>, int, int, int, int)>('gbm_surface_create');
  late final destroySurface = library.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('gbm_surface_destroy');
  late final lockFrontBuffer = library.lookupFunction<
      Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)>('gbm_surface_lock_front_buffer');
  late final releaseBuffer = library.lookupFunction<
      Void Function(Pointer<Void>, Pointer<Void>),
      void Function(
          Pointer<Void>, Pointer<Void>)>('gbm_surface_release_buffer');
  late final hasFreeBuffers = library.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('gbm_surface_has_free_buffers');
  late final planeCount = library.lookupFunction<Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('gbm_bo_get_plane_count');
  late final modifier = library.lookupFunction<Uint64 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('gbm_bo_get_modifier');
  late final format = library.lookupFunction<Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('gbm_bo_get_format');
  late final fdForPlane = library.lookupFunction<
      Int32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)>('gbm_bo_get_fd_for_plane');
  late final strideForPlane = library.lookupFunction<
      Uint32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)>('gbm_bo_get_stride_for_plane');
  late final offset = library.lookupFunction<
      Uint32 Function(Pointer<Void>, Int32),
      int Function(Pointer<Void>, int)>('gbm_bo_get_offset');
  late final closeFd =
      libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  _GbmGeneration createSurface(int width, int height) {
    final surface =
        _createSurface(device, width, height, drmFormatArgb8888, 1 << 2);
    if (surface == nullptr) {
      throw StateError('gbm_surface_create(${width}x$height) failed');
    }
    return _GbmGeneration(surface, width, height);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('gbm_device_destroy')(device);
    closeFd(fd);
  }
}
