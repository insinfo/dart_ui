/// Renders the Flutter-shaped painting API headless - decorations with
/// radii, borders and shadows, `ShapeDecoration`s, a `CustomPainter` and the
/// `ClipOval`/`ClipPath`/`ClipRRect` clips - to one PNG per theme.
///
/// ```
/// dart run tool/painting_shot.dart build/painting
/// ```
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';

Future<void> main(List<String> args) async {
  final String dir = args.isNotEmpty ? args.first : 'build/painting';
  Directory(dir).createSync(recursive: true);
  const int width = 760, height = 560;
  for (final bool dark in <bool>[false, true]) {
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints:
            BoxConstraints.tight(Size(width.toDouble(), height.toDouble())),
      ),
    );
    owner.updateRoot(paintingDemoPage(dark: dark));
    owner.buildScope();
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);
    final RenderDevice device = await const CpuRendererBackend().createDevice();
    final MemoryRenderTarget target = device.createTarget(
      const MemorySurfaceDescriptor(pixelWidth: width, pixelHeight: height),
    ) as MemoryRenderTarget;
    await target.renderDisplayList(list,
        clearColor: dark ? 0xFF111827 : 0xFFF3F4F6);
    final String file = '$dir/p0_paint_${dark ? 'dark' : 'light'}.png';
    File(file).writeAsBytesSync(
        HeadlessScreenshot.fromFramebuffer(target.framebuffer).toPng());
    stdout.writeln('wrote $file');
  }
}

/// The demo page, for a probe that renders it on another backend.
Widget paintingDemoPage({required bool dark}) => _Page(dark: dark);

final class _Page extends StatelessWidget {
  const _Page({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final Color card = dark ? const Color(0xFF1F2937) : const Color(0xFFFFFFFF);
    final Color line = dark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);
    final Color shadow =
        dark ? const Color(0xAA000000) : const Color(0x55000000);
    Widget cell(Widget child) => Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(width: 140, height: 140, child: child),
        );
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Wrap(
        children: <Widget>[
          // 1. Rounded card: Flutter's borderRadius, Border.all, a soft shadow.
          cell(DecoratedBox(
            decoration: BoxDecoration(
              color: card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: line, width: 2),
              boxShadow: <BoxShadow>[
                BoxShadow(
                    color: shadow, blurRadius: 14, offset: const Offset(0, 6)),
              ],
            ),
          )),
          // 2. Non-uniform sides, square corners.
          cell(DecoratedBox(
            decoration: BoxDecoration(
              color: card,
              border: const Border(
                top: BorderSide(color: Color(0xFFEF4444), width: 8),
                left: BorderSide(color: Color(0xFF22C55E), width: 4),
                right: BorderSide(color: Color(0xFF3B82F6), width: 2),
                bottom: BorderSide(color: Color(0xFFF59E0B), width: 12),
              ),
            ),
          )),
          // 3. A circle with a border and a spread shadow.
          cell(DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFF472B6),
              shape: BoxShape.circle,
              border: Border.all(color: card, width: 4),
              boxShadow: <BoxShadow>[
                BoxShadow(color: shadow, blurRadius: 8, spreadRadius: 2),
              ],
            ),
          )),
          // 4. Only the top corners rounded; a sweep gradient fill.
          cell(const DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.vertical(top: Radius.circular(40)),
              gradient: SweepGradient(colors: <Color>[
                Color(0xFFEF4444),
                Color(0xFFF59E0B),
                Color(0xFF22C55E),
                Color(0xFF3B82F6),
                Color(0xFFA855F7),
                Color(0xFFEF4444),
              ]),
            ),
          )),
          // 5. A stadium ShapeDecoration with an outline and a shadow.
          cell(Center(
            child: SizedBox(
              width: 140,
              height: 56,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: line,
                  shape: StadiumBorder(side: BorderSide(color: card, width: 3)),
                  shadows: <BoxShadow>[
                    BoxShadow(
                        color: shadow,
                        blurRadius: 10,
                        offset: const Offset(0, 4)),
                  ],
                ),
              ),
            ),
          )),
          // 6. A CustomPainter: lines, an arc, a path, circles, a gradient.
          cell(CustomPaint(painter: _Chart(dark: dark))),
          // 7. ClipOval over a striped painter.
          cell(const ClipOval(child: CustomPaint(painter: _Stripes()))),
          // 8. ClipPath with a star clipper.
          cell(ClipPath(
            clipper: const _StarClipper(),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: line,
                border: Border.all(color: const Color(0xFFF59E0B), width: 10),
              ),
            ),
          )),
          // 9. ClipRRect with per-corner radii over stripes.
          cell(const ClipRRect(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(48),
              bottomRight: Radius.circular(24),
            ),
            child: CustomPaint(painter: _Stripes()),
          )),
          // 10. ClipPath.shape with a CircleBorder around a card.
          cell(ClipPath.shape(
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.elliptical(60, 24))),
            child: const CustomPaint(painter: _Stripes()),
          )),
        ],
      ),
    );
  }
}

final class _Chart extends CustomPainter {
  const _Chart({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect box = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(10)),
        Paint()
          ..shader = Gradient.linear(
            Offset.zero,
            Offset(size.width, size.height),
            <Color>[
              dark ? const Color(0xFF0F172A) : const Color(0xFFE0F2FE),
              dark ? const Color(0xFF1E3A8A) : const Color(0xFFBAE6FD),
            ],
          ));
    final Paint grid = Paint()
      ..color = dark ? const Color(0x33FFFFFF) : const Color(0x22000000)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final double y = size.height * i / 4;
      canvas.drawLine(Offset(8, y), Offset(size.width - 8, y), grid);
    }
    final Path curve = Path()..moveTo(10, size.height - 20);
    for (var i = 1; i <= 12; i++) {
      final double x = 10 + (size.width - 20) * i / 12;
      final double y = size.height / 2 + math.sin(i / 2) * size.height * 0.3;
      curve.lineTo(x, y);
    }
    canvas.drawPath(
        curve,
        Paint()
          ..color = const Color(0xFFF97316)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round);
    canvas.drawArc(Rect.fromLTWH(size.width - 56, 8, 48, 48), -math.pi / 2,
        math.pi * 1.4, true, Paint()..color = const Color(0xCC22C55E));
    canvas.save();
    canvas.translate(28, 30);
    canvas.rotate(math.pi / 8);
    canvas.drawRect(const Rect.fromLTWH(-12, -12, 24, 24),
        Paint()..color = const Color(0xFFA855F7));
    canvas.restore();
    canvas.drawCircle(Offset(size.width / 2, size.height - 18), 8,
        Paint()..color = const Color(0xFFEF4444));
    canvas.drawCircle(
        Offset(size.width / 2, size.height - 18),
        12,
        Paint()
          ..color = const Color(0xFFEF4444)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_Chart oldDelegate) => oldDelegate.dark != dark;
}

final class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF0EA5E9));
    final Paint stripe = Paint()
      ..color = const Color(0xFFFDE047)
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke;
    for (double x = -size.height; x < size.width; x += 24) {
      canvas.drawLine(
          Offset(x, size.height), Offset(x + size.height, 0), stripe);
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}

final class _StarClipper extends CustomClipper<Path> {
  const _StarClipper();

  @override
  Path getClip(Size size) {
    final Path star = Path();
    final Offset c = Offset(size.width / 2, size.height / 2);
    final double r = size.shortestSideHalf;
    for (var i = 0; i < 5; i++) {
      final double a = -math.pi / 2 + i * 4 * math.pi / 5;
      final Offset p = c + Offset(math.cos(a), math.sin(a)) * r;
      if (i == 0) {
        star.moveTo(p.dx, p.dy);
      } else {
        star.lineTo(p.dx, p.dy);
      }
    }
    star.close();
    return star;
  }

  @override
  bool shouldReclip(_StarClipper oldClipper) => false;
}

extension on Size {
  double get shortestSideHalf => math.min(width, height) / 2;
}
