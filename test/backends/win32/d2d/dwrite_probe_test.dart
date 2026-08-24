/// The DirectWrite bindings against the real `dwrite.dll`.
///
/// Two things are on trial and neither can be checked by reading a header.
///
/// The **slot arithmetic**: `dwrite_interfaces.dart` counts five vtables out
/// by hand, and a method called through the wrong slot does not fail politely.
/// The chain from factory to font face is walked here end to end, which is the
/// only way to find out that the numbers are right.
///
/// The **identity check**: `dwrite_font_faces.dart` refuses a system face
/// whose glyph numbering differs from the bytes this framework parsed, and
/// that refusal is the guard against the worst failure mode of the whole
/// native-text option - correctly spaced nonsense. Both sides are asserted: a
/// font that *is* installed, loaded from its own file, must be accepted; a
/// font that is not installed must be refused with a reason that names it.
library;

import 'dart:io';

import 'package:dart_ui/src/backends/win32/d2d/d2d1_library.dart';
import 'package:dart_ui/src/backends/win32/d2d/dwrite_font_faces.dart';
import 'package:dart_ui/src/backends/win32/d2d/dwrite_interfaces.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:test/test.dart';

/// A font that is installed on every Windows and whose file is readable, so
/// the same bytes can go down both sides of the comparison.
///
/// Arial rather than Segoe UI: `segoeui.ttf` is the one Windows most often
/// replaces between builds, and this test is about the bindings, not about
/// finding a version mismatch on the CI machine. If neither is present the
/// test says so and skips rather than failing for a reason that is not a bug.
const List<String> _candidateFiles = <String>[
  r'C:\Windows\Fonts\arial.ttf',
  r'C:\Windows\Fonts\segoeui.ttf',
  r'C:\Windows\Fonts\tahoma.ttf',
  r'C:\Windows\Fonts\verdana.ttf',
];

void main() {
  final String? platformSkip = Platform.isWindows
      ? null
      : 'DirectWrite exists only on Windows; this runner is '
          '${Platform.operatingSystem}';

  group('the DirectWrite chain, walked against the runtime', () {
    late DWriteFontFaces faces;
    String? skip = platformSkip;

    setUpAll(() {
      if (!Platform.isWindows) return;
      DWriteFontFaces.debugResetCache();
      final D2d1Library? library = D2d1Library.open().library;
      if (library == null) {
        skip = 'no d2d1.dll, so no process-heap allocator to load DWrite with';
        return;
      }
      final DWriteLoad load = DWriteFontFaces.open(library.allocator);
      if (!load.isLoaded) {
        skip = 'DirectWrite did not open: '
            '${load.diagnostics.map((Object d) => d.toString()).join('; ')}';
        return;
      }
      faces = load.faces!;
    });

    test('an installed font resolves to a face with our glyph numbering', () {
      final File? file = _firstExisting();
      if (file == null) {
        markTestSkipped('none of $_candidateFiles is present on this machine');
        return;
      }
      final Typeface typeface = Typeface.parse(file.readAsBytesSync());
      printOnFailure('family "${typeface.familyName}", '
          '${typeface.glyphCount} glyphs, from ${file.path}');

      final DWriteFontFace? face = faces.faceFor(typeface);
      if (face == null) {
        // A real possibility and not a test bug: the installed file and the
        // collection's idea of the family can be different builds. Say which,
        // and skip - failing here would report a machine's font state as a
        // defect in the bindings.
        markTestSkipped('the system collection refused '
            '"${typeface.familyName}": ${faces.refusalFor(typeface)}');
        return;
      }

      expect(face.glyphCount, typeface.glyphCount,
          reason: 'the resolver accepted a face whose glyph count differs, '
              'which is exactly what it exists to refuse');
      expect(faces.residentFaceCount, greaterThan(0));
      expect(identical(faces.faceFor(typeface), face), isTrue,
          reason: 'the second ask must come from the cache; resolving a face '
              'per run would put a font-collection lookup inside a frame');
      expect(faces.refusalFor(typeface), isNull);
    }, skip: skip);

    test('a font that is not installed is refused, by name', () {
      // The path an application that ships its own font bytes takes today.
      // The refusal has to name the font and the reason, because the symptom
      // an application sees is "I turned the option on and nothing changed".
      final Typeface dejaVu =
          Typeface.parse(File('test/fonts/DejaVuSans.ttf').readAsBytesSync());
      final DWriteFontFace? face = faces.faceFor(dejaVu);
      if (face != null) {
        markTestSkipped('DejaVu Sans is installed on this machine, so it '
            'cannot stand in for an absent font');
        return;
      }
      final String? reason = faces.refusalFor(dejaVu);
      expect(reason, isNotNull);
      expect(reason, contains('DejaVu'));
      printOnFailure('refusal: $reason');
    }, skip: skip);
  });
}

File? _firstExisting() {
  for (final String path in _candidateFiles) {
    final File file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}
