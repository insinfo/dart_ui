/// Allocation-free cursor over an encoded display list.
///
/// Deliberately not an `Iterable<Command>`: an iterable of command objects
/// would allocate one object per command on the replay path, which section
/// 6.5 forbids. Instead the reader is a mutable cursor - [moveNext] advances
/// it and the accessors read the operands of whatever command it is parked
/// on. One reader per replay, zero garbage per command.
///
/// Every advance re-validates framing against the opcode table, so a
/// truncated, corrupt or foreign buffer raises a [DisplayListFormatException]
/// instead of being read past. Validation is a handful of integer
/// comparisons; it is cheap enough to keep in release builds, and the failure
/// it prevents (reading operand data as opcodes) is the kind that surfaces as
/// a crash somewhere unrelated.
library;

import 'dart:typed_data';

import 'display_list.dart';
import 'display_list_opcodes.dart';

final class DisplayListReader {
  /// Reads the commands currently encoded in [list].
  ///
  /// The reader borrows the arena buffers. Encoding into [list] or calling
  /// `DisplayList.reset` while a reader is live invalidates it, exactly as
  /// mutating a list invalidates its iterator.
  DisplayListReader(DisplayList list)
      : this.overBuffers(
          list.opBuffer,
          list.opLength,
          list.floatBuffer,
          list.floatLength,
        );

  /// Reads a buffer pair that did not come from a live [DisplayList] - a
  /// buffer received from another isolate, or one built by a test.
  DisplayListReader.overBuffers(
    this._ops,
    this._opLength,
    this._floats,
    this._floatLength,
  ) {
    if (_opLength < 0 || _opLength > _ops.length) {
      throw ArgumentError.value(
        _opLength,
        'opLength',
        'outside the word buffer (${_ops.length} words)',
      );
    }
    if (_floatLength < 0 || _floatLength > _floats.length) {
      throw ArgumentError.value(
        _floatLength,
        'floatLength',
        'outside the float buffer (${_floats.length} slots)',
      );
    }
  }

  final Uint32List _ops;
  final int _opLength;
  final Float32List _floats;
  final int _floatLength;

  int _cursor = 0;
  int _floatCursor = 0;

  int _opcode = opInvalid;
  int _intBase = 0;
  int _intCount = 0;
  int _floatBase = 0;
  int _floatCount = 0;
  int _commandIndex = -1;

  /// Opcode of the current command, or [opInvalid] before the first
  /// [moveNext] and after the last one.
  int get opcode => _opcode;

  int get intOperandCount => _intCount;

  int get floatOperandCount => _floatCount;

  /// Zero-based position of the current command in the stream.
  int get commandIndex => _commandIndex;

  /// Word offset of the current command's header, useful when reporting a
  /// problem found by the caller rather than by the reader.
  int get headerOffset => _intBase - 1;

  /// Advances to the next command.
  ///
  /// Returns false at the end of the stream. Throws
  /// [DisplayListFormatException] if framing does not hold.
  bool moveNext() {
    if (_cursor >= _opLength) {
      _opcode = opInvalid;
      _intCount = 0;
      _floatCount = 0;
      return false;
    }

    final int at = _cursor;
    final int header = _ops[at];
    if (headerMarker(header) != kHeaderMarker) {
      throw DisplayListFormatException(
        'expected a command header, found 0x${header.toRadixString(16)}',
        wordOffset: at,
      );
    }
    final int opcode = headerOpcode(header);
    if (!isKnownOpcode(opcode)) {
      throw DisplayListFormatException(
        'unknown opcode $opcode',
        wordOffset: at,
      );
    }

    final int intSlots = headerIntSlots(header);
    final int floatSlots = headerFloatSlots(header);
    final int expectedInts = intSlotsFor(opcode);
    final int expectedFloats = floatSlotsFor(opcode);
    if (expectedInts != kVariableSlots && intSlots != expectedInts) {
      throw DisplayListFormatException(
        '${opcodeName(opcode)} declares $intSlots int operands, '
        'expected $expectedInts',
        wordOffset: at,
      );
    }
    if (expectedFloats != kVariableSlots && floatSlots != expectedFloats) {
      throw DisplayListFormatException(
        '${opcodeName(opcode)} declares $floatSlots float operands, '
        'expected $expectedFloats',
        wordOffset: at,
      );
    }
    if (at + 1 + intSlots > _opLength) {
      throw DisplayListFormatException(
        'truncated: ${opcodeName(opcode)} needs $intSlots int operands but '
        'only ${_opLength - at - 1} words remain',
        wordOffset: at,
      );
    }
    if (_floatCursor + floatSlots > _floatLength) {
      throw DisplayListFormatException(
        'truncated: ${opcodeName(opcode)} needs $floatSlots float operands '
        'but only ${_floatLength - _floatCursor} slots remain',
        wordOffset: at,
      );
    }

    if (opcode == opDrawGlyphRun) {
      // The table cannot pin a variable-arity command down, so the declared
      // counts are checked against the count embedded in the operands. This
      // is what stops a corrupted glyph count from being trusted.
      if (intSlots < 3) {
        throw DisplayListFormatException(
          'drawGlyphRun declares $intSlots int operands, needs at least 3',
          wordOffset: at,
        );
      }
      final int glyphCount = _ops[at + 3];
      if (glyphCount > kMaxGlyphsPerRun ||
          intSlots != glyphRunIntSlots(glyphCount) ||
          floatSlots != glyphRunFloatSlots(glyphCount)) {
        throw DisplayListFormatException(
          'drawGlyphRun glyph count $glyphCount disagrees with its declared '
          '$intSlots int / $floatSlots float operands',
          wordOffset: at,
        );
      }
    }

    _opcode = opcode;
    _intBase = at + 1;
    _intCount = intSlots;
    _floatBase = _floatCursor;
    _floatCount = floatSlots;
    _cursor = at + 1 + intSlots;
    _floatCursor += floatSlots;
    _commandIndex++;
    return true;
  }

  /// Restarts the walk without reallocating the reader.
  void rewind() {
    _cursor = 0;
    _floatCursor = 0;
    _opcode = opInvalid;
    _intBase = 0;
    _intCount = 0;
    _floatBase = 0;
    _floatCount = 0;
    _commandIndex = -1;
  }

  int intAt(int index) {
    if (index < 0 || index >= _intCount) {
      throw RangeError.index(index, this, 'index', null, _intCount);
    }
    return _ops[_intBase + index];
  }

  double floatAt(int index) {
    if (index < 0 || index >= _floatCount) {
      throw RangeError.index(index, this, 'index', null, _floatCount);
    }
    return _floats[_floatBase + index];
  }

  // Named accessors for the operands whose position is fixed by the format.
  // They exist so replay code reads as intent rather than as magic indices;
  // they are plain arithmetic and allocate nothing.

  /// Paint id of the current command. Its operand position differs per
  /// opcode, so the opcode decides where to look.
  int get paintId {
    switch (_opcode) {
      case opSaveLayer:
      case opDrawRect:
      case opDrawRRect:
        return intAt(0);
      case opDrawPath:
      case opDrawImage:
      case opDrawGlyphRun:
        return intAt(1);
      default:
        throw StateError('${opcodeName(_opcode)} carries no paint');
    }
  }

  int get pathId {
    if (_opcode != opClipPath && _opcode != opDrawPath) {
      throw StateError('${opcodeName(_opcode)} carries no path');
    }
    return intAt(0);
  }

  int get imageId {
    if (_opcode != opDrawImage) {
      throw StateError('${opcodeName(_opcode)} carries no image');
    }
    return intAt(0);
  }

  int get clipOp {
    switch (_opcode) {
      case opClipRect:
        return intAt(0);
      case opClipPath:
        return intAt(1);
      default:
        throw StateError('${opcodeName(_opcode)} is not a clip');
    }
  }

  int get fontId {
    if (_opcode != opDrawGlyphRun) {
      throw StateError('${opcodeName(_opcode)} carries no font');
    }
    return intAt(0);
  }

  int get glyphCount {
    if (_opcode != opDrawGlyphRun) {
      throw StateError('${opcodeName(_opcode)} carries no glyphs');
    }
    return intAt(2);
  }

  int glyphIdAt(int index) => intAt(3 + index);

  double glyphOffsetXAt(int index) => floatAt(2 + index * 2);

  double glyphOffsetYAt(int index) => floatAt(3 + index * 2);

  /// Walks the whole stream from the start and returns the command count.
  ///
  /// A cheap integrity check for a buffer that arrived from outside: it
  /// throws on the first framing problem. Leaves the cursor at the end.
  int validate() {
    rewind();
    var count = 0;
    while (moveNext()) {
      count++;
    }
    if (_floatCursor != _floatLength) {
      throw DisplayListFormatException(
        'trailing float data: ${_floatLength - _floatCursor} unread slots',
        wordOffset: _cursor,
      );
    }
    return count;
  }
}
