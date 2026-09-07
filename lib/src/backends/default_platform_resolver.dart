/// Platform-aware defaults used by the public `runApp` facade.
///
/// This file deliberately lives under `backends`: it is the composition root
/// that is allowed to know concrete platforms. `lib/src/app` remains portable
/// and receives only factories and common contracts.
library;

import 'dart:ffi';
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
import '../rendering/gpu/d3d11/d3d11_mesh_pipeline.dart';
import '../rendering/gpu/d3d12/d3d12_surface_descriptor.dart';
import '../rendering/gpu/gl/gl_backend.dart';
import '../rendering/gpu/gl/gl_context.dart';
import '../rendering/gpu/gl/gl_mesh_renderer.dart';
import '../rendering/gpu/vulkan/vulkan_backend.dart';
import '../rendering/gpu/vulkan/vulkan_instance.dart';
import '../rendering/gpu/vulkan/vulkan_library.dart';
import '../rendering/gpu/vulkan/vulkan_surface_descriptor.dart';
import '../rendering/mesh/mesh_scene.dart';
import '../rendering/render_policy.dart';
import '../rendering/renderer.dart';
import 'headless/headless_backend.dart';
import 'macos/macos.dart';
import 'wayland/wayland_backend.dart';
import 'wayland/wayland_cpu_presenter.dart';
import 'wayland/wayland_window.dart';
import 'win32/d2d/d2d_backend.dart';
import 'win32/d2d/d2d_targets.dart';
import 'win32/d3d11/win32_d3d11_surface.dart';
import 'win32/d3d12/d3d12_backend.dart';
import 'win32/d3d12/d3d12_device.dart';
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
              : () => WaylandWindowingBackend(environment: options.environment),
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
        // Behind the three paths above for the same reason Direct2D is behind
        // the first two, and one more: this one is complete but young. It
        // draws rectangles, antialiased paths, images and text, so it is a
        // path an application can land on by fallback without losing a
        // feature - which is what makes it a candidate rather than an
        // experiment. `--presentation=direct3d12` pins it by name.
        _win32D3d12(),
        // Experimental, and the flag is not caution: `VulkanWindowTarget`
        // builds its `GpuRasterSink` with no glyph atlas and no font
        // resolver, so the first glyph run in any window raises
        // `UnsupportedCapabilityError` by name. A path that cannot draw text
        // must never be reached by fallback in a UI framework; it is here so
        // that `--presentation=vulkan` with
        // `ApplicationOptions.allowExperimentalBackends` can reach it, which
        // is the difference between a backend under development and a backend
        // nobody can run.
        _win32Vulkan(),
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
      // This file is the one place in the tree allowed to name a concrete
      // backend, which is why the mesh factory is declared here and not in
      // `application.dart`: the window that calls it never learns what it got.
      //
      // It throws rather than returning null, and the window turns the throw
      // into a null surface with the reason attached. That is the shape a
      // factory can have when the caller has a working fallback: the CPU
      // rasteriser draws the frame and the viewer says which path it used.
      createMeshRenderer: (RenderDevice device) {
        if (device is! D3d11RenderDevice) {
          throw StateError('direct3d11 mesh rendering needs a '
              'D3d11RenderDevice; got ${device.runtimeType}');
        }
        final Object built = D3d11MeshRenderer.create(device);
        if (built is MeshSceneRenderer) return built;
        throw StateError('$built');
      },
      createAttachment: (
        RendererBackend backend,
        NativeWindow native, {
        RenderDevice? device,
      }) async {
        // The whole of the change, at the site that used to pay for it: a
        // device arrives when the application has one to lend, and only a
        // caller with nobody to borrow from opens its own. An `ID3D11Device`
        // is per adapter by nature - N swap chains hang off one of them - so
        // the second window of an application now costs a swap chain.
        final RenderDevice rawDevice = device ?? await backend.createDevice();
        // Disposed only when this attachment opened it. A leased device may be
        // presenting the window behind this one right now, and the release is
        // the presenter's to make.
        void discardOwnDevice() {
          if (device == null) rawDevice.dispose();
        }

        if (rawDevice is! D3d11RenderDevice || native is! Win32Window) {
          discardOwnDevice();
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
          discardOwnDevice();
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

  static BackendProbeResult _probeWin32OpenGl() {
    final Win32GlSurfaceAttempt surfaceAttempt = Win32GlSurface.hidden(
      className: 'DartUiOpenGlProbe',
    );
    final Win32GlSurface? surface = surfaceAttempt.surface;
    if (surface == null) {
      return BackendProbeResult(
        backendName: GlRendererBackend.backendName,
        supported: false,
        diagnostics: surfaceAttempt.diagnostics,
      );
    }
    final contextAttempt = surface.createContext();
    final context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return BackendProbeResult(
        backendName: GlRendererBackend.backendName,
        supported: false,
        diagnostics: <BackendDiagnostic>[
          ...surfaceAttempt.diagnostics,
          ...contextAttempt.diagnostics,
        ],
      );
    }
    try {
      return GlRendererBackend.describeContext(
        context,
        <BackendDiagnostic>[
          ...surfaceAttempt.diagnostics,
          ...contextAttempt.diagnostics,
        ],
        true,
      );
    } finally {
      context.dispose();
      surface.dispose();
    }
  }

  static PresentationPathEntry _win32Direct2d() {
    const D2dRendererBackend renderer = D2dRendererBackend();
    return PresentationPathEntry.directRenderer(
      backend: renderer,
      compatibleWindowingBackends: const <String>{'win32'},
      createAttachment: (
        RendererBackend backend,
        NativeWindow native, {
        RenderDevice? device,
      }) async {
        final RenderDevice rawDevice = device ?? await backend.createDevice();
        if (rawDevice is! D2dRenderDevice || native is! Win32Window) {
          if (device == null) rawDevice.dispose();
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

  /// Direct3D 12 over a DXGI flip-model swap chain on the application window.
  ///
  /// No surface object crosses back: unlike OpenGL, where the window system
  /// owns the back buffer, the swap chain is a DXGI object the *target* builds
  /// from the queue the device owns and holds for its whole life. So the
  /// attachment hands over a descriptor and a release callback that does
  /// nothing, exactly as the Direct2D path does above.
  static PresentationPathEntry _win32D3d12() {
    const D3d12RendererBackend renderer = D3d12RendererBackend();
    return PresentationPathEntry.directRenderer(
      backend: renderer,
      compatibleWindowingBackends: const <String>{'win32'},
      createAttachment: (
        RendererBackend backend,
        NativeWindow native, {
        RenderDevice? device,
      }) async {
        final RenderDevice rawDevice = device ?? await backend.createDevice();
        if (rawDevice is! D3d12RenderDevice || native is! Win32Window) {
          if (device == null) rawDevice.dispose();
          throw StateError('direct3d12 requires D3d12RenderDevice and '
              'Win32Window; got ${rawDevice.runtimeType} and '
              '${native.runtimeType}');
        }
        return (
          device: rawDevice,
          surface: D3d12WindowSurfaceDescriptor(
            nativeHandle: native.handle,
            pixelWidth: _pixelWidth(native),
            pixelHeight: _pixelHeight(native),
            scale: native.renderScale,
            description: 'Win32 window, DXGI flip-model swap chain',
          ),
          // The swap chain belongs to the target the device creates, so there
          // is no separate surface object to release here.
          releaseSurface: _doNothing,
          releaseSurfaceBeforeDevice: true,
        );
      },
    );
  }

  /// Vulkan over a `VK_KHR_win32_surface` swapchain on the application window.
  ///
  /// The device is opened here rather than through
  /// `VulkanRendererBackend.createDevice`, and that is forced rather than
  /// stylistic: presenting needs `VK_KHR_surface` and `VK_KHR_win32_surface`
  /// named at `vkCreateInstance` and `VK_KHR_swapchain` named at
  /// `vkCreateDevice` - all three long before any window exists - and the
  /// backend's own `createDevice` deliberately opens an offscreen device so a
  /// headless runner without a WSI loader keeps Vulkan at all. The backend is
  /// still the object selection reports, which is what keeps the name `vulkan`
  /// meaning one thing.
  static PresentationPathEntry _win32Vulkan() {
    const VulkanRendererBackend renderer = VulkanRendererBackend();
    return PresentationPathEntry.directRenderer(
      backend: renderer,
      probe: _probeWin32Vulkan,
      experimental: true,
      compatibleWindowingBackends: const <String>{'win32'},
      // The registry keys on the backend and opens the device with this,
      // never with `VulkanRendererBackend.createDevice`. Without it the
      // registry would sit beside this path doing nothing while it went on
      // opening a `VkDevice` per window, and nobody would notice: Vulkan is
      // experimental, is never reached by fallback, and raises on the first
      // glyph, so almost nothing exercises it.
      openDevice: _openWin32VulkanDevice,
      createAttachment: (
        RendererBackend _,
        NativeWindow native, {
        RenderDevice? device,
      }) async {
        if (native is! Win32Window) {
          throw StateError('vulkan on Windows requires Win32Window; got '
              '${native.runtimeType}');
        }
        final RenderDevice raw = device ?? await _openWin32VulkanDevice();
        if (raw is! VulkanRenderDevice) {
          if (device == null) raw.dispose();
          throw StateError('vulkan requires VulkanRenderDevice; got '
              '${raw.runtimeType}');
        }
        return (
          device: raw,
          surface: VulkanWindowSurfaceDescriptor(
            platform: VulkanSurfacePlatform.win32,
            // Zero is legal here and means "the module this process was loaded
            // from", which is the one the window class was registered against.
            // See VulkanWindowSurfaceDescriptor.displayHandle.
            displayHandle: 0,
            windowHandle: native.handle,
            pixelWidth: _pixelWidth(native),
            pixelHeight: _pixelHeight(native),
            scale: native.renderScale,
            description: 'Win32 window, VK_KHR_win32_surface swapchain',
          ),
          // The VkSurfaceKHR and the swapchain belong to the target, which
          // creates them in its constructor and destroys them with itself.
          releaseSurface: _doNothing,
          releaseSurfaceBeforeDevice: true,
        );
      },
    );
  }

  /// Opens the presentation-capable Vulkan device, once per application.
  ///
  /// Separate from the attachment so the registry can call it: what is shared
  /// has to be openable before any window exists, and the surface half below
  /// still needs a window. `VulkanRendererBackend.createDevice` cannot stand
  /// in - it opens an offscreen device with no `VK_KHR_swapchain`, on purpose,
  /// so a headless runner with no WSI loader keeps Vulkan at all.
  static Future<RenderDevice> _openWin32VulkanDevice() async =>
      VulkanRenderDevice.open(
        options: _win32VulkanInstanceOptions,
        enablePresentation: true,
      );

  static const VulkanInstanceOptions _win32VulkanInstanceOptions =
      VulkanInstanceOptions(
    surfaces: <VulkanSurfacePlatform>{VulkanSurfacePlatform.win32},
  );

  /// Whether Vulkan can present to a Win32 window here.
  ///
  /// `VulkanRendererBackend.probe` cannot answer this: it creates an instance
  /// with no WSI extension at all, so it reports success on a loader that has
  /// no `VK_KHR_win32_surface` and would then fail at
  /// `vkCreateWin32SurfaceKHR`. This asks the loader for the extension by name
  /// and stops at the physical device, deliberately: opening a device is the
  /// expensive half and a probe that ran on every startup of every Windows
  /// application would spend it for a path that is experimental and last in
  /// the GPU order. An attach that fails after this said yes is reported by
  /// name and falls through to the next path, which is the mechanism that
  /// already covers the remaining gap.
  ///
  /// Never throws; a throw here would take the whole selection down instead of
  /// losing one candidate.
  static BackendProbeResult _probeWin32Vulkan() {
    try {
      return _probeWin32VulkanSurface();
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        VulkanRendererBackend.backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the Vulkan presentation probe threw, which is a bug in '
              'the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  static BackendProbeResult _probeWin32VulkanSurface() {
    const String name = VulkanRendererBackend.backendName;
    final VulkanLoadResult load = VulkanLibrary.open();
    final VulkanLibrary? library = load.library;
    if (library == null) {
      return BackendProbeResult(
        backendName: name,
        supported: false,
        diagnostics: load.diagnostics,
      );
    }
    final VulkanInstanceAttempt attempt = VulkanInstance.create(
      library,
      options: _win32VulkanInstanceOptions,
    );
    final VulkanInstance? instance = attempt.instance;
    if (instance == null) {
      return BackendProbeResult(
        backendName: name,
        supported: false,
        diagnostics: attempt.diagnostics,
      );
    }
    try {
      if (!instance.supportsSurface(VulkanSurfacePlatform.win32)) {
        return BackendProbeResult(
          backendName: name,
          supported: false,
          diagnostics: <BackendDiagnostic>[
            ...attempt.diagnostics,
            BackendDiagnostic(
              kind: DiagnosticKind.missingSymbol,
              message: 'this Vulkan loader offers no VK_KHR_win32_surface, so '
                  'there is no way to make a surface from a window',
              detail: 'enabled instance extensions: '
                  '${instance.enabledExtensions.join(', ')}',
            ),
          ],
        );
      }
      final VulkanPhysicalDevice? physical = instance.chooseDevice();
      if (physical == null) {
        return BackendProbeResult(
          backendName: name,
          supported: false,
          diagnostics: <BackendDiagnostic>[
            ...attempt.diagnostics,
            const BackendDiagnostic(
              kind: DiagnosticKind.incompatibleDevice,
              message: 'no Vulkan physical device has a graphics queue',
            ),
          ],
        );
      }
      return BackendProbeResult(
        backendName: name,
        supported: true,
        capabilities: const <Capability>{
          Capability.gpuPresentation,
          Capability.vsync,
        },
        diagnostics: <BackendDiagnostic>[
          ...attempt.diagnostics,
          BackendDiagnostic.note(
            'Vulkan on "$physical" through VK_KHR_win32_surface',
          ),
          const BackendDiagnostic.note(
            'this path draws rectangles, antialiased paths and images; it has '
            'no glyph atlas, so a glyph run is refused by name. That is why '
            'it is registered as experimental and is never reached by '
            'fallback',
          ),
        ],
      );
    } finally {
      instance.dispose();
    }
  }

  static PresentationPathEntry _win32OpenGl() {
    const GlRendererBackend renderer = GlRendererBackend();
    return PresentationPathEntry.directRenderer(
      backend: renderer,
      probe: _probeWin32OpenGl,
      compatibleWindowingBackends: const <String>{'win32'},
      // See `_win32D3d11` for why the factory lives here and why it throws.
      createMeshRenderer: (RenderDevice device) {
        if (device is! GlRenderDevice) {
          throw StateError('opengl mesh rendering needs a GlRenderDevice; '
              'got ${device.runtimeType}');
        }
        final GlMeshRendererAttempt attempt = GlMeshRenderer.create(device);
        final GlMeshRenderer? built = attempt.renderer;
        if (built != null) return built;
        throw StateError(attempt.diagnostics.isEmpty
            ? 'the OpenGL mesh program could not be built'
            : attempt.diagnostics
                .map((BackendDiagnostic d) => d.message)
                .join('; '));
      },

      // Declared, not overlooked. `wglCreateContext` below is called on this
      // window's own HDC with this window's chosen pixel format and no share
      // group - there is no `wglShareLists` call anywhere in this repository -
      // so the device this factory builds cannot be handed to a second window
      // even in principle. Making it shareable is a change inside
      // `rendering/gpu/gl`: a share group at creation, or one context made
      // current on several HDCs, which WGL permits only for matching pixel
      // formats and which then serialises every window on `MakeCurrent`. This
      // is the state Avalonia's own GL backends report too - `EglPlatformGra`
      // `phics` answers `UsesSharedContext => false` and `GlxPlatformFeature`
      // answers `CanShareContexts => true, UsesSharedContext => false`, and
      // this path is below even the second of those.
      sharesDevice: false,
      createAttachment: (
        RendererBackend _,
        NativeWindow native, {
        RenderDevice? device,
      }) async {
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
        // Asserted rather than assumed: this path declares `sharesDevice:
        // false`, so a device arriving here would mean the declaration and the
        // wiring had drifted apart, and the symptom would be a silently
        // ignored shared device plus a second context nobody asked for.
        assert(device == null, 'the OpenGL path cannot adopt a shared device');
        final GlRenderDevice adopted;
        try {
          adopted = _adoptGlContext(context, surface.glLibrary);
        } on Object {
          surface.dispose();
          rethrow;
        }
        return (
          device: adopted,
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
      // See `_win32D3d11` for why the factory lives here and why it throws.
      createMeshRenderer: (RenderDevice device) {
        if (device is! GlRenderDevice) {
          throw StateError('opengl mesh rendering needs a GlRenderDevice; '
              'got ${device.runtimeType}');
        }
        final GlMeshRendererAttempt attempt = GlMeshRenderer.create(device);
        final GlMeshRenderer? built = attempt.renderer;
        if (built != null) return built;
        throw StateError(attempt.diagnostics.isEmpty
            ? 'the OpenGL mesh program could not be built'
            : attempt.diagnostics
                .map((BackendDiagnostic d) => d.message)
                .join('; '));
      },

      // As on Win32, and for the GLX equivalent of the same reason: the
      // context comes from the window's own drawable and visual, built with no
      // share list. See `_win32OpenGl`.
      sharesDevice: false,
      createAttachment: (
        RendererBackend _,
        NativeWindow native, {
        RenderDevice? device,
      }) async {
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
        assert(device == null, 'the OpenGL path cannot adopt a shared device');
        final GlRenderDevice adopted;
        try {
          adopted = _adoptGlContext(surface.context, surface.glLibrary);
        } on Object {
          surface.dispose();
          rethrow;
        }
        return (
          device: adopted,
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

/// Opens the GL device for a window, asking for exactly the optional
/// executors the application's [RenderPolicy] declared.
///
/// This is the seam that made approaches B and C reachable at all. Both are
/// built only when [GlRendererBackend.adoptContext] is asked to build them,
/// and until this function existed nothing in the framework ever asked: they
/// ran from tests, from the POC and from direct device use, and no window on
/// any platform could reach them. Sparse strips are not named here on
/// purpose - `GlSparseStripsPolicy.auto` is already `adoptContext`'s default
/// and the driver's symbol table, not a policy, decides them.
///
/// The policy is read from [RenderPolicyScope] rather than threaded through
/// `PresentationPathEntry`, and that is safe by construction rather than by
/// luck: `Application.start` installs it before the first probe runs, and an
/// attachment happens after a window exists, which is later still. A process
/// that never started an [Application] - a test opening a device by hand -
/// reads [RenderPolicy.defaults] and therefore gets exactly the device this
/// resolver built before this function existed.
GlRenderDevice _adoptGlContext(GlContext context, DynamicLibrary glLibrary) {
  final RenderPolicy policy = RenderPolicyScope.policy;
  return GlRendererBackend.adoptContext(
    context,
    glLibrary,
    enableExperimentalCpuTessellation: policy.buildsTessellationExecutor,
    enableExperimentalStencilCover: policy.buildsStencilCoverExecutor,
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
