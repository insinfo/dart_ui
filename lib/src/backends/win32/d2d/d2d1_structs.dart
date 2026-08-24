/// The Direct2D structures and enum constants this backend crosses the ABI
/// with, laid out exactly as `d2d1.h` declares them.
///
/// The same decision `d3d12_structs.dart` made: structures are declared here
/// once, by hand, with the SDK field order preserved, because a wrong offset
/// is a garbage draw rather than an error. Only the structures this backend
/// actually passes are declared - Direct2D has dozens more, and an unused
/// declaration is a place for a transcription error to hide unreviewed.
///
/// ## Two structures cross by value
///
/// `D2D1_SIZE_U` (in `ID2D1RenderTarget::CreateBitmap`) and `D2D1_POINT_2F`
/// (in `ID2D1GeometrySink::BeginFigure` / `AddLine`) are eight-byte aggregates
/// passed **by value**. Under the Windows x64 convention an eight-byte struct
/// argument travels in a general-purpose register, and `dart:ffi` implements
/// that correctly for by-value struct parameters, so those two methods take
/// the struct type directly rather than a pointer. Everything else Direct2D
/// takes is a `const` reference in C++, which is a pointer in the ABI.
///
/// Methods that *return* small structs (`GetSize`, `GetPixelSize`,
/// `GetPixelFormat`) are deliberately not bound anywhere in this directory:
/// MSVC returns aggregates from non-static member functions through a hidden
/// pointer - the divergence `d3d12_interfaces.dart` documents at length for
/// descriptor handles - and this backend never needs to ask a target for a
/// size it already knows.
library;

import 'dart:ffi';

// ---------------------------------------------------------------------------
// Enum constants, with the header's names in comments
// ---------------------------------------------------------------------------

/// `D2D1_FACTORY_TYPE_SINGLE_THREADED`. This framework is single-isolate per
/// window; the multithreaded factory serialises every call for no benefit.
const int d2d1FactoryTypeSingleThreaded = 0;

/// `D2D1_RENDER_TARGET_TYPE_*`.
const int d2d1RenderTargetTypeDefault = 0;
const int d2d1RenderTargetTypeSoftware = 1;
const int d2d1RenderTargetTypeHardware = 2;

/// `D2D1_RENDER_TARGET_USAGE_NONE`.
const int d2d1RenderTargetUsageNone = 0;

/// `D2D1_FEATURE_LEVEL_DEFAULT`.
const int d2d1FeatureLevelDefault = 0;

/// `DXGI_FORMAT_B8G8R8A8_UNORM` - the one format every Direct2D render target
/// accepts and the byte order the rest of this framework already uses.
const int dxgiFormatB8G8R8A8Unorm = 87;

/// `DXGI_FORMAT_UNKNOWN`, for targets that pick their own format.
const int dxgiFormatUnknown = 0;

/// `D2D1_ALPHA_MODE_*`.
const int d2d1AlphaModeUnknown = 0;
const int d2d1AlphaModePremultiplied = 1;
const int d2d1AlphaModeStraight = 2;
const int d2d1AlphaModeIgnore = 3;

/// `D2D1_PRESENT_OPTIONS_NONE`: present on `EndDraw`, waiting for vblank.
const int d2d1PresentOptionsNone = 0;

/// `D2D1_ANTIALIAS_MODE_*`. `FillOpacityMask` requires the aliased mode, which
/// is why the sink switches to it around glyph blits and back afterwards.
const int d2d1AntialiasModePerPrimitive = 0;
const int d2d1AntialiasModeAliased = 1;

/// `D2D1_FILL_MODE_*`. Alternate is even-odd; winding is non-zero.
const int d2d1FillModeAlternate = 0;
const int d2d1FillModeWinding = 1;

/// `D2D1_FIGURE_BEGIN_*`.
const int d2d1FigureBeginFilled = 0;
const int d2d1FigureBeginHollow = 1;

/// `D2D1_FIGURE_END_*`.
const int d2d1FigureEndOpen = 0;
const int d2d1FigureEndClosed = 1;

/// `D2D1_CAP_STYLE_FLAT` - the butt cap `StrokeStyle` defaults to, which is
/// the cap the replay contract promises (see `ReplayPaint.strokeWidth`).
const int d2d1CapStyleFlat = 0;

/// `D2D1_LINE_JOIN_MITER`.
const int d2d1LineJoinMiter = 0;

/// `D2D1_DASH_STYLE_SOLID`.
const int d2d1DashStyleSolid = 0;

/// `D2D1_GAMMA_2_2`: interpolate gradient stops in the space the colours were
/// specified in, which is what the CPU rasteriser does too.
const int d2d1Gamma22 = 0;

/// `D2D1_EXTEND_MODE_CLAMP`.
const int d2d1ExtendModeClamp = 0;

/// `D2D1_BITMAP_INTERPOLATION_MODE_*`.
const int d2d1BitmapInterpolationModeNearestNeighbor = 0;
const int d2d1BitmapInterpolationModeLinear = 1;

/// `D2D1_OPACITY_MASK_CONTENT_GRAPHICS`.
const int d2d1OpacityMaskContentGraphics = 0;

/// `D2D1_LAYER_OPTIONS_NONE`.
const int d2d1LayerOptionsNone = 0;

/// `D2D1_SPRITE_OPTIONS_NONE`: sample the sprite the way any bitmap draw
/// would.
const int d2d1SpriteOptionsNone = 0;

/// `D2D1_SPRITE_OPTIONS_CLAMP_TO_SOURCE_RECTANGLE`: never sample outside the
/// sprite's own source rectangle.
///
/// The option that makes an atlas safe. Without it a sprite whose destination
/// is not a whole number of texels wide can reach past its slot and pick up
/// the neighbouring glyph; with it the fetch is clamped to the slot. The glyph
/// route places sprites on integer boundaries at 1:1 scale, so nothing should
/// reach out in the first place - this is the belt to that pair of braces.
const int d2d1SpriteOptionsClampToSourceRectangle = 1;

/// `D2D1_TEXT_ANTIALIAS_MODE_DEFAULT`: let Direct2D pick per target.
const int d2d1TextAntialiasModeDefault = 0;

/// `D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE`: subpixel coverage, where the target
/// allows it. See [D2dRenderTarget.setTextAntialiasMode] for when it does not.
const int d2d1TextAntialiasModeCleartype = 1;

/// `D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE`.
const int d2d1TextAntialiasModeGrayscale = 2;

/// `D2D1_TEXT_ANTIALIAS_MODE_ALIASED`.
const int d2d1TextAntialiasModeAliased = 3;

/// `D2D1_WINDOW_STATE_OCCLUDED` bit of `CheckWindowState`.
const int d2d1WindowStateOccluded = 1;

// ---------------------------------------------------------------------------
// HRESULTs specific to Direct2D
// ---------------------------------------------------------------------------

/// `D2DERR_RECREATE_TARGET`: the device behind the target is gone and the
/// target must be rebuilt. The Direct2D spelling of
/// `DXGI_ERROR_DEVICE_REMOVED`, and the code that turns a present failure
/// into [PresentStatus.deviceLost].
const int d2dErrRecreateTarget = 0x8899000C;

/// `D2DERR_WRONG_STATE`: a call outside begin/end, or an unbalanced push/pop.
const int d2dErrWrongState = 0x88990001;

/// The names a Direct2D diagnostic should carry, over what `hresultText`
/// already knows.
const Map<int, String> d2dHresultNames = <int, String>{
  0x88990001: 'D2DERR_WRONG_STATE',
  0x88990002: 'D2DERR_NOT_INITIALIZED',
  0x88990003: 'D2DERR_UNSUPPORTED_OPERATION',
  0x88990004: 'D2DERR_SCANNER_FAILED',
  0x88990007: 'D2DERR_ZERO_VECTOR',
  0x88990008: 'D2DERR_INTERNAL_ERROR',
  0x8899000A: 'D2DERR_INVALID_CALL',
  0x8899000C: 'D2DERR_RECREATE_TARGET',
  0x88990010: 'D2DERR_INCOMPATIBLE_BRUSH_TYPES',
  0x88990012: 'D2DERR_PUSH_POP_UNBALANCED',
  0x88990018: 'D2DERR_UNSUPPORTED_PIXEL_FORMAT',
};

// ---------------------------------------------------------------------------
// Structures
// ---------------------------------------------------------------------------

/// `D2D1_PIXEL_FORMAT`.
final class D2dPixelFormat extends Struct {
  @Uint32()
  external int format;
  @Uint32()
  external int alphaMode;
}

/// `D2D1_RENDER_TARGET_PROPERTIES`.
final class D2dRenderTargetProperties extends Struct {
  @Uint32()
  external int type;
  external D2dPixelFormat pixelFormat;

  /// 96 in this backend, always, so one device-independent pixel is exactly
  /// one physical pixel and the replay sink's device-space geometry lands
  /// where the player computed it. Passing 0 would take the desktop DPI and
  /// silently rescale everything on a HiDPI monitor.
  @Float()
  external double dpiX;
  @Float()
  external double dpiY;
  @Uint32()
  external int usage;
  @Uint32()
  external int minLevel;
}

/// `D2D1_SIZE_U`.
final class D2dSizeU extends Struct {
  @Uint32()
  external int width;
  @Uint32()
  external int height;
}

/// `D2D1_HWND_RENDER_TARGET_PROPERTIES`.
final class D2dHwndRenderTargetProperties extends Struct {
  external Pointer<Void> hwnd;
  external D2dSizeU pixelSize;
  @Uint32()
  external int presentOptions;
}

/// `D2D1_COLOR_F`: four straight-alpha floats in 0..1.
final class D2dColorF extends Struct {
  @Float()
  external double r;
  @Float()
  external double g;
  @Float()
  external double b;
  @Float()
  external double a;
}

/// `D2D1_RECT_F`.
final class D2dRectF extends Struct {
  @Float()
  external double left;
  @Float()
  external double top;
  @Float()
  external double right;
  @Float()
  external double bottom;
}

/// `D2D1_RECT_U`: the integer rectangle `ID2D1SpriteBatch::AddSprites` takes
/// for a sprite's source, in texels of the atlas bitmap.
///
/// Integer and not float, and that is the point: a sprite's source rectangle
/// addresses whole texels, so a glyph slot in an atlas cannot land half a
/// texel off the way a `D2D1_RECT_F` source could.
final class D2dRectU extends Struct {
  @Uint32()
  external int left;
  @Uint32()
  external int top;
  @Uint32()
  external int right;
  @Uint32()
  external int bottom;
}

/// `D2D1_POINT_2F`. Crossed by value in `BeginFigure` and `AddLine`.
final class D2dPoint2F extends Struct {
  @Float()
  external double x;
  @Float()
  external double y;
}

/// `D2D1_MATRIX_3X2_F`, in the header's row order: `m11 m12 / m21 m22 /
/// dx dy`. Maps to [Transform2D] as `a b / c d / tx ty`.
final class D2dMatrix3x2F extends Struct {
  @Float()
  external double m11;
  @Float()
  external double m12;
  @Float()
  external double m21;
  @Float()
  external double m22;
  @Float()
  external double dx;
  @Float()
  external double dy;
}

/// `D2D1_BITMAP_PROPERTIES`.
final class D2dBitmapProperties extends Struct {
  external D2dPixelFormat pixelFormat;
  @Float()
  external double dpiX;
  @Float()
  external double dpiY;
}

/// `D2D1_GRADIENT_STOP`.
final class D2dGradientStop extends Struct {
  @Float()
  external double position;
  external D2dColorF color;
}

/// `D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES`.
final class D2dLinearGradientBrushProperties extends Struct {
  external D2dPoint2F startPoint;
  external D2dPoint2F endPoint;
}

/// `D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES`.
final class D2dRadialGradientBrushProperties extends Struct {
  external D2dPoint2F center;
  external D2dPoint2F gradientOriginOffset;
  @Float()
  external double radiusX;
  @Float()
  external double radiusY;
}

/// `D2D1_BRUSH_PROPERTIES`.
final class D2dBrushProperties extends Struct {
  @Float()
  external double opacity;
  external D2dMatrix3x2F transform;
}

/// `D2D1_STROKE_STYLE_PROPERTIES`.
final class D2dStrokeStyleProperties extends Struct {
  @Uint32()
  external int startCap;
  @Uint32()
  external int endCap;
  @Uint32()
  external int dashCap;
  @Uint32()
  external int lineJoin;
  @Float()
  external double miterLimit;
  @Uint32()
  external int dashStyle;
  @Float()
  external double dashOffset;
}

/// `D2D1_BEZIER_SEGMENT`.
final class D2dBezierSegment extends Struct {
  external D2dPoint2F point1;
  external D2dPoint2F point2;
  external D2dPoint2F point3;
}

/// `D2D1_QUADRATIC_BEZIER_SEGMENT`.
final class D2dQuadraticBezierSegment extends Struct {
  external D2dPoint2F point1;
  external D2dPoint2F point2;
}

/// `D2D1_ROUNDED_RECT`.
final class D2dRoundedRect extends Struct {
  external D2dRectF rect;
  @Float()
  external double radiusX;
  @Float()
  external double radiusY;
}

/// `D2D1_LAYER_PARAMETERS`.
final class D2dLayerParameters extends Struct {
  external D2dRectF contentBounds;
  external Pointer<Void> geometricMask;
  @Uint32()
  external int maskAntialiasMode;
  external D2dMatrix3x2F maskTransform;
  @Float()
  external double opacity;
  external Pointer<Void> opacityBrush;
  @Uint32()
  external int layerOptions;
}

// ---------------------------------------------------------------------------
// The two GDI structures the offscreen readback surface needs
// ---------------------------------------------------------------------------

/// `RECT`, for `ID2D1DCRenderTarget::BindDC`.
final class Win32NativeRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

/// `BITMAPINFOHEADER` followed by no palette, which is all a 32-bit DIB
/// section needs. `biHeight` is written negative for a top-down bitmap so the
/// DIB's rows and the framebuffer's rows agree on which one is first.
final class Win32BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;
  @Int32()
  external int biWidth;
  @Int32()
  external int biHeight;
  @Uint16()
  external int biPlanes;
  @Uint16()
  external int biBitCount;
  @Uint32()
  external int biCompression;
  @Uint32()
  external int biSizeImage;
  @Int32()
  external int biXPelsPerMeter;
  @Int32()
  external int biYPelsPerMeter;
  @Uint32()
  external int biClrUsed;
  @Uint32()
  external int biClrImportant;
}

/// `BI_RGB`.
const int biRgb = 0;

/// `DIB_RGB_COLORS`.
const int dibRgbColors = 0;
