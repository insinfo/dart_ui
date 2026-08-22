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
