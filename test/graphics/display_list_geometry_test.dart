import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

/// These tests exist for one reason: the encoder stores geometry positionally
/// as bare floats, and this extension is the only place that decides which
/// position means what. A swapped pair here is invisible in every other test
/// in the package - the display list would round-trip perfectly and only look
/// wrong on screen.
void main() {
  group('transform2D', () {
    test('writes the components in the order Transform2D defines', () {
      const value = Transform2D(1, 2, 3, 4, 5, 6);
      final list = DisplayList()..transform2D(value);

      final expanded = expandDisplayList(list);
      final command = expanded.single as TransformCommand;

      expect(command.a, value.a);
      expect(command.b, value.b);
      expect(command.c, value.c);
      expect(command.d, value.d);
      expect(command.tx, value.tx);
      expect(command.ty, value.ty);
    });

    test('a rotation survives the round trip as the same mapping', () {
      // Distinguishing b from c needs a transform where they differ in sign,
      // which is exactly what rotation gives. A pure scale would pass even
      // with the two swapped.
      final rotation = Transform2D.rotation(0.7);
      final list = DisplayList()..transform2D(rotation);
      final command = expandDisplayList(list).single as TransformCommand;

      final decoded = Transform2D(
        command.a,
        command.b,
        command.c,
        command.d,
        command.tx,
        command.ty,
      );
      const probe = Offset(3, -7);

      final direct = rotation.transformOffset(probe);
      final viaList = decoded.transformOffset(probe);

      // Float32 narrowing in the encoder, so this is close-to, not equal.
      expect(viaList.dx, closeTo(direct.dx, 1e-5));
      expect(viaList.dy, closeTo(direct.dy, 1e-5));
    });
  });

  group('rect-taking helpers', () {
    test('drawRectangle maps a Rect onto the four edge slots', () {
      final list = DisplayList()
        ..drawRectangle(const Rect.fromLTRB(10, 20, 30, 40), 0);

      final command = expandDisplayList(list).single as DrawRectCommand;

      expect(command.left, 10);
      expect(command.top, 20);
      expect(command.right, 30);
      expect(command.bottom, 40);
    });

    test('clipRectangle carries the clip operation through', () {
      final list = DisplayList()
        ..clipRectangle(
          const Rect.fromLTRB(1, 2, 3, 4),
          op: clipOpDifference,
        );

      final command = expandDisplayList(list).single as ClipRectCommand;

      expect(command.op, clipOpDifference);
      expect(command.left, 1);
      expect(command.bottom, 4);
    });

    test('drawImageRects keeps source and destination apart', () {
      final list = DisplayList();
      final imageId = list.addImage(const _Image('atlas'));
      list.drawImageRects(
        imageId,
        const Rect.fromLTRB(0, 0, 16, 16),
        const Rect.fromLTRB(100, 200, 132, 232),
        0,
      );

      final command = expandDisplayList(list).single as DrawImageCommand;

      // Swapping the two rects is the mistake this asserts against: both are
      // squares, so only the coordinates tell them apart.
      expect(command.srcRight, 16);
      expect(command.dstLeft, 100);
      expect(command.dstRight, 132);
    });
  });

  group('drawGlyphRunAt', () {
    test('places the run origin where the Offset says', () {
      final list = DisplayList();
      final glyphIds = Int32List.fromList(<int>[7, 8]);
      final offsets = Float32List.fromList(<double>[0, 0, 9, 0]);

      list.drawGlyphRunAt(
        0,
        0,
        const Offset(12.5, -3.5),
        glyphIds,
        offsets,
        2,
      );

      final command = expandDisplayList(list).single as DrawGlyphRunCommand;

      expect(command.originX, 12.5);
      expect(command.originY, -3.5);
      expect(command.glyphCount, 2);
    });
  });
}

/// A value-typed stand-in, so image interning is exercised by equality rather
/// than by identity.
final class _Image {
  const _Image(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is _Image && other.name == name;

  @override
  int get hashCode => name.hashCode;
}
