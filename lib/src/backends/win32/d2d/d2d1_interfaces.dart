/// One thin Dart class per Direct2D COM interface, with the vtable slot
/// written down - the same shape, and the same discipline, as
/// `d3d12_interfaces.dart`.
///
/// ## How to read a slot number
///
/// A COM vtable is the flattened list of every method the interface and its
/// bases declare, base first. Direct2D's chains, counted out once here and
/// referenced by every class below:
///
///   * `IUnknown` contributes slots 0..2.
///   * `ID2D1Resource` adds `GetFactory` at 3.
///   * `ID2D1RenderTarget : ID2D1Resource` declares its own methods from
///     slot 4 (`CreateBitmap`) through 56 (`IsSupported`), in header order.
///   * `ID2D1HwndRenderTarget : ID2D1RenderTarget` adds `CheckWindowState`
///     57, `Resize` 58, `GetHwnd` 59. The proof-of-concept
///     `poc/poc_05_com_direct2d` drove a window through exactly these
///     numbers, which is the independent check on the arithmetic.
///   * `ID2D1DCRenderTarget : ID2D1RenderTarget` adds `BindDC` 57.
///   * `ID2D1DeviceContext : ID2D1RenderTarget` adds its own 35 methods at
///     57..91, `ID2D1DeviceContext1` three more at 92..94,
///     `ID2D1DeviceContext2` eleven at 95..105, and `ID2D1DeviceContext3`
///     `CreateSpriteBatch` 106 and `DrawSpriteBatch` 107. The chain is counted
///     out method by method above [D2dDeviceContext3], because a slot reached
///     through five inheritance levels is not something to take on trust. The
///     check on the arithmetic is that both are called against the real
///     runtime: `d2d_device_context_probe_test.dart` asks a live target which
///     of the chain it answers to, and `d2d_glyph_transform_test.dart` draws
///     the same run through the batch and around it and compares the pixels.
///   * `ID2D1SpriteBatch : ID2D1Resource` adds `AddSprites` 4, `SetSprites` 5,
///     `GetSprites` 6, `GetSpriteCount` 7, `Clear` 8.
///   * `ID2D1Bitmap : ID2D1Image : ID2D1Resource` - `ID2D1Image` declares no
///     methods at all, so the bitmap's own start right after `GetFactory`:
///     `GetSize` 4, `GetPixelSize` 5, `GetPixelFormat` 6, `GetDpi` 7,
///     `CopyFromBitmap` 8, `CopyFromRenderTarget` 9, `CopyFromMemory` 10.
///     The first four are the by-value-return trap and stay unbound; a
///     method that is not bound still occupies its slot.
///   * `ID2D1Geometry : ID2D1Resource` runs 4..16;
///     `ID2D1PathGeometry` adds `Open` 17, `Stream` 18, counts 19..20.
///   * `ID2D1SimplifiedGeometrySink : IUnknown` runs 3..9;
///     `ID2D1GeometrySink` adds `AddLine` 10 through `AddArc` 14.
///   * `ID2D1Brush : ID2D1Resource` runs 4..7; `ID2D1SolidColorBrush` adds
///     `SetColor` 8, `GetColor` 9.
///
/// The three render-target methods that return small structs by value
/// (`GetSize`, `GetPixelSize`, `GetPixelFormat`) are not bound - see
/// `d2d1_structs.dart` for why that ABI is a trap and why nothing here needs
/// them.
library;

import 'dart:ffi';

import '../d3d12/d3d12_com.dart';
import 'd2d1_structs.dart';
import 'dwrite_interfaces.dart' show DWriteGlyphRun;

/// `ID2D1Factory`. Slots: IUnknown 3, `ReloadSystemMetrics` 3... no -
/// IUnknown is 0..2, then `ReloadSystemMetrics` 3, `GetDesktopDpi` 4, the
/// geometry constructors 5..9, `CreatePathGeometry` 10, `CreateStrokeStyle`
/// 11, `CreateDrawingStateBlock` 12, `CreateWicBitmapRenderTarget` 13,
/// `CreateHwndRenderTarget` 14, `CreateDxgiSurfaceRenderTarget` 15,
/// `CreateDCRenderTarget` 16.
final class D2dFactory {
  D2dFactory(this.pointer)
      : _createPathGeometry = comMethod<
                Int32 Function(
                    Pointer<Void>, Pointer<Pointer<Void>>)>(pointer, 10)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>(),
        _createStrokeStyle = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D2dStrokeStyleProperties>,
                    Pointer<Float>,
                    Uint32,
                    Pointer<Pointer<Void>>)>(pointer, 11)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dStrokeStyleProperties>,
                    Pointer<Float>, int, Pointer<Pointer<Void>>)>(),
        _createHwndRenderTarget = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D2dRenderTargetProperties>,
                    Pointer<D2dHwndRenderTargetProperties>,
                    Pointer<Pointer<Void>>)>(pointer, 14)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<D2dRenderTargetProperties>,
                    Pointer<D2dHwndRenderTargetProperties>,
                    Pointer<Pointer<Void>>)>(),
        _createDcRenderTarget = comMethod<
                Int32 Function(Pointer<Void>, Pointer<D2dRenderTargetProperties>,
                    Pointer<Pointer<Void>>)>(pointer, 16)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dRenderTargetProperties>,
                    Pointer<Pointer<Void>>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _createPathGeometry;
  final int Function(Pointer<Void>, Pointer<D2dStrokeStyleProperties>,
      Pointer<Float>, int, Pointer<Pointer<Void>>) _createStrokeStyle;
  final int Function(
      Pointer<Void>,
      Pointer<D2dRenderTargetProperties>,
      Pointer<D2dHwndRenderTargetProperties>,
      Pointer<Pointer<Void>>) _createHwndRenderTarget;
  final int Function(Pointer<Void>, Pointer<D2dRenderTargetProperties>,
      Pointer<Pointer<Void>>) _createDcRenderTarget;

  int createPathGeometry(Pointer<Pointer<Void>> out) =>
      _createPathGeometry(pointer, out);

  /// [dashes] may be `nullptr` with [dashCount] 0 for a solid stroke.
  int createStrokeStyle(
    Pointer<D2dStrokeStyleProperties> properties,
    Pointer<Float> dashes,
    int dashCount,
    Pointer<Pointer<Void>> out,
  ) =>
      _createStrokeStyle(pointer, properties, dashes, dashCount, out);

  int createHwndRenderTarget(
    Pointer<D2dRenderTargetProperties> targetProperties,
    Pointer<D2dHwndRenderTargetProperties> hwndProperties,
    Pointer<Pointer<Void>> out,
  ) =>
      _createHwndRenderTarget(pointer, targetProperties, hwndProperties, out);

  int createDcRenderTarget(
    Pointer<D2dRenderTargetProperties> targetProperties,
    Pointer<Pointer<Void>> out,
  ) =>
      _createDcRenderTarget(pointer, targetProperties, out);

  void release() => ComObject(pointer).release();
}

/// `ID2D1RenderTarget` - the drawing surface both concrete targets share.
///
/// Slots: IUnknown 3 + `ID2D1Resource::GetFactory` = 4 inherited, then the
/// render target's own methods in header order. The constants below *are* the
/// ABI; the arithmetic is stated in the library comment.
final class D2dRenderTarget {
  D2dRenderTarget(this.pointer)
      : _createBitmap = comMethod<
                Int32 Function(Pointer<Void>, D2dSizeU, Pointer<Void>, Uint32,
                    Pointer<D2dBitmapProperties>, Pointer<Pointer<Void>>)>(
                pointer, 4)
            .asFunction<
                int Function(Pointer<Void>, D2dSizeU, Pointer<Void>, int,
                    Pointer<D2dBitmapProperties>, Pointer<Pointer<Void>>)>(),
        _createSolidColorBrush = comMethod<
                Int32 Function(Pointer<Void>, Pointer<D2dColorF>,
                    Pointer<D2dBrushProperties>, Pointer<Pointer<Void>>)>(
                pointer, 8)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dColorF>,
                    Pointer<D2dBrushProperties>, Pointer<Pointer<Void>>)>(),
        _createGradientStopCollection = comMethod<
                Int32 Function(Pointer<Void>, Pointer<D2dGradientStop>, Uint32,
                    Uint32, Uint32, Pointer<Pointer<Void>>)>(pointer, 9)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dGradientStop>, int, int,
                    int, Pointer<Pointer<Void>>)>(),
        _createLinearGradientBrush = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D2dLinearGradientBrushProperties>,
                    Pointer<D2dBrushProperties>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(pointer, 10)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<D2dLinearGradientBrushProperties>,
                    Pointer<D2dBrushProperties>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(),
        _createRadialGradientBrush = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D2dRadialGradientBrushProperties>,
                    Pointer<D2dBrushProperties>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(pointer, 11)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<D2dRadialGradientBrushProperties>,
                    Pointer<D2dBrushProperties>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(),
        _createLayer = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Void>,
                    Pointer<Pointer<Void>>)>(pointer, 13)
            .asFunction<
                int Function(
                    Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)>(),
        _fillRectangle = comMethod<
                Void Function(Pointer<Void>, Pointer<D2dRectF>,
                    Pointer<Void>)>(pointer, 17)
            .asFunction<
                void Function(
                    Pointer<Void>, Pointer<D2dRectF>, Pointer<Void>)>(),
        _fillRoundedRectangle = comMethod<
                Void Function(Pointer<Void>, Pointer<D2dRoundedRect>,
                    Pointer<Void>)>(pointer, 19)
            .asFunction<
                void Function(
                    Pointer<Void>, Pointer<D2dRoundedRect>, Pointer<Void>)>(),
        _drawGeometry = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    Float, Pointer<Void>)>(pointer, 22)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    double, Pointer<Void>)>(),
        _fillGeometry = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    Pointer<Void>)>(pointer, 23)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    Pointer<Void>)>(),
        _fillOpacityMask = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    Uint32, Pointer<D2dRectF>, Pointer<D2dRectF>)>(pointer, 25)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int,
                    Pointer<D2dRectF>, Pointer<D2dRectF>)>(),
        _drawBitmap = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<D2dRectF>,
                    Float, Uint32, Pointer<D2dRectF>)>(pointer, 26)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, Pointer<D2dRectF>,
                    double, int, Pointer<D2dRectF>)>(),
        _drawGlyphRun = comMethod<
                    Void Function(Pointer<Void>, D2dPoint2F,
                        Pointer<DWriteGlyphRun>, Pointer<Void>, Int32)>(
                pointer, 29)
            .asFunction<
                void Function(Pointer<Void>, D2dPoint2F,
                    Pointer<DWriteGlyphRun>, Pointer<Void>, int)>(),
        _setTextAntialiasMode =
            comMethod<Void Function(Pointer<Void>, Uint32)>(pointer, 34)
                .asFunction<void Function(Pointer<Void>, int)>(),
        _setTransform = comMethod<
                Void Function(
                    Pointer<Void>, Pointer<D2dMatrix3x2F>)>(pointer, 30)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D2dMatrix3x2F>)>(),
        _setAntialiasMode =
            comMethod<Void Function(Pointer<Void>, Uint32)>(pointer, 32)
                .asFunction<void Function(Pointer<Void>, int)>(),
        _pushLayer = comMethod<
                Void Function(Pointer<Void>, Pointer<D2dLayerParameters>,
                    Pointer<Void>)>(pointer, 40)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D2dLayerParameters>,
                    Pointer<Void>)>(),
        _popLayer = comMethod<Void Function(Pointer<Void>)>(pointer, 41)
            .asFunction<void Function(Pointer<Void>)>(),
        _flush = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Uint64>,
                    Pointer<Uint64>)>(pointer, 42)
            .asFunction<
                int Function(
                    Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>)>(),
        _pushAxisAlignedClip = comMethod<
                Void Function(
                    Pointer<Void>, Pointer<D2dRectF>, Uint32)>(pointer, 45)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D2dRectF>, int)>(),
        _popAxisAlignedClip =
            comMethod<Void Function(Pointer<Void>)>(pointer, 46)
                .asFunction<void Function(Pointer<Void>)>(),
        _clear = comMethod<Void Function(Pointer<Void>, Pointer<D2dColorF>)>(
                pointer, 47)
            .asFunction<void Function(Pointer<Void>, Pointer<D2dColorF>)>(),
        _beginDraw = comMethod<Void Function(Pointer<Void>)>(pointer, 48)
            .asFunction<void Function(Pointer<Void>)>(),
        _endDraw = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Uint64>,
                    Pointer<Uint64>)>(pointer, 49)
            .asFunction<
                int Function(
                    Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, D2dSizeU, Pointer<Void>, int,
      Pointer<D2dBitmapProperties>, Pointer<Pointer<Void>>) _createBitmap;
  final int Function(Pointer<Void>, Pointer<D2dColorF>,
      Pointer<D2dBrushProperties>, Pointer<Pointer<Void>>)
      _createSolidColorBrush;
  final int Function(Pointer<Void>, Pointer<D2dGradientStop>, int, int, int,
      Pointer<Pointer<Void>>) _createGradientStopCollection;
  final int Function(
      Pointer<Void>,
      Pointer<D2dLinearGradientBrushProperties>,
      Pointer<D2dBrushProperties>,
      Pointer<Void>,
      Pointer<Pointer<Void>>) _createLinearGradientBrush;
  final int Function(
      Pointer<Void>,
      Pointer<D2dRadialGradientBrushProperties>,
      Pointer<D2dBrushProperties>,
      Pointer<Void>,
      Pointer<Pointer<Void>>) _createRadialGradientBrush;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>)
      _createLayer;
  final void Function(Pointer<Void>, Pointer<D2dRectF>, Pointer<Void>)
      _fillRectangle;
  final void Function(Pointer<Void>, Pointer<D2dRoundedRect>, Pointer<Void>)
      _fillRoundedRectangle;
  final void Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>, double, Pointer<Void>)
      _drawGeometry;
  final void Function(
          Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Void>)
      _fillGeometry;
  final void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int,
      Pointer<D2dRectF>, Pointer<D2dRectF>) _fillOpacityMask;
  final void Function(Pointer<Void>, Pointer<Void>, Pointer<D2dRectF>, double,
      int, Pointer<D2dRectF>) _drawBitmap;
  final void Function(Pointer<Void>, D2dPoint2F, Pointer<DWriteGlyphRun>,
      Pointer<Void>, int) _drawGlyphRun;
  final void Function(Pointer<Void>, int) _setTextAntialiasMode;
  final void Function(Pointer<Void>, Pointer<D2dMatrix3x2F>) _setTransform;
  final void Function(Pointer<Void>, int) _setAntialiasMode;
  final void Function(Pointer<Void>, Pointer<D2dLayerParameters>,
      Pointer<Void>) _pushLayer;
  final void Function(Pointer<Void>) _popLayer;
  final int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>) _flush;
  final void Function(Pointer<Void>, Pointer<D2dRectF>, int)
      _pushAxisAlignedClip;
  final void Function(Pointer<Void>) _popAxisAlignedClip;
  final void Function(Pointer<Void>, Pointer<D2dColorF>) _clear;
  final void Function(Pointer<Void>) _beginDraw;
  final int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>) _endDraw;

  /// [size] crosses by value; see `d2d1_structs.dart`.
  int createBitmap(
    D2dSizeU size,
    Pointer<Void> sourceData,
    int pitch,
    Pointer<D2dBitmapProperties> properties,
    Pointer<Pointer<Void>> out,
  ) =>
      _createBitmap(pointer, size, sourceData, pitch, properties, out);

  int createSolidColorBrush(
    Pointer<D2dColorF> color,
    Pointer<Pointer<Void>> out,
  ) =>
      _createSolidColorBrush(pointer, color, nullptr, out);

  int createGradientStopCollection(
    Pointer<D2dGradientStop> stops,
    int stopCount,
    int gamma,
    int extendMode,
    Pointer<Pointer<Void>> out,
  ) =>
      _createGradientStopCollection(
          pointer, stops, stopCount, gamma, extendMode, out);

  int createLinearGradientBrush(
    Pointer<D2dLinearGradientBrushProperties> properties,
    Pointer<Void> stopCollection,
    Pointer<Pointer<Void>> out,
  ) =>
      _createLinearGradientBrush(
          pointer, properties, nullptr, stopCollection, out);

  int createRadialGradientBrush(
    Pointer<D2dRadialGradientBrushProperties> properties,
    Pointer<Void> stopCollection,
    Pointer<Pointer<Void>> out,
  ) =>
      _createRadialGradientBrush(
          pointer, properties, nullptr, stopCollection, out);

  /// [size] is `nullptr` to let the layer size itself on first push.
  int createLayer(Pointer<Void> size, Pointer<Pointer<Void>> out) =>
      _createLayer(pointer, size, out);

  void fillRectangle(Pointer<D2dRectF> rect, Pointer<Void> brush) =>
      _fillRectangle(pointer, rect, brush);

  void fillRoundedRectangle(
          Pointer<D2dRoundedRect> roundedRect, Pointer<Void> brush) =>
      _fillRoundedRectangle(pointer, roundedRect, brush);

  void drawGeometry(
    Pointer<Void> geometry,
    Pointer<Void> brush,
    double strokeWidth,
    Pointer<Void> strokeStyle,
  ) =>
      _drawGeometry(pointer, geometry, brush, strokeWidth, strokeStyle);

  void fillGeometry(Pointer<Void> geometry, Pointer<Void> brush) =>
      _fillGeometry(pointer, geometry, brush, nullptr);

  /// Requires the aliased antialias mode; the caller switches around it.
  void fillOpacityMask(
    Pointer<Void> maskBitmap,
    Pointer<Void> brush,
    Pointer<D2dRectF> destination,
    Pointer<D2dRectF> source,
  ) =>
      _fillOpacityMask(pointer, maskBitmap, brush,
          d2d1OpacityMaskContentGraphics, destination, source);

  void drawBitmap(
    Pointer<Void> bitmap,
    Pointer<D2dRectF> destination,
    double opacity,
    int interpolationMode,
    Pointer<D2dRectF> source,
  ) =>
      _drawBitmap(
          pointer, bitmap, destination, opacity, interpolationMode, source);

  /// `DrawGlyphRun`, the one entry point of the optional native-text route.
  ///
  /// This is the *only* DirectWrite-shaped call in this backend, and the
  /// narrowness is the design: it takes a run that has already been shaped,
  /// measured and placed by this framework and asks Windows to fill the glyph
  /// bodies. `dwrite_interfaces.dart` states the boundary and why it is there.
  ///
  /// [baselineOrigin] crosses by value; see `d2d1_structs.dart`.
  void drawGlyphRun(
    D2dPoint2F baselineOrigin,
    Pointer<DWriteGlyphRun> glyphRun,
    Pointer<Void> foregroundBrush,
    int measuringMode,
  ) =>
      _drawGlyphRun(
          pointer, baselineOrigin, glyphRun, foregroundBrush, measuringMode);

  /// Which of ClearType, greyscale or aliased [drawGlyphRun] may use.
  ///
  /// Advisory, not a guarantee, and that is Direct2D's behaviour rather than
  /// this binding's: it drops from ClearType to greyscale on its own wherever
  /// subpixel coverage cannot be composited correctly - a non-axis-aligned
  /// transform, a target whose alpha mode is not ignore, anything inside a
  /// layer. Asking for ClearType where those hold produces greyscale, silently
  /// and correctly.
  void setTextAntialiasMode(int mode) =>
      _setTextAntialiasMode(pointer, mode);

  void setTransform(Pointer<D2dMatrix3x2F> matrix) =>
      _setTransform(pointer, matrix);

  void setAntialiasMode(int mode) => _setAntialiasMode(pointer, mode);

  void pushLayer(Pointer<D2dLayerParameters> parameters, Pointer<Void> layer) =>
      _pushLayer(pointer, parameters, layer);

  void popLayer() => _popLayer(pointer);

  int flush() => _flush(pointer, nullptr, nullptr);

  void pushAxisAlignedClip(Pointer<D2dRectF> rect, int antialiasMode) =>
      _pushAxisAlignedClip(pointer, rect, antialiasMode);

  void popAxisAlignedClip() => _popAxisAlignedClip(pointer);

  void clear(Pointer<D2dColorF> color) => _clear(pointer, color);

  void beginDraw() => _beginDraw(pointer);

  /// Returns the raw `HRESULT`. `D2DERR_RECREATE_TARGET` is the device-lost
  /// signal and must be mapped, not thrown; see `d2d_targets.dart`.
  int endDraw() => _endDraw(pointer, nullptr, nullptr);

  /// The [D2dDeviceContext3] this target also is, or null where it is not.
  ///
  /// Asked of the object rather than inferred from which factory method made
  /// it - see [D2dDeviceContext3] for why those two can disagree. The returned
  /// context holds a reference of its own and the caller must [release] it.
  ///
  /// Null is a normal answer, not a failure: it means this `d2d1.dll` predates
  /// the sprite batch, and the caller's fallback is the route it already had.
  D2dDeviceContext3? queryDeviceContext3(Allocator allocator) {
    final Pointer<Guid> iid = allocator.allocate<Guid>(sizeOf<Guid>());
    final Pointer<Pointer<Void>> out =
        allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
    writeGuid(iid, iidD2d1DeviceContext3);
    out.value = nullptr;
    final int hr = ComObject(pointer).queryInterface(iid, out);
    final Pointer<Void> raw = out.value;
    allocator
      ..free(iid)
      ..free(out);
    if (comFailed(hr) || raw == nullptr) return null;
    return D2dDeviceContext3(raw);
  }

  void release() => ComObject(pointer).release();
}

/// `IID_ID2D1DeviceContext3`, as `d2d1_3.h` declares it.
const String iidD2d1DeviceContext3 = '235A7496-8351-414C-BCD4-6672AB2D8E00';

/// `ID2D1Bitmap`, bound for the one method a glyph atlas needs.
///
/// [copyFromMemory] is what makes an atlas an atlas: a slot is rewritten in
/// place instead of the whole texture being recreated, so admitting one glyph
/// costs its own texels and not four megabytes.
///
/// ## The ordering rule this method carries
///
/// Direct2D batches drawing commands until `Flush` or `EndDraw`. A batched
/// command that samples this bitmap reads the texels *as they are when the
/// batch runs*, not as they were when the command was recorded, so overwriting
/// a slot that an already-recorded draw points at repaints that draw with the
/// new glyph. The caller must `Flush` before writing texels the frame has
/// already sampled; `d2d_raster_sink.dart` states where it does that and why.
final class D2dBitmap {
  D2dBitmap(this.pointer)
      : _copyFromMemory = comMethod<
                    Int32 Function(
                        Pointer<Void>, Pointer<D2dRectU>, Pointer<Void>,
                        Uint32)>(pointer, 10)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D2dRectU>, Pointer<Void>,
                    int)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, Pointer<D2dRectU>, Pointer<Void>, int)
      _copyFromMemory;

  /// Writes [pitch]-strided pixels into [destination], or into the whole
  /// bitmap when [destination] is `nullptr`.
  ///
  /// [source] points at the pixel that lands in [destination]'s top-left
  /// corner, not at the start of the caller's buffer: the copy walks
  /// [pitch] bytes per row through whatever it is given.
  int copyFromMemory(
    Pointer<D2dRectU> destination,
    Pointer<Void> source,
    int pitch,
  ) =>
      _copyFromMemory(pointer, destination, source, pitch);

  void release() => ComObject(pointer).release();
}

/// `ID2D1DeviceContext3`, reached by `QueryInterface` from a render target.
///
/// ## Why this is a QueryInterface and not a different constructor
///
/// The targets in `d2d_targets.dart` are made by `ID2D1Factory`'s Direct2D 1.0
/// constructors, which are declared to return `ID2D1HwndRenderTarget` and
/// `ID2D1DCRenderTarget`. On every Windows that ships `d2d1.dll` with the 1.1
/// object model - Windows 8 and later - the object behind those pointers *is*
/// the object a device context is, so it answers `QueryInterface` for the
/// whole `ID2D1DeviceContext` chain. That is a property of the runtime and not
/// of the call that made the object, so it is probed rather than assumed:
/// [D2dRenderTarget.queryDeviceContext3] returns null where the answer is no,
/// and the glyph route keeps its per-glyph blits there.
///
/// Only the two sprite-batch methods are bound. The rest of the chain is real
/// and reachable, and a bound method nothing calls is a slot number nobody
/// checks.
///
/// ## Slots
///
/// `ID2D1RenderTarget` ends at 56. `ID2D1DeviceContext` then declares, in
/// header order: `CreateBitmap` 57, `CreateBitmapFromWicBitmap` 58,
/// `CreateColorContext` 59, `CreateColorContextFromFilename` 60,
/// `CreateColorContextFromWicColorContext` 61,
/// `CreateBitmapFromDxgiSurface` 62, `CreateEffect` 63,
/// `CreateGradientStopCollection` 64, `CreateImageBrush` 65,
/// `CreateBitmapBrush` 66, `CreateCommandList` 67, `IsDxgiFormatSupported` 68,
/// `IsBufferPrecisionSupported` 69, `GetImageLocalBounds` 70,
/// `GetImageWorldBounds` 71, `GetGlyphRunWorldBounds` 72, `GetDevice` 73,
/// `SetTarget` 74, `GetTarget` 75, `SetRenderingControls` 76,
/// `GetRenderingControls` 77, `SetPrimitiveBlend` 78, `GetPrimitiveBlend` 79,
/// `SetUnitMode` 80, `GetUnitMode` 81, `DrawGlyphRun` 82, `DrawImage` 83,
/// `DrawGdiMetafile` 84, `DrawBitmap` 85, `PushLayer` 86,
/// `InvalidateEffectInputRectangle` 87, `GetEffectInvalidRectangleCount` 88,
/// `GetEffectInvalidRectangles` 89, `GetEffectRequiredInputRectangles` 90,
/// `FillOpacityMask` 91.
///
/// `ID2D1DeviceContext1` adds `CreateFilledGeometryRealization` 92,
/// `CreateStrokedGeometryRealization` 93, `DrawGeometryRealization` 94.
///
/// `ID2D1DeviceContext2` adds `CreateInk` 95, `CreateInkStyle` 96,
/// `CreateGradientMesh` 97, `CreateImageSourceFromWic` 98,
/// `CreateLookupTable3D` 99, `CreateImageSourceFromDxgi` 100,
/// `GetGradientMeshWorldBounds` 101, `DrawInk` 102, `DrawGradientMesh` 103,
/// `DrawGdiMetafile` 104, `CreateTransformedImageSource` 105.
///
/// `ID2D1DeviceContext3` adds `CreateSpriteBatch` **106** and
/// `DrawSpriteBatch` **107**.
final class D2dDeviceContext3 {
  D2dDeviceContext3(this.pointer)
      : _createSpriteBatch = comMethod<
                    Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>)>(
                pointer, 106)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>(),
        _drawSpriteBatch = comMethod<
                    Void Function(Pointer<Void>, Pointer<Void>, Uint32, Uint32,
                        Pointer<Void>, Int32, Int32)>(pointer, 107)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>, int, int,
                    Pointer<Void>, int, int)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _createSpriteBatch;
  final void Function(
          Pointer<Void>, Pointer<Void>, int, int, Pointer<Void>, int, int)
      _drawSpriteBatch;

  int createSpriteBatch(Pointer<Pointer<Void>> out) =>
      _createSpriteBatch(pointer, out);

  /// Draws [spriteCount] sprites of [batch], starting at [startIndex], all
  /// sampled from [bitmap].
  ///
  /// The full vtable form, with the range explicit: the two-argument spelling
  /// in `d2d1_3.h` is an inline C++ helper that fills the range in, not a
  /// second slot.
  void drawSpriteBatch(
    Pointer<Void> batch,
    int startIndex,
    int spriteCount,
    Pointer<Void> bitmap,
    int interpolationMode,
    int spriteOptions,
  ) =>
      _drawSpriteBatch(pointer, batch, startIndex, spriteCount, bitmap,
          interpolationMode, spriteOptions);

  void release() => ComObject(pointer).release();
}

/// `ID2D1SpriteBatch`: the array of sprites one [D2dDeviceContext3] draw call
/// consumes.
///
/// A batch is a *resource*, not a command: it is filled with [addSprites],
/// emptied with [clear] and reused, so a steady-state frame costs no COM
/// allocation.
///
/// Slots: IUnknown 0..2, `ID2D1Resource::GetFactory` 3, then `AddSprites` 4,
/// `SetSprites` 5, `GetSprites` 6, `GetSpriteCount` 7, `Clear` 8.
final class D2dSpriteBatch {
  D2dSpriteBatch(this.pointer)
      : _addSprites = comMethod<
                    Int32 Function(
                        Pointer<Void>,
                        Uint32,
                        Pointer<D2dRectF>,
                        Pointer<D2dRectU>,
                        Pointer<D2dColorF>,
                        Pointer<D2dMatrix3x2F>,
                        Uint32,
                        Uint32,
                        Uint32,
                        Uint32)>(pointer, 4)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    int,
                    Pointer<D2dRectF>,
                    Pointer<D2dRectU>,
                    Pointer<D2dColorF>,
                    Pointer<D2dMatrix3x2F>,
                    int,
                    int,
                    int,
                    int)>(),
        _getSpriteCount = comMethod<Uint32 Function(Pointer<Void>)>(pointer, 7)
            .asFunction<int Function(Pointer<Void>)>(),
        _clear = comMethod<Void Function(Pointer<Void>)>(pointer, 8)
            .asFunction<void Function(Pointer<Void>)>();

  final Pointer<Void> pointer;

  final int Function(
      Pointer<Void>,
      int,
      Pointer<D2dRectF>,
      Pointer<D2dRectU>,
      Pointer<D2dColorF>,
      Pointer<D2dMatrix3x2F>,
      int,
      int,
      int,
      int) _addSprites;
  final int Function(Pointer<Void>) _getSpriteCount;
  final void Function(Pointer<Void>) _clear;

  /// Appends [count] sprites.
  ///
  /// Each array may be `nullptr` for "no such property", and each stride may
  /// be 0 for "every sprite reads element zero" - which is how a run of glyphs
  /// in one colour passes a single [D2dColorF] instead of [count] copies of
  /// it. A stride of 0 against a non-null pointer is the header's documented
  /// spelling of that, not a trick.
  int addSprites(
    int count,
    Pointer<D2dRectF> destinations,
    Pointer<D2dRectU> sources,
    Pointer<D2dColorF> colors,
    Pointer<D2dMatrix3x2F> transforms, {
    int destinationStride = 0,
    int sourceStride = 0,
    int colorStride = 0,
    int transformStride = 0,
  }) =>
      _addSprites(pointer, count, destinations, sources, colors, transforms,
          destinationStride, sourceStride, colorStride, transformStride);

  int get spriteCount => _getSpriteCount(pointer);

  void clear() => _clear(pointer);

  void release() => ComObject(pointer).release();
}

/// `ID2D1HwndRenderTarget`. Adds `CheckWindowState` 57, `Resize` 58.
final class D2dHwndRenderTarget {
  D2dHwndRenderTarget(this.pointer)
      : target = D2dRenderTarget(pointer),
        _checkWindowState =
            comMethod<Uint32 Function(Pointer<Void>)>(pointer, 57)
                .asFunction<int Function(Pointer<Void>)>(),
        _resize =
            comMethod<Int32 Function(Pointer<Void>, Pointer<D2dSizeU>)>(
                    pointer, 58)
                .asFunction<int Function(Pointer<Void>, Pointer<D2dSizeU>)>();

  final Pointer<Void> pointer;

  /// The shared drawing surface. One vtable, two Dart views; both views bind
  /// their slots once in their constructors.
  final D2dRenderTarget target;

  final int Function(Pointer<Void>) _checkWindowState;
  final int Function(Pointer<Void>, Pointer<D2dSizeU>) _resize;

  /// `D2D1_WINDOW_STATE` flags; bit 0 is occluded.
  int checkWindowState() => _checkWindowState(pointer);

  /// Resizes the target's back buffer. Cheap, and unlike DXGI's
  /// `ResizeBuffers` it has no outstanding-reference precondition.
  int resize(Pointer<D2dSizeU> size) => _resize(pointer, size);

  void release() => ComObject(pointer).release();
}

/// `ID2D1DCRenderTarget`. Adds `BindDC` 57.
final class D2dDcRenderTarget {
  D2dDcRenderTarget(this.pointer)
      : target = D2dRenderTarget(pointer),
        _bindDc = comMethod<
                Int32 Function(Pointer<Void>, Pointer<Void>,
                    Pointer<Win32NativeRect>)>(pointer, 57)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Void>,
                    Pointer<Win32NativeRect>)>();

  final Pointer<Void> pointer;
  final D2dRenderTarget target;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Win32NativeRect>)
      _bindDc;

  /// Points the target at [hdc], drawing into [rect] of it (device pixels).
  int bindDc(Pointer<Void> hdc, Pointer<Win32NativeRect> rect) =>
      _bindDc(pointer, hdc, rect);

  void release() => ComObject(pointer).release();
}

/// `ID2D1SolidColorBrush`. Slots: `ID2D1Brush` inherits 4..7
/// (`SetOpacity` 4, `SetTransform` 5, `GetOpacity` 6, `GetTransform` 7), then
/// `SetColor` 8.
final class D2dSolidColorBrush {
  D2dSolidColorBrush(this.pointer)
      : _setOpacity = comMethod<Void Function(Pointer<Void>, Float)>(pointer, 4)
            .asFunction<void Function(Pointer<Void>, double)>(),
        _setColor =
            comMethod<Void Function(Pointer<Void>, Pointer<D2dColorF>)>(
                    pointer, 8)
                .asFunction<void Function(Pointer<Void>, Pointer<D2dColorF>)>();

  final Pointer<Void> pointer;
  final void Function(Pointer<Void>, double) _setOpacity;
  final void Function(Pointer<Void>, Pointer<D2dColorF>) _setColor;

  void setOpacity(double opacity) => _setOpacity(pointer, opacity);

  void setColor(Pointer<D2dColorF> color) => _setColor(pointer, color);

  void release() => ComObject(pointer).release();
}

/// `ID2D1PathGeometry`. Slots: `ID2D1Geometry` inherits 4..16, then `Open` 17.
final class D2dPathGeometry {
  D2dPathGeometry(this.pointer)
      : _open = comMethod<
                Int32 Function(
                    Pointer<Void>, Pointer<Pointer<Void>>)>(pointer, 17)
            .asFunction<int Function(Pointer<Void>, Pointer<Pointer<Void>>)>();

  final Pointer<Void> pointer;
  final int Function(Pointer<Void>, Pointer<Pointer<Void>>) _open;

  /// Opens the one-shot `ID2D1GeometrySink`. A path geometry can be opened
  /// exactly once; after `Close` it is immutable, which matches [Path].
  int open(Pointer<Pointer<Void>> out) => _open(pointer, out);

  void release() => ComObject(pointer).release();
}

/// `ID2D1GeometrySink`. Slots: `ID2D1SimplifiedGeometrySink` declares
/// `SetFillMode` 3, `SetSegmentFlags` 4, `BeginFigure` 5, `AddLines` 6,
/// `AddBeziers` 7, `EndFigure` 8, `Close` 9; `ID2D1GeometrySink` adds
/// `AddLine` 10, `AddBezier` 11, `AddQuadraticBezier` 12.
final class D2dGeometrySink {
  D2dGeometrySink(this.pointer)
      : _setFillMode =
            comMethod<Void Function(Pointer<Void>, Uint32)>(pointer, 3)
                .asFunction<void Function(Pointer<Void>, int)>(),
        _beginFigure =
            comMethod<Void Function(Pointer<Void>, D2dPoint2F, Uint32)>(
                    pointer, 5)
                .asFunction<void Function(Pointer<Void>, D2dPoint2F, int)>(),
        _endFigure = comMethod<Void Function(Pointer<Void>, Uint32)>(pointer, 8)
            .asFunction<void Function(Pointer<Void>, int)>(),
        _close = comMethod<Int32 Function(Pointer<Void>)>(pointer, 9)
            .asFunction<int Function(Pointer<Void>)>(),
        _addLine = comMethod<Void Function(Pointer<Void>, D2dPoint2F)>(
                pointer, 10)
            .asFunction<void Function(Pointer<Void>, D2dPoint2F)>(),
        _addBezier = comMethod<
                Void Function(
                    Pointer<Void>, Pointer<D2dBezierSegment>)>(pointer, 11)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D2dBezierSegment>)>(),
        _addQuadraticBezier = comMethod<
                Void Function(Pointer<Void>,
                    Pointer<D2dQuadraticBezierSegment>)>(pointer, 12)
            .asFunction<
                void Function(
                    Pointer<Void>, Pointer<D2dQuadraticBezierSegment>)>();

  final Pointer<Void> pointer;
  final void Function(Pointer<Void>, int) _setFillMode;
  final void Function(Pointer<Void>, D2dPoint2F, int) _beginFigure;
  final void Function(Pointer<Void>, int) _endFigure;
  final int Function(Pointer<Void>) _close;
  final void Function(Pointer<Void>, D2dPoint2F) _addLine;
  final void Function(Pointer<Void>, Pointer<D2dBezierSegment>) _addBezier;
  final void Function(Pointer<Void>, Pointer<D2dQuadraticBezierSegment>)
      _addQuadraticBezier;

  /// Must be called before the first figure or Direct2D ignores it.
  void setFillMode(int fillMode) => _setFillMode(pointer, fillMode);

  /// [startPoint] crosses by value; see `d2d1_structs.dart`.
  void beginFigure(D2dPoint2F startPoint, int figureBegin) =>
      _beginFigure(pointer, startPoint, figureBegin);

  void endFigure(int figureEnd) => _endFigure(pointer, figureEnd);

  /// Seals the geometry. Failure here is the *first* place a degenerate
  /// figure is reported, which is why the sink's HRESULT must be checked.
  int close() => _close(pointer);

  void addLine(D2dPoint2F point) => _addLine(pointer, point);

  void addBezier(Pointer<D2dBezierSegment> segment) =>
      _addBezier(pointer, segment);

  void addQuadraticBezier(Pointer<D2dQuadraticBezierSegment> segment) =>
      _addQuadraticBezier(pointer, segment);

  void release() => ComObject(pointer).release();
}
