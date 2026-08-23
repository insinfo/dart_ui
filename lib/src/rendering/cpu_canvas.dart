/// Canvas and adapter boundaries for the portable CPU renderer.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../graphics/display_list.dart';
import '../graphics/display_list_geometry.dart';
import '../graphics/display_list_opcodes.dart';
import '../graphics/gradient.dart';
import 'cpu_renderer.dart';
import 'framebuffer.dart';
import 'raster/blend.dart';

/// Rasterizer implementations available to the CPU backend.
enum CpuRasterizerKind { scanline, reference }

/// Alpha-mask glyph supplied by a Dart text shaper or test fixture.
final class GlyphBitmap {
  GlyphBitmap({
    required this.width,
    required this.height,
    required this.pixels,
  }) : assert(pixels.length == width * height);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// Selects a Dart rasterizer without leaking that choice into widgets.
final class CpuRasterizerSelector {
  const CpuRasterizerSelector({this.kind = CpuRasterizerKind.scanline});

  final CpuRasterizerKind kind;

  CpuRasterizerAdapter create() => switch (kind) {
        CpuRasterizerKind.scanline => const ScanlineCpuRasterizerAdapter(),
        CpuRasterizerKind.reference => const ReferenceCpuRasterizerAdapter(),
      };
}

/// Adapter boundary shared by the production and reference CPU paths.
abstract interface class CpuRasterizerAdapter {
  String get name;

  void rasterize(
    DisplayList displayList,
    Framebuffer framebuffer, {
    int? clearColor,
    Rect? damage,
  });
}

/// The optimized path used by the portable backend.
final class ScanlineCpuRasterizerAdapter implements CpuRasterizerAdapter {
  const ScanlineCpuRasterizerAdapter();

  @override
  String get name => 'scanline';

  @override
  void rasterize(
    DisplayList displayList,
    Framebuffer framebuffer, {
    int? clearColor,
    Rect? damage,
  }) {
    rasterizeDisplayList(
      displayList,
      framebuffer,
      clearColor: clearColor,
      damage: damage,
    );
  }
}

/// A deliberately separate selection point for slow differential rendering.
///
/// It currently delegates to the same exact Dart implementation because the
/// reference is used to validate command and pixel contracts before a second
/// algorithm is promoted. Keeping the adapter distinct lets benchmarks and
/// differential tests name the chosen implementation rather than guessing.
final class ReferenceCpuRasterizerAdapter implements CpuRasterizerAdapter {
  const ReferenceCpuRasterizerAdapter();

  @override
  String get name => 'reference';

  @override
  void rasterize(
    DisplayList displayList,
    Framebuffer framebuffer, {
    int? clearColor,
    Rect? damage,
  }) {
    rasterizeDisplayList(
      displayList,
      framebuffer,
      clearColor: clearColor,
      damage: damage,
    );
  }
}

/// Retained display-list canvas for one CPU surface.
final class CpuCanvas {
  CpuCanvas({
    required this.framebuffer,
    CpuRasterizerAdapter? rasterizer,
  }) : rasterizer = rasterizer ?? const CpuRasterizerSelector().create();

  final Framebuffer framebuffer;
  final CpuRasterizerAdapter rasterizer;
  final DisplayList displayList = DisplayList();

  Rect? _damage;

  Rect? get damage => _damage;

  void reset() {
    displayList.reset();
    _damage = null;
  }

  void addDamage(Rect rect) {
    if (rect.isEmpty) return;
    _damage = _damage == null ? rect : _damage!.union(rect);
  }

  int paint({
    required int colorArgb,
    int style = paintStyleFill,
    double strokeWidth = 0,
    int blendMode = blendModeSrcOver,
    bool antiAlias = true,
    Gradient? gradient,
  }) =>
      displayList.addPaint(
        colorArgb: colorArgb,
        style: style,
        strokeWidth: strokeWidth,
        blendMode: blendMode,
        antiAlias: antiAlias,
        gradient: gradient,
      );

  void fillRect(Rect rect, int paintId) {
    displayList.drawRectangle(rect, paintId);
    addDamage(rect);
  }

  void fillPath(Path path, int paintId) {
    final id = displayList.addPath(path);
    displayList.drawPath(id, paintId);
    addDamage(path.bounds);
  }

  /// Strokes flattened contours with a deterministic, reference-quality
  /// distance test. The scanline display-list path remains the fast fill path;
  /// this direct primitive is useful for adapters and differential goldens.
  void strokePath(Path path, int colorArgb, double width) {
    if (!width.isFinite || width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be finite and positive');
    }
    final flattened = path.flatten(0.25);
    final halfWidth = width / 2;
    final bounds = path.bounds.inflate(halfWidth);
    final left = bounds.left.floor().clamp(0, framebuffer.width);
    final top = bounds.top.floor().clamp(0, framebuffer.height);
    final right = bounds.right.ceil().clamp(0, framebuffer.width);
    final bottom = bounds.bottom.ceil().clamp(0, framebuffer.height);
    final radiusSquared = halfWidth * halfWidth;
    for (var contour = 0; contour < flattened.contourCount; contour++) {
      final start = flattened.contourStarts[contour];
      final end = flattened.contourStarts[contour + 1];
      final segmentCount =
          end - start - 1 + (flattened.contourClosed[contour] == 1 ? 1 : 0);
      for (var segment = 0; segment < segmentCount; segment++) {
        final a = start + segment;
        final b = segment + 1 < end ? a + 1 : start;
        final ax = flattened.pointX(a);
        final ay = flattened.pointY(a);
        final bx = flattened.pointX(b);
        final by = flattened.pointY(b);
        for (var y = top; y < bottom; y++) {
          for (var x = left; x < right; x++) {
            final distance = _distanceSquaredToSegment(
              x + 0.5,
              y + 0.5,
              ax,
              ay,
              bx,
              by,
            );
            if (distance <= radiusSquared) {
              _blendArgbAt(x, y, colorArgb);
            }
          }
        }
      }
    }
    addDamage(bounds);
  }

  /// Blends one alpha-mask glyph into the target. Shaping and fallback remain
  /// outside this layer; this method is the stable rasterization boundary.
  void drawGlyph(GlyphBitmap glyph, int left, int top, int colorArgb) {
    for (var y = 0; y < glyph.height; y++) {
      final targetY = top + y;
      if (targetY < 0 || targetY >= framebuffer.height) continue;
      for (var x = 0; x < glyph.width; x++) {
        final targetX = left + x;
        if (targetX < 0 || targetX >= framebuffer.width) continue;
        final coverage = glyph.pixels[y * glyph.width + x];
        if (coverage == 0) continue;
        final alpha = premultiply((colorArgb >> 24) & 0xFF, coverage);
        _blendArgbAt(
          targetX,
          targetY,
          (alpha << 24) | (colorArgb & 0x00FFFFFF),
        );
      }
    }
    addDamage(Rect.fromLTWH(
      left.toDouble(),
      top.toDouble(),
      glyph.width.toDouble(),
      glyph.height.toDouble(),
    ));
  }

  void drawImage(
    Framebuffer image,
    Rect source,
    Rect destination,
    int paintId,
  ) {
    displayList.drawImage(
      displayList.addImage(image),
      source.left,
      source.top,
      source.right,
      source.bottom,
      destination.left,
      destination.top,
      destination.right,
      destination.bottom,
      paintId,
    );
    addDamage(destination);
  }

  /// Paints a linear gradient directly into the retained pixel target.
  ///
  /// This predates display-list gradient paints and remains as a direct-pixel
  /// convenience for adapters. Retained scenes should pass a [Gradient] to
  /// [paint], so replay preserves transforms, clips, paths and layers. Colors
  /// use the public `0xAARRGGBB` convention and are premultiplied at the edge.
  void fillLinearGradient(
    Rect rect,
    int startColor,
    int endColor, {
    bool vertical = false,
  }) {
    final left = rect.left.floor().clamp(0, framebuffer.width);
    final top = rect.top.floor().clamp(0, framebuffer.height);
    final right = rect.right.ceil().clamp(0, framebuffer.width);
    final bottom = rect.bottom.ceil().clamp(0, framebuffer.height);
    if (right <= left || bottom <= top) return;
    for (var y = top; y < bottom; y++) {
      for (var x = left; x < right; x++) {
        final position = vertical
            ? ((y + 0.5 - rect.top) / rect.height).clamp(0.0, 1.0)
            : ((x + 0.5 - rect.left) / rect.width).clamp(0.0, 1.0);
        final color = _lerpArgb(startColor, endColor, position);
        final offset = framebuffer.offsetOf(x, y);
        final alpha = (color >> 24) & 0xFF;
        final red = premultiply((color >> 16) & 0xFF, alpha);
        final green = premultiply((color >> 8) & 0xFF, alpha);
        final blue = premultiply(color & 0xFF, alpha);
        final redIndex =
            framebuffer.format == PixelFormat.bgra8888Premultiplied ? 2 : 0;
        final first = redIndex == 0 ? red : blue;
        final third = redIndex == 0 ? blue : red;
        blendPixelOver(framebuffer.pixels, offset, first, green, third, alpha);
      }
    }
    addDamage(rect);
  }

  void flush({int? clearColor}) {
    rasterizer.rasterize(
      displayList,
      framebuffer,
      clearColor: clearColor,
      damage: _damage,
    );
    _damage = null;
  }

  void _blendArgbAt(int x, int y, int color) {
    final offset = framebuffer.offsetOf(x, y);
    final alpha = (color >> 24) & 0xFF;
    final red = premultiply((color >> 16) & 0xFF, alpha);
    final green = premultiply((color >> 8) & 0xFF, alpha);
    final blue = premultiply(color & 0xFF, alpha);
    final redIndex =
        framebuffer.format == PixelFormat.bgra8888Premultiplied ? 2 : 0;
    blendPixelOver(
      framebuffer.pixels,
      offset,
      redIndex == 0 ? red : blue,
      green,
      redIndex == 0 ? blue : red,
      alpha,
    );
  }
}

double _distanceSquaredToSegment(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax;
  final dy = by - ay;
  final lengthSquared = dx * dx + dy * dy;
  if (lengthSquared == 0) {
    final x = px - ax;
    final y = py - ay;
    return x * x + y * y;
  }
  final t = ((px - ax) * dx + (py - ay) * dy) / lengthSquared;
  final clamped = math.max(0.0, math.min(1.0, t));
  final x = px - (ax + clamped * dx);
  final y = py - (ay + clamped * dy);
  return x * x + y * y;
}

int _lerpArgb(int start, int end, double t) {
  int channel(int shift) => (((start >> shift) & 0xFF) +
          (((end >> shift) & 0xFF) - ((start >> shift) & 0xFF)) * t)
      .round()
      .clamp(0, 255);

  return (channel(24) << 24) |
      (channel(16) << 16) |
      (channel(8) << 8) |
      channel(0);
}

/// Small identity cache for immutable path resources.
final class PathCache<T> {
  final Map<Path, T> _entries = <Path, T>{};

  T? operator [](Path path) => _entries[path];

  void operator []=(Path path, T value) => _entries[path] = value;

  int get length => _entries.length;

  void clear() => _entries.clear();
}

/// Small cache boundary for shaped glyph resources.
final class GlyphCache<T> {
  final Map<int, T> _entries = <int, T>{};

  T? operator [](int glyphId) => _entries[glyphId];

  void operator []=(int glyphId, T value) => _entries[glyphId] = value;

  int get length => _entries.length;

  void clear() => _entries.clear();
}
