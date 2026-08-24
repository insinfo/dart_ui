/// The five DirectWrite interfaces the *optional* native-text route needs,
/// with the vtable slot written down - the same shape and the same discipline
/// as `d2d1_interfaces.dart`.
///
/// ## What this is for, and what it deliberately is not
///
/// The framework owns its text stack: shaping, OpenType, hinting policy and a
/// glyph rasteriser, all in Dart, identical on every platform. That is a
/// declared promise and DirectWrite does not get to break it. So nothing here
/// shapes, measures, breaks lines or lays anything out. The only thing these
/// bindings can do is hand Direct2D a *run this framework already resolved* -
/// our glyph ids, our advances, our origin - and let Windows rasterise the
/// glyph bodies. `doc/architecture/TEXTO_DIRECT2D.md` states why that boundary
/// is where it is, and what would break if it moved.
///
/// `IDWriteTextFormat`, `IDWriteTextLayout` and `IDWriteTextAnalyzer` are
/// therefore **not bound, on purpose**. They are the level this project does
/// not take: they would give Windows the metrics, and different metrics mean a
/// different layout, which means the same application is a different size on
/// Windows than everywhere else.
///
/// ## How to read a slot number
///
/// Every interface below derives from `IUnknown` and from nothing else except
/// where noted, so `IUnknown` takes 0..2 and the interface's own methods start
/// at 3, in header order.
///
///   * `IDWriteFactory`: `GetSystemFontCollection` 3, `CreateCustomFontCollection`
///     4, `RegisterFontCollectionLoader` 5, `UnregisterFontCollectionLoader` 6,
///     `CreateFontFileReference` 7, `CreateCustomFontFileReference` 8,
///     `CreateFontFace` 9, `CreateRenderingParams` 10,
///     `CreateMonitorRenderingParams` 11, `CreateCustomRenderingParams` 12,
///     `RegisterFontFileLoader` 13, `UnregisterFontFileLoader` 14,
///     `CreateTextFormat` 15, `CreateTypography` 16, `GetGdiInterop` 17,
///     `CreateTextLayout` 18, `CreateGdiCompatibleTextLayout` 19,
///     `CreateEllipsisTrimmingSign` 20, `CreateTextAnalyzer` 21,
///     `CreateNumberSubstitution` 22, `CreateGlyphRunAnalysis` 23.
///   * `IDWriteFontCollection`: `GetFontFamilyCount` 3, `GetFontFamily` 4,
///     `FindFamilyName` 5, `GetFontFromFontFace` 6.
///   * `IDWriteFontFamily : IDWriteFontList`, and the list contributes
///     `GetFontCollection` 3, `GetFontCount` 4, `GetFont` 5; the family then
///     adds `GetFamilyNames` 6, `GetFirstMatchingFont` 7, `GetMatchingFonts` 8.
///   * `IDWriteFont`: `GetFontFamily` 3, `GetWeight` 4, `GetStretch` 5,
///     `GetStyle` 6, `IsSymbolFont` 7, `GetFaceNames` 8,
///     `GetInformationalStrings` 9, `GetSimulations` 10, `GetMetrics` 11,
///     `HasCharacter` 12, `CreateFontFace` 13.
///   * `IDWriteFontFace`: `GetType` 3, `GetFiles` 4, `GetIndex` 5,
///     `GetSimulations` 6, `IsSymbolFont` 7, `GetMetrics` 8, `GetGlyphCount` 9,
///     `GetDesignGlyphMetrics` 10, `GetGlyphIndices` 11, `TryGetFontTable` 12,
///     `ReleaseFontTable` 13, `GetGlyphRunOutline` 14,
///     `GetRecommendedRenderingMode` 15, `GetGdiCompatibleMetrics` 16,
///     `GetGdiCompatibleGlyphMetrics` 17.
///
/// `GetMetrics` on the font and the face return a struct by value and are the
/// ABI trap `d2d1_structs.dart` describes; they stay unbound, and an unbound
/// method still occupies its slot.
///
/// `dwrite_probe_test.dart` calls the whole chain against the real
/// `dwrite.dll`, which is the check on this arithmetic.
library;

import 'dart:ffi';

import '../d3d12/d3d12_com.dart';

/// `IID_IDWriteFactory`, as `dwrite.h` declares it.
const String iidDWriteFactory = 'B859EE5A-D838-4B5B-A2E8-1ADC7D93DB48';

/// `DWRITE_FACTORY_TYPE_SHARED`: the process-wide factory, which is what a
/// process that draws text wants - a private one would build a second font
/// cache beside the one Windows already has.
const int dwriteFactoryTypeShared = 0;

/// `DWRITE_FONT_WEIGHT_NORMAL`.
const int dwriteFontWeightNormal = 400;

/// `DWRITE_FONT_WEIGHT_BOLD`.
const int dwriteFontWeightBold = 700;

/// `DWRITE_FONT_STRETCH_NORMAL`.
const int dwriteFontStretchNormal = 5;

/// `DWRITE_FONT_STYLE_NORMAL`.
const int dwriteFontStyleNormal = 0;

/// `DWRITE_FONT_STYLE_ITALIC`.
const int dwriteFontStyleItalic = 2;

/// `DWRITE_MEASURING_MODE_NATURAL`: place glyphs at their design advances,
/// which is the only mode that can honour advances this framework computed.
///
/// The GDI-compatible modes re-grid-fit advances to whole pixels using
/// DirectWrite's own rules, which is exactly the substitution of metrics this
/// route exists to avoid.
const int dwriteMeasuringModeNatural = 0;

/// `DWRITE_GLYPH_OFFSET`: a per-glyph nudge, along the run and across it.
final class DWriteGlyphOffset extends Struct {
  @Float()
  external double advanceOffset;

  /// Positive is *up*, which is the opposite of this framework's y axis. The
  /// sink negates on the way in; see `d2d_raster_sink.dart`.
  @Float()
  external double ascenderOffset;
}

/// `DWRITE_GLYPH_RUN`: one run of glyph ids at one size in one face.
///
/// The whole contract of the native-text route lives in this structure. Every
/// field is filled from what this framework already decided - the face, the em
/// size, the glyph ids the shaper chose, the advances the metrics gave - so
/// Windows is told where each glyph goes rather than asked.
final class DWriteGlyphRun extends Struct {
  external Pointer<Void> fontFace;

  @Float()
  external double fontEmSize;

  @Uint32()
  external int glyphCount;

  /// `UINT16 const*`. Glyph ids, not code points.
  external Pointer<Uint16> glyphIndices;

  /// `FLOAT const*`, or null for the face's own advances - which this sink
  /// never passes, because the whole point is that the advances are ours.
  external Pointer<Float> glyphAdvances;

  /// `DWRITE_GLYPH_OFFSET const*`, or null for no offsets.
  external Pointer<DWriteGlyphOffset> glyphOffsets;

  @Int32()
  external int isSideways;

  @Uint32()
  external int bidiLevel;
}

/// `IDWriteFactory`.
final class DWriteFactory {
  DWriteFactory(this.pointer)
      : _getSystemFontCollection = comMethod<
                    Int32 Function(
                        Pointer<Void>, Pointer<Pointer<Void>>, Int32)>(
                pointer, 3)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Pointer<Void>>, int)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, Pointer<Pointer<Void>>, int)
      _getSystemFontCollection;

  /// The fonts installed on this machine.
  ///
  /// [checkForUpdates] false is deliberate: true makes the call cross to the
  /// font cache service, which is measured in milliseconds and would be paid
  /// on a path that runs while a frame is being drawn.
  int getSystemFontCollection(
    Pointer<Pointer<Void>> out, {
    bool checkForUpdates = false,
  }) =>
      _getSystemFontCollection(pointer, out, checkForUpdates ? 1 : 0);

  void release() => ComObject(pointer).release();
}

/// `IDWriteFontCollection`.
final class DWriteFontCollection {
  DWriteFontCollection(this.pointer)
      : _getFontFamily = comMethod<
                    Int32 Function(
                        Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(
                pointer, 4)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>(),
        _findFamilyName = comMethod<
                    Int32 Function(Pointer<Void>, Pointer<Uint16>,
                        Pointer<Uint32>, Pointer<Int32>)>(pointer, 5)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>,
                    Pointer<Int32>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>) _getFontFamily;
  final int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>,
      Pointer<Int32>) _findFamilyName;

  int getFontFamily(int index, Pointer<Pointer<Void>> out) =>
      _getFontFamily(pointer, index, out);

  /// Looks up a family by its UTF-16 name.
  ///
  /// [exists] is the answer that matters and it is **not** an error code: a
  /// name Windows does not have returns `S_OK` with `exists` false, so a
  /// caller that only checked the `HRESULT` would go on to use index 0 - some
  /// unrelated font, drawn confidently.
  int findFamilyName(
    Pointer<Uint16> name,
    Pointer<Uint32> index,
    Pointer<Int32> exists,
  ) =>
      _findFamilyName(pointer, name, index, exists);

  void release() => ComObject(pointer).release();
}

/// `IDWriteFontFamily`. Slots continue after `IDWriteFontList`'s 3..5.
final class DWriteFontFamily {
  DWriteFontFamily(this.pointer)
      : _getFirstMatchingFont = comMethod<
                    Int32 Function(Pointer<Void>, Int32, Int32, Int32,
                        Pointer<Pointer<Void>>)>(pointer, 7)
            .asFunction<
                int Function(Pointer<Void>, int, int, int,
                    Pointer<Pointer<Void>>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, int, int, int, Pointer<Pointer<Void>>)
      _getFirstMatchingFont;

  int getFirstMatchingFont(
    int weight,
    int stretch,
    int style,
    Pointer<Pointer<Void>> out,
  ) =>
      _getFirstMatchingFont(pointer, weight, stretch, style, out);

  void release() => ComObject(pointer).release();
}

/// `IDWriteFont`.
final class DWriteFont {
  DWriteFont(this.pointer)
      : _createFontFace = comMethod<
                    Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(
                pointer, 13)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _createFontFace;

  int createFontFace(Pointer<Pointer<Void>> out) =>
      _createFontFace(pointer, out);

  void release() => ComObject(pointer).release();
}

/// `IDWriteFontFace`: the object `DWRITE_GLYPH_RUN` points at.
final class DWriteFontFace {
  DWriteFontFace(this.pointer)
      : _getGlyphCount = comMethod<Uint16 Function(Pointer<Void>)>(pointer, 9)
            .asFunction<int Function(Pointer<Void>)>(),
        _getGlyphIndices = comMethod<
                    Int32 Function(Pointer<Void>, Pointer<Uint32>, Uint32,
                        Pointer<Uint16>)>(pointer, 11)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Uint32>, int,
                    Pointer<Uint16>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>) _getGlyphCount;
  final int Function(Pointer<Void>, Pointer<Uint32>, int, Pointer<Uint16>)
      _getGlyphIndices;

  /// How many glyphs the face has. The first half of the identity check
  /// `dwrite_font_faces.dart` makes before it lets a face stand in for one of
  /// ours.
  int get glyphCount => _getGlyphCount(pointer);

  /// Windows' `cmap` lookup, for the other half of that check.
  int getGlyphIndices(
    Pointer<Uint32> codePoints,
    int count,
    Pointer<Uint16> out,
  ) =>
      _getGlyphIndices(pointer, codePoints, count, out);

  void release() => ComObject(pointer).release();
}
