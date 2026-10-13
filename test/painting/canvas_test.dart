/// The Canvas/Paint facade: what each call writes into the display list, and
/// what the CPU renderer draws from it.
library;

import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

List<DisplayListCommand> _record(void Function(Canvas canvas) draw) {
  final DisplayList list = DisplayList();
  final Canvas canvas = Canvas.forDisplayList(list);
  draw(canvas);
  canvas.close();
  return expandDisplayList(list);
}

Future<Framebuffer> _render(void Function(Canvas canvas) draw,
    {int size = 40}) {
  final DisplayList list = DisplayList();
  final Canvas canvas = Canvas.forDisplayList(list);
  draw(canvas);
  canvas.close();
  return renderList(list, size, size);
}

const Color _red = Color(0xFFFF0000);
const (int, int, int, int) _redPixel = (0xFF, 0, 0, 0xFF);

void main() {
  group('commands', () {
    test('a canvas that only draws writes only draws', () {
      final List<DisplayListCommand> c = _record((Canvas canvas) {
        canvas.drawRect(const Rect.fromLTRB(0, 0, 10, 10), Paint());
      });
      expect(c, hasLength(1));
      expect(c.single, isA<DrawRectCommand>());
    });

    test('state changes are scoped and restored on close', () {
      final List<DisplayListCommand> c = _record((Canvas canvas) {
        canvas.translate(5, 5);
        canvas.save();
        canvas.scale(2);
        // No matching restore: close() must balance it.
      });
      expect(c.whereType<SaveCommand>().length,
          c.whereType<RestoreCommand>().length);
      expect(c.first, isA<SaveCommand>());
      expect(c.last, isA<RestoreCommand>());
    });

    test('save count, restoreToCount and extra restores', () {
      final DisplayList list = DisplayList();
      final Canvas canvas = Canvas.forDisplayList(list);
      expect(canvas.getSaveCount(), 1);
      canvas
        ..save()
        ..save();
      expect(canvas.getSaveCount(), 3);
      canvas.restoreToCount(2);
      expect(canvas.getSaveCount(), 2);
      canvas
        ..restore()
        ..restore()
        ..restore();
      expect(canvas.getSaveCount(), 1, reason: 'extra restores are ignored');
      canvas.close();
      expect(() => canvas.save(), throwsStateError);
    });

    test('getTransform reports Matrix4 storage', () {
      final DisplayList list = DisplayList();
      final Canvas canvas = Canvas.forDisplayList(list)
        ..translate(10, 20)
        ..scale(2, 3);
      final List<double> m = canvas.getTransform();
      expect(m[0], 2);
      expect(m[5], 3);
      expect(m[12], 10);
      expect(m[13], 20);
      canvas.close();
    });

    test('an axis-aligned clipRect is a native clip; a rotated one a mask', () {
      final List<DisplayListCommand> straight = _record((Canvas canvas) {
        canvas.clipRect(const Rect.fromLTRB(0, 0, 10, 10));
      });
      expect(straight.whereType<ClipRectCommand>(), hasLength(1));
      expect(straight.whereType<SaveLayerCommand>(), isEmpty);

      final List<DisplayListCommand> turned = _record((Canvas canvas) {
        canvas
          ..rotate(0.3)
          ..clipRect(const Rect.fromLTRB(0, 0, 10, 10));
      });
      expect(turned.whereType<ClipRectCommand>(), isEmpty);
      expect(turned.whereType<SaveLayerCommand>(), hasLength(1));
    });

    test('clipRRect and clipPath never emit opClipPath', () {
      final List<DisplayListCommand> c = _record((Canvas canvas) {
        canvas
          ..clipRRect(RRect.fromLTRBR(0, 0, 20, 20, const Radius.circular(5)))
          ..clipPath(Path()..addOval(const Rect.fromLTRB(0, 0, 20, 20)))
          ..drawPaint(Paint());
      });
      expect(c.whereType<ClipPathCommand>(), isEmpty);
      expect(
          c.whereType<SaveCommand>().length +
              c.whereType<SaveLayerCommand>().length,
          c.whereType<RestoreCommand>().length);
    });

    test('paint translation: style, hairline, blend, cap and join', () {
      final DisplayList list = DisplayList();
      final Canvas canvas = Canvas.forDisplayList(list);
      final int id = canvas.paintId(Paint()
        ..color = _red
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.bevel
        ..blendMode = BlendMode.plus);
      expect(list.paintColor(id), 0xFFFF0000);
      expect(list.paintStyle(id), paintStyleStroke);
      expect(list.paintStrokeWidth(id), 1.0, reason: 'hairline');
      expect(list.paintBlendMode(id), blendModePlus);
      expect(list.paintStrokeCap(id), StrokeCap.round);
      expect(list.paintStrokeJoin(id), StrokeJoin.bevel);
      final int multiply =
          canvas.paintId(Paint()..blendMode = BlendMode.multiply);
      expect(list.paintBlendMode(multiply), blendModeSrcOver,
          reason: 'unsupported modes are drawn as srcOver');
      expect(BlendMode.multiply.isSupported, isFalse);
      expect(BlendMode.clear.isSupported, isTrue);
      canvas.close();
    });

    test('drawPath copies the path, so later edits change nothing', () {
      final DisplayList list = DisplayList();
      final Canvas canvas = Canvas.forDisplayList(list);
      final Path p = Path()..addRect(const Rect.fromLTRB(0, 0, 5, 5));
      canvas.drawPath(p, Paint());
      p.lineTo(100, 100);
      canvas.close();
      final DrawPathCommand draw =
          expandDisplayList(list).whereType<DrawPathCommand>().single;
      expect((list.pathAt(draw.pathId) as Path).getBounds(),
          const Rect.fromLTRB(0, 0, 5, 5));
    });

    test('a picture replays into another canvas', () {
      final PictureRecorder recorder = PictureRecorder();
      final Canvas c = Canvas(recorder);
      c.drawCircle(const Offset(5, 5), 5, Paint()..color = _red);
      expect(recorder.isRecording, isTrue);
      final Picture picture = recorder.endRecording();
      expect(recorder.isRecording, isFalse);
      final List<DisplayListCommand> out = _record((Canvas canvas) {
        canvas.drawPicture(picture);
      });
      expect(out.whereType<DrawRRectCommand>(), hasLength(1));
    });
  });

  group('pixels', () {
    test('drawCircle, drawRect, drawLine', () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas
          ..drawCircle(const Offset(10, 10), 8, Paint()..color = _red)
          ..drawRect(const Rect.fromLTRB(20, 0, 40, 20),
              Paint()..color = const Color(0xFF00FF00))
          ..drawLine(
              const Offset(0, 30),
              const Offset(40, 30),
              Paint()
                ..color = const Color(0xFF0000FF)
                ..strokeWidth = 4);
      });
      expect(pixelAt(fb, 10, 10), _redPixel);
      expect(pixelAt(fb, 1, 1), kBackgroundPixel, reason: 'outside the disc');
      expect(pixelAt(fb, 30, 10), (0, 0xFF, 0, 0xFF));
      expect(pixelAt(fb, 20, 30), (0, 0, 0xFF, 0xFF));
      expect(pixelAt(fb, 20, 34), kBackgroundPixel);
    });

    test('translate and rotate move what follows', () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas
          ..translate(20, 20)
          ..rotate(math.pi / 4)
          ..drawRect(
              const Rect.fromLTRB(-2, -14, 2, 14), Paint()..color = _red);
      });
      // A bar rotated 45 degrees runs from top-right to bottom-left.
      expect(pixelAt(fb, 27, 13), _redPixel);
      expect(pixelAt(fb, 13, 27), _redPixel);
      expect(pixelAt(fb, 27, 27), kBackgroundPixel);
    });

    test('clipRRect cuts the corners', () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas
          ..clipRRect(RRect.fromLTRBR(0, 0, 40, 40, const Radius.circular(16)))
          ..drawPaint(Paint()..color = _red);
      });
      expect(pixelAt(fb, 20, 20), _redPixel);
      expect(pixelAt(fb, 1, 1), kBackgroundPixel);
      expect(pixelAt(fb, 38, 38), kBackgroundPixel);
      expect(pixelAt(fb, 20, 1), _redPixel);
    });

    test('a self-crossing non-zero star clips its middle in', () async {
      final Path star = Path();
      for (var i = 0; i < 5; i++) {
        final double a = -math.pi / 2 + i * 4 * math.pi / 5;
        final double x = 20 + 19 * math.cos(a), y = 21 + 19 * math.sin(a);
        if (i == 0) {
          star.moveTo(x, y);
        } else {
          star.lineTo(x, y);
        }
      }
      star.close();
      final Framebuffer nonZero = await _render((Canvas canvas) {
        canvas
          ..clipPath(star)
          ..drawPaint(Paint()..color = _red);
      });
      expect(pixelAt(nonZero, 20, 21), _redPixel,
          reason: 'winding 2 is inside under non-zero');
      expect(pixelAt(nonZero, 2, 38), kBackgroundPixel);

      star.fillType = PathFillType.evenOdd;
      final Framebuffer evenOdd = await _render((Canvas canvas) {
        canvas
          ..clipPath(star)
          ..drawPaint(Paint()..color = _red);
      });
      expect(pixelAt(evenOdd, 20, 21), kBackgroundPixel,
          reason: 'winding 2 is a hole under even-odd');
      expect(pixelAt(evenOdd, 20, 6), _redPixel, reason: 'a point of the star');
    });

    test('clipRect difference keeps the outside', () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas
          ..clipRect(const Rect.fromLTRB(10, 10, 30, 30),
              clipOp: ClipOp.difference)
          ..drawPaint(Paint()..color = _red);
      });
      expect(pixelAt(fb, 20, 20), kBackgroundPixel);
      expect(pixelAt(fb, 5, 5), _redPixel);
    });

    test('a clip ends at its restore', () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas
          ..save()
          ..clipPath(Path()..addOval(const Rect.fromLTRB(0, 0, 20, 20)))
          ..drawPaint(Paint()..color = _red)
          ..restore()
          ..drawRect(const Rect.fromLTRB(30, 30, 40, 40),
              Paint()..color = const Color(0xFF00FF00));
      });
      expect(pixelAt(fb, 10, 10), _redPixel);
      expect(pixelAt(fb, 25, 25), kBackgroundPixel);
      expect(pixelAt(fb, 35, 35), (0, 0xFF, 0, 0xFF));
    });

    test('saveLayer with BlendMode.clear erases only the layer', () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas
          ..saveLayer(null, Paint())
          ..drawRect(const Rect.fromLTRB(0, 0, 40, 40), Paint()..color = _red)
          ..drawCircle(
              const Offset(20, 20), 10, Paint()..blendMode = BlendMode.clear)
          ..restore();
      });
      expect(pixelAt(fb, 20, 20), kBackgroundPixel, reason: 'a hole');
      expect(pixelAt(fb, 2, 2), _redPixel);
    });

    test('a linear gradient shader, with the paint alpha as opacity', () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas.drawRect(
            const Rect.fromLTRB(0, 0, 40, 40),
            Paint()
              ..shader = Gradient.linear(const Offset(0, 0),
                  const Offset(40, 0), const <Color>[_red, Color(0xFF0000FF)]));
      });
      final (int r0, _, int b0, _) = pixelAt(fb, 1, 20);
      final (int r1, _, int b1, _) = pixelAt(fb, 38, 20);
      expect(r0, greaterThan(200));
      expect(b0, lessThan(30));
      expect(b1, greaterThan(200));
      expect(r1, lessThan(30));
    });

    test('a sweep shader goes around its centre, clipped to the shape',
        () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas.drawCircle(
            const Offset(20, 20),
            18,
            Paint()
              ..shader = SweepShader(
                center: const Offset(20, 20),
                startAngle: 0,
                endAngle: 2 * math.pi,
                colors: const <Color>[_red, Color(0xFF0000FF)],
              ));
      });
      final (int rRight, _, int bRight, _) = pixelAt(fb, 30, 21);
      final (int rTop, _, int bTop, _) = pixelAt(fb, 21, 4);
      expect(rRight, greaterThan(bRight), reason: 'near angle 0: red');
      expect(bTop, greaterThan(rTop), reason: 'near 3/4 turn: mostly blue');
      expect(pixelAt(fb, 1, 1), kBackgroundPixel, reason: 'outside the disc');
    });

    test('stroked rounded rectangle and drawDRRect', () async {
      final Framebuffer fb = await _render((Canvas canvas) {
        canvas.drawDRRect(
            RRect.fromLTRBR(0, 0, 40, 40, const Radius.circular(8)),
            RRect.fromLTRBR(6, 6, 34, 34, const Radius.circular(2)),
            Paint()..color = _red);
      });
      expect(pixelAt(fb, 20, 2), _redPixel);
      expect(pixelAt(fb, 20, 20), kBackgroundPixel, reason: 'the hole');
    });
  });
}
