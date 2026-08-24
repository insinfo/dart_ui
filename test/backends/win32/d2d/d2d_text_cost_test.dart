/// What a glyph run costs on Direct2D, measured against the CPU and OpenGL.
///
/// ## The claim on trial
///
/// `d2d_raster_sink.dart` states its steady-state text cost as "one
/// `FillOpacityMask` per glyph and no rasterisation". The masks are cached, so
/// nothing is rasterised per frame; what is paid per frame is a *call* per
/// character. This file measures whether that call count is the cost that
/// matters, and it does it in the only way that can answer the question on a
/// real driver: draw the same coverage as N small calls and as one big call,
/// same total area, same clock.
///
/// ## Why it is gated, like the vector cost files
///
/// The same contract `gl_vector_cost_test.dart` and
/// `d3d12_vector_cost_test.dart` state: a shared machine makes any duration
/// threshold either flaky or meaningless, so this file *prints* numbers and
/// asserts only what needs no clock. To take the numbers:
///
///     DART_UI_GPU_BENCHMARK=1 dart test test/backends/win32/d2d/d2d_text_cost_test.dart -j 1
///
/// ## How the cost is split
///
/// Three frames per scene, each a superset of the last, so a subtraction
/// attributes the cost instead of a guess:
///
///   1. **clear only** - `BeginDraw`, `Clear`, `EndDraw`, `GdiFlush`. The
///      fixed price of a frame on this target, whatever it draws.
///   2. **the same display list with a fully transparent paint** - the sink
///      returns before it touches a glyph, so this adds the player's walk and
///      the list decode and nothing else.
///   3. **the real scene** - adds the glyph cache lookups and the draw calls.
///
/// (3) - (2) is what text costs once the masks are resident, which is the
/// number the batching question is about.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d2d/d2d1_interfaces.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d1_library.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d1_structs.dart';
import 'package:dart_ui/src/backends/win32/d2d/d2d_targets.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_com.dart';
import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_backend.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

import 'd2d_session.dart';

const int _clear = 0xFF101418;
const int _ink = 0xFFE8E8E8;

/// Frames per measurement, and frames thrown away before each one.
const int _iterations = 21;
const int _warmupFrames = 5;

const String _benchmarkVariable = 'DART_UI_GPU_BENCHMARK';

final String? _benchmarkSkip = Platform.environment[_benchmarkVariable] == '1'
    ? null
    : 'a measurement rather than a correctness test; set '
        '$_benchmarkVariable=1 to take the numbers';

void main() {
  final D2dSession session = D2dSession.open();
  final String? skip =
      D2dSession.platformSkip ?? session.skipReason ?? _benchmarkSkip;

  tearDownAll(() {
    _gl.close();
    session.close();
  });

  final Typeface dejaVu =
      Typeface.parse(File('test/fonts/DejaVuSans.ttf').readAsBytesSync());

  group('what a run costs, per backend', () {
    for (final _TextScene scene in _scenes(dejaVu)) {
      test('${scene.name}: ${scene.glyphCount} glyphs', () async {
        final DisplayList list = scene.build(argb: _ink);
        final DisplayList invisible = scene.build(argb: 0x00000000);
        final DisplayList blank = DisplayList();

        // Direct2D.
        final D2dOffscreenSurface surface =
            session.surface(scene.width, scene.height);
        addTearDown(surface.dispose);
        double d2dOf(DisplayList l) =>
            _medianSync(() => surface.renderDisplayList(l, clearColor: _clear));
        final double d2dBlank = d2dOf(blank);
        final double d2dWalk = d2dOf(invisible);
        final double d2dFull = d2dOf(list);

        // The same atlas, one `FillOpacityMask` per glyph instead of one
        // `DrawSpriteBatch` per run: what a runtime without
        // `ID2D1DeviceContext3` would pay, measured here rather than guessed
        // at from the synthetic quad test below.
        final D2dOffscreenSurface looped = session.surface(
            scene.width, scene.height,
            spriteBatching: false);
        addTearDown(looped.dispose);
        final double loopBlank = _medianSync(
            () => looped.renderDisplayList(blank, clearColor: _clear));
        final double loopFull = _medianSync(
            () => looped.renderDisplayList(list, clearColor: _clear));

        // The cold frame: the masks are rasterised and uploaded here, once.
        final D2dOffscreenSurface cold =
            session.surface(scene.width, scene.height);
        addTearDown(cold.dispose);
        final Stopwatch coldClock = Stopwatch()..start();
        cold.renderDisplayList(list, clearColor: _clear);
        coldClock.stop();
        final double coldMs = coldClock.elapsedMicroseconds / 1000.0;

        // The CPU renderer, same list, same size.
        final cpu = MemoryRenderTarget(MemorySurfaceDescriptor(
          pixelWidth: scene.width,
          pixelHeight: scene.height,
          format: PixelFormat.bgra8888Premultiplied,
        ));
        addTearDown(cpu.dispose);
        final double cpuBlank = await _median(
            () => cpu.renderDisplayList(blank, clearColor: _clear));
        final double cpuFull = await _median(
            () => cpu.renderDisplayList(list, clearColor: _clear));

        // OpenGL, when this machine has one.
        String glLine = '  gl      unavailable: ${_gl.skipReason}';
        final GlRenderDevice? glDevice = _gl.device;
        if (glDevice != null) {
          final GlOffscreenTarget gl = glDevice.createTarget(
            MemorySurfaceDescriptor(
              pixelWidth: scene.width,
              pixelHeight: scene.height,
              format: PixelFormat.rgba8888Premultiplied,
            ),
          ) as GlOffscreenTarget;
          addTearDown(gl.dispose);
          final double glBlank = await _median(
              () => gl.renderDisplayList(blank, clearColor: _clear));
          final double glFull = await _median(
              () => gl.renderDisplayList(list, clearColor: _clear));
          glLine = '  gl      frame ${_ms(glFull)}   '
              'clear ${_ms(glBlank)}   text ${_ms(glFull - glBlank)}';
        }

        // ignore: avoid_print
        print(
          '\n${scene.name}  ${scene.width}x${scene.height}, '
          '${scene.glyphCount} glyphs at ${scene.pixelSize}px, '
          'median of $_iterations frames\n'
          '  d2d     frame ${_ms(d2dFull)}   clear ${_ms(d2dBlank)}   '
          'walk ${_ms(d2dWalk - d2dBlank)}   '
          'text ${_ms(d2dFull - d2dWalk)}\n'
          '          per glyph ${_us((d2dFull - d2dWalk) / scene.glyphCount)}'
          ' us   cold frame ${_ms(coldMs)}\n'
          '          atlas ${surface.sink.glyphAtlasEntryCount} glyphs, '
          'own bitmaps ${surface.sink.glyphBitmapCount}, '
          'sprite batch ${surface.sink.usesSpriteBatch}\n'
          '  d2d/loop frame ${_ms(loopFull)}   clear ${_ms(loopBlank)}   '
          'text ${_ms(loopFull - loopBlank)}\n'
          '  cpu     frame ${_ms(cpuFull)}   clear ${_ms(cpuBlank)}   '
          'text ${_ms(cpuFull - cpuBlank)}\n'
          '$glLine',
        );

        expect(
            surface.sink.glyphAtlasEntryCount + surface.sink.glyphBitmapCount,
            greaterThan(0),
            reason: 'the upright scenes must go through a resident-mask '
                'route, or the numbers above are measuring the outline one');
      }, skip: skip);
    }
  });

  group('the call count, isolated from everything else', () {
    test('N small FillOpacityMask against one that covers the same area', () {
      // The decisive experiment, and the reason this file exists. The two
      // measurements below put the *same* number of covered pixels on the
      // same surface through the same API, differing only in how many calls
      // it takes. If the per-call overhead is what text costs, the ratio is
      // enormous; if Direct2D's cost is area-proportional, the two are close
      // and batching would buy nothing.
      final D2d1LibraryLoad load = D2d1Library.open();
      final D2d1Library library = load.library!;
      final Allocator alloc = library.allocator;

      const int size = 512;
      const int cell = 16;
      const int across = size ~/ cell;
      const int count = across * across;

      final D2dOffscreenSurface surface = session.surface(size, size);
      addTearDown(surface.dispose);
      final D2dRenderTarget target = surface.renderTarget;

      final Pointer<Void> small = _maskBitmap(target, alloc, cell, cell);
      final Pointer<Void> large = _maskBitmap(target, alloc, size, size);
      final Pointer<Void> brush = _whiteBrush(target, alloc);
      addTearDown(() {
        _release(small);
        _release(large);
        _release(brush);
      });

      final Pointer<D2dRectF> dest =
          alloc.allocate<D2dRectF>(sizeOf<D2dRectF>());
      final Pointer<D2dRectF> src =
          alloc.allocate<D2dRectF>(sizeOf<D2dRectF>());
      addTearDown(() => alloc
        ..free(dest)
        ..free(src));

      void many() {
        surface.beginDirectDraw();
        target.setAntialiasMode(d2d1AntialiasModeAliased);
        src.ref
          ..left = 0
          ..top = 0
          ..right = cell.toDouble()
          ..bottom = cell.toDouble();
        for (var i = 0; i < count; i++) {
          final double x = (i % across) * cell.toDouble();
          final double y = (i ~/ across) * cell.toDouble();
          dest.ref
            ..left = x
            ..top = y
            ..right = x + cell
            ..bottom = y + cell;
          target.fillOpacityMask(small, brush, dest, src);
        }
        target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
        surface.endDirectDraw();
      }

      void one() {
        surface.beginDirectDraw();
        target.setAntialiasMode(d2d1AntialiasModeAliased);
        src.ref
          ..left = 0
          ..top = 0
          ..right = size.toDouble()
          ..bottom = size.toDouble();
        dest.ref
          ..left = 0
          ..top = 0
          ..right = size.toDouble()
          ..bottom = size.toDouble();
        target.fillOpacityMask(large, brush, dest, src);
        target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
        surface.endDirectDraw();
      }

      final double manyMs = _medianSync(many);
      final double oneMs = _medianSync(one);

      // ignore: avoid_print
      print(
        '\nFillOpacityMask call overhead at ${size}x$size '
        '(${size * size} covered pixels either way)\n'
        '  $count calls of ${cell}x$cell   ${_ms(manyMs)}\n'
        '  1 call of ${size}x$size        ${_ms(oneMs)}\n'
        '  per call ${_us(manyMs / count)} us   '
        'ratio ${(manyMs / (oneMs == 0 ? 1e-6 : oneMs)).toStringAsFixed(1)}x',
      );
    }, skip: skip);
  });
  group('the three shapes a run of glyphs could be drawn in', () {
    test('per glyph, per glyph from an atlas, and one sprite batch', () {
      // The route decision, measured. All three draw the same 3400 glyph-sized
      // quads over the same surface from resident bitmaps; they differ only in
      // how many Direct2D calls that takes and where the texels come from.
      //
      //   * per glyph      - what `d2d_raster_sink.dart` does today: one
      //                      `FillOpacityMask` per glyph, each from that
      //                      glyph's own small bitmap;
      //   * atlas, per glyph - one `FillOpacityMask` per glyph, all from one
      //                      bitmap. Isolates what *switching bitmaps* costs
      //                      from what the call itself costs;
      //   * sprite batch   - one `DrawSpriteBatch` for the whole lot.
      //
      // The gap between the first two is what an atlas alone buys; the gap
      // between the second and the third is what batching buys.
      final D2d1Library library = D2d1Library.open().library!;
      final Allocator alloc = library.allocator;

      const int cellWidth = 12;
      const int cellHeight = 16;
      const int across = 100;
      const int down = 34;
      const int count = across * down;
      const int distinctGlyphs = 100;
      const int atlasSize = 256;
      const int slotsAcross = atlasSize ~/ cellWidth;

      final D2dOffscreenSurface surface = session.surface(1280, 720);
      addTearDown(surface.dispose);
      final D2dRenderTarget target = surface.renderTarget;

      final List<Pointer<Void>> singles = <Pointer<Void>>[
        for (var i = 0; i < distinctGlyphs; i++)
          _maskBitmap(target, alloc, cellWidth, cellHeight),
      ];
      final Pointer<Void> atlas =
          _maskBitmap(target, alloc, atlasSize, atlasSize);
      final Pointer<Void> brush = _whiteBrush(target, alloc);
      addTearDown(() {
        for (final Pointer<Void> bitmap in singles) {
          _release(bitmap);
        }
        _release(atlas);
        _release(brush);
      });

      final Pointer<D2dRectF> dest =
          alloc.allocate<D2dRectF>(sizeOf<D2dRectF>());
      final Pointer<D2dRectF> src =
          alloc.allocate<D2dRectF>(sizeOf<D2dRectF>());
      final Pointer<D2dRectF> destinations =
          alloc.allocate<D2dRectF>(sizeOf<D2dRectF>() * count);
      final Pointer<D2dRectU> sources =
          alloc.allocate<D2dRectU>(sizeOf<D2dRectU>() * count);
      final Pointer<D2dColorF> tint =
          alloc.allocate<D2dColorF>(sizeOf<D2dColorF>());
      tint.ref
        ..r = 0.9
        ..g = 0.9
        ..b = 0.9
        ..a = 1;
      addTearDown(() => alloc
        ..free(dest)
        ..free(src)
        ..free(destinations)
        ..free(sources)
        ..free(tint));

      double x(int i) => (i % across) * (cellWidth + 1).toDouble();
      double y(int i) => (i ~/ across) * (cellHeight + 4).toDouble();

      void perGlyph() {
        surface.beginDirectDraw();
        target.setAntialiasMode(d2d1AntialiasModeAliased);
        for (var i = 0; i < count; i++) {
          src.ref
            ..left = 0
            ..top = 0
            ..right = cellWidth.toDouble()
            ..bottom = cellHeight.toDouble();
          dest.ref
            ..left = x(i)
            ..top = y(i)
            ..right = x(i) + cellWidth
            ..bottom = y(i) + cellHeight;
          target.fillOpacityMask(
              singles[i % distinctGlyphs], brush, dest, src);
        }
        target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
        surface.endDirectDraw();
      }

      void perGlyphFromAtlas() {
        surface.beginDirectDraw();
        target.setAntialiasMode(d2d1AntialiasModeAliased);
        for (var i = 0; i < count; i++) {
          final int slot = i % distinctGlyphs;
          final double sx = (slot % slotsAcross) * cellWidth.toDouble();
          final double sy = (slot ~/ slotsAcross) * cellHeight.toDouble();
          src.ref
            ..left = sx
            ..top = sy
            ..right = sx + cellWidth
            ..bottom = sy + cellHeight;
          dest.ref
            ..left = x(i)
            ..top = y(i)
            ..right = x(i) + cellWidth
            ..bottom = y(i) + cellHeight;
          target.fillOpacityMask(atlas, brush, dest, src);
        }
        target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
        surface.endDirectDraw();
      }

      final D2dDeviceContext3? context = target.queryDeviceContext3(alloc);
      Pointer<Void> batchPointer = nullptr;
      if (context != null) {
        final Pointer<Pointer<Void>> out =
            alloc.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
        final int hr = context.createSpriteBatch(out);
        batchPointer = comFailed(hr) ? nullptr : out.value;
        alloc.free(out);
      }
      addTearDown(() {
        if (batchPointer != nullptr) D2dSpriteBatch(batchPointer).release();
        context?.release();
      });

      void spriteBatch() {
        final D2dSpriteBatch batch = D2dSpriteBatch(batchPointer);
        surface.beginDirectDraw();
        target.setAntialiasMode(d2d1AntialiasModeAliased);
        for (var i = 0; i < count; i++) {
          final int slot = i % distinctGlyphs;
          final int sx = (slot % slotsAcross) * cellWidth;
          final int sy = (slot ~/ slotsAcross) * cellHeight;
          (destinations + i).ref
            ..left = x(i)
            ..top = y(i)
            ..right = x(i) + cellWidth
            ..bottom = y(i) + cellHeight;
          (sources + i).ref
            ..left = sx
            ..top = sy
            ..right = sx + cellWidth
            ..bottom = sy + cellHeight;
        }
        batch.clear();
        final int hr = batch.addSprites(
          count,
          destinations,
          sources,
          tint,
          nullptr,
          destinationStride: sizeOf<D2dRectF>(),
          sourceStride: sizeOf<D2dRectU>(),
        );
        expect(hr, 0, reason: 'AddSprites failed');
        context!.drawSpriteBatch(
          batchPointer,
          0,
          count,
          atlas,
          d2d1BitmapInterpolationModeNearestNeighbor,
          d2d1SpriteOptionsClampToSourceRectangle,
        );
        target.setAntialiasMode(d2d1AntialiasModePerPrimitive);
        surface.endDirectDraw();
      }

      final double perGlyphMs = _medianSync(perGlyph);
      final double atlasMs = _medianSync(perGlyphFromAtlas);
      final String batchLine = batchPointer == nullptr
          ? '  sprite batch          unavailable on this runtime'
          : '  sprite batch          ${_ms(_medianSync(spriteBatch))}';

      // ignore: avoid_print
      print(
        '\n$count quads of ${cellWidth}x$cellHeight over 1280x720, '
        'median of $_iterations frames\n'
        '  per glyph, own bitmap ${_ms(perGlyphMs)}   '
        '(${_us(perGlyphMs / count)} us each)\n'
        '  per glyph, one atlas  ${_ms(atlasMs)}   '
        '(${_us(atlasMs / count)} us each)\n'
        '$batchLine',
      );
    }, skip: skip);
  });

}

// ---------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------

/// One text scene: a surface size, a face at a size, and lines of text laid
/// out by advance.
///
/// The advances come from `hmtx` rather than from the shaper, for the reason
/// `d2d_glyph_transform_test.dart` states: what is on trial is the renderer,
/// and a run whose placement came from a layout engine would make a number
/// ambiguous between the two.
final class _TextScene {
  _TextScene({
    required this.name,
    required this.width,
    required this.height,
    required this.font,
    required this.lines,
    required this.originX,
    required this.firstBaseline,
    required this.lineHeight,
  });

  final String name;
  final int width;
  final int height;
  final ScaledTypeface font;
  final List<String> lines;
  final double originX;
  final double firstBaseline;
  final double lineHeight;

  double get pixelSize => font.pixelSize;

  int get glyphCount {
    var total = 0;
    for (final String line in lines) {
      total += line.runes.length;
    }
    return total;
  }

  DisplayList build({required int argb}) {
    final list = DisplayList();
    final int paint = list.addPaint(colorArgb: argb);
    final int fontId = list.addFont(font);
    for (var l = 0; l < lines.length; l++) {
      final List<int> glyphs = <int>[
        for (final int rune in lines[l].runes)
          font.typeface.glyphForCodePoint(rune),
      ];
      final offsets = Float32List(glyphs.length * 2);
      var pen = 0.0;
      for (var i = 0; i < glyphs.length; i++) {
        offsets[i * 2] = pen;
        pen += font.advanceOf(glyphs[i]);
      }
      list.drawGlyphRun(
        fontId,
        paint,
        originX,
        firstBaseline + l * lineHeight,
        Int32List.fromList(glyphs),
        offsets,
        glyphs.length,
      );
    }
    return list;
  }
}

const String _prose =
    'The quick brown fox jumps over the lazy dog, and then it does '
    'it again because measuring one line proves nothing at all here.';

List<_TextScene> _scenes(Typeface face) {
  final ScaledTypeface body = ScaledTypeface(face, 14);
  final ScaledTypeface small = ScaledTypeface(face, 13);
  final ScaledTypeface display = ScaledTypeface(face, 96);
  return <_TextScene>[
    _TextScene(
      name: 'a paragraph of UI text',
      width: 512,
      height: 256,
      font: body,
      lines: _wrap(_prose, 62, 10),
      originX: 8,
      firstBaseline: 20,
      lineHeight: 22,
    ),
    _TextScene(
      name: 'a screen full of text',
      width: 1280,
      height: 720,
      font: small,
      lines: _wrap(_prose, 170, 40),
      originX: 8,
      firstBaseline: 16,
      lineHeight: 17,
    ),
    _TextScene(
      name: 'a headline',
      width: 768,
      height: 160,
      font: display,
      lines: const <String>['Direct2D'],
      originX: 16,
      firstBaseline: 112,
      lineHeight: 0,
    ),
  ];
}

/// [lineCount] lines of exactly [columns] characters, cycling [source] so no
/// two lines are identical and the glyph cache is exercised the way a real
/// page exercises it.
List<String> _wrap(String source, int columns, int lineCount) {
  final List<String> out = <String>[];
  for (var l = 0; l < lineCount; l++) {
    final buffer = StringBuffer();
    for (var c = 0; c < columns; c++) {
      buffer.writeCharCode(source.codeUnitAt((l * 7 + c) % source.length));
    }
    out.add(buffer.toString());
  }
  return out;
}

// ---------------------------------------------------------------------
// Measurement
// ---------------------------------------------------------------------

String _ms(double value) => '${value.toStringAsFixed(3)} ms';

String _us(double milliseconds) => (milliseconds * 1000).toStringAsFixed(2);

/// The median of [_iterations] timed runs of [body], after [_warmupFrames].
///
/// Median rather than mean, for the reason `gl_vector_cost_test.dart` states:
/// one scheduling hiccup in twenty-one frames should not decide the number.
Future<double> _median(Future<void> Function() body) async {
  for (var i = 0; i < _warmupFrames; i++) {
    await body();
  }
  final List<double> samples = <double>[];
  for (var i = 0; i < _iterations; i++) {
    final Stopwatch clock = Stopwatch()..start();
    await body();
    clock.stop();
    samples.add(clock.elapsedMicroseconds / 1000.0);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

double _medianSync(void Function() body) {
  for (var i = 0; i < _warmupFrames; i++) {
    body();
  }
  final List<double> samples = <double>[];
  for (var i = 0; i < _iterations; i++) {
    final Stopwatch clock = Stopwatch()..start();
    body();
    clock.stop();
    samples.add(clock.elapsedMicroseconds / 1000.0);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

// ---------------------------------------------------------------------
// Direct Direct2D resources, for the call-count experiment
// ---------------------------------------------------------------------

Pointer<Void> _maskBitmap(
  D2dRenderTarget target,
  Allocator alloc,
  int width,
  int height,
) {
  final int pitch = width * 4;
  final Pointer<Uint8> staging = alloc.allocate<Uint8>(pitch * height);
  final Uint8List bytes = staging.asTypedList(pitch * height);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = 0x80;
  }
  final Pointer<D2dSizeU> size = alloc.allocate<D2dSizeU>(sizeOf<D2dSizeU>());
  size.ref
    ..width = width
    ..height = height;
  final Pointer<D2dBitmapProperties> properties =
      alloc.allocate<D2dBitmapProperties>(sizeOf<D2dBitmapProperties>());
  properties.ref
    ..dpiX = 96
    ..dpiY = 96;
  properties.ref.pixelFormat
    ..format = dxgiFormatB8G8R8A8Unorm
    ..alphaMode = d2d1AlphaModePremultiplied;
  final Pointer<Pointer<Void>> out =
      alloc.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
  final int hr = target.createBitmap(
      size.ref, staging.cast<Void>(), pitch, properties, out);
  final Pointer<Void> bitmap = out.value;
  alloc
    ..free(staging)
    ..free(size)
    ..free(properties)
    ..free(out);
  expect(hr, 0, reason: 'CreateBitmap ${width}x$height failed');
  return bitmap;
}

Pointer<Void> _whiteBrush(D2dRenderTarget target, Allocator alloc) {
  final Pointer<D2dColorF> color =
      alloc.allocate<D2dColorF>(sizeOf<D2dColorF>());
  color.ref
    ..r = 1
    ..g = 1
    ..b = 1
    ..a = 1;
  final Pointer<Pointer<Void>> out =
      alloc.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
  final int hr = target.createSolidColorBrush(color, out);
  final Pointer<Void> brush = out.value;
  alloc
    ..free(color)
    ..free(out);
  expect(hr, 0, reason: 'CreateSolidColorBrush failed');
  return brush;
}

void _release(Pointer<Void> object) {
  if (object != nullptr) D2dSolidColorBrush(object).release();
}

// ---------------------------------------------------------------------
// One OpenGL device for the whole file, for scale
// ---------------------------------------------------------------------

final _GlScale _gl = _GlScale.open();

final class _GlScale {
  _GlScale._(this.device, this.skipReason, this._surface, this._context);

  final GlRenderDevice? device;
  final String? skipReason;
  final Win32GlSurface? _surface;
  final GlContext? _context;

  static _GlScale open() {
    if (!Platform.isWindows ||
        Platform.environment[_benchmarkVariable] != '1') {
      return _GlScale._(null, 'not measuring', null, null);
    }
    try {
      final attempt = Win32GlSurface.hidden();
      final Win32GlSurface? surface = attempt.surface;
      if (surface == null) {
        return _GlScale._(null,
            'no GL surface: ${attempt.diagnostics.join('; ')}', null, null);
      }
      final contextAttempt = surface.createContext();
      final GlContext? context = contextAttempt.context;
      if (context == null) {
        surface.dispose();
        return _GlScale._(
            null,
            'no GL context: ${contextAttempt.diagnostics.join('; ')}',
            null,
            null);
      }
      return _GlScale._(
        GlRendererBackend.adoptContext(context, surface.glLibrary),
        null,
        surface,
        context,
      );
    } on Object catch (error) {
      return _GlScale._(null, 'opening a GL device threw: $error', null, null);
    }
  }

  void close() {
    device?.dispose();
    _context?.dispose();
    _surface?.dispose();
  }
}
