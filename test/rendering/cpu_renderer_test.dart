import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// End-to-end: an encoded display list becomes bytes, with no window, no GPU
/// and no display server anywhere in the path. Every layer above the renderer
/// gets to be tested this way, which is the reason this backend exists before
/// any real one.
void main() {
  /// 0xAARRGGBB, the form ReplayPaint carries.
  const opaqueRed = 0xFFFF0000;
  const opaqueBlue = 0xFF0000FF;

  /// Reads a pixel as (r, g, b, a) regardless of the buffer's channel order,
  /// so a test asserting colour never accidentally asserts byte layout.
  (int, int, int, int) pixelAt(Framebuffer buffer, int x, int y) {
    final i = buffer.offsetOf(x, y);
    final bytes = buffer.pixels;
    return switch (buffer.format) {
      PixelFormat.bgra8888Premultiplied => (
          bytes[i + 2],
          bytes[i + 1],
          bytes[i],
          bytes[i + 3]
        ),
      PixelFormat.rgba8888Premultiplied => (
          bytes[i],
          bytes[i + 1],
          bytes[i + 2],
          bytes[i + 3]
        ),
    };
  }

  Future<MemoryRenderTarget> targetOf(int width, int height) async {
    final device = await const CpuRendererBackend().createDevice();
    return device.createTarget(
      MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
    ) as MemoryRenderTarget;
  }

  group('CpuRendererBackend', () {
    test('is always available and says what it cannot do', () {
      final probe = const CpuRendererBackend().probe();

      expect(probe.supported, isTrue);
      expect(probe.supports(Capability.cpuPresentation), isTrue);
      // The note is the point: a backend that reports success without saying
      // "no antialiasing, no paths, no text" invites someone to assume all
      // three work.
      expect(probe.diagnostics.single.kind, DiagnosticKind.note);
      expect(probe.diagnostics.single.message, contains('antialiasing'));
    });

    test('refuses a surface it cannot present to, by name', () async {
      final device = await const CpuRendererBackend().createDevice();

      expect(
        () => device.createTarget(_FakeGpuSurface()),
        throwsA(isA<UnsupportedCapabilityError>()
            .having((e) => e.detail, 'detail', contains('opaque-gpu'))),
      );
    });
  });

  group('display list to pixels', () {
    test('a filled rect lands where the encoder said', () async {
      final target = await targetOf(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: opaqueRed);
      list.drawRectangle(const Rect.fromLTRB(2, 2, 6, 6), paint);

      final result = await target.renderDisplayList(list, clearColor: 0);

      expect(result.isSuccess, isTrue);
      expect(pixelAt(target.framebuffer, 3, 3), (255, 0, 0, 255));
      // Half-open edges: the rect covers 2..5 inclusive, not 6.
      expect(pixelAt(target.framebuffer, 6, 3), (0, 0, 0, 0));
      expect(pixelAt(target.framebuffer, 1, 3), (0, 0, 0, 0));
    });

    test('a transform moves the rect, and the clip cuts it', () async {
      final target = await targetOf(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: opaqueBlue);
      list
        ..save()
        ..transform2D(const Transform2D.translation(4, 4))
        ..clipRectangle(const Rect.fromLTRB(0, 0, 6, 16))
        ..drawRectangle(const Rect.fromLTRB(0, 0, 8, 8), paint)
        ..restore();

      await target.renderDisplayList(list, clearColor: 0);

      // The clip is stated in LOCAL space and the transform is already in
      // effect, so it moves too: 0..6 becomes 4..10, and the rect 0..8 becomes
      // 4..12. What survives is their intersection, 4..10.
      //
      // This is the semantics a caller expects - a clip inside a translated
      // subtree follows the subtree - but it is easy to reason about as if the
      // clip were in device space, which is how this test was wrong first.
      expect(pixelAt(target.framebuffer, 5, 5), (0, 0, 255, 255));
      expect(pixelAt(target.framebuffer, 9, 5), (0, 0, 255, 255));
      expect(pixelAt(target.framebuffer, 10, 5), (0, 0, 0, 0));
      expect(pixelAt(target.framebuffer, 3, 5), (0, 0, 0, 0));
    });

    test('restore undoes the clip for later commands', () async {
      final target = await targetOf(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: opaqueRed);
      list
        ..save()
        ..clipRectangle(const Rect.fromLTRB(0, 0, 2, 8))
        ..restore()
        ..drawRectangle(const Rect.fromLTRB(0, 0, 8, 8), paint);

      await target.renderDisplayList(list, clearColor: 0);

      // If restore had not popped the clip, this pixel would be untouched.
      expect(pixelAt(target.framebuffer, 7, 7), (255, 0, 0, 255));
    });

    test('a half-transparent fill blends with what is under it', () async {
      final target = await targetOf(4, 4);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0x80FF0000);
      list.drawRectangle(const Rect.fromLTRB(0, 0, 4, 4), paint);

      // Opaque black underneath.
      await target.renderDisplayList(list, clearColor: 0xFF000000);

      final (r, g, b, a) = pixelAt(target.framebuffer, 1, 1);
      expect(a, 255);
      expect(g, 0);
      expect(b, 0);
      // Source-over with a premultiplied half-alpha red over black.
      expect(r, closeTo(128, 2));
    });
  });

  group('MemoryRenderTarget', () {
    test('rejects a frame from before a resize instead of drawing it',
        () async {
      final target = await targetOf(8, 8);
      final frame = target.beginFrame(const FrameRequest());

      target.resize(16, 16, 1);
      final result = await target.present(frame);

      expect(result.status, PresentStatus.stale);
      expect(result.isSuccess, isFalse);
      // Saying which generation it belonged to is what turns a dropped frame
      // from a mystery into a log line.
      expect(result.diagnostic, isNotNull);
    });

    test('a resize to the same size does not bump the generation', () async {
      final target = await targetOf(8, 8);
      final before = target.generation;

      target.resize(8, 8, 1);

      expect(target.generation, before);
    });

    test('refuses use after dispose', () async {
      final target = await targetOf(4, 4)
        ..dispose();

      expect(
        () => target.beginFrame(const FrameRequest()),
        throwsA(isA<StateError>()),
      );
    });
  });
}

final class _FakeGpuSurface implements NativeSurfaceDescriptor {
  @override
  String get kind => 'opaque-gpu';

  @override
  int get pixelWidth => 4;

  @override
  int get pixelHeight => 4;

  @override
  double get scale => 1;
}
