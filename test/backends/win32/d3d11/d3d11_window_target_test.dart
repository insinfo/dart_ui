/// The windowed Direct3D 11 target, against a real swap chain over a real
/// window.
///
/// `d3d11_device_test.dart` covers the offscreen target and can check its work
/// by reading the pixels back. This file cannot: the whole point of
/// [D3d11WindowTarget] is that nothing reads pixels back, so what is asserted
/// here is the contract around the present rather than the image it produced -
/// that a present reaches `IDXGISwapChain::Present` and reports success, that a
/// frame recorded before a resize is refused, that a dead window becomes a named
/// failure and not an access violation, and that `ResizeBuffers` behaves the way
/// the API actually documents rather than the way it is usually written.
///
/// The window is a real one. `Win32D3d11Surface.hidden` makes one and never
/// shows it, which is what `test/backends/win32` does throughout: a hidden
/// window has a client area, a swap chain over it has a real back buffer, and
/// `Present` does everything it would on a visible one except reach a monitor.
///
/// ## The `ResizeBuffers` group is the reason this file exists
///
/// `ResizeBuffers` fails with `DXGI_ERROR_INVALID_CALL` unless every outstanding
/// reference to every back buffer has been released, and the failure does not
/// crash: the call returns an error, the old buffers stay at the old size, and
/// every frame afterwards is drawn at the wrong one. It is the single most
/// common Direct3D 11 mistake. The group below reproduces it deliberately by
/// holding a reference the implementation cannot see, proves that it fails,
/// releases the reference and proves that it then succeeds. Asserting only the
/// happy path would leave the whole discipline untested, because the happy path
/// also passes when the discipline is absent and nothing else happens to hold a
/// reference.
///
/// It skips rather than fails where there is no device or no Windows, which on
/// the Linux and macOS halves of CI is every test in the file.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/backends/win32/d3d11/win32_d3d11_surface.dart';
import 'package:dart_ui/src/ffi/com.dart';
import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/foundation/lifecycle.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_window_target.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

void main() {
  group('the surface descriptor', () {
    test('carries the window as an opaque integer and keeps its token', () {
      final token = GenerationToken();
      final chain = _ScriptedSwapChain();
      final surface = D3d11WindowSurfaceDescriptor(
        nativeHandle: 0xDEADBEEF,
        pixelWidth: 320,
        pixelHeight: 200,
        swapChain: chain,
        generation: token,
        scale: 2.0,
      );

      expect(surface.kind, 'd3d11-window');
      expect(surface.nativeHandle, 0xDEADBEEF);
      expect(surface.scale, 2.0);
      // The window's token, not a copy of its value. A snapshot would be a
      // number that was true once, which is the bug the shared token exists to
      // prevent.
      token.invalidate();
      expect(surface.generation.current, token.current);
      expect(surface.toString(), contains('deadbeef'));
    });

    test('resizing shares the window, the chain and the token', () {
      final token = GenerationToken();
      final chain = _ScriptedSwapChain();
      final surface = D3d11WindowSurfaceDescriptor(
        nativeHandle: 7,
        pixelWidth: 100,
        pixelHeight: 50,
        swapChain: chain,
        generation: token,
        format: PixelFormat.bgra8888Premultiplied,
      );
      final bigger = surface.resized(pixelWidth: 200, pixelHeight: 100);

      expect(bigger.pixelWidth, 200);
      expect(bigger.pixelHeight, 100);
      expect(bigger.nativeHandle, 7);
      expect(bigger.format, PixelFormat.bgra8888Premultiplied);
      expect(identical(bigger.swapChain, chain), isTrue);
      expect(identical(bigger.generation, token), isTrue);
    });

    test('an empty surface is refused at construction', () {
      expect(
        () => D3d11WindowSurfaceDescriptor(
          nativeHandle: 1,
          pixelWidth: 0,
          pixelHeight: 8,
          swapChain: _ScriptedSwapChain(),
          generation: GenerationToken(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('the backend accepts a window descriptor', () {
      const backend = D3d11RendererBackend();
      expect(
        backend.supportsSurface(D3d11WindowSurfaceDescriptor(
          nativeHandle: 1,
          pixelWidth: 4,
          pixelHeight: 4,
          swapChain: _ScriptedSwapChain(),
          generation: GenerationToken(),
        )),
        isTrue,
      );
    });
  });

  group('adopting a window', () {
    // Both tests here are about a handle that is refused before the device is
    // ever looked at, so the session is opened only because the signature
    // demands a device.
    final session = _WindowSession.open();
    tearDownAll(session.close);

    test('a null handle is refused by name', () {
      final attempt = Win32D3d11Surface.forWindow(
        session.device!,
        0,
        pixelWidth: 8,
        pixelHeight: 8,
      );
      expect(attempt.surface, isNull);
      expect(attempt.diagnostics.map((d) => d.message).join('; '),
          contains('null window handle'));
    }, skip: session.skipReason);

    test('a handle that is not a window is refused by name', () {
      // 0x1234 is not a window. The check is IsWindow, and the point is that
      // this fails with a diagnostic rather than inside CreateSwapChainForHwnd.
      final attempt = Win32D3d11Surface.forWindow(
        session.device!,
        0x1234,
        pixelWidth: 8,
        pixelHeight: 8,
      );
      expect(attempt.surface, isNull);
      expect(attempt.diagnostics.map((d) => d.message).join('; '),
          contains('not a live window'));
    }, skip: session.skipReason);

    test('and a real one is adopted without taking ownership of it', () {
      // Unlike the GL surface there is no pixel format to fight over, so a
      // second chain over the same window simply works - and disposing it must
      // leave the window alone, because a borrowed window has to survive its
      // borrower.
      final Win32D3d11SurfaceAttempt second = Win32D3d11Surface.forWindow(
        session.device!,
        session.surface!.windowHandle,
        pixelWidth: 32,
        pixelHeight: 32,
      );
      expect(second.surface, isNotNull, reason: second.diagnostics.join('; '));
      expect(second.surface!.windowHandle, session.surface!.windowHandle);
      second.surface!.dispose();

      expect(session.surface!.isPresentable, isTrue,
          reason: 'the borrower went; the window and the chain that owns it '
              'must not have gone with it');
    }, skip: session.skipReason);
  });

  group('a live windowed Direct3D 11 target', () {
    final session = _WindowSession.open();
    tearDownAll(session.close);

    test('creates a swap chain and says which model it got', () {
      // The swap effect is a compatibility ladder, not a preference, and which
      // rung this machine landed on explains a frame time nothing else in the
      // report would.
      final report = session.diagnostics.map((d) => d.message).join('\n');
      expect(report, contains('swap chain:'));
      printOnFailure(report);
      expect(
        session.surface!.swapEffect,
        anyOf(
          dxgiSwapEffectFlipDiscard,
          dxgiSwapEffectFlipSequential,
          dxgiSwapEffectDiscard,
        ),
      );
      expect(session.surface!.bufferFormat, dxgiFormatB8G8R8A8Unorm);
    }, skip: session.skipReason);

    test('creates a target over a real window handle', () {
      final D3d11WindowTarget target = session.target(64, 48);
      expect(target.surface.nativeHandle, session.surface!.windowHandle);
      expect(target.surface.pixelWidth, 64);
      expect(target.surface.pixelHeight, 48);
      // The descriptor reports the format the chain's buffers actually have,
      // even though nothing reads them back.
      expect(target.surface.format, PixelFormat.bgra8888Premultiplied);
      expect(target.surface.swapChain.backBufferView, isNot(nullptr));
      target.dispose();
    }, skip: session.skipReason);

    test('present reaches Present instead of reading the buffer back',
        () async {
      final D3d11WindowTarget target = session.target(64, 48);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFF3366CC, antiAlias: false);
      list.drawRect(4, 4, 40, 30, paint);

      final int before = session.surface!.presentCount;
      final PresentResult result =
          await target.renderDisplayList(list, clearColor: 0xFF102030);

      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      expect(session.surface!.presentCount, before + 1,
          reason: 'a windowed present that never reaches Present is the '
              'readback path wearing a different name');
      // S_OK on a hidden window on this machine. DXGI_STATUS_OCCLUDED would
      // also be a success and is handled separately below.
      expect(succeeded(target.lastPresentHresult), isTrue);
      printOnFailure('Present -> ${hresultName(target.lastPresentHresult)}');
      target.dispose();
    }, skip: session.skipReason);

    test('several frames in a row each present once', () async {
      final D3d11WindowTarget target = session.target(32, 32);
      final int before = session.surface!.presentCount;
      for (var i = 0; i < 3; i++) {
        final PresentResult result = await target.renderDisplayList(
          DisplayList(),
          clearColor: 0xFF000000 | i,
        );
        expect(result.status, PresentStatus.presented);
      }
      expect(session.surface!.presentCount - before, 3);
      target.dispose();
    }, skip: session.skipReason);

    test('the sync interval can be set and is honest about it', () {
      final D3d11WindowTarget target = session.target(16, 16);
      // Unlike WGL, this is an argument to Present rather than an extension
      // entry point the driver may not export, so it cannot fail for lack of
      // support.
      expect(target.swapChain.setSyncInterval(0), isTrue);
      expect(target.swapChain.setSyncInterval(1), isTrue);
      expect(target.swapChain.setSyncInterval(-1), isFalse);
      target.dispose();
    }, skip: session.skipReason);

    test('a frame from before a resize is refused, not drawn', () async {
      final D3d11WindowTarget target = session.target(64, 48);
      final Frame frame =
          target.beginFrame(const FrameRequest(clearColor: 0xFF000000));
      final int before = session.surface!.presentCount;

      target.resize(96, 72, 1.0);
      final PresentResult result = await target.present(frame);

      expect(result.status, PresentStatus.stale);
      expect(result.diagnostic, isNotNull);
      expect(session.surface!.presentCount, before,
          reason: 'a stale frame must not reach the window system at all');
      // And the target still works afterwards: stale is not an error state.
      final PresentResult next =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(next.status, PresentStatus.presented);
      target.dispose();
    }, skip: session.skipReason);

    test('a frame from before the window invalidated itself is refused',
        () async {
      // The case a target-local counter cannot catch: the window resized and
      // nobody told the target. The shared GenerationToken is what makes it
      // visible.
      final token = GenerationToken();
      final D3d11WindowTarget target = session.target(64, 48, token: token);
      final Frame frame = target.beginFrame(const FrameRequest());

      token.invalidate();

      expect(target.needsResize, isTrue);
      final PresentResult result = await target.present(frame);
      expect(result.status, PresentStatus.stale);
      expect(result.diagnostic!.detail, contains('resize()'));

      // Reconciling with the window's size clears it, and frames flow again.
      target.resize(64, 48, 1.0);
      expect(target.needsResize, isFalse);
      final PresentResult next =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(next.status, PresentStatus.presented);
      target.dispose();
    }, skip: session.skipReason);

    test('resize changes the viewport the next frame is drawn at', () async {
      final D3d11WindowTarget target = session.target(32, 32);
      expect(target.surface.pixelWidth, 32);

      target.resize(80, 60, 2.0);

      expect(target.surface.pixelWidth, 80);
      expect(target.surface.pixelHeight, 60);
      expect(target.surface.scale, 2.0);
      // The window handle and the swap chain survive a resize: a window that
      // was resized is the same window.
      expect(target.surface.nativeHandle, session.surface!.windowHandle);
      expect(session.device!.isLost, isFalse,
          reason: 'a reconfigure failure marks the device lost, so a live '
              'device here is the assertion that ResizeBuffers succeeded');
      final PresentResult result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF204060);
      expect(result.status, PresentStatus.presented);
      target.dispose();
    }, skip: session.skipReason);

    test('a resize to the same size with no invalidation is a no-op', () {
      final D3d11WindowTarget target = session.target(40, 40);
      final int generation = target.generation;
      final int resizes = session.surface!.resizeCount;
      target.resize(40, 40, 1.0);
      expect(target.generation, generation);
      expect(session.surface!.resizeCount, resizes);
      target.dispose();
    }, skip: session.skipReason);

    test('a zero-sized resize is refused', () {
      final D3d11WindowTarget target = session.target(40, 40);
      expect(() => target.resize(0, 40, 1.0), throwsArgumentError);
      expect(() => target.resize(40, -1, 1.0), throwsArgumentError);
      target.dispose();
    }, skip: session.skipReason);

    test('the same device still builds offscreen targets', () {
      // The window path must not have taken the offscreen one with it: both
      // descriptors go to the same createTarget and produce different classes.
      final RenderTarget target =
          session.device!.createTarget(const MemorySurfaceDescriptor(
        pixelWidth: 8,
        pixelHeight: 8,
        format: PixelFormat.rgba8888Premultiplied,
      ));
      expect(target, isA<D3d11OffscreenTarget>());
      target.dispose();
    }, skip: session.skipReason);
  });

  group('ResizeBuffers', () {
    final session = _WindowSession.open();
    tearDownAll(session.close);

    test('succeeds when nothing holds the back buffer', () {
      final Win32D3d11Surface surface = session.surface!;
      // The context is what usually holds the invisible reference, so it is
      // unbound first - which is exactly what D3d11WindowTarget.resize does.
      session.device!.unbindTargets();
      final int before = surface.resizeCount;

      expect(surface.reconfigure(pixelWidth: 128, pixelHeight: 96), isNull);
      expect(surface.resizeCount, before + 1);
      // And the chain has a usable view again: ResizeBuffers destroyed the old
      // back buffer, so a chain that did not re-acquire would refuse every
      // frame afterwards.
      expect(surface.backBufferView, isNot(nullptr));
    }, skip: session.skipReason);

    test('fails with DXGI_ERROR_INVALID_CALL while a reference is outstanding',
        () {
      // The classic Direct3D 11 mistake, reproduced on purpose. The reference
      // below is one the swap chain cannot see and cannot release: exactly the
      // situation a render-target view left alive, or a back buffer still bound
      // to the immediate context, creates in real code.
      final Win32D3d11Surface surface = session.surface!;
      session.device!.unbindTargets();

      final arena = NativeArena();
      addTearDown(arena.dispose);
      final Pointer<Pointer<Void>> out = arena.allocateOutPointer();
      expect(
        succeeded(surface.swapChain.getBuffer(
          surface.swapChain.pointer,
          0,
          iidId3d11Texture2D.allocateIn(arena),
          out,
        )),
        isTrue,
      );
      final ComObject held =
          ComObject(out.value, interfaceName: 'ID3D11Texture2D');

      final int before = surface.resizeCount;
      final BackendDiagnostic? failure =
          surface.reconfigure(pixelWidth: 160, pixelHeight: 120);

      expect(failure, isNotNull,
          reason: 'ResizeBuffers must not be reported as succeeding while a '
              'back-buffer reference is outstanding; it does not crash, it '
              'leaves the old buffers at the old size and every frame '
              'afterwards is drawn wrong');
      expect(failure!.detail, contains('DXGI_ERROR_INVALID_CALL'));
      expect(failure.detail, contains('render-target view'));
      expect(surface.resizeCount, before,
          reason: 'a refused resize is not a resize');
      // The chain is left usable at its old size rather than viewless, so the
      // caller can keep drawing while it works out what it is still holding.
      expect(surface.backBufferView, isNot(nullptr));

      held.dispose();

      // And now the same call, with nothing changed except the reference.
      expect(surface.reconfigure(pixelWidth: 160, pixelHeight: 120), isNull,
          reason: 'releasing the outstanding reference is the whole fix');
      expect(surface.resizeCount, before + 1);
      expect(surface.backBufferView, isNot(nullptr));
    }, skip: session.skipReason);

    test('a target that resizes unbinds the context first', () async {
      // The end-to-end form of the test above. The immediate context holds a
      // reference to whatever is bound as a render target, and nothing in Dart
      // can see it - so a target that presented a frame and then resized
      // without unbinding would fail here and nowhere else.
      final D3d11WindowTarget target = session.target(64, 48);
      final PresentResult drawn =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF204060);
      expect(drawn.status, PresentStatus.presented);
      // The back buffer is now bound to the context, which is the state that
      // makes ResizeBuffers fail.
      final int before = session.surface!.resizeCount;

      target.resize(96, 72, 1.0);

      expect(session.surface!.resizeCount, before + 1,
          reason: 'resize() must have unbound the render target before asking '
              'the chain to reconfigure');
      expect(session.device!.isLost, isFalse);
      final PresentResult next =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF204060);
      expect(next.status, PresentStatus.presented);
      target.dispose();
    }, skip: session.skipReason);

    test('an empty size is refused without touching the chain', () {
      final Win32D3d11Surface surface = session.surface!;
      final int before = surface.resizeCount;
      expect(surface.reconfigure(pixelWidth: 0, pixelHeight: 8), isNotNull);
      expect(surface.reconfigure(pixelWidth: 8, pixelHeight: -1), isNotNull);
      expect(surface.resizeCount, before);
      expect(surface.backBufferView, isNot(nullptr));
    }, skip: session.skipReason);
  });

  group('a present that does not simply succeed', () {
    final session = _WindowSession.open();
    tearDownAll(session.close);

    test('a window that is gone becomes a named failure, not a crash',
        () async {
      final chain = _ScriptedSwapChain(delegate: session.surface)
        ..presentable = false;
      final D3d11WindowTarget target = session.targetOver(chain, 32, 32);

      final PresentResult result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(result.status, PresentStatus.failed);
      expect(result.diagnostic!.message, contains('window is gone'));
      expect(chain.presentCount, 0);
      target.dispose();
    }, skip: session.skipReason);

    test('a chain with no back-buffer view refuses rather than drawing nowhere',
        () async {
      // OMSetRenderTargets accepts a null view and renders nowhere without
      // complaining, so a frame drawn against one looks exactly like a frame
      // the compositor lost. This is the state a failed ResizeBuffers leaves.
      final chain = _ScriptedSwapChain(delegate: session.surface)
        ..viewless = true;
      final D3d11WindowTarget target = session.targetOver(chain, 32, 32);

      final PresentResult result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(result.status, PresentStatus.failed);
      expect(result.diagnostic!.message, contains('no back-buffer view'));
      expect(chain.presentCount, 0);
      target.dispose();
    }, skip: session.skipReason);

    test('a refused Present names the HRESULT', () async {
      final chain = _ScriptedSwapChain(delegate: session.surface)
        ..result = dxgiErrorInvalidCall;
      final D3d11WindowTarget target = session.targetOver(chain, 32, 32);

      final PresentResult result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(result.status, PresentStatus.failed);
      expect(result.diagnostic!.message, contains('refused to present'));
      expect(result.diagnostic!.detail, contains('DXGI_ERROR_INVALID_CALL'));
      expect(chain.presentCount, 1, reason: 'the present was attempted');
      target.dispose();
    }, skip: session.skipReason);

    test('DXGI_STATUS_OCCLUDED is a presented frame with a note', () async {
      // A *success* code meaning the frame was accepted and thrown away
      // because nothing can see the window. Calling it a failure would make a
      // minimised application look like a broken renderer; saying nothing
      // would hide why a frame rate collapses behind another window.
      final chain = _ScriptedSwapChain(delegate: session.surface)
        ..result = dxgiStatusOccluded;
      final D3d11WindowTarget target = session.targetOver(chain, 32, 32);

      final PresentResult result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(result.status, PresentStatus.presented);
      expect(result.diagnostic, isNotNull);
      expect(result.diagnostic!.message, contains('occluded'));
      expect(target.lastPresentHresult, dxgiStatusOccluded);
      target.dispose();
    }, skip: session.skipReason);

    test('DXGI_ERROR_DEVICE_REMOVED is device loss, not a failed present',
        () async {
      // The distinction the whole PresentStatus enum exists for: `failed`
      // means retry the frame, `deviceLost` means build a new device. Getting
      // it wrong turns a driver update into an application that spins forever
      // re-presenting into a device that is gone.
      final chain = _ScriptedSwapChain(delegate: session.surface)
        ..result = dxgiErrorDeviceRemoved;
      final D3d11WindowTarget target = session.targetOver(chain, 32, 32);

      final PresentResult result =
          await target.renderDisplayList(DisplayList(), clearColor: 0xFF000000);
      expect(result.status, PresentStatus.deviceLost);
      expect(result.diagnostic!.detail, contains('DXGI_ERROR_DEVICE_REMOVED'));
      // The real device underneath is fine - GetDeviceRemovedReason said so -
      // so nothing was marked lost on the strength of one HRESULT.
      expect(session.device!.isLost, isFalse);
      target.dispose();
    }, skip: session.skipReason);
  });
}

/// A swap chain whose answers a test chooses.
///
/// Delegates [backBufferView] to a real surface when it has one, so a target
/// built over it draws into a genuine back buffer and only the *outcome* of the
/// present is scripted. A wholly fake view would make every one of these tests
/// a test of the fake.
final class _ScriptedSwapChain implements D3d11SwapChain {
  _ScriptedSwapChain({this.delegate});

  final Win32D3d11Surface? delegate;

  int result = sOk;
  bool presentable = true;
  bool viewless = false;
  int presentCount = 0;
  int syncInterval = 1;

  @override
  Pointer<Void> get backBufferView =>
      viewless ? nullptr : (delegate?.backBufferView ?? nullptr);

  @override
  bool get isPresentable => presentable;

  @override
  int present() {
    presentCount++;
    return result;
  }

  @override
  bool setSyncInterval(int interval) {
    syncInterval = interval;
    return true;
  }

  @override
  BackendDiagnostic? reconfigure({
    required int pixelWidth,
    required int pixelHeight,
  }) =>
      null;
}

/// One device, one window and one swap chain per group, or the reason there is
/// none.
///
/// Per group rather than per file because the `ResizeBuffers` group changes the
/// chain's size underneath itself, and a group that inherited a chain another
/// group had resized would be asserting against a state it did not set.
final class _WindowSession {
  _WindowSession._(
      this.device, this.surface, this.skipReason, this.diagnostics);

  final D3d11RenderDevice? device;
  final Win32D3d11Surface? surface;

  /// Null when everything opened. A string - which `skip:` accepts - when it
  /// did not, so a run with no GPU names what was missing.
  final String? skipReason;

  final List<BackendDiagnostic> diagnostics;

  static _WindowSession open() {
    if (!Platform.isWindows) {
      return _WindowSession._(
          null,
          null,
          'Direct3D 11 needs Windows; this is ${Platform.operatingSystem}',
          const <BackendDiagnostic>[]);
    }
    final D3d11RenderDevice device;
    try {
      device = D3d11RendererBackend.openDevice();
    } on Object catch (error) {
      return _WindowSession._(
          null, null, 'no D3D11 device: $error', const <BackendDiagnostic>[]);
    }
    final Win32D3d11SurfaceAttempt attempt =
        Win32D3d11Surface.hidden(device, width: 64, height: 48);
    if (attempt.surface == null) {
      device.dispose();
      return _WindowSession._(
        null,
        null,
        'no swap chain: ${attempt.diagnostics.join('; ')}',
        attempt.diagnostics,
      );
    }
    return _WindowSession._(device, attempt.surface, null, attempt.diagnostics);
  }

  D3d11WindowTarget target(int width, int height, {GenerationToken? token}) =>
      device!.createTarget(surface!.describeSurface(
        pixelWidth: width,
        pixelHeight: height,
        generation: token,
      )) as D3d11WindowTarget;

  /// A target over a scripted chain rather than the real one, so a present's
  /// outcome can be chosen while everything else stays real.
  D3d11WindowTarget targetOver(
    D3d11SwapChain chain,
    int width,
    int height,
  ) =>
      D3d11WindowTarget(
        device!,
        D3d11WindowSurfaceDescriptor(
          nativeHandle: surface!.windowHandle,
          pixelWidth: width,
          pixelHeight: height,
          swapChain: chain,
          generation: GenerationToken(),
        ),
      );

  void close() {
    surface?.dispose();
    device?.dispose();
  }
}
