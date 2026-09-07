/// The flip-model swap chain over a real window.
///
/// A hidden top-level window, exactly as `test/backends/win32` already does
/// for the OpenGL surface: a window that is never passed to `ShowWindow` still
/// has a valid handle and a client rectangle, and DXGI asks for nothing more.
/// That is what makes presenting testable on a build machine without putting
/// anything on an operator's screen.
///
/// What this file can and cannot prove about `PresentMode.mailbox`: it can
/// prove the **shape** of the swap chain - that the waitable flag was
/// accepted, that three buffers were created, that a handle came back, and
/// above all that `ResizeBuffers` was given the flag again - because those are
/// answers from DXGI rather than facts about a picture. It cannot prove
/// anything about pacing: a hidden window is not scanned out, so the frame
/// cadence here means nothing. `tool/d3d12_mailbox_smoke.dart` is the other
/// half and it needs a window on screen.
///
/// The observable that matters is the **back buffer index**. Under
/// `DXGI_SWAP_EFFECT_FLIP_DISCARD` it advances on every present and wraps at
/// the buffer count, and `GetCurrentBackBufferIndex` is the only correct
/// source for it. A renderer that kept its own counter would pass a
/// pixel test and tear on the first skipped present.
library;

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_backend.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_window_target.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/gpu/d3d12/d3d12_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/present_mode.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import 'd3d12_session.dart';

void main() {
  final D3d12Session session = D3d12Session.open(window: true);

  group('a swap chain over a hidden window', () {
    tearDownAll(session.close);

    test('is created, and says so rather than throwing when it is not', () {
      final D3d12WindowTarget target = _target(session, 64, 48);
      // Null means it was created. The descriptor carries an opaque integer
      // this framework cannot validate before the call - see
      // d3d12_surface_descriptor.dart - so a refusal has to be reported by
      // name rather than raised.
      expect(target.creationFailure, isNull);
      expect(target.isPresentable, isTrue);
      expect(
          target.bufferCount, D3d12WindowSurfaceDescriptor.kDefaultBufferCount);
      target.dispose();
    }, skip: session.skipReason);

    test('the back buffer index advances on every present and wraps', () async {
      final D3d12WindowTarget target = _target(session, 64, 48);
      // vsync off: this test presents as fast as it can and has nothing on
      // screen to pace itself against, and one blank interval per frame would
      // make it the slowest test in the suite for no signal.
      target.syncInterval = 0;

      final List<int> indices = <int>[];
      for (var frame = 0; frame < 6; frame++) {
        final PresentResult result = await target.renderDisplayList(
          _scene(),
          clearColor: 0xFF102030,
        );
        expect(result.status, PresentStatus.presented,
            reason: '${result.diagnostic}');
        indices.add(target.backBufferIndex);
      }

      // Two buffers, so the sequence is 0, 1, 0, 1, ... A renderer that drew
      // into the same buffer every frame would produce [0, 0, 0, ...] and
      // still look correct on screen, because the compositor would be showing
      // the buffer being written.
      expect(indices, <int>[0, 1, 0, 1, 0, 1]);
      target.dispose();
    }, skip: session.skipReason);

    test('resizing waits for the GPU, resizes the buffers and keeps drawing',
        () async {
      final D3d12WindowTarget target = _target(session, 64, 48);
      target.syncInterval = 0;
      await target.renderDisplayList(_scene(), clearColor: 0xFF102030);

      final int generationBefore = target.generation;
      target.resize(96, 72, 1.0);

      // ResizeBuffers refuses outright while a reference to a back buffer
      // survives, so a null failure here is also the evidence that every one
      // of them was released first. The wait for GPU idle has no loud half -
      // see D3d12WindowTarget.resize - which is why it is done in the same
      // place and documented there.
      expect(target.creationFailure, isNull);
      expect(target.generation, greaterThan(generationBefore));
      expect(target.surface.pixelWidth, 96);
      expect(target.surface.pixelHeight, 72);

      final PresentResult result =
          await target.renderDisplayList(_scene(), clearColor: 0xFF102030);
      expect(result.status, PresentStatus.presented,
          reason: '${result.diagnostic}');
      target.dispose();
    }, skip: session.skipReason);

    test(
        'mailbox rebuilds the chain waitable, and the resize keeps it that way',
        () async {
      final D3d12WindowTarget target = _target(session, 64, 48);
      expect(target.presentMode, PresentMode.fifo);
      expect(target.hasFrameLatencyWaitableObject, isFalse);

      final PresentModeOutcome outcome =
          target.requestPresentMode(PresentMode.mailbox);
      if (!outcome.accepted) {
        // A refusal is a legitimate answer and must name what refused - so it
        // is checked rather than skipped over, and the test then stops
        // because there is no mailbox chain to say anything else about.
        expect(outcome.applied, PresentMode.fifo);
        expect(outcome.diagnostic, isNotNull);
        printOnFailure('$outcome');
        target.dispose();
        return;
      }
      expect(target.presentMode, PresentMode.mailbox);
      expect(target.hasFrameLatencyWaitableObject, isTrue);
      // Three, not the descriptor's two: with two buffers the producer has
      // nothing to draw into while one is on screen and one is queued.
      expect(target.bufferCount, 3);
      expect(target.swapChainFlags & 0x40, 0x40);

      final PresentResult presented =
          await target.renderDisplayList(_scene(), clearColor: 0xFF102030);
      expect(presented.status, PresentStatus.presented,
          reason: '${presented.diagnostic}');

      target.resize(96, 72, 1.0);

      // The whole point of this test. `ResizeBuffers` given 0 instead of the
      // flag returns S_OK and quietly un-waitables the chain, and the handle
      // the frame loop is waiting on then never signals again - so every
      // frame after the first window resize stalls for the wait's full
      // timeout, with nothing anywhere reporting it.
      expect(target.creationFailure, isNull);
      expect(target.swapChainFlags & 0x40, 0x40,
          reason: 'ResizeBuffers dropped the frame-latency waitable flag');
      expect(target.hasFrameLatencyWaitableObject, isTrue);
      expect(target.bufferCount, 3);
      expect(target.presentMode, PresentMode.mailbox);

      final PresentResult afterResize =
          await target.renderDisplayList(_scene(), clearColor: 0xFF102030);
      expect(afterResize.status, PresentStatus.presented,
          reason: '${afterResize.diagnostic}');

      // And back. Leaving mailbox has to release the handle and put the plain
      // chain back, or the next fifo window in the process inherits a waitable
      // object nobody waits on.
      expect(target.requestPresentMode(PresentMode.fifo).accepted, isTrue);
      expect(target.hasFrameLatencyWaitableObject, isFalse);
      expect(target.swapChainFlags, 0);
      expect(
          target.bufferCount, D3d12WindowSurfaceDescriptor.kDefaultBufferCount);
      target.dispose();
    }, skip: session.skipReason);

    test('a frame recorded before a resize presents as stale, not torn',
        () async {
      final D3d12WindowTarget target = _target(session, 64, 48);
      target.syncInterval = 0;
      final Frame frame = target.beginFrame(const FrameRequest());
      target.resize(80, 64, 1.0);

      final PresentResult result = await target.present(frame);
      expect(result.status, PresentStatus.stale);
      expect(result.diagnostic, isNotNull);
      target.dispose();
    }, skip: session.skipReason);

    test('a window handle that is not a window is a diagnostic', () {
      // The consequence the descriptor states out loud: the handle is an
      // opaque integer here and cannot be validated, so the failure surfaces
      // as DXGI's own refusal - which must become a named diagnostic and not
      // an access violation or a thrown error.
      final D3d12WindowTarget target =
          session.device!.createTarget(D3d12WindowSurfaceDescriptor(
        nativeHandle: 0,
        pixelWidth: 16,
        pixelHeight: 16,
        description: 'a null window',
      )) as D3d12WindowTarget;

      expect(target.creationFailure, isNotNull);
      expect(target.isPresentable, isFalse);
      printOnFailure('${target.creationFailure}');
      target.dispose();
    }, skip: session.skipReason);

    test('a present into a target with no swap chain fails by name', () async {
      final D3d12WindowTarget target =
          session.device!.createTarget(D3d12WindowSurfaceDescriptor(
        nativeHandle: 0,
        pixelWidth: 16,
        pixelHeight: 16,
      )) as D3d12WindowTarget;

      final PresentResult result =
          await target.present(target.beginFrame(const FrameRequest()));
      expect(result.status, PresentStatus.failed);
      expect(result.diagnostic, isNotNull);
      target.dispose();
    }, skip: session.skipReason);
  });
}

D3d12WindowTarget _target(D3d12Session session, int width, int height) {
  final D3d12HiddenWindow window = session.window!;
  return session.device!.createTarget(
    window.describe(width: width, height: height),
  ) as D3d12WindowTarget;
}

/// Something with real geometry in it, so a present that silently drew nothing
/// is not what is being measured.
DisplayList _scene() {
  final DisplayList list = DisplayList();
  final int fill = list.addPaint(colorArgb: 0xFFCC3311, antiAlias: false);
  final int soft = list.addPaint(colorArgb: 0x80FFFFFF);
  list
    ..drawRect(4, 4, 40, 30, fill)
    ..drawRRect(10, 10, 50, 40, 5, 5, 5, 5, 5, 5, 5, 5, soft);
  return list;
}
