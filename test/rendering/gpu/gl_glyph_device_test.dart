/// Text on a real driver, against the pixels the CPU renderer produces.
///
/// Until this file existed, a glyph run on a GL device was refused by name:
/// neither target built a [GpuGlyphAtlas], so `GpuRasterSink` had nothing to
/// draw text out of. The atlas itself was tested, the sink's batching was
/// tested, and no test anywhere put a letter on a GPU surface. That is the gap
/// this file closes, and the assertion that closes it is the first one below -
/// the same display list down both backends, compared pixel by pixel.
///
/// ## Why the comparison outranks everything else here
///
/// Every other check in this file can pass while the picture is wrong. An
/// upload count proves nothing was re-sent, not that the right texels were
/// sent. A recycle count proves the atlas made room, not that the glyph that
/// forced it was drawn. Only a readback compared against an independent
/// rasteriser answers whether the number in each channel is right, and the CPU
/// renderer is that independent implementation: it composites 8-bit coverage
/// through `mul255` while the shader multiplies floats and hands the result to
/// a fixed-function blend unit.
///
/// **Observed deviation: 0, on every scene in this file, in all four
/// channels.** The tolerance is declared per test and measured rather than
/// assumed; anything above 0 on a scene that has been exact is a regression,
/// not rounding.
///
/// ## The orientation trap, and why Ahem cannot spring it
///
/// The glyph atlas is *uploaded*, so it is sampled top-down and `uYFlip` -
/// which inverts the projection of a pass whose output is sampled later - has
/// nothing to do with it. Reaching for [kYFlipTopDown] there would draw every
/// letter upside down. A test written with `ahem.ttf` would not notice: Ahem's
/// glyphs are solid squares, and a square is its own mirror image in both
/// axes. So the orientation test below uses DejaVu's **F**, which is
/// asymmetric horizontally (the stem is on the left) and vertically (the bars
/// are at the top), and asserts the asymmetry directly on the read-back
/// pixels rather than only through the diff.
///
/// It skips rather than fails where no driver answers, because "this machine
/// has no GPU" is not a defect in the renderer.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

/// Opaque black, so a scene that got its alpha wrong shows as a colour rather
/// than as transparency nobody looks at.
const int _clear = 0xFF000000;

void main() {
  final session = _GlSession.open();
  // One device for the file: a context costs tens of milliseconds and, on
  // Windows, a window.
  tearDownAll(session.close);

  final Typeface ahem = Typeface.parse(_fontBytes('ahem.ttf'));
  final Typeface dejaVu = Typeface.parse(_fontBytes('DejaVuSans.ttf'));

  group('a glyph run on a live GL device', () {
    test('draws Ahem exactly where the CPU renderer draws it', () async {
      // Ahem's letters are solid boxes with exact metrics, so this is the
      // scene where placement - not shape - is on trial. The box runs from
      // 0.8 em above the baseline to 0.2 em below it and spans one em: at 8 px
      // with the pen at (8, 14) that is x in [8, 16) and y in [7.6, 15.6), so
      // rows 7 and 15 are the fractional ends. A backend that snapped the
      // baseline to a whole row would put 0 or 255 in both and still look like
      // text.
      //
      // Observed deviation: 0.
      final ScaledTypeface font = ahem.atSize(8);
      final DisplayList list = _run(
        font,
        <int>[ahem.glyphForCodePoint(0x58)],
        originX: 8,
        originY: 14,
      );
      await _expectParity(session, list, 24, 24, tolerance: 0);
    }, skip: session.skipReason);

    test('draws a real face, ascenders and descenders and all', () async {
      // DejaVu rather than Ahem: antialiased edges, glyphs of different
      // heights, and a descender that reaches below the baseline - the parts
      // of a run that a mask offset applied with the wrong sign moves.
      //
      // Observed deviation: 0.
      final ScaledTypeface font = dejaVu.atSize(18);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'Ergonomy'),
        originX: 4,
        originY: 24,
        advance: 11,
      );
      await _expectParity(session, list, 104, 34, tolerance: 0);
    }, skip: session.skipReason);

    test('draws an asymmetric glyph the right way up and the right way round',
        () async {
      // The orientation test. `F` has its bars at the top and its stem on the
      // left, so a vertical flip and a horizontal mirror are both visible in
      // the ink distribution - and neither is visible in a square.
      final ScaledTypeface font = dejaVu.atSize(48);
      final DisplayList list = _run(
        font,
        <int>[dejaVu.glyphForCodePoint(0x46)],
        originX: 8,
        originY: 52,
      );
      final _Rendered rendered =
          await _renderBoth(session, list, 48, 64, tolerance: 0);
      final Framebuffer gpu = rendered.gpu;

      // The ink's bounding box, taken from the pixels rather than from the
      // font's metrics: this test is about what reached the surface.
      final _Ink ink = _Ink.of(gpu);
      printOnFailure('ink box $ink');
      expect(ink.width, greaterThan(8));
      expect(ink.height, greaterThan(16));

      // Vertically: the top bar spans the glyph's whole width, the bottom is
      // the stem alone. Upside down, this comparison reverses.
      final int topRow = _rowInk(gpu, ink.top + 1, ink);
      final int bottomRow = _rowInk(gpu, ink.bottom - 2, ink);
      expect(topRow, greaterThan(bottomRow * 2),
          reason: 'F carries its bars at the top; a vertical flip would put '
              'the wide row at the bottom, which is what reaching for '
              'kYFlipTopDown on an uploaded atlas produces');

      // Horizontally: the stem runs the full height on the left, the right
      // side is only reached by the two bars. Mirrored, this reverses.
      final int leftColumn = _columnInk(gpu, ink.left + 1, ink);
      final int rightColumn = _columnInk(gpu, ink.right - 2, ink);
      expect(leftColumn, greaterThan(rightColumn * 2),
          reason: 'F carries its stem on the left; a mirrored atlas fetch '
              'would move it to the right');
      rendered.dispose();
    }, skip: session.skipReason);

    test('is clipped where the CPU clips it', () async {
      // A whole-pixel clip on purpose. `gpu_raster_sink.dart` states the one
      // divergence in its glyph path - a glyph straddling a *fractional* clip
      // edge keeps up to one pixel of ink past it, because trimming the quad
      // at a fraction would misalign every texel in the glyph - so a
      // fractional edge here would be asserting a difference the sink already
      // declares rather than testing the clip.
      //
      // Observed deviation: 0.
      final ScaledTypeface font = dejaVu.atSize(32);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'clip'),
        originX: 4,
        originY: 36,
        advance: 18,
        clip: const _Clip(6, 12, 60, 30),
      );
      await _expectParity(session, list, 80, 48, tolerance: 0);
    }, skip: session.skipReason);
  });

  group('the glyph atlas behind it', () {
    test('uploads nothing on a second frame of the same text', () async {
      // The claim the atlas exists for. A cache hit writes no texels, so
      // nothing is dirty, so no region is sent - and the count is per
      // `glTexSubImage2D` call rather than per frame, so a backend that
      // uploaded the whole atlas "just in case" would fail this by 1.
      final GlOffscreenTarget target = session.target(96, 32);
      final ScaledTypeface font = dejaVu.atSize(16);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'repeat'),
        originX: 4,
        originY: 22,
        advance: 10,
      );

      await target.renderDisplayList(list, clearColor: _clear);
      final int firstUploads = target.glyphUploadCount;
      final int firstMisses = target.glyphAtlas.missCount;
      expect(firstUploads, greaterThan(0),
          reason: 'the first frame has to send the coverage it rasterised');
      expect(firstMisses, greaterThan(0));

      await target.renderDisplayList(list, clearColor: _clear);
      expect(target.glyphUploadCount, firstUploads,
          reason: 'a cache hit dirties nothing, so there is nothing to send');
      expect(target.glyphAtlas.missCount, firstMisses,
          reason: 'the second frame must not rasterise a glyph again');
      expect(target.glyphAtlas.hitCount, greaterThanOrEqualTo(firstMisses));
      expect(target.glyphAtlas.isDirty, isFalse);
      printOnFailure('uploads $firstUploads, misses $firstMisses, '
          'hits ${target.glyphAtlas.hitCount}');
      target.dispose();
    }, skip: session.skipReason);

    test('uploads one region per plot, not the whole texture', () async {
      // Six small glyphs land in one plot, so the frame costs exactly one
      // driver call. A full-atlas upload would move a megabyte to do it.
      final GlOffscreenTarget target = session.target(96, 32);
      final ScaledTypeface font = dejaVu.atSize(16);
      await target.renderDisplayList(
        _run(
          font,
          _glyphsFor(dejaVu, 'plots'),
          originX: 4,
          originY: 22,
          advance: 10,
        ),
        clearColor: _clear,
      );
      expect(target.glyphUploadCount, 1);
      expect(target.glyphAtlas.usedPlotCount, 1);
      target.dispose();
    }, skip: session.skipReason);

    test('an atlas that fills mid-run flushes without losing a glyph',
        () async {
      // Twenty wide capitals at 250 px: each one takes a whole 256 px plot, so
      // the seventeenth has nowhere to go and the sink runs the flush cycle -
      // close the batch, upload, submit what is recorded, mark uploaded,
      // recycle, retry once. The letters are cascaded 12 px apart so that
      // every one of them leaves a strip of ink nothing else covers: a glyph
      // dropped after the flush, or one drawn from texels the retry had
      // already handed to its successor, changes the picture.
      //
      // Observed deviation: 0.
      final ScaledTypeface font = dejaVu.atSize(250);
      final DisplayList list = _run(
        font,
        _glyphsFor(dejaVu, 'ABCDGHKMNOQRSUVWXYZ'),
        originX: 10,
        originY: 260,
        advance: 12,
      );

      final _Rendered rendered =
          await _renderBoth(session, list, 440, 300, tolerance: 0);
      final GlOffscreenTarget target = rendered.target;
      expect(target.glyphAtlas.plotRecycleCount, greaterThan(0),
          reason: 'the run has to have filled the atlas, or this test is '
              'checking the flush cycle without running it');
      expect(target.glyphUploadCount, greaterThan(1),
          reason: 'the flush uploads what was written before it, and present '
              'uploads what was written after');
      printOnFailure('recycled ${target.glyphAtlas.plotRecycleCount} plots in '
          '${target.glyphUploadCount} uploads');
      rendered.dispose();
    }, skip: session.skipReason);

    test('text inside a layer lands in the layer, not on top of it', () async {
      // A layer target is rendered *into* and then sampled, so it is the one
      // pass that does invert its projection - and the glyph quads inside it
      // travel through that inversion while their texture coordinates do not.
      // Getting the pair wrong draws the text upside down inside an
      // otherwise correct layer, which is why this is here and not in
      // gl_layer_device_test.dart.
      //
      // Observed deviation: 0.
      final ScaledTypeface font = dejaVu.atSize(28);
      final list = DisplayList();
      final int background =
          list.addPaint(colorArgb: 0xFF204060, antiAlias: false);
      list.drawRect(0, 0, 80, 48, background);
      final int layerPaint = list.addPaint(colorArgb: 0x80FFFFFF);
      list.saveLayer(2, 2, 78, 46, layerPaint);
      final int ink = list.addPaint(colorArgb: 0xFFFFFFFF);
      list.drawGlyphRun(
        list.addFont(font),
        ink,
        6,
        34,
        Int32List.fromList(_glyphsFor(dejaVu, 'Fj')),
        Float32List.fromList(<double>[0, 0, 18, 0]),
        2,
      );
      list.restore();

      await _expectParity(session, list, 80, 48, tolerance: 0);
    }, skip: session.skipReason);
  });

  group('what this device says about itself', () {
    test('the probe reports that it draws text', () {
      // The report is the only place that can say it: Capability has no member
      // for glyph rendering and RendererCapabilities has no field for one, so
      // before this note a reader could not tell a device that draws text from
      // one that refuses a run by name - and this backend was the second kind
      // until the atlas was wired.
      final BackendProbeResult report =
          GlRendererBackend.describeContext(session.context!);
      expect(report.supported, isTrue);
      final Iterable<String> messages =
          report.diagnostics.map((BackendDiagnostic d) => '${d.message} '
              '${d.detail ?? ''}');
      expect(messages.join('\n'), contains('glyph atlas'));
      expect(
        report.diagnostics.any((BackendDiagnostic d) =>
            d.kind == DiagnosticKind.note && d.message.startsWith('text:')),
        isTrue,
        reason: 'the probe has to name text as something this device does',
      );
    }, skip: session.skipReason);
  });
}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

/// A whole-pixel clip rectangle wrapped around a run.
final class _Clip {
  const _Clip(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// One glyph run, optionally inside a clip.
///
/// The offsets are laid out here rather than shaped, because what is on trial
/// is the renderer and not the shaper: a run whose advances came from a text
/// layout would make a failure ambiguous between the two.
DisplayList _run(
  ScaledTypeface font,
  List<int> glyphs, {
  required double originX,
  required double originY,
  double advance = 0,
  int argb = 0xFFFFFFFF,
  _Clip? clip,
}) {
  final list = DisplayList();
  final int ink = list.addPaint(colorArgb: argb);
  if (clip != null) {
    list
      ..save()
      ..clipRect(clip.left, clip.top, clip.right, clip.bottom);
  }
  final offsets = Float32List(glyphs.length * 2);
  for (var i = 0; i < glyphs.length; i++) {
    offsets[i * 2] = i * advance;
  }
  list.drawGlyphRun(
    list.addFont(font),
    ink,
    originX,
    originY,
    Int32List.fromList(glyphs),
    offsets,
    glyphs.length,
  );
  if (clip != null) list.restore();
  return list;
}

List<int> _glyphsFor(Typeface face, String text) => <int>[
      for (final int rune in text.runes) face.glyphForCodePoint(rune),
    ];

Uint8List _fontBytes(String name) => File('test/fonts/$name').readAsBytesSync();

// ---------------------------------------------------------------------
// The comparison
// ---------------------------------------------------------------------

/// Both renderings of one display list, kept alive for further assertions.
final class _Rendered {
  _Rendered(this.target, this.cpu);

  final GlOffscreenTarget target;
  final MemoryRenderTarget cpu;

  Framebuffer get gpu => target.framebuffer;

  void dispose() {
    target.dispose();
    cpu.dispose();
  }
}

Future<void> _expectParity(
  _GlSession session,
  DisplayList list,
  int width,
  int height, {
  required int tolerance,
}) async {
  final _Rendered rendered =
      await _renderBoth(session, list, width, height, tolerance: tolerance);
  rendered.dispose();
}

/// Renders [list] through both backends at [width] x [height] and asserts they
/// agree to within [tolerance] levels per channel.
Future<_Rendered> _renderBoth(
  _GlSession session,
  DisplayList list,
  int width,
  int height, {
  required int tolerance,
}) async {
  final cpu = MemoryRenderTarget(MemorySurfaceDescriptor(
    pixelWidth: width,
    pixelHeight: height,
    // The same pixel format the GL readback uses, so a comparison that went
    // wrong cannot be a channel-order mistake in the test itself.
    format: PixelFormat.rgba8888Premultiplied,
  ));
  await cpu.renderDisplayList(list, clearColor: _clear);

  final GlOffscreenTarget gpu = session.target(width, height);
  final PresentResult result =
      await gpu.renderDisplayList(list, clearColor: _clear);
  expect(result.status, PresentStatus.presented);

  // Two identically blank surfaces agree perfectly, so a run that drew nothing
  // - a glyph id that resolved to .notdef, a paint that came out transparent -
  // would pass this silently.
  expect(_isUniform(cpu.framebuffer), isFalse,
      reason: 'the scene drew no text, so comparing it proves nothing');

  final _Diff diff = _diff(cpu.framebuffer, gpu.framebuffer);
  printOnFailure('max deviation ${diff.maxDeviation} over '
      '${diff.differingPixels} pixels');
  expect(
    diff.maxDeviation,
    lessThanOrEqualTo(tolerance),
    reason: 'CPU and GPU disagree by up to ${diff.maxDeviation} levels on '
        '${diff.differingPixels} pixels, over a declared tolerance of '
        '$tolerance.\n${diff.report}',
  );
  return _Rendered(gpu, cpu);
}

final class _Diff {
  _Diff(this.maxDeviation, this.differingPixels, this.report);

  final int maxDeviation;
  final int differingPixels;

  /// The first handful of differing pixels, both sides shown. Not all of them:
  /// a wrong picture differs everywhere, and a thousand-line failure hides the
  /// one number that matters.
  final String report;
}

_Diff _diff(Framebuffer cpu, Framebuffer gpu) {
  expect(gpu.width, cpu.width);
  expect(gpu.height, cpu.height);
  var maxDeviation = 0;
  var differing = 0;
  final lines = <String>[];
  for (var y = 0; y < cpu.height; y++) {
    for (var x = 0; x < cpu.width; x++) {
      final List<int> a = _pixel(cpu, x, y);
      final List<int> b = _pixel(gpu, x, y);
      var deviation = 0;
      for (var c = 0; c < 4; c++) {
        final int delta = (a[c] - b[c]).abs();
        if (delta > deviation) deviation = delta;
      }
      if (deviation == 0) continue;
      differing++;
      if (deviation > maxDeviation) maxDeviation = deviation;
      if (lines.length < 12) lines.add('($x, $y): cpu $a, gpu $b');
    }
  }
  return _Diff(maxDeviation, differing, lines.join('\n'));
}

bool _isUniform(Framebuffer buffer) {
  final List<int> first = _pixel(buffer, 0, 0);
  for (var y = 0; y < buffer.height; y++) {
    for (var x = 0; x < buffer.width; x++) {
      final List<int> pixel = _pixel(buffer, x, y);
      for (var c = 0; c < 4; c++) {
        if (pixel[c] != first[c]) return false;
      }
    }
  }
  return true;
}

List<int> _pixel(Framebuffer framebuffer, int x, int y) {
  final int offset = y * framebuffer.bytesPerRow + x * 4;
  return <int>[
    framebuffer.pixels[offset],
    framebuffer.pixels[offset + 1],
    framebuffer.pixels[offset + 2],
    framebuffer.pixels[offset + 3],
  ];
}

// ---------------------------------------------------------------------
// Ink, for the orientation test
// ---------------------------------------------------------------------

/// The bounding box of everything brighter than the cleared background.
final class _Ink {
  _Ink(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;

  static _Ink of(Framebuffer buffer) {
    var left = buffer.width;
    var top = buffer.height;
    var right = 0;
    var bottom = 0;
    for (var y = 0; y < buffer.height; y++) {
      for (var x = 0; x < buffer.width; x++) {
        if (_pixel(buffer, x, y)[0] <= _inkThreshold) continue;
        if (x < left) left = x;
        if (y < top) top = y;
        if (x >= right) right = x + 1;
        if (y >= bottom) bottom = y + 1;
      }
    }
    return _Ink(left, top, right, bottom);
  }

  @override
  String toString() => '($left, $top)..($right, $bottom)';
}

/// Above the antialiased fringe, so a row is measured by its ink and not by
/// the half-covered pixels around it.
const int _inkThreshold = 32;

int _rowInk(Framebuffer buffer, int y, _Ink ink) {
  var total = 0;
  for (var x = ink.left; x < ink.right; x++) {
    total += _pixel(buffer, x, y)[0];
  }
  return total;
}

int _columnInk(Framebuffer buffer, int x, _Ink ink) {
  var total = 0;
  for (var y = ink.top; y < ink.bottom; y++) {
    total += _pixel(buffer, x, y)[0];
  }
  return total;
}

// ---------------------------------------------------------------------
// Session plumbing - the same shape gl_device_test.dart uses, and for the
// same reason: a context costs tens of milliseconds and, on Windows, a window.
// ---------------------------------------------------------------------

final class _GlSession {
  _GlSession._(this.device, this.context, this.skipReason, this._surface);

  final GlRenderDevice? device;
  final GlContext? context;

  /// Null when the device opened. A string when it did not, so a run with no
  /// GPU reports the driver that was missing rather than passing quietly.
  final String? skipReason;

  final Win32GlSurface? _surface;

  static _GlSession open() {
    try {
      return Platform.isWindows ? _openWindows() : _openEgl();
    } on Object catch (error) {
      return _GlSession._(
          null, null, 'opening a GL device threw: $error', null);
    }
  }

  static _GlSession _openWindows() {
    final attempt = Win32GlSurface.hidden();
    final Win32GlSurface? surface = attempt.surface;
    if (surface == null) {
      return _GlSession._(
          null, null, 'no GL surface: ${attempt.diagnostics.join('; ')}', null);
    }
    final contextAttempt = surface.createContext();
    final GlContext? context = contextAttempt.context;
    if (context == null) {
      surface.dispose();
      return _GlSession._(null, null,
          'no GL context: ${contextAttempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, surface.glLibrary),
        context,
        null,
        surface,
      );
    } on BackendSelectionError catch (error) {
      surface.dispose();
      return _GlSession._(null, null, 'no GL device: $error', null);
    }
  }

  static _GlSession _openEgl() {
    final load = GlLibrary.open();
    if (!load.isLoaded) {
      return _GlSession._(
          null, null, 'no GL library: ${load.attempted.join(', ')}', null);
    }
    final attempt = const GlContextFactory()
        .create(width: 16, height: 16, glLibrary: load.library!);
    final GlContext? context = attempt.context;
    if (context == null) {
      return _GlSession._(null, null,
          'no EGL context: ${attempt.diagnostics.join('; ')}', null);
    }
    try {
      return _GlSession._(
        GlRendererBackend.adoptContext(context, load.library!),
        context,
        null,
        null,
      );
    } on BackendSelectionError catch (error) {
      return _GlSession._(null, null, 'no GL device: $error', null);
    }
  }

  GlOffscreenTarget target(int width, int height) =>
      device!.createTarget(MemorySurfaceDescriptor(
        pixelWidth: width,
        pixelHeight: height,
        format: PixelFormat.rgba8888Premultiplied,
      )) as GlOffscreenTarget;

  void close() {
    device?.dispose();
    _surface?.dispose();
  }
}
