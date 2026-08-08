/// Readable expansion of an encoded display list - the debug mode required by
/// section 9.6.
///
/// **Everything in this file allocates.** One object per command, plus lists
/// for the variable-length operands, plus strings for the dump. That is the
/// point: it is the mirror image of the encoder, kept honest by round-trip
/// tests, and it exists for tests, goldens and bug reports. It must never be
/// called from the frame pipeline - `DisplayList` and `DisplayListReader` are
/// the allocation-free path, and section 6.5 applies to them, not here.
library;

import 'display_list.dart';
import 'display_list_opcodes.dart';
import 'display_list_reader.dart';

/// One decoded command. Sealed so that a `switch` over the hierarchy is
/// checked by the compiler when an opcode is added.
sealed class DisplayListCommand {
  const DisplayListCommand();
}

final class SaveCommand extends DisplayListCommand {
  const SaveCommand();

  @override
  String toString() => 'Save()';
}

final class SaveLayerCommand extends DisplayListCommand {
  const SaveLayerCommand({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.paintId,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final int paintId;

  @override
  String toString() =>
      'SaveLayer(($left, $top, $right, $bottom), paint: $paintId)';
}

final class RestoreCommand extends DisplayListCommand {
  const RestoreCommand();

  @override
  String toString() => 'Restore()';
}

final class TransformCommand extends DisplayListCommand {
  const TransformCommand({
    required this.a,
    required this.b,
    required this.c,
    required this.d,
    required this.tx,
    required this.ty,
  });

  final double a;
  final double b;
  final double c;
  final double d;
  final double tx;
  final double ty;

  @override
  String toString() => 'Transform([$a, $b, $c, $d, $tx, $ty])';
}

final class ClipRectCommand extends DisplayListCommand {
  const ClipRectCommand({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.op,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final int op;

  @override
  String toString() =>
      'ClipRect(($left, $top, $right, $bottom), ${clipOpName(op)})';
}

final class ClipPathCommand extends DisplayListCommand {
  const ClipPathCommand({required this.pathId, required this.op});

  final int pathId;
  final int op;

  @override
  String toString() => 'ClipPath(path: $pathId, ${clipOpName(op)})';
}

final class DrawRectCommand extends DisplayListCommand {
  const DrawRectCommand({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.paintId,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;
  final int paintId;

  @override
  String toString() =>
      'DrawRect(($left, $top, $right, $bottom), paint: $paintId)';
}

final class DrawRRectCommand extends DisplayListCommand {
  DrawRRectCommand({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required List<double> radii,
    required this.paintId,
  }) : radii = List<double>.unmodifiable(radii);

  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Eight values: top-left x/y, top-right x/y, bottom-right x/y,
  /// bottom-left x/y.
  final List<double> radii;

  final int paintId;

  @override
  String toString() => 'DrawRRect(($left, $top, $right, $bottom), '
      'radii: $radii, paint: $paintId)';
}

final class DrawPathCommand extends DisplayListCommand {
  const DrawPathCommand({required this.pathId, required this.paintId});

  final int pathId;
  final int paintId;

  @override
  String toString() => 'DrawPath(path: $pathId, paint: $paintId)';
}

final class DrawImageCommand extends DisplayListCommand {
  const DrawImageCommand({
    required this.imageId,
    required this.srcLeft,
    required this.srcTop,
    required this.srcRight,
    required this.srcBottom,
    required this.dstLeft,
    required this.dstTop,
    required this.dstRight,
    required this.dstBottom,
    required this.paintId,
  });

  final int imageId;
  final double srcLeft;
  final double srcTop;
  final double srcRight;
  final double srcBottom;
  final double dstLeft;
  final double dstTop;
  final double dstRight;
  final double dstBottom;
  final int paintId;

  @override
  String toString() => 'DrawImage(image: $imageId, '
      'src: ($srcLeft, $srcTop, $srcRight, $srcBottom), '
      'dst: ($dstLeft, $dstTop, $dstRight, $dstBottom), paint: $paintId)';
}

final class DrawGlyphRunCommand extends DisplayListCommand {
  DrawGlyphRunCommand({
    required this.fontId,
    required this.paintId,
    required this.originX,
    required this.originY,
    required List<int> glyphIds,
    required List<double> offsets,
  })  : glyphIds = List<int>.unmodifiable(glyphIds),
        offsets = List<double>.unmodifiable(offsets);

  final int fontId;
  final int paintId;
  final double originX;
  final double originY;
  final List<int> glyphIds;

  /// `2 * glyphIds.length` values, x then y, relative to the origin.
  final List<double> offsets;

  int get glyphCount => glyphIds.length;

  @override
  String toString() => 'DrawGlyphRun(font: $fontId, paint: $paintId, '
      'origin: ($originX, $originY), glyphs: $glyphIds, offsets: $offsets)';
}

/// Decodes every command currently encoded in [list].
List<DisplayListCommand> expandDisplayList(DisplayList list) =>
    expandWithReader(DisplayListReader(list));

/// Decodes from [reader], which is rewound first so the result is always the
/// whole stream.
List<DisplayListCommand> expandWithReader(DisplayListReader reader) {
  reader.rewind();
  final commands = <DisplayListCommand>[];
  while (reader.moveNext()) {
    commands.add(_expandCurrent(reader));
  }
  return commands;
}

DisplayListCommand _expandCurrent(DisplayListReader reader) {
  switch (reader.opcode) {
    case opSave:
      return const SaveCommand();
    case opSaveLayer:
      return SaveLayerCommand(
        left: reader.floatAt(0),
        top: reader.floatAt(1),
        right: reader.floatAt(2),
        bottom: reader.floatAt(3),
        paintId: reader.intAt(0),
      );
    case opRestore:
      return const RestoreCommand();
    case opTransform:
      return TransformCommand(
        a: reader.floatAt(0),
        b: reader.floatAt(1),
        c: reader.floatAt(2),
        d: reader.floatAt(3),
        tx: reader.floatAt(4),
        ty: reader.floatAt(5),
      );
    case opClipRect:
      return ClipRectCommand(
        left: reader.floatAt(0),
        top: reader.floatAt(1),
        right: reader.floatAt(2),
        bottom: reader.floatAt(3),
        op: reader.intAt(0),
      );
    case opClipPath:
      return ClipPathCommand(pathId: reader.intAt(0), op: reader.intAt(1));
    case opDrawRect:
      return DrawRectCommand(
        left: reader.floatAt(0),
        top: reader.floatAt(1),
        right: reader.floatAt(2),
        bottom: reader.floatAt(3),
        paintId: reader.intAt(0),
      );
    case opDrawRRect:
      return DrawRRectCommand(
        left: reader.floatAt(0),
        top: reader.floatAt(1),
        right: reader.floatAt(2),
        bottom: reader.floatAt(3),
        radii: <double>[
          for (var i = 4; i < 12; i++) reader.floatAt(i),
        ],
        paintId: reader.intAt(0),
      );
    case opDrawPath:
      return DrawPathCommand(pathId: reader.intAt(0), paintId: reader.intAt(1));
    case opDrawImage:
      return DrawImageCommand(
        imageId: reader.intAt(0),
        srcLeft: reader.floatAt(0),
        srcTop: reader.floatAt(1),
        srcRight: reader.floatAt(2),
        srcBottom: reader.floatAt(3),
        dstLeft: reader.floatAt(4),
        dstTop: reader.floatAt(5),
        dstRight: reader.floatAt(6),
        dstBottom: reader.floatAt(7),
        paintId: reader.intAt(1),
      );
    case opDrawGlyphRun:
      final int count = reader.glyphCount;
      return DrawGlyphRunCommand(
        fontId: reader.intAt(0),
        paintId: reader.intAt(1),
        originX: reader.floatAt(0),
        originY: reader.floatAt(1),
        glyphIds: <int>[
          for (var i = 0; i < count; i++) reader.glyphIdAt(i),
        ],
        offsets: <double>[
          for (var i = 0; i < count * 2; i++) reader.floatAt(2 + i),
        ],
      );
    default:
      // Unreachable: the reader rejects unknown opcodes. Kept as a loud
      // failure so that adding an opcode without teaching this file about it
      // shows up in the debug path rather than silently dropping a command.
      throw DisplayListFormatException(
        'no debug expansion for opcode ${reader.opcode}',
        wordOffset: reader.headerOffset,
      );
  }
}

/// One line per command, preceded by the resource tables.
///
/// Meant to be pasted into a bug report or diffed as a golden.
String dumpDisplayList(DisplayList list) {
  final buffer = StringBuffer()
    ..writeln('DisplayList: ${list.commandCount} commands, '
        '${list.opLength} words, ${list.floatLength} floats')
    ..writeln('paints: ${list.paintCount}, paths: ${list.pathCount}, '
        'images: ${list.imageCount}');
  for (var id = 0; id < list.paintCount; id++) {
    buffer.writeln('  paint $id: '
        'color 0x${list.paintColor(id).toRadixString(16).padLeft(8, '0')}, '
        'style ${list.paintStyle(id)}, '
        'strokeWidth ${list.paintStrokeWidth(id)}, '
        'blend ${list.paintBlendMode(id)}, '
        'aa ${list.paintAntiAlias(id)}');
  }
  final commands = expandDisplayList(list);
  for (var i = 0; i < commands.length; i++) {
    buffer.writeln('$i: ${commands[i]}');
  }
  return buffer.toString();
}
