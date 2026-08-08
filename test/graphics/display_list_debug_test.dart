import 'dart:typed_data';

import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_debug.dart';
import 'package:dart_ui/src/graphics/display_list_opcodes.dart';
import 'package:dart_ui/src/graphics/display_list_reader.dart';
import 'package:test/test.dart';

/// One list carrying every opcode exactly once, in the order the expansion
/// below expects.
DisplayList _everyOpcode() {
  final list = DisplayList();
  final int paint = list.addPaint(
    colorArgb: 0xFF336699,
    style: paintStyleStroke,
    strokeWidth: 2.0,
    blendMode: blendModePlus,
    antiAlias: false,
  );
  final int path = list.addPath(Object());
  final int image = list.addImage(Object());
  return list
    ..save()
    ..saveLayer(0.0, 1.0, 2.0, 3.0, paint)
    ..transform(1.0, 0.25, -0.25, 1.0, 10.0, 20.0)
    ..clipRect(4.0, 5.0, 6.0, 7.0, op: clipOpDifference)
    ..clipPath(path)
    ..drawRect(8.0, 9.0, 10.0, 11.0, paint)
    ..drawRRect(
      0.0,
      0.0,
      64.0,
      32.0,
      1.0,
      2.0,
      3.0,
      4.0,
      5.0,
      6.0,
      7.0,
      8.0,
      paint,
    )
    ..drawPath(path, paint)
    ..drawImage(image, 0.0, 0.0, 16.0, 16.0, 2.0, 4.0, 18.0, 20.0, paint)
    ..drawGlyphRun(
      5,
      paint,
      100.0,
      200.0,
      Int32List.fromList(<int>[11, 12]),
      Float32List.fromList(<double>[0.0, 0.0, 7.5, -1.5]),
      2,
    )
    ..restore();
}

void main() {
  test('every opcode expands into its readable command', () {
    final commands = expandDisplayList(_everyOpcode());
    expect(commands, hasLength(11));

    expect(commands[0], isA<SaveCommand>());

    final saveLayer = commands[1] as SaveLayerCommand;
    expect(saveLayer.left, 0.0);
    expect(saveLayer.top, 1.0);
    expect(saveLayer.right, 2.0);
    expect(saveLayer.bottom, 3.0);
    expect(saveLayer.paintId, 0);

    final transform = commands[2] as TransformCommand;
    expect(
      <double>[
        transform.a,
        transform.b,
        transform.c,
        transform.d,
        transform.tx,
        transform.ty,
      ],
      <double>[1.0, 0.25, -0.25, 1.0, 10.0, 20.0],
    );

    final clipRect = commands[3] as ClipRectCommand;
    expect(clipRect.left, 4.0);
    expect(clipRect.bottom, 7.0);
    expect(clipRect.op, clipOpDifference);

    final clipPath = commands[4] as ClipPathCommand;
    expect(clipPath.pathId, 0);
    expect(clipPath.op, clipOpIntersect);

    final drawRect = commands[5] as DrawRectCommand;
    expect(drawRect.left, 8.0);
    expect(drawRect.right, 10.0);
    expect(drawRect.paintId, 0);

    final drawRRect = commands[6] as DrawRRectCommand;
    expect(drawRRect.right, 64.0);
    expect(drawRRect.radii, <double>[1, 2, 3, 4, 5, 6, 7, 8]);

    final drawPath = commands[7] as DrawPathCommand;
    expect(drawPath.pathId, 0);
    expect(drawPath.paintId, 0);

    final drawImage = commands[8] as DrawImageCommand;
    expect(drawImage.imageId, 0);
    expect(drawImage.srcRight, 16.0);
    expect(drawImage.dstBottom, 20.0);

    final glyphRun = commands[9] as DrawGlyphRunCommand;
    expect(glyphRun.fontId, 5);
    expect(glyphRun.originX, 100.0);
    expect(glyphRun.originY, 200.0);
    expect(glyphRun.glyphCount, 2);
    expect(glyphRun.glyphIds, <int>[11, 12]);
    expect(glyphRun.offsets, <double>[0.0, 0.0, 7.5, -1.5]);

    expect(commands[10], isA<RestoreCommand>());
  });

  test('the expanded commands are immutable views of the buffer', () {
    final commands = expandDisplayList(_everyOpcode());
    final glyphRun = commands[9] as DrawGlyphRunCommand;
    expect(() => glyphRun.glyphIds.add(1), throwsUnsupportedError);
    expect(() => glyphRun.offsets.add(1.0), throwsUnsupportedError);
    final drawRRect = commands[6] as DrawRRectCommand;
    expect(() => drawRRect.radii[0] = 0.0, throwsUnsupportedError);
  });

  test('expansion rewinds a reader that was already partly consumed', () {
    final list = _everyOpcode();
    final reader = DisplayListReader(list)
      ..moveNext()
      ..moveNext()
      ..moveNext();
    expect(expandWithReader(reader), hasLength(11));
  });

  test('an empty list expands to nothing', () {
    expect(expandDisplayList(DisplayList()), isEmpty);
  });

  test('a list reset between frames expands to only the new frame', () {
    final list = DisplayList()..drawRect(0.0, 0.0, 1.0, 1.0, 0);
    expect(expandDisplayList(list), hasLength(1));
    list
      ..reset()
      ..save()
      ..restore();
    final commands = expandDisplayList(list);
    expect(commands, hasLength(2));
    expect(commands[0], isA<SaveCommand>());
  });

  test('the dump reports resources and one line per command', () {
    final dump = dumpDisplayList(_everyOpcode());
    final lines = dump.trimRight().split('\n');

    expect(lines.first, contains('11 commands'));
    expect(dump, contains('paints: 1, paths: 1, images: 1'));
    expect(dump, contains('color 0xff336699'));
    expect(dump, contains('strokeWidth 2.0'));
    for (var i = 0; i < 11; i++) {
      expect(dump, contains('\n$i: '));
    }
    expect(dump, contains('DrawGlyphRun(font: 5'));
    expect(dump, contains('ClipRect((4.0, 5.0, 6.0, 7.0), difference)'));
  });

  test('the debug expansion refuses a buffer the reader would refuse', () {
    final list = DisplayList()..save();
    list.opBuffer[0] = 0;
    expect(
      () => expandDisplayList(list),
      throwsA(isA<DisplayListFormatException>()),
    );
  });
}
