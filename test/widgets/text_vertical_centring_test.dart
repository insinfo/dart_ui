/// Text centred in a box looks centred: the ink of its capitals sits in the
/// middle of the box, not just its line box.
///
/// The two only agree when the face's ascent and descent are balanced around
/// the capitals and when the leading a line height adds is split evenly above
/// and below - Flutter's `TextLeadingDistribution.even`. Inter, the UI face,
/// is drawn that way (ascent 1984, descent 494, cap height 1490 in a 2048 em:
/// the capitals' middle is the line box's middle to a hundredth of a pixel),
/// so a label in a 32 px row whose letters land a few pixels high is a layout
/// bug in the row, never a property of the text. These tests pin that down
/// from the widget to the rasterised pixels, for every path a label can take.
library;

import 'package:dart_ui/dart_ui.dart' hide GlyphCache;
import 'package:dart_ui/src/rendering/text/glyph_cache.dart';
import 'package:test/test.dart';

/// [child] rasterised in black on white, in a [width] x [height] surface.
Framebuffer _render(Widget child, double width, double height) {
  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints: BoxConstraints.tight(Size(width, height)),
  );
  final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
    ..updateRoot(Directionality(
      textDirection: TextDirection.leftToRight,
      child: ColoredBox(color: const Color(0xFFFFFFFF), child: child),
    ));
  addTearDown(owner.dispose);
  owner.buildScope();
  pipeline.flushLayout();
  final DisplayList list = DisplayList();
  pipeline.flushPaint(list);
  final Framebuffer surface = Framebuffer.allocate(
    width: width.round(),
    height: height.round(),
  )..clear(255, 255, 255, 255);
  rasterizeDisplayList(list, surface, glyphCache: GlyphCache());
  return surface;
}

/// The vertical centre of the ink, each row weighted by how dark it is - a
/// sub-pixel measure that antialiasing cannot fool, since a row half covered
/// counts half.
double _inkCentreY(Framebuffer surface) {
  double sum = 0;
  double weight = 0;
  for (int y = 0; y < surface.height; y++) {
    for (int x = 0; x < surface.width; x++) {
      final int offset = surface.offsetOf(x, y);
      final double ink = (255 - surface.pixels[offset + 1]) / 255;
      sum += ink * (y + .5);
      weight += ink;
    }
  }
  expect(weight, greaterThan(0), reason: 'something was drawn');
  return sum / weight;
}

void main() {
  setUpAll(FrameworkFonts.install);
  tearDownAll(FontRegistry.instance.reset);

  // `I` is a bare stem from the baseline to the cap height in Inter, so its
  // ink centre is exactly the capitals' centre.
  const String capitals = 'III';
  const Color ink = Color(0xFF000000);

  for (final double fontSize in <double>[12, 13, 14, 16, 20]) {
    for (final double box in <double>[24, 28, 32, 36, 41]) {
      // A box shorter than the 1.45 line box cuts it at the bottom - the
      // line starts at the box's top, as in Flutter and in CSS - so those
      // lines are not centred, by design, and not measured here.
      final bool roomy = fontSize * (1984 + 494) / 2048 * 1.45 <= box;
      group('$fontSize px text in a $box px box', () {
        test('a label', () {
          final Framebuffer surface = _render(
            Center(
              child: Text(capitals,
                  style: TextStyle(fontSize: fontSize), color: ink),
            ),
            120,
            box,
          );
          expect(_inkCentreY(surface), closeTo(box / 2, .5));
        });

        if (roomy) {
          test('a label cut with an ellipsis, laid out as a paragraph', () {
            final Framebuffer surface = _render(
              Center(
                child: Text(capitals,
                    style: TextStyle(fontSize: fontSize, height: 1.45),
                    color: ink,
                    maxLines: 1,
                    ellipsis: '…'),
              ),
              120,
              box,
            );
            expect(_inkCentreY(surface), closeTo(box / 2, .5));
          });

          test('wrapped text with a 1.45 line height', () {
            final Framebuffer surface = _render(
              Center(
                child: Text(capitals,
                    style: TextStyle(fontSize: fontSize, height: 1.45),
                    color: ink,
                    softWrap: true),
              ),
              120,
              box,
            );
            expect(_inkCentreY(surface), closeTo(box / 2, .5));
          });

          test('in a row that centres its children', () {
            final Framebuffer surface = _render(
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  const SizedBox(width: 16, height: 16),
                  Expanded(
                    child: Text(capitals,
                        style: TextStyle(fontSize: fontSize, height: 1.45),
                        color: ink,
                        maxLines: 1,
                        ellipsis: '…'),
                  ),
                ],
              ),
              120,
              box,
            );
            expect(_inkCentreY(surface), closeTo(box / 2, .5));
          });
        }
      });
    }
  }
}
