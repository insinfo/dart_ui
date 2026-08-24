/// Opening `dwrite.dll` and turning one of *our* [Typeface]s into an
/// `IDWriteFontFace` - or refusing, by name.
///
/// ## The one job, and the refusal that guards it
///
/// The optional native-text route (see `dwrite_interfaces.dart`) needs a
/// `IDWriteFontFace` for a run this framework has already shaped with its own
/// parser over its own bytes. Those two have to be *the same font*, and
/// "the same font" here means something very specific: the same glyph
/// numbering. If Windows resolves "Segoe UI" to a file whose `cmap` and glyph
/// order differ from the bytes we parsed - a different version, a variable
/// instance, a font the user replaced - then our glyph id 42 is its glyph id
/// 42 by coincidence only, and the text comes out as confident nonsense: right
/// spacing, wrong letters. It is the most likely silent failure of this whole
/// integration, so it is checked rather than hoped for, and a face that fails
/// the check is refused so the caller falls back to the portable route.
///
/// The check is [_agrees]: the glyph counts must match, and Windows'
/// `GetGlyphIndices` must return our [Typeface.glyphForCodePoint] for a sample
/// of code points spread across the ranges a Latin interface actually uses. It
/// is a sample and not a proof - a full comparison would walk 65 536 code
/// points on the first frame that draws text - and the sample is chosen to
/// include the places where two builds of a font differ first: the ASCII
/// block, the Latin-1 supplement, punctuation Windows likes to add, and the
/// currency and arrow blocks that fonts grow between versions.
///
/// ## Only the system collection
///
/// A face is looked up by family name in the system font collection and
/// nowhere else. An application that ships its own font bytes would need a
/// custom `IDWriteFontFileLoader` and `IDWriteFontCollectionLoader` over those
/// bytes; that is real work and it is not done here. The consequence is stated
/// rather than hidden: [DWriteFontFaces.faceFor] returns null for a font that
/// is not installed on the machine, the caller draws that run the portable
/// way, and an application that turned the option on gets native rasterisation
/// for its system fonts and the framework's own for the rest. Drawing it with
/// *some other* face would be worse than not drawing it natively at all.
library;

import 'dart:ffi';

import '../../../foundation/diagnostics.dart';
import '../../../text/typeface.dart';
import '../d3d12/d3d12_com.dart';
import 'dwrite_interfaces.dart';

/// `DWriteCreateFactory`.
typedef _CreateFactoryNative = Int32 Function(
  Uint32 factoryType,
  Pointer<Guid> iid,
  Pointer<Pointer<Void>> factory,
);

typedef DWriteCreateFactoryDart = int Function(
  int factoryType,
  Pointer<Guid> iid,
  Pointer<Pointer<Void>> factory,
);

/// Code points compared before a system face is allowed to stand in for one of
/// ours. See the library comment for why these and not others.
const List<int> kDWriteIdentityProbe = <int>[
  0x20, // space
  0x41, // A
  0x5A, // Z
  0x61, // a
  0x7A, // z
  0x30, // 0
  0x39, // 9
  0x2E, // .
  0x2C, // ,
  0xC1, // A acute - Latin-1 supplement
  0xE7, // c cedilla
  0x2013, // en dash
  0x2019, // right single quote
  0x20AC, // euro
  0x2192, // rightwards arrow
];

/// What [DWriteFontFaces.open] found, whether or not it succeeded.
final class DWriteLoad {
  const DWriteLoad({required this.faces, required this.diagnostics});

  /// Null when `dwrite.dll` or the factory was not available.
  final DWriteFontFaces? faces;

  final List<BackendDiagnostic> diagnostics;

  bool get isLoaded => faces != null;
}

/// The DirectWrite factory and system font collection, plus the cache of faces
/// already resolved and already checked.
final class DWriteFontFaces {
  DWriteFontFaces._(this._factory, this._collection, this._allocator);

  static DWriteLoad? _cached;

  /// Loads `dwrite.dll` and opens the shared factory and system collection.
  ///
  /// Cached per process: the system collection is the expensive part and it is
  /// the same object for everyone. [debugResetCache] drops it.
  static DWriteLoad open(Allocator allocator) {
    final DWriteLoad? cached = _cached;
    if (cached != null) return cached;
    final DWriteLoad result = _open(allocator);
    _cached = result;
    return result;
  }

  /// Only for tests that want a fresh load.
  static void debugResetCache() => _cached = null;

  static DWriteLoad _open(Allocator allocator) {
    final DynamicLibrary dwrite;
    try {
      dwrite = DynamicLibrary.open('dwrite.dll');
    } on Object catch (error) {
      return DWriteLoad(
        faces: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingLibrary(
            'dwrite.dll',
            detail: '$error. DirectWrite shipped with Windows 7; without it '
                'the native text option cannot be honoured and the portable '
                'glyph route is the answer',
          ),
        ],
      );
    }

    final DWriteCreateFactoryDart createFactory;
    try {
      createFactory =
          dwrite.lookupFunction<_CreateFactoryNative, DWriteCreateFactoryDart>(
              'DWriteCreateFactory');
    } on ArgumentError catch (error) {
      return DWriteLoad(
        faces: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic.missingSymbol('DWriteCreateFactory',
              detail: '$error'),
        ],
      );
    }

    final Pointer<Guid> iid = allocator.allocate<Guid>(sizeOf<Guid>());
    final Pointer<Pointer<Void>> out =
        allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    writeGuid(iid, iidDWriteFactory);
    out.value = nullptr;
    final int hr = createFactory(dwriteFactoryTypeShared, iid, out);
    final Pointer<Void> raw = out.value;
    if (comFailed(hr) || raw == nullptr) {
      allocator
        ..free(iid)
        ..free(out);
      return DWriteLoad(
        faces: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'DWriteCreateFactory failed',
            detail: hresultText(hr),
          ),
        ],
      );
    }
    final DWriteFactory factory = DWriteFactory(raw);

    out.value = nullptr;
    final int collectionHr = factory.getSystemFontCollection(out);
    final Pointer<Void> collectionRaw = out.value;
    allocator
      ..free(iid)
      ..free(out);
    if (comFailed(collectionHr) || collectionRaw == nullptr) {
      factory.release();
      return DWriteLoad(
        faces: null,
        diagnostics: <BackendDiagnostic>[
          BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'GetSystemFontCollection failed',
            detail: hresultText(collectionHr),
          ),
        ],
      );
    }

    final DWriteLoad load = DWriteLoad(
      faces: DWriteFontFaces._(
          factory, DWriteFontCollection(collectionRaw), allocator),
      diagnostics: const <BackendDiagnostic>[],
    );
    return load;
  }

  final DWriteFactory _factory;
  final DWriteFontCollection _collection;
  final Allocator _allocator;

  /// Faces already resolved, by the typeface they stand in for. A null value
  /// is a *remembered refusal* - a face that is not installed, or one whose
  /// glyph numbering disagreed - so a page of text does not re-ask Windows and
  /// re-fail once per run.
  final Map<Typeface, DWriteFontFace?> _faces = <Typeface, DWriteFontFace?>{};

  /// Why each refused typeface was refused, for a diagnostic that would
  /// otherwise be "the option is on and nothing changed".
  final Map<Typeface, String> _refusals = <Typeface, String>{};

  /// How many typefaces have been resolved to a face, for tests.
  int get residentFaceCount =>
      _faces.values.where((DWriteFontFace? face) => face != null).length;

  /// Why [face] was refused for [typeface], or null if it was not refused.
  String? refusalFor(Typeface typeface) => _refusals[typeface];

  /// The system face that may stand in for [typeface], or null.
  ///
  /// Null means "draw this run the portable way", and it is a normal answer:
  /// the font is not installed, or Windows' copy of it numbers its glyphs
  /// differently from the bytes this framework parsed. Either way the reason
  /// is recorded in [refusalFor].
  DWriteFontFace? faceFor(Typeface typeface) {
    if (_faces.containsKey(typeface)) return _faces[typeface];
    final DWriteFontFace? resolved = _resolve(typeface);
    _faces[typeface] = resolved;
    return resolved;
  }

  DWriteFontFace? _resolve(Typeface typeface) {
    final String? family = typeface.familyName;
    if (family == null || family.isEmpty) {
      _refusals[typeface] = 'the font carries no family name in its name '
          'table, so there is nothing to look up in the system collection';
      return null;
    }

    final Pointer<Uint16> name = _utf16(family);
    final Pointer<Uint32> index =
        _allocator.allocate<Uint32>(sizeOf<Uint32>());
    final Pointer<Int32> exists = _allocator.allocate<Int32>(sizeOf<Int32>());
    exists.value = 0;
    final int hr = _collection.findFamilyName(name, index, exists);
    final bool found = !comFailed(hr) && exists.value != 0;
    final int familyIndex = index.value;
    _allocator
      ..free(name)
      ..free(index)
      ..free(exists);
    if (!found) {
      _refusals[typeface] = '"$family" is not in the system font collection; '
          'a font the application carries its own bytes for would need a '
          'custom IDWriteFontFileLoader, which this backend does not build';
      return null;
    }

    final Pointer<Pointer<Void>> out =
        _allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    out.value = nullptr;
    if (comFailed(_collection.getFontFamily(familyIndex, out)) ||
        out.value == nullptr) {
      _allocator.free(out);
      _refusals[typeface] = 'GetFontFamily failed for "$family"';
      return null;
    }
    final DWriteFontFamily fontFamily = DWriteFontFamily(out.value);

    out.value = nullptr;
    final int fontHr = fontFamily.getFirstMatchingFont(
      // Weight, width and slant come from the font's own OS/2 table - through
      // [Typeface], which already resolves the `head` fallback for a font
      // without one - so a bold face this framework loaded is matched against
      // the bold system face and not against the regular one that shares its
      // family name. `DWRITE_FONT_STRETCH` is `usWidthClass` numbered the same
      // way, 1..9, which is why this passes it straight through.
      typeface.weightClass,
      _stretchOf(typeface),
      typeface.isItalic ? dwriteFontStyleItalic : dwriteFontStyleNormal,
      out,
    );
    final Pointer<Void> fontRaw = out.value;
    fontFamily.release();
    if (comFailed(fontHr) || fontRaw == nullptr) {
      _allocator.free(out);
      _refusals[typeface] = 'GetFirstMatchingFont failed for "$family"';
      return null;
    }
    final DWriteFont font = DWriteFont(fontRaw);

    out.value = nullptr;
    final int faceHr = font.createFontFace(out);
    final Pointer<Void> faceRaw = out.value;
    font.release();
    _allocator.free(out);
    if (comFailed(faceHr) || faceRaw == nullptr) {
      _refusals[typeface] = 'CreateFontFace failed for "$family"';
      return null;
    }
    final DWriteFontFace face = DWriteFontFace(faceRaw);

    final String? disagreement = _agrees(typeface, face);
    if (disagreement != null) {
      face.release();
      _refusals[typeface] = disagreement;
      return null;
    }
    return face;
  }

  /// Null when [face] numbers its glyphs exactly as [typeface] does; the
  /// reason to refuse otherwise.
  String? _agrees(Typeface typeface, DWriteFontFace face) {
    final int theirs = face.glyphCount;
    if (theirs != typeface.glyphCount) {
      return 'the installed "${typeface.familyName}" has $theirs glyphs and '
          'the bytes this framework parsed have ${typeface.glyphCount}; the '
          'glyph ids the shaper produced would address a different font';
    }

    final int count = kDWriteIdentityProbe.length;
    final Pointer<Uint32> codePoints =
        _allocator.allocate<Uint32>(sizeOf<Uint32>() * count);
    final Pointer<Uint16> indices =
        _allocator.allocate<Uint16>(sizeOf<Uint16>() * count);
    for (var i = 0; i < count; i++) {
      (codePoints + i).value = kDWriteIdentityProbe[i];
      (indices + i).value = 0;
    }
    final int hr = face.getGlyphIndices(codePoints, count, indices);
    String? disagreement;
    if (comFailed(hr)) {
      disagreement = 'GetGlyphIndices failed: ${hresultText(hr)}';
    } else {
      for (var i = 0; i < count; i++) {
        final int codePoint = kDWriteIdentityProbe[i];
        final int ours = typeface.glyphForCodePoint(codePoint);
        final int theirGlyph = (indices + i).value;
        if (ours != theirGlyph) {
          disagreement = 'the installed "${typeface.familyName}" maps U+'
              '${codePoint.toRadixString(16).toUpperCase()} to glyph '
              '$theirGlyph and the bytes this framework parsed map it to '
              '$ours; drawing our glyph ids through that face would produce '
              'correctly spaced nonsense';
          break;
        }
      }
    }
    _allocator
      ..free(codePoints)
      ..free(indices);
    return disagreement;
  }

  /// `usWidthClass`, clamped to the range `DWRITE_FONT_STRETCH` defines.
  ///
  /// The clamp is not defensive noise: a font with a malformed OS/2 can carry
  /// 0 or 200 there, and `GetFirstMatchingFont` with a value outside 1..9
  /// fails, which would refuse a font over a field nothing about the drawing
  /// depends on.
  int _stretchOf(Typeface typeface) {
    final int width = typeface.widthClass;
    if (width < 1 || width > 9) return dwriteFontStretchNormal;
    return width;
  }

  /// A null-terminated UTF-16 copy of [text], owned by the caller.
  Pointer<Uint16> _utf16(String text) {
    final List<int> units = text.codeUnits;
    final Pointer<Uint16> out =
        _allocator.allocate<Uint16>(sizeOf<Uint16>() * (units.length + 1));
    for (var i = 0; i < units.length; i++) {
      (out + i).value = units[i];
    }
    (out + units.length).value = 0;
    return out;
  }

  void dispose() {
    for (final DWriteFontFace? face in _faces.values) {
      face?.release();
    }
    _faces.clear();
    _refusals.clear();
    _collection.release();
    _factory.release();
  }
}
