/// The window a DXGI swap chain hangs off, and nothing else.
///
/// The Direct3D 11 counterpart of `win32_gl_surface.dart`, and it exists for the
/// same layering reason: `IDXGIFactory2::CreateSwapChainForHwnd` needs a window
/// handle, and `test/architecture/layering_test.dart` fails the build if any
/// file under `lib/src` outside `backends/` so much as names `HWND`. This file
/// is where that type is allowed to be named. Everything crossing back into
/// `lib/src/rendering` is either an integer or the [D3d11SwapChain] interface
/// declared there.
///
/// ## What is different from the GL surface, and why it is much less work
///
/// A WGL context needs a *pixel format*, which can be set exactly once per
/// window, which is why `Win32GlSurface` is mostly a careful dance around
/// `SetPixelFormat`. DXGI has no such thing. A swap chain is created over a
/// window and does not modify it, several may exist over the same window at
/// once, and none of them is a property of the window that outlives the object.
/// So [Win32D3d11Surface.forWindow] simply builds one; there is no format to
/// adopt, no second-call trap, and no diagnostic explaining which of the two
/// happened.
///
/// What replaces that complexity is the resize. See [reconfigure].
///
/// ## Why the window is never shown
///
/// [Win32D3d11Surface.hidden] creates a normal top-level window and does not
/// call `ShowWindow`, which is what `test/backends/win32` does throughout. A
/// hidden window is a real window: it has a client area, a swap chain over it
/// has a real back buffer, and `Present` does everything it would do on a
/// visible one except reach a monitor. That is exactly the part a test can
/// check. The one observable difference is honest and worth knowing:
/// `Present` on a window nothing can see is entitled to return
/// `DXGI_STATUS_OCCLUDED`, which `D3d11WindowTarget` reports as a presented
/// frame with a note rather than as a failure.
///
/// A message-only window would *not* work, for a different reason than it does
/// not work for GL: `HWND_MESSAGE` windows have no client area, and
/// `CreateSwapChainForHwnd` fails on them.
///
/// ## Absent by name
///
/// **DirectComposition.** This file calls `CreateSwapChainForHwnd`, so the swap
/// chain is a window's own back buffer. A composed visual would need
/// `DCompositionCreateDevice`, `IDCompositionDevice::CreateTargetForHwnd`,
/// `CreateVisual`, `IDCompositionVisual::SetContent`,
/// `IDCompositionTarget::SetRoot`, `IDCompositionDevice::Commit` and
/// `IDXGIFactory2::CreateSwapChainForComposition`. None of them are bound
/// anywhere in this repository. Without them there is no per-visual transform
/// and no transparent, non-rectangular window.
///
/// **Fullscreen.** `SetFullscreenState` is not bound and no fullscreen
/// descriptor is passed; the swap chain is created windowed. `DXGI_MWA_NO_ALT_
/// ENTER` is set precisely so DXGI does not take a window into fullscreen
/// behind its owner's back.
library;

import 'dart:ffi';

import '../../../ffi/com.dart';
import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../rendering/framebuffer.dart';
import '../../../rendering/gpu/d3d11/d3d11_backend.dart';
import '../../../rendering/gpu/d3d11/d3d11_bindings.dart';
import '../../../rendering/gpu/d3d11/d3d11_surface_descriptor.dart';
import '../win32_api.dart';
import '../win32_constants.dart';
import '../win32_structs.dart';

/// What [Win32D3d11Surface.hidden] or [Win32D3d11Surface.forWindow] found.
final class Win32D3d11SurfaceAttempt {
  const Win32D3d11SurfaceAttempt(this.surface, this.diagnostics);

  /// Null when no swap chain could be created; [diagnostics] then says why.
  final Win32D3d11Surface? surface;

  final List<BackendDiagnostic> diagnostics;
}

/// A window with a DXGI swap chain over it.
///
/// Implements [D3d11SwapChain] so `D3d11WindowTarget` can present through it
/// without the renderer ever learning what a window is.
final class Win32D3d11Surface implements D3d11SwapChain {
  Win32D3d11Surface._({
    required Win32Api api,
    required D3d11RenderDevice device,
    required int windowHandle,
    required DxgiSwapChain1 swapChain,
    required this.bufferFormat,
    required this.swapEffect,
    required bool ownsWindow,
    required Pointer<Uint16>? className,
  })  : _api = api,
        _device = device,
        _windowHandle = windowHandle,
        _swapChain = swapChain,
        _ownsWindow = ownsWindow,
        _className = className;

  final Win32Api _api;
  final D3d11RenderDevice _device;
  final int _windowHandle;
  final DxgiSwapChain1 _swapChain;

  /// Whether [dispose] destroys the window.
  ///
  /// False for [forWindow]. Destroying a window this object merely borrowed
  /// would take the application's window down with the renderer, which is the
  /// opposite of the lifetime `renderer.dart` describes.
  final bool _ownsWindow;

  /// Null when the window came from somewhere else: there is no class name to
  /// release because this file did not register one.
  final Pointer<Uint16>? _className;

  /// `DXGI_FORMAT_B8G8R8A8_UNORM` or whatever the fallback settled on.
  ///
  /// Reported because the swap effect and the format are chosen together - the
  /// flip models refuse most formats - and a bug report that says which pair
  /// this machine ended up with is the difference between reproducing it and
  /// guessing.
  final int bufferFormat;

  /// The `DXGI_SWAP_EFFECT` that was accepted. See [_swapEffectName].
  final int swapEffect;

  /// The view the target renders into. Recreated by every [reconfigure].
  ComObject? _backBufferView;

  /// The back-buffer texture the view was made from.
  ///
  /// Held as a field rather than released immediately after
  /// `CreateRenderTargetView`, because [reconfigure] has to prove it released
  /// *both* - and a reference that only ever existed inside a local is a
  /// reference nobody can be sure went away.
  ComObject? _backBufferTexture;

  int _syncInterval = 1;
  bool _disposed = false;

  /// The window, as an opaque integer.
  ///
  /// Goes into [D3d11WindowSurfaceDescriptor.nativeHandle], which documents at
  /// length why it is a number rather than a type.
  int get windowHandle => _windowHandle;

  /// The `IDXGISwapChain1` itself.
  ///
  /// Exposed for one purpose that is worth the exposure: a test that wants to
  /// hold a reference to a back buffer and prove that [reconfigure] then fails
  /// with `DXGI_ERROR_INVALID_CALL`. That is the single most common D3D11 bug
  /// and it cannot be reproduced from outside without reaching the chain.
  DxgiSwapChain1 get swapChain => _swapChain;

  /// How many times [present] has been called and succeeded.
  ///
  /// A window target reads no pixels back by construction, so the only evidence
  /// that a frame reached the window system is that this went up.
  int get presentCount => _presentCount;
  int _presentCount = 0;

  /// How many times [reconfigure] has called `ResizeBuffers` successfully.
  int get resizeCount => _resizeCount;
  int _resizeCount = 0;

  // -----------------------------------------------------------------
  // Construction
  // -----------------------------------------------------------------

  /// Creates a hidden window and a swap chain over it.
  ///
  /// Never throws. Every failure is a diagnostic, so a caller probing for a GPU
  /// backend on a machine without one falls back rather than crashing.
  static Win32D3d11SurfaceAttempt hidden(
    D3d11RenderDevice device, {
    int width = 64,
    int height = 64,
    String className = 'DartUiD3d11Surface',
  }) {
    final diagnostics = <BackendDiagnostic>[];
    final Win32LoadResult load = Win32Api.load();
    final Win32Api? api = load.api;
    if (api == null) return Win32D3d11SurfaceAttempt(null, load.diagnostics);

    final int window;
    final Pointer<Uint16> name;
    try {
      final _Window created = _createWindow(api, className, width, height);
      if (created.handle == 0) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: created.failure ?? 'the window could not be created',
          detail: 'GetLastError=${api.getLastError()}',
        ));
        return Win32D3d11SurfaceAttempt(null, diagnostics);
      }
      window = created.handle;
      name = created.className;
    } on Object catch (error, stack) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'creating the Direct3D 11 window threw',
        detail: '$error\n$stack',
      ));
      return Win32D3d11SurfaceAttempt(null, diagnostics);
    }

    final Win32D3d11SurfaceAttempt attempt = _attach(
      api,
      device,
      window,
      width,
      height,
      diagnostics,
      ownsWindow: true,
      className: name,
    );
    if (attempt.surface == null) {
      api.destroyWindow(window);
      api.heapRelease(name);
    }
    return attempt;
  }

  /// Builds a swap chain over a window somebody else created.
  ///
  /// This is the entry point a real application uses:
  /// `lib/src/backends/win32/win32_window.dart` owns a visible window, and a
  /// `D3d11WindowTarget` over it needs exactly one thing from this file - an
  /// `IDXGISwapChain1`.
  ///
  /// [windowHandle] is the window, as an integer, for the same reason
  /// `Win32GlSurface.forWindow` takes one: the value's only journey is from the
  /// window that made it into `CreateSwapChainForHwnd`, and giving it a name
  /// would invite code that assumes more about it than that.
  ///
  /// Unlike the GL path there is no pixel format to adopt or fight over, so
  /// several swap chains may exist over one window with no interaction. Does
  /// **not** take ownership of the window: [dispose] releases COM references and
  /// stops there.
  static Win32D3d11SurfaceAttempt forWindow(
    D3d11RenderDevice device,
    int windowHandle, {
    required int pixelWidth,
    required int pixelHeight,
  }) {
    final diagnostics = <BackendDiagnostic>[];
    if (windowHandle == 0) {
      diagnostics.add(const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'a null window handle cannot carry a swap chain',
      ));
      return Win32D3d11SurfaceAttempt(null, diagnostics);
    }

    final Win32LoadResult load = Win32Api.load();
    final Win32Api? api = load.api;
    if (api == null) return Win32D3d11SurfaceAttempt(null, load.diagnostics);

    if (api.isWindow(windowHandle) == 0) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'the handle is not a live window',
        detail: '0x${windowHandle.toUnsigned(64).toRadixString(16)}; it was '
            'closed, or it never was one',
      ));
      return Win32D3d11SurfaceAttempt(null, diagnostics);
    }

    return _attach(
      api,
      device,
      windowHandle,
      pixelWidth,
      pixelHeight,
      diagnostics,
      ownsWindow: false,
      className: null,
    );
  }

  /// Creates the chain, tries the flip model first and says which one it got.
  ///
  /// The order is not a preference, it is a compatibility ladder:
  ///
  ///   * `FLIP_DISCARD` needs Windows 10 and two buffers. It is the only model
  ///     that avoids a copy per frame on a modern compositor.
  ///   * `FLIP_SEQUENTIAL` needs Windows 8.
  ///   * `DISCARD` is the bitblt model and works on everything back to Vista.
  ///
  /// Each failure is recorded as a note rather than swallowed, because "this
  /// machine fell back to the bitblt model" explains a frame time nothing else
  /// in the report would.
  static Win32D3d11SurfaceAttempt _attach(
    Win32Api api,
    D3d11RenderDevice device,
    int window,
    int width,
    int height,
    List<BackendDiagnostic> diagnostics, {
    required bool ownsWindow,
    required Pointer<Uint16>? className,
  }) {
    final DxgiFactory2? factory = device.dxgiFactory(diagnostics: diagnostics);
    if (factory == null) return Win32D3d11SurfaceAttempt(null, diagnostics);

    final arena = NativeArena();
    try {
      final Pointer<Uint8> desc = arena.allocate<Uint8>(sizeOfSwapChainDesc1);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();

      DxgiSwapChain1? chain;
      var chosenEffect = dxgiSwapEffectFlipDiscard;
      var lastHr = sOk;
      for (final (int effect, int buffers) in const <(int, int)>[
        (dxgiSwapEffectFlipDiscard, 2),
        (dxgiSwapEffectFlipSequential, 2),
        (dxgiSwapEffectDiscard, 1),
      ]) {
        _writeSwapChainDesc1(
          desc,
          width: width,
          height: height,
          format: _bufferFormat,
          bufferCount: buffers,
          swapEffect: effect,
        );
        final int hr = hresult(factory.createSwapChainForHwnd(
          factory.pointer,
          device.device.pointer,
          window,
          desc.cast(),
          nullptr,
          nullptr,
          out,
        ));
        lastHr = hr;
        if (succeeded(hr) && out.value != nullptr) {
          chain = DxgiSwapChain1(out.value);
          chosenEffect = effect;
          break;
        }
        diagnostics.add(BackendDiagnostic.note(
          'CreateSwapChainForHwnd refused ${_swapEffectName(effect)}',
          detail: '${hresultName(hr)}; falling back. A flip model needs '
              'Windows 8 (sequential) or 10 (discard) and at least two '
              'buffers; the bitblt model works everywhere and copies once '
              'more per frame',
        ));
      }

      if (chain == null) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'no swap chain could be created over this window',
          detail: '${hresultName(lastHr)}; every swap effect was refused for a '
              '${width}x$height B8G8R8A8_UNORM chain',
        ));
        return Win32D3d11SurfaceAttempt(null, diagnostics);
      }

      // Without this DXGI installs a message hook and turns Alt+Enter into a
      // fullscreen transition behind the window owner's back, which is a
      // behaviour change a UI framework must not make for its embedder.
      final int association = hresult(factory.makeWindowAssociation(
          factory.pointer, window, DxgiFactory2.noAltEnter));
      if (failed(association)) {
        diagnostics.add(BackendDiagnostic.note(
          'MakeWindowAssociation(DXGI_MWA_NO_ALT_ENTER) failed',
          detail: '${hresultName(association)}; Alt+Enter over this window may '
              'trigger a DXGI fullscreen transition this framework did not ask '
              'for',
        ));
      }

      final surface = Win32D3d11Surface._(
        api: api,
        device: device,
        windowHandle: window,
        swapChain: chain,
        bufferFormat: _bufferFormat,
        swapEffect: chosenEffect,
        ownsWindow: ownsWindow,
        className: className,
      );
      final BackendDiagnostic? view = surface._acquireBackBuffer();
      if (view != null) {
        surface.dispose();
        diagnostics.add(view);
        return Win32D3d11SurfaceAttempt(null, diagnostics);
      }
      diagnostics.add(BackendDiagnostic.note(
        'swap chain: ${width}x$height, B8G8R8A8_UNORM, '
        '${_swapEffectName(chosenEffect)}',
      ));
      return Win32D3d11SurfaceAttempt(surface, diagnostics);
    } finally {
      arena.dispose();
    }
  }

  /// `DXGI_FORMAT_B8G8R8A8_UNORM`.
  ///
  /// BGRA and not RGBA because it is the format every Windows compositor path
  /// accepts, including the flip models and Direct2D interop, and because the
  /// device is created with `D3D11_CREATE_DEVICE_BGRA_SUPPORT` already. The
  /// choice is invisible in the picture: a render target's format decides which
  /// *byte* a shader output component lands in, and the shader emits
  /// `float4(r, g, b, a)` either way. It would matter only to something that
  /// read these pixels back, and nothing ever does - that is the definition of
  /// this target.
  static const int _bufferFormat = dxgiFormatB8G8R8A8Unorm;

  static String _swapEffectName(int effect) => switch (effect) {
        dxgiSwapEffectDiscard => 'DXGI_SWAP_EFFECT_DISCARD',
        dxgiSwapEffectSequential => 'DXGI_SWAP_EFFECT_SEQUENTIAL',
        dxgiSwapEffectFlipSequential => 'DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL',
        dxgiSwapEffectFlipDiscard => 'DXGI_SWAP_EFFECT_FLIP_DISCARD',
        _ => '0x${effect.toRadixString(16)}',
      };

  /// Fills a `DXGI_SWAP_CHAIN_DESC1` at [target].
  ///
  /// Written as offsets for the reason `d3d11_bindings.dart` gives for all of
  /// them. The layout, in `UINT`s: Width, Height, Format, Stereo, SampleDesc
  /// {Count, Quality}, BufferUsage, BufferCount, Scaling, SwapEffect,
  /// AlphaMode, Flags - twelve fields, 48 bytes, no padding.
  static void _writeSwapChainDesc1(
    Pointer<Uint8> target, {
    required int width,
    required int height,
    required int format,
    required int bufferCount,
    required int swapEffect,
  }) {
    final Pointer<Uint32> view = target.cast<Uint32>();
    view[0] = width;
    view[1] = height;
    view[2] = format;
    view[3] = 0; // Stereo
    view[4] = 1; // SampleDesc.Count - a flip model refuses anything else
    view[5] = 0; // SampleDesc.Quality
    view[6] = dxgiUsageRenderTargetOutput;
    view[7] = bufferCount;
    // STRETCH rather than NONE: NONE is only legal with a flip model, and this
    // descriptor is reused for the bitblt fallback.
    view[8] = dxgiScalingStretch;
    view[9] = swapEffect;
    // UNSPECIFIED is the only value CreateSwapChainForHwnd accepts; the
    // transparency modes belong to CreateSwapChainForComposition.
    view[10] = dxgiAlphaModeUnspecified;
    view[11] = 0; // Flags
  }

  /// Fetches back buffer 0 and makes a render-target view over it.
  ///
  /// Returns null on success, or the diagnostic that explains the failure.
  /// Called once at construction and once after every successful
  /// `ResizeBuffers`, because a resize destroys both.
  BackendDiagnostic? _acquireBackBuffer() {
    final arena = NativeArena();
    try {
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      final int hr = hresult(_swapChain.getBuffer(
        _swapChain.pointer,
        0,
        iidId3d11Texture2D.allocateIn(arena),
        out,
      ));
      if (failed(hr) || out.value == nullptr) {
        return BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'the swap chain would not hand back its back buffer',
          detail: hresultName(hr),
        );
      }
      final texture = ComObject(out.value, interfaceName: 'ID3D11Texture2D');
      final int rtv = hresult(_device.device.createRenderTargetView(
        _device.device.pointer,
        texture.pointer,
        nullptr,
        out,
      ));
      if (failed(rtv) || out.value == nullptr) {
        texture.dispose();
        return BackendDiagnostic(
          kind: DiagnosticKind.surfaceCreationFailed,
          message: 'no render-target view could be made over the back buffer',
          detail: hresultName(rtv),
        );
      }
      _backBufferTexture = texture;
      _backBufferView =
          ComObject(out.value, interfaceName: 'ID3D11RenderTargetView');
      return null;
    } finally {
      arena.dispose();
    }
  }

  /// Releases this object's two references to the back buffer.
  ///
  /// Both, and in this order: the view first because it holds the texture, the
  /// texture second. Everything `ResizeBuffers` needs released that this class
  /// owns is released here; the third owner is the immediate context, and it is
  /// `D3d11WindowTarget.resize` that unbinds it. See [reconfigure].
  void _releaseBackBuffer() {
    _backBufferView?.dispose();
    _backBufferView = null;
    _backBufferTexture?.dispose();
    _backBufferTexture = null;
  }

  // -----------------------------------------------------------------
  // D3d11SwapChain
  // -----------------------------------------------------------------

  @override
  Pointer<Void> get backBufferView =>
      _disposed ? nullptr : (_backBufferView?.pointer ?? nullptr);

  @override
  bool get isPresentable => !_disposed && _api.isWindow(_windowHandle) != 0;

  /// `Present(syncInterval, 0)`.
  ///
  /// Returns the raw `HRESULT` because the interesting answers are success
  /// codes: `DXGI_STATUS_OCCLUDED` means the frame was accepted and discarded
  /// because nothing can see the window, which is not an error and is also not
  /// a frame that was shown.
  @override
  int present() {
    if (_disposed) return dxgiErrorInvalidCall;
    final int hr =
        hresult(_swapChain.present(_swapChain.pointer, _syncInterval, 0));
    if (succeeded(hr)) _presentCount++;
    return hr;
  }

  /// Records the interval the next [present] will ask for.
  ///
  /// Unlike WGL, vsync here is an argument to `Present` rather than an
  /// extension entry point the driver may not export, so this cannot fail for
  /// lack of support - only for lack of a chain to present on.
  @override
  bool setSyncInterval(int interval) {
    if (_disposed || interval < 0) return false;
    _syncInterval = interval;
    return true;
  }

  /// `ResizeBuffers`, with the reference discipline it demands.
  ///
  /// The sequence, and every step of it is load bearing:
  ///
  ///   1. **release the view and the texture** this object holds. Two
  ///      references, both to the same back buffer, both counted.
  ///   2. call `ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0)`.
  ///      Zero for the buffer count and `UNKNOWN` for the format both mean
  ///      "keep what the chain was created with", which is what a resize wants
  ///      and what stops this method from having to remember the descriptor.
  ///   3. re-acquire the back buffer, because step 2 destroyed and recreated
  ///      it.
  ///
  /// A **fourth** reference exists and is not this object's to drop: the
  /// immediate context holds one for whatever is bound as a render target.
  /// `D3d11WindowTarget.resize` calls `D3d11RenderDevice.unbindTargets` before
  /// this method for exactly that reason. If any reference at all survives,
  /// step 2 returns `DXGI_ERROR_INVALID_CALL`, the old buffers stay at the old
  /// size, and every frame afterwards is drawn at the wrong one. It is the
  /// classic Direct3D 11 mistake and it does not crash, which is why it costs
  /// an afternoon.
  ///
  /// When step 2 fails the back buffer is re-acquired anyway, so the chain is
  /// left usable at its old size rather than viewless. The diagnostic is still
  /// returned, and `D3d11WindowTarget` marks the device lost on it.
  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) {
    if (_disposed) {
      return const BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'this swap chain was disposed and cannot be resized',
      );
    }
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      return BackendDiagnostic(
        kind: DiagnosticKind.surfaceCreationFailed,
        message: 'a swap chain cannot be resized to an empty rectangle',
        detail: '${pixelWidth}x$pixelHeight',
      );
    }

    _releaseBackBuffer();
    final int hr = hresult(_swapChain.resizeBuffers(
      _swapChain.pointer,
      0, // keep the buffer count
      pixelWidth,
      pixelHeight,
      dxgiFormatUnknown, // keep the format
      0,
    ));
    if (failed(hr)) {
      // Re-acquired even on failure: a chain with no view refuses every frame,
      // and the old buffers are still there and still valid.
      _acquireBackBuffer();
      return BackendDiagnostic(
        kind: hr == dxgiErrorInvalidCall
            ? DiagnosticKind.surfaceCreationFailed
            : DiagnosticKind.connectionFailed,
        message: 'ResizeBuffers refused to bring the back buffer to '
            '${pixelWidth}x$pixelHeight',
        detail: hr == dxgiErrorInvalidCall
            ? '${hresultName(hr)}. This code means a reference to a back '
                'buffer was still outstanding. The three that exist are the '
                'render-target view, the texture it was made from - both '
                'released by this method - and whatever the immediate context '
                'has bound, which D3d11WindowTarget.resize unbinds before '
                'calling. A fourth held by the caller is the remaining '
                'explanation'
            : hresultName(hr),
      );
    }
    _resizeCount++;
    return _acquireBackBuffer();
  }

  // -----------------------------------------------------------------
  // Describing the surface to the renderer
  // -----------------------------------------------------------------

  /// Describes this window to the renderer, as the thing a target draws into.
  ///
  /// [generation] is the *window's* token. Pass the one the window already owns
  /// - `NativeWindow.generation` is driven by one - so that a resize
  /// invalidates in-flight frames without the window and the renderer having to
  /// agree on a protocol. A fresh token is created when none is given, which is
  /// right only for a window nobody else resizes, such as the hidden one in a
  /// test.
  ///
  /// The size is in physical pixels and is the caller's to get right: this file
  /// could call `GetClientRect`, and deliberately does not, because the window
  /// owner already tracks its client size and a second source of truth for it
  /// is how a renderer ends up one resize behind.
  D3d11WindowSurfaceDescriptor describeSurface({
    required int pixelWidth,
    required int pixelHeight,
    double scale = 1.0,
    GenerationToken? generation,
  }) =>
      D3d11WindowSurfaceDescriptor(
        nativeHandle: _windowHandle,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        swapChain: this,
        generation: generation ?? GenerationToken(),
        scale: scale,
        // The swap chain's buffers are B8G8R8A8_UNORM; saying so keeps the
        // descriptor honest even though nothing reads these pixels back.
        format: PixelFormat.bgra8888Premultiplied,
        description: 'Win32 window, ${_swapEffectName(swapEffect)}',
      );

  /// Releases the swap chain, and the window only if this made it.
  ///
  /// The class registration is left behind on purpose: unregistering it would
  /// break any other surface still using it, and a process holds at most one
  /// such class for its whole life.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releaseBackBuffer();
    _swapChain.dispose();
    if (!_ownsWindow) return;
    _api.destroyWindow(_windowHandle);
    final Pointer<Uint16>? name = _className;
    if (name != null) _api.heapRelease(name);
  }

  // -----------------------------------------------------------------
  // The window itself
  // -----------------------------------------------------------------

  static _Window _createWindow(
    Win32Api api,
    String className,
    int width,
    int height,
  ) {
    final int instance = api.getModuleHandleW(nullptr);
    final Pointer<Uint16> name = api.toUtf16(className);

    // The class's window procedure is DefWindowProcW itself, taken straight out
    // of user32's export table. There is no Dart callback and therefore no way
    // for a Dart exception to unwind through a native frame: this window has no
    // behaviour to implement, it only has to exist.
    final user32 = DynamicLibrary.open('user32.dll');
    final Pointer<NativeFunction<WndProcNative>> defaultProc =
        user32.lookup<NativeFunction<WndProcNative>>('DefWindowProcW');

    final Pointer<WndClassExW> descriptor = api.allocator<WndClassExW>();
    descriptor.ref
      ..cbSize = sizeOf<WndClassExW>()
      ..style = csOwndc | csHredraw | csVredraw
      ..lpfnWndProc = defaultProc
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
      // Class already registered is not a failure: a second surface in the same
      // process reuses it, which is why the error code is inspected rather than
      // the return value alone.
      final int error = api.getLastError();
      if (error != _errorClassAlreadyExists) {
        api.heapRelease(name);
        return _Window(0, nullptr,
            failure: 'the Direct3D 11 window class could not be registered');
      }
    }

    final Pointer<Uint16> title = api.toUtf16('dart_ui D3D11 surface');
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
      api.heapRelease(name);
      return _Window(0, nullptr,
          failure: 'the Direct3D 11 window could not be created');
    }
    return _Window(window, name);
  }
}

/// `ERROR_CLASS_ALREADY_EXISTS`. A second surface in one process is fine.
const int _errorClassAlreadyExists = 1410;

final class _Window {
  const _Window(this.handle, this.className, {this.failure});

  final int handle;
  final Pointer<Uint16> className;
  final String? failure;
}
