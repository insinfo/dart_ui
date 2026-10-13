/// File and folder icons drawn as vectors - the yellow two-tone folder, the
/// page with a folded corner and a mark in the colour of its kind - so they
/// stay sharp from 16 px in Details to 96 px in Extra large icons.
library;

import 'package:dart_ui/dart_ui.dart';

import '../engine/file_types.dart';

/// The icon of [kind] at [size].
class FileIcon extends StatelessWidget {
  const FileIcon(this.kind, {super.key, this.size = 16});

  final FileKind kind;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          size: Size(size, size),
          painter: (DisplayList list, Size box) =>
              paintFileIcon(list, kind, box.width),
        ),
      );
}

const Color _folderBack = Color(0xFFE0A100);
const Color _folderFront = Color(0xFFFFC83D);
const Color _folderEdge = Color(0xFFF7B500);
const Color _page = Color(0xFFFFFFFF);
const Color _pageEdge = Color(0xFF8A8A8A);
const Color _fold = Color(0xFFDADADA);

/// The colour that says what a file is.
Color kindColor(FileKind kind) => switch (kind) {
      FileKind.document => const Color(0xFF2B6CD8),
      FileKind.spreadsheet => const Color(0xFF1E8E4E),
      FileKind.presentation => const Color(0xFFD9541E),
      FileKind.pdf => const Color(0xFFD13438),
      FileKind.image => const Color(0xFF0E9AA7),
      FileKind.audio => const Color(0xFF8E44AD),
      FileKind.video => const Color(0xFF5B2C83),
      FileKind.archive => const Color(0xFFC08A1E),
      FileKind.code => const Color(0xFF3A6EA5),
      FileKind.executable => const Color(0xFF0067C0),
      FileKind.font => const Color(0xFF4A4A4A),
      FileKind.text => const Color(0xFF7A7A7A),
      FileKind.folder ||
      FileKind.drive ||
      FileKind.generic =>
        const Color(0xFF7A7A7A),
    };

void _fill(DisplayList list, double l, double t, double r, double b, Color c,
    {double radius = 0}) {
  final int paint = list.addPaint(colorArgb: c.value);
  if (radius <= 0) {
    list.drawRect(l, t, r, b, paint);
  } else {
    final PathBuilder path = PathBuilder()
      ..addRoundedRect(Rect.fromLTRB(l, t, r, b), radius, radius);
    list.drawPath(list.addPath(path.build()), paint);
  }
}

void _polygon(DisplayList list, List<Offset> points, Color c) {
  final PathBuilder path = PathBuilder()
    ..moveTo(points.first.dx, points.first.dy);
  for (final Offset p in points.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  path.close();
  list.drawPath(list.addPath(path.build()), list.addPaint(colorArgb: c.value));
}

/// Paints [kind]'s icon in a [s] x [s] box at the origin.
void paintFileIcon(DisplayList list, FileKind kind, double s) {
  switch (kind) {
    case FileKind.folder:
      _paintFolder(list, s);
    case FileKind.drive:
      _paintDrive(list, s);
    case FileKind.archive:
      _paintFolder(list, s, zip: true);
    default:
      _paintPage(list, kind, s);
  }
}

void _paintFolder(DisplayList list, double s, {bool zip = false}) {
  final double r = s * 0.07;
  // The back panel and its tab, darker, behind the front.
  _fill(list, s * .06, s * .16, s * .46, s * .34, _folderBack, radius: r);
  _fill(list, s * .06, s * .24, s * .94, s * .84, _folderBack, radius: r);
  _fill(list, s * .06, s * .34, s * .94, s * .86, _folderFront, radius: r);
  _fill(list, s * .06, s * .34, s * .94, s * .38, _folderEdge);
  if (zip) {
    // A zipped folder: the zipper down the middle.
    final double x = s * .5;
    for (double y = s * .38; y < s * .80; y += s * .08) {
      _fill(list, x - s * .05, y, x, y + s * .04, const Color(0xFF6B4E0E));
      _fill(list, x, y + s * .04, x + s * .05, y + s * .08,
          const Color(0xFF6B4E0E));
    }
  }
}

void _paintDrive(DisplayList list, double s) {
  _fill(list, s * .06, s * .30, s * .94, s * .78, const Color(0xFF6E6E6E),
      radius: s * .08);
  _fill(list, s * .10, s * .34, s * .90, s * .74, const Color(0xFFB8B8B8),
      radius: s * .06);
  _fill(list, s * .16, s * .58, s * .30, s * .66, const Color(0xFF39B54A),
      radius: s * .02);
}

void _paintPage(DisplayList list, FileKind kind, double s) {
  final double l = s * .18;
  final double t = s * .04;
  final double r = s * .82;
  final double b = s * .96;
  final double fold = s * .22;
  final double edge = s >= 24 ? s / 32 : 1;
  // The outline, then the page inset by it, then the folded corner.
  _polygon(
      list,
      <Offset>[
        Offset(l, t),
        Offset(r - fold, t),
        Offset(r, t + fold),
        Offset(r, b),
        Offset(l, b),
      ],
      _pageEdge);
  _polygon(
      list,
      <Offset>[
        Offset(l + edge, t + edge),
        Offset(r - fold, t + edge),
        Offset(r - edge, t + fold),
        Offset(r - edge, b - edge),
        Offset(l + edge, b - edge),
      ],
      _page);
  _polygon(
      list,
      <Offset>[
        Offset(r - fold, t),
        Offset(r - fold, t + fold),
        Offset(r, t + fold),
      ],
      _fold);

  final Color c = kindColor(kind);
  switch (kind) {
    case FileKind.text || FileKind.generic:
      if (kind == FileKind.text) {
        for (var i = 0; i < 4; i++) {
          final double y = s * (.42 + i * .12);
          _fill(list, s * .28, y, s * (i == 3 ? .56 : .72), y + s * .04, c);
        }
      }
    case FileKind.image:
      _fill(list, s * .26, s * .40, s * .74, s * .80, const Color(0xFFBFE9F2));
      _polygon(
          list,
          <Offset>[
            Offset(s * .26, s * .80),
            Offset(s * .44, s * .56),
            Offset(s * .58, s * .72),
            Offset(s * .64, s * .64),
            Offset(s * .74, s * .80),
          ],
          c);
      _fill(list, s * .58, s * .46, s * .66, s * .54, const Color(0xFFFFB900),
          radius: s * .04);
    case FileKind.audio:
      _fill(list, s * .36, s * .64, s * .50, s * .78, c, radius: s * .07);
      _fill(list, s * .46, s * .38, s * .51, s * .72, c);
      _fill(list, s * .46, s * .38, s * .64, s * .46, c);
    case FileKind.video:
      _fill(list, s * .26, s * .44, s * .74, s * .80, c, radius: s * .04);
      _polygon(
          list,
          <Offset>[
            Offset(s * .44, s * .52),
            Offset(s * .60, s * .62),
            Offset(s * .44, s * .72),
          ],
          _page);
    case FileKind.code:
      _polygon(
          list,
          <Offset>[
            Offset(s * .40, s * .50),
            Offset(s * .30, s * .62),
            Offset(s * .40, s * .74),
            Offset(s * .44, s * .70),
            Offset(s * .37, s * .62),
            Offset(s * .44, s * .54),
          ],
          c);
      _polygon(
          list,
          <Offset>[
            Offset(s * .60, s * .50),
            Offset(s * .70, s * .62),
            Offset(s * .60, s * .74),
            Offset(s * .56, s * .70),
            Offset(s * .63, s * .62),
            Offset(s * .56, s * .54),
          ],
          c);
    case FileKind.executable:
      _fill(list, s * .26, s * .44, s * .74, s * .80, c, radius: s * .03);
      _fill(list, s * .30, s * .52, s * .70, s * .76, _page);
    default:
      // A band of the kind's colour across the lower page: Word blue,
      // Excel green, PDF red.
      _fill(list, s * .12, s * .50, s * .62, s * .80, c, radius: s * .04);
      _fill(list, s * .20, s * .58, s * .54, s * .62, _page);
      _fill(list, s * .20, s * .66, s * .48, s * .70, _page);
  }
}
