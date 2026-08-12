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

  group('antialiasing reaches the pixels', () {
    test('a rect on fractional bounds comes out soft at the edge', () async {
      final target = await targetOf(8, 4);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      // Left edge at 2.5: pixel 2 gets half coverage, pixel 3 gets all of it.
      list.drawRectangle(const Rect.fromLTRB(2.5, 0, 6, 4), paint);

      await target.renderDisplayList(list, clearColor: 0xFF000000);

      final (_, _, _, aOutside) = pixelAt(target.framebuffer, 1, 1);
      final (rEdge, _, _, _) = pixelAt(target.framebuffer, 2, 1);
      final (rInside, _, _, _) = pixelAt(target.framebuffer, 3, 1);

      expect(aOutside, 255, reason: 'the background is opaque black');
      expect(pixelAt(target.framebuffer, 1, 1).$1, 0);
      // Half coverage of white over black. 127 rather than 128 because
      // coverage conserves area rather than splitting symmetrically.
      expect(rEdge, closeTo(127, 2));
      expect(rInside, 255);
    });

    test('an integer-bounds rect is byte-identical to the hard fill', () async {
      // The regression guard: turning antialiasing on must not change anything
      // that was already exact, or every existing golden would shift by a
      // pixel of grey.
      final soft = await targetOf(8, 4);
      final hard = await targetOf(8, 4);

      final aa = DisplayList();
      aa.drawRectangle(
          const Rect.fromLTRB(2, 1, 6, 3), aa.addPaint(colorArgb: 0xFF00FF00));
      final noAa = DisplayList();
      noAa.drawRectangle(const Rect.fromLTRB(2, 1, 6, 3),
          noAa.addPaint(colorArgb: 0xFF00FF00, antiAlias: false));

      await soft.renderDisplayList(aa, clearColor: 0xFF000000);
      await hard.renderDisplayList(noAa, clearColor: 0xFF000000);

      expect(
          soft.framebuffer.toPackedBytes(), hard.framebuffer.toPackedBytes());
    });
  });

  group('paths reach the pixels', () {
    test('a rectangular path fills the same pixels a rect fill would',
        () async {
      // Ties the scanline filler to the rect path: the same geometry through
      // two entirely different code paths must land on the same bytes, or
      // shapes will not line up where a border meets a fill.
      final viaPath = await targetOf(8, 8);
      final viaRect = await targetOf(8, 8);

      final pathList = DisplayList();
      final pathPaint = pathList.addPaint(colorArgb: 0xFFFFFFFF);
      final pathId =
          pathList.addPath(Path.rect(const Rect.fromLTRB(2, 2, 6, 6)));
      pathList.drawPath(pathId, pathPaint);

      final rectList = DisplayList();
      rectList.drawRectangle(const Rect.fromLTRB(2, 2, 6, 6),
          rectList.addPaint(colorArgb: 0xFFFFFFFF));

      await viaPath.renderDisplayList(pathList, clearColor: 0xFF000000);
      await viaRect.renderDisplayList(rectList, clearColor: 0xFF000000);

      expect(
        viaPath.framebuffer.toPackedBytes(),
        viaRect.framebuffer.toPackedBytes(),
      );
    });

    test('a triangle covers its interior and antialiases its slope', () async {
      final target = await targetOf(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      final builder = PathBuilder()
        ..moveTo(2, 2)
        ..lineTo(14, 2)
        ..lineTo(2, 14)
        ..close();
      list.drawPath(list.addPath(builder.build()), paint);

      await target.renderDisplayList(list, clearColor: 0xFF000000);

      // Well inside the triangle.
      expect(pixelAt(target.framebuffer, 4, 4).$1, 255);
      // Well outside it, past the hypotenuse.
      expect(pixelAt(target.framebuffer, 13, 13).$1, 0);
      // On the slope. The hypotenuse runs from (14,2) to (2,14), so the
      // interior is x + y < 16 and pixel (8,8) - whose nearest corner already
      // sums to 16 - lies entirely OUTSIDE it. Pixel (7,8) spans sums 15..17
      // and is the one the edge actually cuts, which is where partial
      // coverage has to show up.
      final onEdge = pixelAt(target.framebuffer, 7, 8).$1;
      expect(onEdge, greaterThan(0));
      expect(onEdge, lessThan(255));
      expect(pixelAt(target.framebuffer, 8, 8).$1, 0);
    });

    test('a stroke-styled path draws its outline, not its enclosed region',
        () async {
      final target = await targetOf(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFFFFFFFF,
        style: paintStyleStroke,
        strokeWidth: 2,
      );
      list.drawPath(
        list.addPath(Path.rect(const Rect.fromLTRB(4, 4, 12, 12))),
        paint,
      );

      await target.renderDisplayList(list, clearColor: 0);

      // The border, and only the border. Filling the enclosed region would
      // draw a solid block where a frame was asked for.
      expect(pixelAt(target.framebuffer, 8, 4).$1, 255);
      expect(pixelAt(target.framebuffer, 8, 8).$1, 0);
    });
  });

  group('rounded rectangles have real corners', () {
    test('a rounded corner is cut away, and the middle is not', () async {
      final target = await targetOf(20, 20);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawRRect(
        2,
        2,
        18,
        18,
        6,
        6,
        6,
        6,
        6,
        6,
        6,
        6,
        paint,
      );

      await target.renderDisplayList(list, clearColor: 0xFF000000);

      // The corner pixel of the bounding box is outside a 6px radius, so a
      // bounding-box fill - which is what this used to do - would light it up.
      expect(pixelAt(target.framebuffer, 2, 2).$1, 0);
      // The middle of each edge is well inside.
      expect(pixelAt(target.framebuffer, 10, 3).$1, 255);
      expect(pixelAt(target.framebuffer, 3, 10).$1, 255);
      expect(pixelAt(target.framebuffer, 10, 10).$1, 255);
    });

    test('a zero radius keeps that corner square', () async {
      final target = await targetOf(20, 20);
      final list = DisplayList();
      final paint = list.addPaint(colorArgb: 0xFFFFFFFF);
      // Round only the bottom-right corner.
      list.drawRRect(
        2, 2, 18, 18,
        // Only the bottom-right corner is rounded.
        0, 0, 0, 0, 8, 8, 0, 0,
        paint,
      );

      await target.renderDisplayList(list, clearColor: 0xFF000000);

      // Square corners stay filled; only the rounded one is cut.
      expect(pixelAt(target.framebuffer, 2, 2).$1, 255);
      expect(pixelAt(target.framebuffer, 17, 2).$1, 255);
      expect(pixelAt(target.framebuffer, 2, 17).$1, 255);
      expect(pixelAt(target.framebuffer, 17, 17).$1, 0);
    });

    test('a stroke-styled rounded rect is a frame with rounded corners',
        () async {
      final target = await targetOf(20, 20);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFFFFFFFF,
        style: paintStyleStroke,
        strokeWidth: 2,
      );
      list.drawRRect(2, 2, 18, 18, 4, 4, 4, 4, 4, 4, 4, 4, paint);

      await target.renderDisplayList(list, clearColor: 0xFF000000);

      // Ink on the straight part of the top edge, which the 2-wide pen
      // straddles: rows 1 and 2.
      expect(pixelAt(target.framebuffer, 10, 1).$1, 255);
      expect(pixelAt(target.framebuffer, 10, 2).$1, 255);
      // Not inside, and not outside.
      expect(pixelAt(target.framebuffer, 10, 5).$1, 0);
      expect(pixelAt(target.framebuffer, 10, 10).$1, 0);
      expect(pixelAt(target.framebuffer, 10, 0).$1, 0);
      // The corner is still round. The centreline's corner arc has radius 4
      // about (6, 6) and the pen reaches 1 either side of it, so ink lives
      // between radius 3 and 5: pixel (1, 1), whose centre is 6.36 out, is
      // clear, and pixel (2, 2) at 4.95 is only grazed. A mitred square
      // corner - which is what stroking the bounding box would give - fills
      // both of them solid.
      expect(pixelAt(target.framebuffer, 1, 1).$1, 0);
      expect(pixelAt(target.framebuffer, 2, 2).$1, inExclusiveRange(0, 255));
    });
  });

  group('strokes put ink where the pen sweeps', () {
    /// A one-segment open contour.
    Path segment(double x0, double y0, double x1, double y1) =>
        (PathBuilder()
              ..moveTo(x0, y0)
              ..lineTo(x1, y1))
            .build();

    /// The alpha of the column at [x], top to bottom.
    List<int> column(Framebuffer buffer, int x, int height) => <int>[
          for (var y = 0; y < height; y++) pixelAt(buffer, x, y).$4,
        ];

    test('a horizontal line is width tall and centred on the centreline',
        () async {
      // The bug this is here for: offsetting to one side only. That produces a
      // line of the right thickness sitting half a width off the geometry it
      // was meant to trace, which looks like a layout bug, not a stroker one.
      final target = await targetOf(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFFFFFFFF,
        style: paintStyleStroke,
        strokeWidth: 4,
      );
      list.drawPath(list.addPath(segment(2, 8, 14, 8)), paint);

      await target.renderDisplayList(list, clearColor: 0);

      // Rows 6..9 inclusive: the pen spans y in [6, 10], four pixels, two
      // either side of y = 8. Full coverage, so exactly 255 - the edges land
      // on pixel boundaries and nothing is antialiased.
      expect(
        column(target.framebuffer, 8, 16),
        <int>[0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0],
      );
    });

    test('an open contour ends square at its endpoint: the butt cap default',
        () async {
      // Cap, join and miter limit have no operand in the display list, so the
      // sink supplies StrokeStyle's defaults. This pins the one that is
      // visible on a plain line, so a change to the default is a failing test
      // rather than a picture nobody compares.
      final target = await targetOf(16, 16);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFFFFFFFF,
        style: paintStyleStroke,
        strokeWidth: 4,
      );
      list.drawPath(list.addPath(segment(4, 8, 12, 8)), paint);

      await target.renderDisplayList(list, clearColor: 0);

      // Ink up to the endpoint and not one pixel past it. A square cap would
      // reach x = 14 and a round cap would reach it with a curve.
      expect(pixelAt(target.framebuffer, 4, 8).$4, 255);
      expect(pixelAt(target.framebuffer, 11, 8).$4, 255);
      expect(pixelAt(target.framebuffer, 3, 8).$4, 0);
      expect(pixelAt(target.framebuffer, 12, 8).$4, 0);
    });

    test('a stroked rectangle is a frame, hollow in the middle', () async {
      final target = await targetOf(20, 20);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFFFFFFFF,
        style: paintStyleStroke,
        strokeWidth: 2,
      );
      list.drawRect(5, 5, 15, 15, paint);

      await target.renderDisplayList(list, clearColor: 0);

      final buffer = target.framebuffer;
      // The pen straddles each edge: rows/columns 4 and 5 on the near side,
      // 14 and 15 on the far one.
      for (final int x in <int>[4, 5, 14, 15]) {
        expect(pixelAt(buffer, x, 10).$4, 255, reason: 'vertical edge at $x');
        expect(pixelAt(buffer, 10, x).$4, 255, reason: 'horizontal edge at $x');
      }
      // Inside the frame and outside it, both clear.
      expect(pixelAt(buffer, 10, 10).$4, 0);
      expect(pixelAt(buffer, 10, 7).$4, 0);
      expect(pixelAt(buffer, 10, 3).$4, 0);
      expect(pixelAt(buffer, 10, 16).$4, 0);
      // The corner is mitred, so the outer corner pixel of the frame is ink
      // where a naive four-line stroke would leave a notch.
      expect(pixelAt(buffer, 4, 4).$4, 255);
    });

    test('fillAndStroke draws both halves, and the stroke is not swallowed',
        () async {
      // What the pixels can and cannot show. With one colour per paint - the
      // wire format has no second one - a fill drawn *over* the stroke is
      // indistinguishable from a stroke drawn over the fill: same colour, and
      // source-over composition of a colour with itself is commutative. So a
      // "the overlap is the stroke's colour" assertion is not writable here.
      //
      // What is writable, with a translucent paint, is that the band the two
      // halves share was composited TWICE - which is the observable that dies
      // if either half is skipped, and the reason the sink draws the fill
      // first is documented at drawDevicePath. A caller who wants a border in
      // a different colour issues two commands, which is the case the order
      // will matter for the moment a paint can carry two colours.
      final target = await targetOf(20, 20);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0x80FFFFFF,
        style: paintStyleFillAndStroke,
        strokeWidth: 4,
      );
      list.drawRect(5, 5, 15, 15, paint);

      await target.renderDisplayList(list, clearColor: 0xFF000000);

      final buffer = target.framebuffer;
      final int fillOnly = pixelAt(buffer, 10, 9).$1;
      final int strokeOnly = pixelAt(buffer, 10, 3).$1;
      final int both = pixelAt(buffer, 10, 6).$1;

      // The fill: the shape's interior, which the pen never reaches.
      expect(fillOnly, greaterThan(0));
      // The stroke's outer half: outside the rectangle entirely, so only a
      // stroke can have put ink there.
      expect(strokeOnly, greaterThan(0));
      // The stroke's inner half, over the fill.
      expect(both, greaterThan(fillOnly));
      expect(both, greaterThan(strokeOnly));
      // Beyond the pen's outer edge, nothing.
      expect(pixelAt(buffer, 10, 2).$1, 0);
    });

    test('stroke width scales with the device transform', () async {
      // Stroking happens in local space and the outline is transformed, so a
      // border thickens with the subtree it belongs to - a 2 px rule inside a
      // 2x scaled scene is 4 device pixels. The alternative, a width fixed in
      // device pixels, would make every border in a zoomed UI hairline-thin.
      final target = await targetOf(32, 32);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFFFFFFFF,
        style: paintStyleStroke,
        strokeWidth: 2,
      );
      list.drawPath(list.addPath(segment(2, 8, 14, 8)), paint);

      await target.renderDisplayList(
        list,
        clearColor: 0,
        deviceTransform: const Transform2D.scaling(2, 2),
      );

      final List<int> alphas = column(target.framebuffer, 16, 32);
      final int inked = alphas.where((int a) => a != 0).length;
      expect(inked, 4, reason: 'a 2-unit pen under 2x is 4 device pixels');
      // Still centred, now on the transformed centreline y = 16.
      expect(alphas.indexWhere((int a) => a != 0), 14);
      expect(alphas.lastIndexWhere((int a) => a != 0), 17);
    });

    test('a non-uniform scale stretches the pen, not just its width', () async {
      // The outline is transformed, so the pen is an ellipse under scale(3, 1)
      // and a vertical line comes out three times as wide while a horizontal
      // one does not thicken at all. A single scalar width scaled by "the"
      // device scale - whichever axis it picked - cannot express this.
      final target = await targetOf(32, 16);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFFFFFFFF,
        style: paintStyleStroke,
        strokeWidth: 2,
      );
      list.drawPath(list.addPath(segment(4, 2, 4, 14)), paint);

      await target.renderDisplayList(
        list,
        clearColor: 0,
        deviceTransform: const Transform2D.scaling(3, 1),
      );

      final List<int> row = <int>[
        for (var x = 0; x < 32; x++) pixelAt(target.framebuffer, x, 8).$4,
      ];
      expect(row.where((int a) => a != 0).length, 6);
      expect(row.indexWhere((int a) => a != 0), 9);
      expect(row.lastIndexWhere((int a) => a != 0), 14);
    });

    test('a zero-width stroke draws nothing rather than throwing', () async {
      // A width animating through zero is not a programming error the frame
      // can react to, so it is a stroke of no width - not a hairline, and not
      // an exception in the middle of a paint.
      final target = await targetOf(8, 8);
      final list = DisplayList();
      final paint = list.addPaint(
        colorArgb: 0xFFFFFFFF,
        style: paintStyleStroke,
      );
      list
        ..drawPath(list.addPath(Path.rect(const Rect.fromLTRB(1, 1, 7, 7))),
            paint)
        ..drawRect(1, 1, 7, 7, paint);

      await target.renderDisplayList(list, clearColor: 0);

      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          expect(pixelAt(target.framebuffer, x, y).$4, 0);
        }
      }
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
