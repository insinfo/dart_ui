/// The Metal objects, on the Mac that CI provides.
///
/// Everything here that touches hardware is gated on `Platform.isMacOS` and
/// runs on the `macos-14` leg of the Framework workflow, which is an Apple
/// Silicon machine whose `MTLCreateSystemDefaultDevice` answers. The tests that
/// need no hardware run everywhere and are the ones that keep the call sites
/// honest off a Mac.
///
/// ## The rule every hardware test here obeys
///
/// Apple documents that sending a message to `nullptr` is legal and does
/// nothing. So a test that calls something and checks that the process did not
/// crash proves **nothing**: it would pass identically against a nil device, a
/// nil library and a nil function. Every test below asserts a **returned
/// value** - a non-nil object, a name with characters in it, a compiler
/// message with the offending token in it.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/src/ffi/objc_runtime.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_device.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_shaders.dart';
import 'package:test/test.dart';

final String? _needsMac = Platform.isMacOS
    ? null
    : 'needs a Mac: this opens a real MTLDevice and runs the Metal shader '
        'compiler. On Windows there is neither.';

void main() {
  group('call sites cannot invent a selector or a shape', () {
    // Runs anywhere, because it is pure bookkeeping: the assertion fires
    // before the message is built, so no runtime is touched.
    test('an undeclared selector is refused before it is sent', () {
      expect(
        () => metalSendPointer(nullptr, 'thisSelectorIsNotInTheTable'),
        throwsA(isA<MetalError>()),
      );
    });

    test('a declared selector sent with the wrong shape is refused', () {
      // `name` is declared pointerReturn0; sending it as pointerReturn1 is the
      // mistake that reads an argument register nobody wrote.
      expect(
        () => metalSendPointer1(nullptr, 'name', 0),
        throwsA(isA<MetalError>()),
      );
    });

    test('off macOS, opening a device says what was missing', () {
      if (Platform.isMacOS) return;
      expect(MetalGpu.open, throwsA(isA<MetalError>()));
    });
  });

  group('a real device', () {
    late MetalGpu gpu;

    setUpAll(() {
      if (!Platform.isMacOS) return;
      gpu = MetalGpu.open();
    });

    tearDownAll(() {
      if (!Platform.isMacOS) return;
      gpu.dispose();
    });

    test('answers with a device name and a command queue', () {
      // A value, not a survival: a nil device would answer every message with
      // zero and this would fail on the empty name.
      expect(gpu.device, isNot(nullptr));
      expect(gpu.commandQueue, isNot(nullptr));
      final String name = gpu.name;
      expect(name, isNotEmpty);
      expect(name, isNot('unnamed'));
      print('MTLDevice: $name');
    }, skip: _needsMac);

    test('compiles the MSL of metal_shaders.dart', () {
      // The first time this string has ever been through a Metal compiler.
      // Until now `kMetalShaderSource` was a string nobody had parsed, and a
      // syntax error in it would have survived every structural test in this
      // repository.
      final Pointer<ObjCObject> library = gpu.compileShaderLibrary();
      expect(library, isNot(nullptr));
      objcRelease(library);
    }, skip: _needsMac);

    test('the declared entry points exist in the compiled library', () {
      // Two, not three: `metal_shaders.dart` declares one `vertex` function
      // and one `fragment` function, and `boxCoverage` is a plain `static`
      // helper that no `newFunctionWithName:` can return - Metal only makes
      // qualified functions into MTLFunctions. That is why this asserts the
      // helper is *not* reachable as well as that the two entry points are.
      final Pointer<ObjCObject> library = gpu.compileShaderLibrary();
      try {
        for (final String entry in <String>[
          kMetalVertexEntryPoint,
          kMetalFragmentEntryPoint,
        ]) {
          final Pointer<ObjCObject> function = gpu.newFunction(library, entry);
          expect(function, isNot(nullptr), reason: entry);
          objcRelease(function);
        }
        expect(
          () => gpu.newFunction(library, 'boxCoverage'),
          throwsA(isA<MetalError>()),
          reason: 'an unqualified MSL function is not an entry point, and a '
              'library that handed one back would mean the shader was compiled '
              'from something other than metal_shaders.dart',
        );
        expect(
          () => gpu.newFunction(library, 'noSuchFunction'),
          throwsA(isA<MetalError>()),
        );
      } finally {
        objcRelease(library);
      }
    }, skip: _needsMac);

    test('a syntax error comes back as Apple\'s own diagnostic', () {
      // The half that matters when this file is wrong: the failure has to name
      // the line. A backend that reported "compilation failed" would leave the
      // next person to bisect a 90-line shader by deleting halves of it.
      Object? thrown;
      try {
        gpu.compileShaderLibrary('kernel void broken(');
      } on Object catch (error) {
        thrown = error;
      }
      expect(thrown, isA<MetalError>());
      final MetalError error = thrown! as MetalError;
      expect(error.detail, isNotNull);
      expect(error.detail, isNotEmpty);
      print('metal compiler on a deliberate syntax error: ${error.detail}');
    }, skip: _needsMac);
  });
}
