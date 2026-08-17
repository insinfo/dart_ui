library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../document/pdf_page.dart';
import '../format/pdf_object.dart';
import '../gfx/pdf_gfx_state.dart';
import '../gfx/pdf_matrix.dart';
import '../gfx/pdf_output_device.dart';
import 'pdf_page_renderer.dart';

/// A text run recovered from a PDF page, in page coordinates with the origin
/// at the visible page's top-left corner.
final class PdfTextFragment {
  const PdfTextFragment({
    required this.text,
    required this.textStart,
    required this.bounds,
  });

  final String text;
  final int textStart;
  final Rect bounds;

  int get textEnd => textStart + text.length;
}

/// Searchable and selectable text geometry for one PDF page.
final class PdfPageTextLayout {
  const PdfPageTextLayout({
    required this.pageNumber,
    required this.text,
    required this.fragments,
  });

  final int pageNumber;
  final String text;
  final List<PdfTextFragment> fragments;

  /// Returns the nearest UTF-16 text offset to [position].
  int positionForOffset(Offset position) {
    if (fragments.isEmpty) return 0;
    PdfTextFragment best = fragments.first;
    var bestDistance = double.infinity;
    for (final PdfTextFragment fragment in fragments) {
      if (fragment.bounds.contains(position)) {
        return _offsetInside(fragment, position);
      }
      final double dx = position.dx < fragment.bounds.left
          ? fragment.bounds.left - position.dx
          : position.dx > fragment.bounds.right
              ? position.dx - fragment.bounds.right
              : 0;
      final double dy = position.dy < fragment.bounds.top
          ? fragment.bounds.top - position.dy
          : position.dy > fragment.bounds.bottom
              ? position.dy - fragment.bounds.bottom
              : 0;
      final double distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = fragment;
      }
    }
    return _offsetInside(best, position);
  }

  List<Rect> selectionRects(int base, int extent) {
    final int start = math.min(base, extent).clamp(0, text.length);
    final int end = math.max(base, extent).clamp(0, text.length);
    if (start == end) return const <Rect>[];
    final List<Rect> result = <Rect>[];
    for (final PdfTextFragment fragment in fragments) {
      final int localStart = math.max(start, fragment.textStart);
      final int localEnd = math.min(end, fragment.textEnd);
      if (localStart >= localEnd || fragment.text.isEmpty) continue;
      final double from =
          (localStart - fragment.textStart) / fragment.text.length;
      final double to = (localEnd - fragment.textStart) / fragment.text.length;
      result.add(Rect.fromLTRB(
        fragment.bounds.left + fragment.bounds.width * from,
        fragment.bounds.top,
        fragment.bounds.left + fragment.bounds.width * to,
        fragment.bounds.bottom,
      ));
    }
    return result;
  }

  int _offsetInside(PdfTextFragment fragment, Offset position) {
    if (fragment.text.isEmpty || fragment.bounds.width <= 0) {
      return fragment.textStart;
    }
    final double fraction =
        ((position.dx - fragment.bounds.left) / fragment.bounds.width)
            .clamp(0.0, 1.0);
    return fragment.textStart + (fragment.text.length * fraction).round();
  }
}

/// Extracts text and its page geometry through the same content interpreter
/// used by painting, so rendering, searching and selection agree.
final class PdfTextExtractor {
  const PdfTextExtractor(this.page);

  final PdfPage page;

  PdfPageTextLayout extract() {
    final _PdfTextOutputDevice device = _PdfTextOutputDevice(page);
    PdfPageRenderer(page).render(device, applyPageRotation: false);
    return device.layout;
  }
}

final class _PdfTextOutputDevice extends PdfOutputDevice {
  _PdfTextOutputDevice(this.page)
      : _pageToView = pdfPageTransform(page, Offset.zero, 1);

  final PdfPage page;
  final Transform2D _pageToView;
  final List<Transform2D> _stack = <Transform2D>[];
  final List<PdfTextFragment> _fragments = <PdfTextFragment>[];
  final StringBuffer _text = StringBuffer();
  Transform2D _ctm = Transform2D.identity;

  PdfPageTextLayout get layout => PdfPageTextLayout(
        pageNumber: page.pageNumber,
        text: _text.toString(),
        fragments: List<PdfTextFragment>.unmodifiable(_fragments),
      );

  @override
  void saveState() => _stack.add(_ctm);

  @override
  void restoreState() {
    if (_stack.isNotEmpty) _ctm = _stack.removeLast();
  }

  @override
  void transform(PdfMatrix matrix) {
    _ctm = _ctm.multiply(_asTransform(matrix));
  }

  @override
  void drawText(
    String text,
    PdfGfxState state,
    PdfMatrix textMatrix, {
    double? advance,
  }) {
    if (text.isEmpty) return;
    final double width = (advance ?? state.fontSize * text.length * 0.5).abs();
    if (width == 0 || !width.isFinite || state.fontSize == 0) return;
    final Transform2D transform =
        _pageToView.multiply(_ctm).multiply(_asTransform(textMatrix));
    final Rect bounds = transform.transformRect(Rect.fromLTRB(
      0,
      state.textRise - state.fontSize * 0.20,
      width,
      state.textRise + state.fontSize * 0.85,
    ));
    if (bounds.isEmpty) return;

    final PdfTextFragment? previous =
        _fragments.isEmpty ? null : _fragments.last;
    if (previous != null) {
      final double lineTolerance =
          math.max(previous.bounds.height, bounds.height) * 0.55;
      final bool sameLine =
          (previous.bounds.center.dy - bounds.center.dy).abs() <= lineTolerance;
      if (!sameLine) {
        _text.write('\n');
      } else {
        final double gap = bounds.left - previous.bounds.right;
        final double spaceThreshold =
            math.min(previous.bounds.height, bounds.height) * 0.12;
        if (gap > spaceThreshold &&
            !previous.text.endsWith(' ') &&
            !text.startsWith(' ')) {
          _text.write(' ');
        }
      }
    }
    final int start = _text.length;
    _text.write(text);
    _fragments.add(PdfTextFragment(
      text: text,
      textStart: start,
      bounds: bounds,
    ));
  }

  @override
  void clip(Path path, {bool evenOdd = false}) {}

  @override
  void fillPath(Path path, PdfGfxState state, {bool evenOdd = false}) {}

  @override
  void strokePath(Path path, PdfGfxState state) {}

  @override
  void drawImage(
    Uint8List imageBytes,
    int width,
    int height,
    Rect dstRect,
    PdfGfxState state, {
    PdfDict? imageDictionary,
  }) {}
}

Transform2D _asTransform(PdfMatrix matrix) => Transform2D(
      matrix.a,
      matrix.b,
      matrix.c,
      matrix.d,
      matrix.e,
      matrix.f,
    );

/// Maps raw PDF coordinates to visible page coordinates.
Transform2D pdfPageTransform(PdfPage page, Offset offset, double scale) {
  final Rect crop = page.cropBox;
  final int rotation = ((page.rotation % 360) + 360) % 360;
  return switch (rotation) {
    90 => Transform2D(
        0,
        scale,
        scale,
        0,
        offset.dx - crop.top * scale,
        offset.dy - crop.left * scale,
      ),
    180 => Transform2D(
        -scale,
        0,
        0,
        scale,
        offset.dx + crop.right * scale,
        offset.dy - crop.top * scale,
      ),
    270 => Transform2D(
        0,
        -scale,
        -scale,
        0,
        offset.dx + crop.bottom * scale,
        offset.dy + crop.right * scale,
      ),
    _ => Transform2D(
        scale,
        0,
        0,
        -scale,
        offset.dx - crop.left * scale,
        offset.dy + crop.bottom * scale,
      ),
  };
}
