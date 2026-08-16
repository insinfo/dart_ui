/// The parts of the Objective-C binding that are arithmetic, tested where
/// there is no Objective-C runtime at all.
///
/// This file is the concrete form of the argument `objc_runtime.dart` makes in
/// its library comment: `objc_msgSend` has no prototype, the caller supplies
/// the signature, and a wrong signature corrupts a call frame silently on
/// arm64. Two of the three mechanisms that keep the signature honest - the
/// closed shape table and the declared type encoding - are pure Dart, and pure
/// Dart is checkable on a machine with no Mac in it. That is what runs here.
///
/// What is deliberately **not** here: any assertion that a message was
/// actually sent. Nothing in this file loads `libobjc`, and a test that
/// pretended to would be the "capacidade fingida" the roadmap's section 6.6
/// forbids.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/ffi/objc_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('type encodings', () {
    test('reads the bare spelling a header would be transcribed as', () {
      expect(
        parseObjCTypeEncoding('v@:'),
        const ObjCSignature(
          ObjCAbiClass.none,
          <ObjCAbiClass>[ObjCAbiClass.word, ObjCAbiClass.word],
        ),
      );
    });

    test('reads the frame-offset spelling method_getTypeEncoding returns', () {
      // The offsets are the old stack frame layout and are meaningless on
      // arm64. Skipping them rather than trusting them is the point: a reader
      // that derived argument positions from these numbers would place the
      // second argument at byte 16 of a frame that does not exist.
      expect(
        parseObjCTypeEncoding('v24@0:8Q16'),
        parseObjCTypeEncoding('v@:Q'),
      );
    });

    test('ignores the const/in/out qualifiers', () {
      expect(parseObjCTypeEncoding('v@:r^v'), parseObjCTypeEncoding('v@:^v'));
      expect(parseObjCTypeEncoding('v@:nN@'), parseObjCTypeEncoding('v@:@'));
    });

    test('a pointer to anything is one word, pointee consumed', () {
      // `^{CGImage=}` must not leave a stray aggregate behind, or every later
      // argument shifts by one.
      expect(
        parseObjCTypeEncoding('v@:^{CGImage=}Q'),
        const ObjCSignature(
          ObjCAbiClass.none,
          <ObjCAbiClass>[
            ObjCAbiClass.word,
            ObjCAbiClass.word,
            ObjCAbiClass.word,
            ObjCAbiClass.word,
          ],
        ),
      );
    });

    test('a struct argument is one aggregate', () {
      expect(
        parseObjCTypeEncoding('v@:{CGSize=dd}'),
        const ObjCSignature(
          ObjCAbiClass.none,
          <ObjCAbiClass>[
            ObjCAbiClass.word,
            ObjCAbiClass.word,
            ObjCAbiClass.aggregate,
          ],
        ),
      );
    });

    test('a nested struct does not leak its members as arguments', () {
      // MTLRegion is {MTLOrigin=QQQ} followed by {MTLSize=QQQ}. A reader that
      // did not balance the braces would report six extra word arguments.
      final ObjCSignature signature = parseObjCTypeEncoding(
          'v@:{MTLRegion={MTLOrigin=QQQ}{MTLSize=QQQ}}Q^vQ');
      expect(signature.explicitArgumentCount, 4);
      expect(signature.argumentClasses[2], ObjCAbiClass.aggregate);
      expect(signature.argumentClasses[3], ObjCAbiClass.word);
    });

    group('the @ suffixes that are not separate arguments', () {
      // The bug this group exists for: `@?` is a block and `@"NSString"` is a
      // named object, both ONE argument. Read as two, a correct call site
      // fails the shape check and the check gets switched off.
      test('@? is one argument, not two', () {
        expect(parseObjCTypeEncoding('v@:@?').explicitArgumentCount, 1);
        expect(
          parseObjCTypeEncoding('v@:@?'),
          parseObjCTypeEncoding('v@:@'),
        );
      });

      test('@"ClassName" is one argument, not two', () {
        expect(
          parseObjCTypeEncoding('v@:@"NSString"').explicitArgumentCount,
          1,
        );
      });

      test('a named object followed by another argument keeps its place', () {
        final ObjCSignature signature =
            parseObjCTypeEncoding('v@:@"MTLTexture"Q');
        expect(signature.explicitArgumentCount, 2);
        expect(signature.argumentClasses[3], ObjCAbiClass.word);
      });

      test('an unterminated class name is refused, not silently consumed', () {
        expect(
          () => parseObjCTypeEncoding('v@:@"MTLTexture'),
          throwsA(isA<ObjCTypeEncodingError>()),
        );
      });
    });

    test('float and double are their own classes', () {
      // The one distinction that changes the register file, and therefore the
      // one this parser is not allowed to coarsen away.
      expect(
        parseObjCTypeEncoding('f@:d').argumentClasses.last,
        ObjCAbiClass.float64,
      );
      expect(parseObjCTypeEncoding('f@:d').returnClass, ObjCAbiClass.float32);
    });

    test('an encoding with no receiver and selector is refused', () {
      expect(
        () => parseObjCTypeEncoding('v'),
        throwsA(isA<ObjCTypeEncodingError>()),
      );
      expect(
        () => parseObjCTypeEncoding('v@'),
        throwsA(isA<ObjCTypeEncodingError>()),
      );
    });

    test('an unknown type code names itself and its offset', () {
      final ObjCTypeEncodingError error = _encodingError('v@:z');
      expect(error.offset, 3);
      expect(error.toString(), contains('"z"'));
      expect(error.toString(), contains('v@:z'));
    });

    test('an unterminated struct is refused', () {
      expect(
        () => parseObjCTypeEncoding('v@:{CGSize=dd'),
        throwsA(isA<ObjCTypeEncodingError>()),
      );
    });
  });

  group('the shape table', () {
    test('every shape declares receiver and selector as words', () {
      for (final ObjCSendShape shape in ObjCSendShape.values) {
        expect(
          shape.signature.argumentClasses.take(2),
          <ObjCAbiClass>[ObjCAbiClass.word, ObjCAbiClass.word],
          reason: '${shape.name} must take id and SEL first',
        );
      }
    });

    test('no shape returns an aggregate', () {
      // objc_msgSend is the wrong trampoline for a large struct return on
      // x86_64 and the right one (objc_msgSend_stret) does not exist on
      // arm64, so a shape that grew one would have to branch on the
      // architecture. This is the assertion that keeps that from happening
      // by accident.
      for (final ObjCSendShape shape in ObjCSendShape.values) {
        expect(shape.signature.hasAggregateReturn, isFalse,
            reason: '${shape.name} returns an aggregate');
      }
    });

    test('each shape matches the encoding of a selector it is used for', () {
      // Mechanism 2 of the library comment, exercised. Each row is a real
      // selector, the type encoding its header declares, and the shape a call
      // site would pick. The comparison is what catches a transcription slip
      // before it becomes a wrong register read.
      const Map<String, (String, ObjCSendShape)> table =
          <String, (String, ObjCSendShape)>{
        'newCommandQueue': ('@@:', ObjCSendShape.pointerReturn0),
        'commandBuffer': ('@@:', ObjCSendShape.pointerReturn0),
        'newBufferWithLength:options:': ('@@:QQ', ObjCSendShape.pointerReturn2),
        'newTextureWithDescriptor:iosurface:plane:': (
          '@@:@^{__IOSurface=}Q',
          ObjCSendShape.pointerReturn3
        ),
        'setVertexBuffer:offset:atIndex:': (
          'v@:@QQ',
          ObjCSendShape.voidReturn3
        ),
        'drawPrimitives:vertexStart:vertexCount:': (
          'v@:QQQ',
          ObjCSendShape.voidReturn3
        ),
        'setFragmentTexture:atIndex:': ('v@:@Q', ObjCSendShape.voidReturn2),
        'endEncoding': ('v@:', ObjCSendShape.voidReturn0),
        'addCompletedHandler:': ('v@:@?', ObjCSendShape.voidReturn1),
        'status': ('Q@:', ObjCSendShape.unsignedReturn0),
        'isHeadless': ('B@:', ObjCSendShape.boolReturn0),
        'setDrawableSize:': ('v@:{CGSize=dd}', ObjCSendShape.voidReturnDouble2),
        'setClearColor:': (
          'v@:{MTLClearColor=dddd}',
          ObjCSendShape.voidReturnDouble4
        ),
        'setViewport:': (
          'v@:{MTLViewport=dddddd}',
          ObjCSendShape.voidReturnDouble6
        ),
        'setScissorRect:': (
          'v@:{MTLScissorRect=QQQQ}',
          ObjCSendShape.voidReturnWord4
        ),
        'replaceRegion:mipmapLevel:withBytes:bytesPerRow:': (
          'v@:{MTLRegion={MTLOrigin=QQQ}{MTLSize=QQQ}}Q^vQ',
          ObjCSendShape.voidReturnRegionLevelBytesStride
        ),
      };

      table.forEach((String selector, (String, ObjCSendShape) row) {
        final (String encoding, ObjCSendShape shape) = row;
        expect(
          shape.signature,
          parseObjCTypeEncoding(encoding),
          reason: '$selector is declared "$encoding" but ${shape.name} '
              'implements ${shape.signature}',
        );
      });
    });

    test('a word shape does NOT match an aggregate encoding', () {
      // The negative half, and the one that matters: this is the mistake
      // poc_07_metal's comment made - treating a four-double MTLClearColor as
      // if it travelled in general-purpose registers. If this ever passes,
      // the shape check has stopped checking anything.
      expect(
        ObjCSendShape.voidReturn1.signature ==
            parseObjCTypeEncoding('v@:{MTLClearColor=dddd}'),
        isFalse,
      );
      expect(
        ObjCSendShape.voidReturn2.signature ==
            parseObjCTypeEncoding('v@:{CGSize=dd}'),
        isFalse,
      );
    });

    test('argument order is compared, not just the multiset', () {
      // replaceRegion: puts its aggregate first. A shape with the same classes
      // in a different order must not compare equal, because on arm64 an
      // indirectly-passed aggregate still consumes an integer register and
      // everything after it shifts.
      final ObjCSignature real = parseObjCTypeEncoding(
          'v@:{MTLRegion={MTLOrigin=QQQ}{MTLSize=QQQ}}Q^vQ');
      final ObjCSignature shuffled = parseObjCTypeEncoding(
          'v@:Q^vQ{MTLRegion={MTLOrigin=QQQ}{MTLSize=QQQ}}');
      expect(real == shuffled, isFalse);
      expect(ObjCSendShape.voidReturnRegionLevelBytesStride.signature, real);
    });
  });

  group('aggregate struct layout', () {
    // dart:ffi computes these, so what is really being asserted is that the
    // declarations say what their names claim. A CGSize that had grown a third
    // field would be caught here rather than by a viewport that is subtly
    // wrong.
    test('sizes are the C sizes', () {
      expect(sizeOf<ObjCDouble2>(), 16);
      expect(sizeOf<ObjCDouble4>(), 32);
      expect(sizeOf<ObjCDouble6>(), 48);
      expect(sizeOf<ObjCWord4>(), 4 * sizeOf<IntPtr>());
      expect(sizeOf<ObjCWord6>(), 6 * sizeOf<IntPtr>());
    });

    test(
        'ObjCWord4 and ObjCDouble4 are the same size and not the same '
        'argument', () {
      // 32 bytes both. On arm64 the first is passed indirectly and the second
      // in d0..d3. Equal size is exactly why a call site is not allowed to
      // describe an argument by its byte count.
      expect(sizeOf<ObjCWord4>(), sizeOf<ObjCDouble4>());
      expect(
        ObjCSendShape.voidReturnWord4,
        isNot(ObjCSendShape.voidReturnDouble4),
      );
    });

    test('the builders fill every field', () {
      final ObjCDouble2 size = objcDouble2(1.5, 2.5);
      expect(<double>[size.a0, size.a1], <double>[1.5, 2.5]);

      final ObjCDouble4 color = objcDouble4(0.2, 0.6, 0.8, 1.0);
      expect(<double>[color.a0, color.a1, color.a2, color.a3],
          <double>[0.2, 0.6, 0.8, 1.0]);

      final ObjCDouble6 viewport = objcDouble6(0, 0, 640, 480, 0, 1);
      expect(
        <double>[
          viewport.a0,
          viewport.a1,
          viewport.a2,
          viewport.a3,
          viewport.a4,
          viewport.a5,
        ],
        <double>[0, 0, 640, 480, 0, 1],
      );

      final ObjCWord4 scissor = objcWord4(1, 2, 3, 4);
      expect(<int>[scissor.a0, scissor.a1, scissor.a2, scissor.a3],
          <int>[1, 2, 3, 4]);

      final ObjCWord6 region = objcWord6(1, 2, 3, 4, 5, 6);
      expect(
        <int>[region.a0, region.a1, region.a2, region.a3, region.a4, region.a5],
        <int>[1, 2, 3, 4, 5, 6],
      );
    });

    test('each builder returns independent storage', () {
      // Struct.create hands back a fresh instance; two of them sharing backing
      // memory would make the second setViewport: overwrite the first.
      final ObjCDouble2 first = objcDouble2(1, 2);
      final ObjCDouble2 second = objcDouble2(3, 4);
      expect(first.a0, 1);
      expect(second.a0, 3);
    });
  });

  group('block layout', () {
    // struct Block_literal_1 is a published ABI. These offsets are what the
    // compiler emits and what every framework taking a block reads, and the
    // LP64 layout is the same on the Windows x64 this test runs on.
    test('the literal is the five published fields, 32 bytes', () {
      expect(sizeOf<ObjCBlockLiteral>(), 32);
    });

    test('the descriptor carries reserved, size and signature', () {
      expect(sizeOf<ObjCBlockDescriptor>(), 24);
    });

    test('the flag values are libclosure\'s', () {
      expect(kObjCBlockHasCopyDispose, 0x02000000);
      expect(kObjCBlockIsGlobal, 0x10000000);
      expect(kObjCBlockHasSignature, 0x40000000);
    });

    test('the completion-handler signature parses as one block argument', () {
      final ObjCSignature signature =
          parseObjCTypeEncoding(kObjCCompletionHandlerSignature);
      expect(signature.returnClass, ObjCAbiClass.none);
      // Receiver (the block itself) and the one object it is handed. There is
      // no selector in a block encoding, which is why this is 2 and not 3.
      expect(signature.argumentClasses.length, 2);
    });
  });

  group('ownership', () {
    test('the +1 prefixes are recognised', () {
      for (final String selector in <String>[
        'alloc',
        'new',
        'copy',
        'mutableCopy',
        'init',
        'newCommandQueue',
        'newBufferWithLength:options:',
        'initWithDevice:',
        'copyWithZone:',
        'mutableCopyWithZone:',
        'new_thing',
      ]) {
        expect(objcSelectorReturnsOwned(selector), isTrue,
            reason: '$selector returns +1');
      }
    });

    test('a prefix that does not end at a word boundary is not owning', () {
      // The whole reason this is a function with a test instead of five
      // startsWith calls: `newer` and `copyright` both start with an owning
      // prefix and both return a borrowed reference. Releasing one of them
      // over-releases, and an over-released Metal object crashes several
      // frames later inside the driver.
      for (final String selector in <String>[
        'newer',
        'copyright',
        'initialise',
        'allocation',
        'description',
        'texture',
        'nextDrawable',
        'commandBuffer',
        'renderCommandEncoderWithDescriptor:',
      ]) {
        expect(objcSelectorReturnsOwned(selector), isFalse,
            reason: '$selector returns a borrowed or autoreleased reference');
      }
    });

    test('commandBuffer and newCommandQueue differ, which is the point', () {
      // Two selectors one word apart on the same class, with opposite
      // ownership. Getting this pair backwards is the classic Metal leak.
      expect(objcSelectorReturnsOwned('newCommandQueue'), isTrue);
      expect(objcSelectorReturnsOwned('commandBuffer'), isFalse);
    });
  });

  group('C strings', () {
    // These allocate through NativeAllocator, which binds CoTaskMemAlloc on
    // Windows. The first draft of objc_runtime.dart bound calloc out of
    // DynamicLibrary.process(), which is unsupported on Windows and made this
    // whole group unreachable.
    test('round-trips ASCII', () {
      _roundTrip('newTextureWithDescriptor:iosurface:plane:');
      _roundTrip('');
      _roundTrip('v@:{MTLClearColor=dddd}');
    });

    test('round-trips text outside ASCII', () {
      // The previous reader copied bytes with writeCharCode, which turns every
      // multi-byte sequence into mojibake instead of failing.
      _roundTrip('resolução');
      _roundTrip('日本語');
      _roundTrip('an emoji: \u{1F600}');
    });

    test('length is bytes, not code units', () {
      expect(objcCStringLength('abc'), 3);
      expect(objcCStringLength('é'), 2);
      expect(objcCStringLength('日'), 3);
      expect(objcCStringLength('\u{1F600}'), 4);
    });

    test('agrees with dart:convert byte for byte', () {
      // The encoder is hand-rolled to keep this file free of a converter
      // dependency on the allocation path; this is what makes that safe.
      for (final String sample in <String>[
        'alloc',
        'resolução',
        '日本語',
        '\u{1F600}\u{1F3F4}',
        'mixed ascii e acentuação 123',
      ]) {
        expect(objcCStringLength(sample), utf8.encode(sample).length,
            reason: sample);
        final Pointer<Uint8> buffer = objcAllocateCString(sample);
        try {
          final Uint8List bytes =
              buffer.asTypedList(objcCStringLength(sample) + 1);
          expect(
            bytes.sublist(0, objcCStringLength(sample)),
            utf8.encode(sample),
            reason: sample,
          );
          expect(bytes.last, 0, reason: 'missing NUL terminator for $sample');
        } finally {
          objcFreeCString(buffer);
        }
      }
    });

    test('reading a null pointer is empty, not a crash', () {
      expect(objcReadCString(nullptr), isEmpty);
    });
  });

  group('availability, off macOS', () {
    test('the probe answers instead of throwing', () {
      // Section 6.6: a backend that is not here says so. Importing this file
      // on Windows must cost nothing and must not throw, which is why every
      // handle in it is a lazy top-level final.
      expect(isObjCRuntimeAvailable, isA<bool>());
      if (!Platform.isMacOS) {
        expect(isObjCRuntimeAvailable, isFalse);
        expect(objcRuntimeLoadError, isNotNull);
      }
    });

    test('touching the runtime without it names what was missing', () {
      if (Platform.isMacOS) return;
      expect(
        () => objcSelector('alloc'),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            allOf(
              contains('libobjc'),
              contains('isObjCRuntimeAvailable'),
            ),
          ),
        ),
      );
    });

    test('the block runtime reports absence rather than throwing', () {
      expect(isObjCBlockRuntimeAvailable, isA<bool>());
      if (!Platform.isMacOS) {
        expect(isObjCBlockRuntimeAvailable, isFalse);
      }
    });
  });
}

ObjCTypeEncodingError _encodingError(String encoding) {
  try {
    parseObjCTypeEncoding(encoding);
  } on ObjCTypeEncodingError catch (error) {
    return error;
  }
  fail('"$encoding" was expected to be refused');
}

void _roundTrip(String value) {
  final Pointer<Uint8> buffer = objcAllocateCString(value);
  try {
    expect(objcReadCString(buffer), value);
  } finally {
    objcFreeCString(buffer);
  }
}
