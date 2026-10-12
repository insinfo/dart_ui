/// The seam between a Metal target and the macOS window it presents into.
///
/// Almost everything here runs **without a Mac**, and that is the point: the
/// parts of ADR 0005's window path that can be wrong without a GPU are the
/// refusals, and a refusal that only fires on Apple hardware is a refusal
/// nobody sees until it is too late to be cheap.
///
/// What genuinely needs a device - wrapping an `IOSurface`, drawing into it,
/// presenting it - is not simulated here. It is measured by
/// `tool/metal_present_probe.dart` and `tool/metal_window_present_probe.dart`
/// on a real `macos-14` runner, because a fake that answered those questions
/// would be asserting its own construction. Tests that need the device skip
/// with a reason rather than passing quietly, which is the discipline
/// `test/rendering/gpu/webgl/webgl_session.dart` documents.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/macos/io_surface.dart';
import 'package:dart_ui/src/backends/macos/surface_pool.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_backend.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_device.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_surface_descriptor.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_window_target.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

const String _needsMac =
    'needs a Mac: this opens an MTLDevice and wraps an IOSurface with it';

void main() {
  group('the descriptor a window offers', () {
    test('is the surface a Metal target presents through', () {
      // One descriptor, not two. A window that offered a CPU surface and a
      // separate GPU surface would be claiming two buffers where there is one
      // pool, and the two would drift on the first resize.
      final MacosSurfaceDescriptor descriptor = _pool().describe(2.0);
      expect(descriptor, isA<MetalPresentSurface>());
      expect(descriptor, isA<NativeSurfaceDescriptor>());
      expect(descriptor.kind, 'iosurface');
      expect(descriptor.scale, 2.0);
      expect(descriptor.slotCount, 2);
    });

    test('reports the pool stride and not width times four', () {
      // The number a presenter must not compute for itself: IOSurface rounds
      // the row up for alignment, and a target that assumed the product would
      // shear every frame by the difference.
      final MacosSurfaceDescriptor descriptor = _pool().describe(1.0);
      expect(descriptor.bytesPerRow, 512);
      expect(descriptor.pixelWidth * 4, 400);
      expect(descriptor.bytesPerRow, isNot(descriptor.pixelWidth * 4));
    });

    test('without a window behind it, it refuses to present by name', () async {
      // `describe` is also called for geometry alone. The honest answer then
      // is a named failure, not a present that appears to work: a descriptor
      // that silently did nothing would make a renderer report frames it
      // never showed.
      final MacosSurfaceDescriptor descriptor = _pool().describe(1.0);
      expect(descriptor.isPresentable, isFalse);
      expect(descriptor.presentGeneration, -1);
      final PresentResult result =
          await descriptor.presentBackBuffer(generation: 0);
      expect(result.isSuccess, isFalse);
      expect(result.status, PresentStatus.failed);
      expect(result.diagnostic, isNotNull);
      expect(result.diagnostic!.kind, DiagnosticKind.surfaceCreationFailed);
      expect(result.diagnostic!.detail, contains('geometry'));
    });

    test('a slot that is not an IOSurface answers nullptr, not a crash', () {
      // What a test double reports. `MetalWindowTarget` turns this into a
      // named refusal; handing Metal a nil surface instead returns a nil
      // texture, and that surfaces three steps later as a render pass which
      // silently encodes nothing.
      final MacosSurfaceDescriptor descriptor = _pool().describe(1.0);
      expect(descriptor.surfaceRefForSlot(0), nullptr);
      // Out of range, both ends, rather than an exception from the list.
      expect(descriptor.surfaceRefForSlot(-1), nullptr);
      expect(descriptor.surfaceRefForSlot(99), nullptr);
    });

    test('answers for the window\'s current pool, not the one it was built on',
        () {
      // A renderer keeps the descriptor it was attached with, and a resize
      // replaces the pool behind it. Answering for the old, disposed pool is
      // what made every native popup's first Metal frame throw: a popup is
      // created and then sized, and the target found no IOSurface behind the
      // slots it was given.
      final MacosSurfacePool first = _pool();
      final _Host host = _Host(first);
      final MacosSurfaceDescriptor descriptor = first.describe(1.0, host: host);
      expect(descriptor.pixelWidth, 100);

      final MacosSurfacePool second = MacosSurfacePool(<MacosPoolSurface>[
        _FakeSurface(width: 200, height: 80, bytesPerRow: 832),
        _FakeSurface(width: 200, height: 80, bytesPerRow: 832),
      ]);
      first.dispose();
      host.pool = second;
      expect(descriptor.pixelWidth, 200);
      expect(descriptor.pixelHeight, 80);
      expect(descriptor.bytesPerRow, 832);
      expect(descriptor.isPresentable, isTrue,
          reason: 'the window has a live pool, so presenting is possible');
      second.dispose();
    });

    test('a disposed pool stops being presentable', () {
      final MacosSurfacePool pool = _pool();
      final MacosSurfaceDescriptor descriptor = pool.describe(1.0);
      pool.dispose();
      expect(descriptor.isPresentable, isFalse);
      expect(descriptor.surfaceRefForSlot(0), nullptr);
    });
  });

  group('the backend', () {
    test('accepts a presentable surface on any platform', () {
      // supportsSurface is a question about the descriptor, not the machine.
      // Keeping it platform-independent is what lets selection policy explain
      // itself on a machine that has no Metal at all.
      const MetalRendererBackend backend = MetalRendererBackend();
      expect(backend.supportsSurface(_pool().describe(1.0)), isTrue);
    });
  });

  group('the present timeout', () {
    test('is finite, and far above the measured handler latency', () {
      // A future nobody completes is the failure mode this bounds. The
      // measured latency on the slowest device this has run on - the CI
      // paravirtual GPU, run 34165428755 - was 6.7 ms.
      expect(kMetalPresentTimeout.inMilliseconds, greaterThan(6672 ~/ 1000));
      expect(kMetalPresentTimeout.inSeconds, lessThanOrEqualTo(5),
          reason: 'a timeout long enough to look like a hang is not a timeout');
    });
  });

  group('on a device', () {
    test('a target refuses a pipeline cache built for the wrong format', () {
      // The mistake this catches is invisible until it is expensive: a
      // pipeline state's attachment format is part of its identity in Metal,
      // so a window target handed the device's rgba8Unorm cache would encode
      // nothing on every frame while the offscreen suite stayed green.
      final MetalGpu gpu = MetalGpu.open();
      final MetalPipelineCache rgba = MetalPipelineCache.build(gpu);
      try {
        expect(
          () => MetalWindowTarget(
            gpu: gpu,
            pipelines: rgba,
            surface: _pool().describe(1.0),
          ),
          throwsA(isA<MetalError>().having((MetalError e) => e.message,
              'message', contains('pixel format'))),
        );
      } finally {
        rgba.dispose();
        gpu.dispose();
      }
    }, skip: Platform.isMacOS ? null : _needsMac);

    test('a bgra cache is accepted, and refuses a slot with no IOSurface', () {
      // The pool here is fake, so the target is built and then asked for a
      // surface it cannot get. That is the refusal an application would hit
      // against a window whose pool was torn down under it.
      final MetalGpu gpu = MetalGpu.open();
      final MetalPipelineCache bgra = MetalPipelineCache.build(
        gpu,
        pixelFormat: MtlPixelFormat.bgra8Unorm,
      );
      MetalWindowTarget? target;
      try {
        target = MetalWindowTarget(
          gpu: gpu,
          pipelines: bgra,
          surface: _pool().describe(1.0),
        );
        expect(target.generation, 0);
        expect(target.surface.kind, 'iosurface');
        expect(
          () => target!.beginFrame(const FrameRequest()),
          throwsA(isA<UnsupportedCapabilityError>()),
        );
      } finally {
        target?.dispose();
        bgra.dispose();
        gpu.dispose();
      }
    }, skip: Platform.isMacOS ? null : _needsMac);
  });
}

/// Two surfaces that are not `IOSurface`s, at a stride IOSurface would round to.
///
/// Real enough for the pool's invariants - it refuses fewer than two and
/// refuses mismatched geometry - and deliberately not an `IOSurface`, so the
/// null path is the one under test.
MacosSurfacePool _pool() => MacosSurfacePool(<MacosPoolSurface>[
      _FakeSurface(),
      _FakeSurface(),
    ]);

final class _FakeSurface implements MacosPoolSurface {
  _FakeSurface({this.width = 100, this.height = 40, this.bytesPerRow = 512});

  @override
  int get id => 0;

  @override
  final int width;

  @override
  final int height;

  /// 512 and not 400 by default: the rounding a real IOSurface applies, so a
  /// caller that assumed `width * 4` fails here rather than on a Mac.
  @override
  final int bytesPerRow;

  @override
  bool isDisposed = false;

  @override
  void withPixels(void Function(Uint8List pixels) write) =>
      write(Uint8List(bytesPerRow * height));

  @override
  int createMachPort() => 0;

  @override
  void dispose() => isDisposed = true;
}

final class _Host implements MacosSurfaceHost {
  _Host(this.pool);

  MacosSurfacePool pool;

  @override
  MacosSurfacePool? get currentPool => pool;

  @override
  bool get isPresentable => true;

  @override
  int get presentGeneration => 0;

  @override
  Future<PresentResult> presentBackBuffer({required int generation}) async =>
      const PresentResult(status: PresentStatus.presented);
}
