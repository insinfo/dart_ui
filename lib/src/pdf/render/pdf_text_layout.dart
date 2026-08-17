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
      // A standalone whitespace showing operator has geometry but no visible
      // ink. Painting its often very narrow box creates the orphan vertical
      // blue bars seen in office-generated PDFs. Spaces between visible
      // fragments are still covered when the neighbouring boxes are merged.
      if (localStart >= localEnd || fragment.text.trim().isEmpty) continue;
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
    return _mergeSelectionRects(result);
  }

  /// Joins adjacent fragment boxes into the visual bands users expect.
  ///
  /// Many PDF producers emit one text-showing operation per character. The
  /// extractor must retain those fragments for precise hit testing, but
  /// painting every fragment independently creates a picket-fence of blue
  /// boxes and darker seams where translucent rectangles overlap. Fragments
  /// on the same visual line are therefore joined across normal word-space
  /// gaps. Large gaps remain separate so columns and unrelated blocks do not
  /// acquire highlight over their empty area.
  List<Rect> _mergeSelectionRects(List<Rect> rects) {
    if (rects.length < 2) return rects;
    final List<Rect> merged = <Rect>[rects.first];
    for (final Rect next in rects.skip(1)) {
      final Rect current = merged.last;
      final double overlap = math.min(current.bottom, next.bottom) -
          math.max(current.top, next.top);
      final double smallerHeight = math.min(current.height, next.height);
      final bool sameVisualLine =
          smallerHeight > 0 && overlap >= smallerHeight * 0.5;
      final double horizontalGap = next.left - current.right;
      final double normalSpace = math.max(1.0, smallerHeight * 0.75);
      if (sameVisualLine && horizontalGap <= normalSpace) {
        merged[merged.length - 1] = current.union(next);
      } else {
        merged.add(next);
      }
    }
    return merged;
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
  Transform2D _ctm = Transform2D.identity;

  PdfPageTextLayout get layout => _layoutInVisualReadingOrder();

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

    _fragments.add(PdfTextFragment(
      text: text,
      // Content-stream order is not reading order. Stable offsets are assigned
      // after every fragment has been grouped into visual lines.
      textStart: 0,
      bounds: bounds,
    ));
  }

  PdfPageTextLayout _layoutInVisualReadingOrder() {
    if (_fragments.isEmpty) {
      return PdfPageTextLayout(
        pageNumber: page.pageNumber,
        text: '',
        fragments: const <PdfTextFragment>[],
      );
    }

    // PDF producers commonly emit headings, paragraphs, decorations and
    // footers in independent content streams. Operator order therefore bears
    // little relation to reading order. Group by visual lines first, then sort
    // top-to-bottom and left-to-right so selection cannot skip a title merely
    // because that title was painted later in the stream.
    final List<PdfTextFragment> byVertical =
        List<PdfTextFragment>.of(_fragments)
          ..sort((PdfTextFragment a, PdfTextFragment b) {
            final int vertical =
                a.bounds.center.dy.compareTo(b.bounds.center.dy);
            return vertical != 0
                ? vertical
                : a.bounds.left.compareTo(b.bounds.left);
          });
    final List<_VisualTextLine> lines = <_VisualTextLine>[];
    for (final PdfTextFragment fragment in byVertical) {
      _VisualTextLine? closest;
      double closestDistance = double.infinity;
      for (final _VisualTextLine line in lines.reversed) {
        final double distance =
            (line.centerY - fragment.bounds.center.dy).abs();
        final double tolerance =
            math.max(line.height, fragment.bounds.height) * 0.55;
        final double overlap = math.min(line.bottom, fragment.bounds.bottom) -
            math.max(line.top, fragment.bounds.top);
        if ((overlap > 0 || distance <= tolerance) &&
            distance < closestDistance) {
          closest = line;
          closestDistance = distance;
        }
        if (line.bottom + tolerance < fragment.bounds.top) break;
      }
      if (closest == null) {
        closest = _VisualTextLine();
        lines.add(closest);
      }
      closest.add(fragment);
    }
    lines.sort((_VisualTextLine a, _VisualTextLine b) {
      final int vertical = a.centerY.compareTo(b.centerY);
      return vertical != 0 ? vertical : a.left.compareTo(b.left);
    });

    final StringBuffer text = StringBuffer();
    final List<PdfTextFragment> ordered = <PdfTextFragment>[];
    for (int lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      if (lineIndex > 0) text.write('\n');
      final List<PdfTextFragment> fragments = lines[lineIndex].fragments
        ..sort((PdfTextFragment a, PdfTextFragment b) =>
            a.bounds.left.compareTo(b.bounds.left));
      PdfTextFragment? previous;
      for (final PdfTextFragment fragment in fragments) {
        if (previous != null) {
          final double gap = fragment.bounds.left - previous.bounds.right;
          final double spaceThreshold =
              math.min(previous.bounds.height, fragment.bounds.height) * 0.12;
          if (gap > spaceThreshold &&
              !previous.text.endsWith(' ') &&
              !fragment.text.startsWith(' ')) {
            text.write(' ');
          }
        }
        final int start = text.length;
        text.write(fragment.text);
        ordered.add(PdfTextFragment(
          text: fragment.text,
          textStart: start,
          bounds: fragment.bounds,
        ));
        previous = fragment;
      }
    }
    return PdfPageTextLayout(
      pageNumber: page.pageNumber,
      text: text.toString(),
      fragments: List<PdfTextFragment>.unmodifiable(ordered),
    );
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

final class _VisualTextLine {
  final List<PdfTextFragment> fragments = <PdfTextFragment>[];
  double top = double.infinity;
  double bottom = double.negativeInfinity;
  double left = double.infinity;

  double get height => bottom - top;
  double get centerY => (top + bottom) / 2;

  void add(PdfTextFragment fragment) {
    fragments.add(fragment);
    top = math.min(top, fragment.bounds.top);
    bottom = math.max(bottom, fragment.bounds.bottom);
    left = math.min(left, fragment.bounds.left);
  }
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
