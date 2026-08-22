/// Platform-aware defaults used by the public `runApp` facade.
///
/// This file deliberately lives under `backends`: it is the composition root
/// that is allowed to know concrete platforms. `lib/src/app` remains portable
/// and receives only factories and common contracts.
library;

import 'dart:io';

import '../app/application.dart';
import '../foundation/diagnostics.dart';
import '../foundation/lifecycle.dart';
import '../geometry/rect.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../platform/native_window.dart';
import '../rendering/cpu_renderer.dart';
import '../rendering/framebuffer.dart';
import '../rendering/gpu/d3d11/d3d11_backend.dart';
import '../rendering/gpu/gl/gl_backend.dart';
import '../rendering/renderer.dart';
import 'headless/headless_backend.dart';
import 'macos/macos.dart';
import 'wayland/wayland_backend.dart';
import 'wayland/wayland_cpu_presenter.dart';
import 'wayland/wayland_window.dart';
import 'win32/d2d/d2d_backend.dart';
import 'win32/d2d/d2d_targets.dart';
import 'win32/d3d11/win32_d3d11_surface.dart';
import 'win32/win32.dart';
import 'win32/win32_gl_surface.dart';
import 'x11/x11_backend.dart';
import 'x11/x11_cpu_presenter.dart';
import 'x11/x11_gl_surface.dart';
import 'x11/x11_window.dart';

/// Resolves the production defaults without leaking native backend types into
/// application code.
final class PlatformBackendResolver {
  const PlatformBackendResolver._();

  /// Native windowing first, headless last.
  static List<WindowingBackendEntry> defaultBackends({
    ApplicationOptions options = const ApplicationOptions(),
    String? operatingSystem,
  }) {
    final String platform = operatingSystem ?? Platform.operatingSystem;
    return <WindowingBackendEntry>[
      if (platform == 'windows')
        const WindowingBackendEntry(
          name: 'win32',
          create: Win32WindowingBackend.new,
        ),
      // Wayland is probed first: its probe only succeeds when the session
      // variables point at a compositor that actually answers the registry
      // handshake, so an X11 session falls through with the reason on record.
      if (platform == 'linux')
        WindowingBackendEntry(
          name: 'wayland',
          create: options.environment.isEmpty
              ? WaylandWindowingBackend.new
              : () =>
                  WaylandWindowingBackend(environment: options.environment),
        ),
      if (platform == 'linux')
        WindowingBackendEntry(
          name: 'x11',
          create: options.environment.isEmpty
              ? X11WindowingBackend.new
              : () => X11WindowingBackend(environment: options.environment),
        ),
      if (platform == 'macos')
        const WindowingBackendEntry(
          name: 'macos',
          create: MacosWindowingBackend.new,
        ),
      WindowingBackendEntry(
        name: 'headless',
        create: () => HeadlessWindowingBackend(
          renderScale: options.headlessRenderScale,
        ),
      ),
    ];
  }

  /// GPU paths first, native CPU presentation next, headless memory last.
  ///
  /// Every native entry declares the windowing backend it can attach to. If a
  /// display server probe loses and the headless backend wins, selection skips
  /// those entries and reaches the portable CPU path instead of failing a
  /// platform cast after the window has already been created.
  static List<PresentationPathEntry> defaultPresentations({
    String? operatingSystem,
  }) {
    final String platform = operatingSystem ?? Platform.operatingSystem;
    return <PresentationPathEntry>[
      if (platform == 'windows') ...<PresentationPathEntry>[
        _win32D3d11(),
        _win32OpenGl(),
        // After the established GPU paths so the default picture on a stock
        // machine does not change while Direct2D is new, and before the DIB
        // presenter so a machine whose D3D11/GL probes fail still gets an
        // accelerated path. `--presentation=direct2d` pins it by name.
        _win32Direct2d(),
        PresentationPathEntry.retainedCpu(
          name: 'win32-dib',
          deviceDescription: 'GDI DIB section, BGRA8888 top-down',
          compatibleWindowingBackends: const <String>{'win32'},
          create: (NativeWindow window) {
            final Win32CpuPresenter presenter =
                Win32CpuPresenter(window as Win32Window);
            return (
              present: presenter.renderDisplayList,
              presentNow: presenter.renderDisplayListNow,
              release: presenter.dispose,
            );
          },
        ),
      ],
      if (platform == 'linux') ...<PresentationPathEntry>[
        _x11OpenGl(),
        PresentationPathEntry.retainedCpu(
          name: 'wayland-shm',
          deviceDescription: 'wl_shm ARGB8888 shared memory, BGRA8888',
          compatibleWindowingBackends: const <String>{'wayland'},
          create: (NativeWindow window) {
            final WaylandCpuPresenter presenter =
                WaylandCpuPresenter(window as WaylandWindow);
            return (
              present: presenter.renderDisplayList,
              presentNow: null,
              release: presenter.dispose,
            );
          },
        ),
        PresentationPathEntry.retainedCpu(
          name: 'x11-putimage',
          deviceDescription: 'X11 core PutImage, BGRA8888',
          compatibleWindowingBackends: const <String>{'x11'},
          create: (NativeWindow window) {
            final X11CpuPresenter presenter =
                X11CpuPresenter(window as X11Window);
            return (
              present: presenter.renderDisplayList,
              presentNow: null,
              release: presenter.dispose,
            );
          },
        ),
      ],
      if (platform == 'macos') _macosCpu(),
      PresentationPathEntry.cpuRenderer(
        backend: const CpuRendererBackend(),
        name: 'headless-cpu',
      ),
    ];
  }

  static PresentationPathEntry _win32D3d11() {
    const D3d11RendererBackend renderer = D3d11RendererBackend();
    return PresentationPathEntry.directRenderer(
      backend: renderer,
      compatibleWindowingBackends: const <String>{'win32'},
      createAttachment: (RendererBackend backend, NativeWindow native) async {
        final RenderDevice rawDevice = await backend.createDevice();
        if (rawDevice is! D3d11RenderDevice || native is! Win32Window) {
          rawDevice.dispose();
          throw StateError('direct3d11 requires D3d11RenderDevice and '
              'Win32Window; got ${rawDevice.runtimeType} and '
              '${native.runtimeType}');
        }
        final Win32D3d11SurfaceAttempt attempt = Win32D3d11Surface.forWindow(
          rawDevice,
          native.handle,
          pixelWidth: _pixelWidth(native),
          pixelHeight: _pixelHeight(native),
        );
        final Win32D3d11Surface? surface = attempt.surface;
        if (surface == null) {
          rawDevice.dispose();
          _throwAttachmentFailure(
            D3d11RendererBackend.backendName,
            attempt.diagnostics,
          );
        }
        return (
          device: rawDevice,
          surface: surface.describeSurface(
            pixelWidth: _pixelWidth(native),
            pixelHeight: _pixelHeight(native),
            scale: native.renderScale,
          ),
          releaseSurface: surface.dispose,
          releaseSurfaceBeforeDevice: true,
        );
      },
    );
  }

  static PresentationPathEntry _win32Direct2d() {
    const D2dRendererBackend renderer = D2dRendererBackend();
    return PresentationPathEntry.directRenderer(
      backend: renderer,
      compatibleWindowingBackends: const <String>{'win32'},
      createAttachment: (RendererBackend backend, NativeWindow native) async {
        final RenderDevice rawDevice = await backend.createDevice();
        if (rawDevice is! D2dRenderDevice || native is! Win32Window) {
          rawDevice.dispose();
          throw StateError('direct2d requires D2dRenderDevice and '
              'Win32Window; got ${rawDevice.runtimeType} and '
              '${native.runtimeType}');
        }
        return (
          device: rawDevice,
          surface: Win32D2dSurfaceDescriptor(
            windowHandle: native.handle,
            pixelWidth: _pixelWidth(native),
            pixelHeight: _pixelHeight(native),
            scale: native.renderScale,
            generation: GenerationToken(),
            description: 'Win32 window, ID2D1HwndRenderTarget',
          ),
          // The render target is owned by the target the device creates, so
          // there is no separate surface object to release here.
          releaseSurface: _doNothing,
          releaseSurfaceBeforeDevice: true,
        );
      },
    );
  }

  static PresentationPathEntry _win32OpenGl() {
    const GlRendererBackend renderer = GlRendererBackend();
    return PresentationPathEntry.directRenderer(
      backend: renderer,
      compatibleWindowingBackends: const <String>{'win32'},
      createAttachment: (RendererBackend _, NativeWindow native) async {
        if (native is! Win32Window) {
          throw StateError('opengl on Windows requires Win32Window; got '
              '${native.runtimeType}');
        }
        final Win32GlSurfaceAttempt surfaceAttempt =
            Win32GlSurface.forWindow(native.handle);
        final Win32GlSurface? surface = surfaceAttempt.surface;
        if (surface == null) {
          _throwAttachmentFailure(
            GlRendererBackend.backendName,
            surfaceAttempt.diagnostics,
          );
        }
        final contextAttempt = surface.createContext();
        final context = contextAttempt.context;
        if (context == null) {
          surface.dispose();
          _throwAttachmentFailure(
            GlRendererBackend.backendName,
            <BackendDiagnostic>[
              ...surfaceAttempt.diagnostics,
              ...contextAttempt.diagnostics,
            ],
          );
        }
        final GlRenderDevice device;
        try {
          device = GlRendererBackend.adoptContext(context, surface.glLibrary);
        } on Object {
          surface.dispose();
          rethrow;
        }
        return (
          device: device,
          surface: surface.describeSurface(
            pixelWidth: _pixelWidth(native),
            pixelHeight: _pixelHeight(native),
            scale: native.renderScale,
          ),
          releaseSurface: surface.dispose,
          releaseSurfaceBeforeDevice: false,
        );
      },
    );
  }

  static PresentationPathEntry _x11OpenGl() {
    const GlRendererBackend renderer = GlRendererBackend();
    return PresentationPathEntry.directRenderer(
      backend: renderer,
      compatibleWindowingBackends: const <String>{'x11'},
      createAttachment: (RendererBackend _, NativeWindow native) async {
        if (native is! X11Window) {
          throw StateError('opengl on Linux requires X11Window; got '
              '${native.runtimeType}');
        }
        final X11GlSurfaceAttempt attempt =
            X11GlSurface.forWindow(native.xcbWindow);
        final X11GlSurface? surface = attempt.surface;
        if (surface == null) {
          _throwAttachmentFailure(
            GlRendererBackend.backendName,
            attempt.diagnostics,
          );
        }
        final GlRenderDevice device;
        try {
          device = GlRendererBackend.adoptContext(
            surface.context,
            surface.glLibrary,
          );
        } on Object {
          surface.dispose();
          rethrow;
        }
        return (
          device: device,
          surface: surface.describeSurface(
            pixelWidth: _pixelWidth(native),
            pixelHeight: _pixelHeight(native),
            scale: native.renderScale,
          ),
          releaseSurface: surface.dispose,
          releaseSurfaceBeforeDevice: false,
        );
      },
    );
  }

  static PresentationPathEntry _macosCpu() => PresentationPathEntry.retainedCpu(
        name: 'macos-iosurface',
        deviceDescription: 'IOSurface back buffer presented by AppKit host',
        compatibleWindowingBackends: const <String>{'macos'},
        create: (NativeWindow window) {
          final MacosWindow native = window as MacosWindow;
          return (
            present: (
              DisplayList list, {
              int? clearColor,
              Transform2D? deviceTransform,
              Rect? damage,
            }) =>
                native.drawAndPresent(
                  (Framebuffer buffer) => rasterizeDisplayList(
                    list,
                    buffer,
                    clearColor: clearColor,
                    damage: damage,
                    deviceTransform: deviceTransform ??
                        Transform2D.scaling(
                          native.renderScale,
                          native.renderScale,
                        ),
                  ),
                  frameGeneration: native.generation,
                ),
            presentNow: null,
            release: _doNothing,
          );
        },
      );
}

int _pixelWidth(NativeWindow window) =>
    (window.clientSize.width * window.renderScale).ceil();

int _pixelHeight(NativeWindow window) =>
    (window.clientSize.height * window.renderScale).ceil();

Never _throwAttachmentFailure(
  String backendName,
  List<BackendDiagnostic> diagnostics,
) {
  throw BackendSelectionError(
    requested: backendName,
    attempts: <BackendProbeResult>[
      BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: diagnostics.isEmpty
            ? const <BackendDiagnostic>[
                BackendDiagnostic(
                  kind: DiagnosticKind.surfaceCreationFailed,
                  message: 'the renderer could not attach to the window',
                ),
              ]
            : diagnostics,
      ),
    ],
  );
}

void _doNothing() {}
