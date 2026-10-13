/// A `Text` with an emoji in it draws the emoji, from the emoji face.
///
/// The single-line path shapes one run in one face, and that path is what
/// drew `.notdef` boxes for "Hello 😀". The label now routes through the
/// paragraph engine whenever its face lacks a character, and the paragraph
/// falls back through `FontRegistry.instance`. The emoji face here is built in
/// memory (`color_font_fixtures.dart`) and registered under this platform's
/// emoji family name, so the test is the same on every machine.
library;

import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import '../text/color_font_fixtures.dart';

/// DejaVu Sans with a red 16x16 picture for 😀 in a 16 ppem `sbix` strike.
Typeface _colourFace() {
  final Uint8List dejaVu = fixtureFontBytes('DejaVuSans.ttf');
  final Typeface plain = Typeface.parse(dejaVu);
  return Typeface.parse(withTables(dejaVu, <String, Uint8List>{
    'sbix': sbixTable(glyphCount: plain.glyphCount, strikes: {
      16: <int, SbixRecord>{
        plain.glyphForCodePoint(0x1F600):
            SbixRecord('png ', solidPng(16, 16, 0xFFFF0000)),
      },
    }),
  }));
}

/// The frame [text] draws: how many images, and every glyph id.
({int images, List<int> glyphs}) _draw(Text text) {
  final BuildOwner owner = BuildOwner(
    pipelineOwner: PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(300, 60)),
    ),
  );
  owner.updateRoot(Directionality(
    textDirection: TextDirection.leftToRight,
    child: Align(alignment: Alignment.topLeft, child: text),
  ));
  owner.buildScope();
  final DisplayList list = DisplayList();
  owner.pipelineOwner.drawFrame(list);
  int images = 0;
  final List<int> glyphs = <int>[];
  final DisplayListReader reader = DisplayListReader(list);
  while (reader.moveNext()) {
    if (reader.opcode == opDrawImage) images++;
    if (reader.opcode == opDrawGlyphRun) {
      for (int i = 0; i < reader.glyphCount; i++) {
        glyphs.add(reader.glyphIdAt(i));
      }
    }
  }
  return (images: images, glyphs: glyphs);
}

void main() {
  setUp(() {
    FontRegistry.instance
      ..reset()
      ..useTypeface(
        Typeface.parse(fixtureFontBytes('Roboto-Regular.ttf')),
        source: 'roboto',
      )
      ..registerTypeface(
        _colourFace(),
        family: FontRegistry.emojiFamilies().first,
        source: 'colour emoji',
      );
  });
  tearDown(FontRegistry.instance.reset);

  test('an emoji the face lacks is drawn as a picture, with no box', () {
    final ({int images, List<int> glyphs}) frame =
        _draw(const Text('a\u{1F600}b', fontSize: 16));
    expect(frame.images, 1);
    expect(frame.glyphs, isNot(contains(0)));
    expect(frame.glyphs, hasLength(2), reason: 'a and b, from Roboto');
  });

  test('a joiner or selector the face lacks draws nothing, not a box', () {
    // No fallback needed - Roboto has both letters - so this is the
    // single-line path, and the shaper hides the controls on its own.
    final ({int images, List<int> glyphs}) frame =
        _draw(const Text('a\u200Db\uFE0Fc', fontSize: 16));
    expect(frame.images, 0);
    expect(frame.glyphs, isNot(contains(0)));
  });

  test('the label keeps the height of its own face', () {
    RenderText laid(String text) {
      final BuildOwner owner = BuildOwner(
        pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(300, 60)),
        ),
      );
      owner.updateRoot(Directionality(
        textDirection: TextDirection.leftToRight,
        child: Align(
          alignment: Alignment.topLeft,
          child: Text(text, fontSize: 16),
        ),
      ));
      owner.buildScope();
      owner.pipelineOwner.drawFrame(DisplayList());
      RenderText? found;
      void walk(RenderBox node) {
        if (node is RenderText) found = node;
        node.visitChildren(walk);
      }

      walk(owner.renderRoot!);
      return found!;
    }

    final RenderText plain = laid('ab');
    final RenderText emoji = laid('a\u{1F600}b');
    expect(emoji.size.height, plain.size.height);
    expect(emoji.size.width, greaterThan(plain.size.width));
  });
}
