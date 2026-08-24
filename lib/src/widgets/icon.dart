/// Icons, drawn as glyphs.
///
/// ## Why a glyph and not a bitmap
///
/// An icon is a small, monochrome, tintable shape at whatever size the
/// interface asks for. That is the exact description of a glyph, and this
/// framework already has an entire pipeline for glyphs which is better than
/// anything an icon-specific path would get on its first day:
///
///   * **it scales.** The outline is rasterised at the device size, so a 16 px
///     icon and the same icon at 64 px are both sharp. A bitmap sheet is sharp
///     at the size it was authored and blurry everywhere else, which is why
///     every one of them ends up shipping three resolutions;
///   * **it is already cached.** `GlyphCache` in the renderer keys a coverage
///     mask by (face, size, subpixel bucket) and the GPU backend keys the same
///     shape into its glyph atlas. An icon drawn in a list of two hundred rows
///     is rasterised once, not two hundred times, and neither this file nor the
///     renderer had to learn anything new for that to be true;
///   * **it is tinted for free.** A coverage mask carries no colour, so the
///     same cached mask serves a black icon, a red one and the same icon in a
///     dark theme. A coloured bitmap needs a copy per colour;
///   * **hinting, subpixel positioning, and the composite equation** are the
///     ones text already uses, so an icon sitting on a label's baseline lands
///     on the same pixel grid the label does.
///
/// ## What it costs
///
/// Three things, and they are real:
///
///   * **an icon needs a font.** [IconData] names a family and a code point,
///     and if that family is not registered nothing is drawn. There is no
///     inline fallback artwork - see [RenderIcon.hasGlyph], which says outright
///     whether anything will appear, so a missing icon font is a question a
///     caller can ask instead of a blank square it discovers;
///   * **icons are monochrome.** A multicolour icon lives in `COLR`/`CBDT`
///     tables this engine does not implement (see `FontRegistry.resolveEmoji`,
///     which documents the same absence for emoji). A two-tone icon has to be
///     two glyphs stacked, or an image;
///   * **the code point is a magic number.** `IconData(0xE800)` says nothing to
///     a reader, which is a property of icon fonts rather than of this design;
///     an application is expected to declare named constants, the way
///     [Icons] does below for the handful the framework's own controls use.
///
/// ## Mirroring in a right-to-left interface
///
/// Some icons must flip when the reading order does - anything with a
/// directional meaning, like a back arrow or an indent - and most must not: a
/// clock, a magnifier, a checkmark. Only the author of the icon knows which, so
/// it is a property of [IconData], not of the widget.
///
/// A mirrored glyph **cannot go through the glyph cache**. The CPU renderer
/// refuses a mirrored transform on a run and says why: its glyph rasteriser
/// takes a uniform scale and a subpixel offset, so a run under a reflection
/// would silently come out upright - a wrong picture that looks deliberate. So
/// a mirroring icon is drawn from its **outline**, as a filled path.
///
/// The consequence is that [IconData.matchTextDirection] changes the
/// rasterisation route, and it therefore changes it in **both** directions:
/// an icon that mirrors takes the path route left-to-right as well. Switching
/// route with the direction would mean the two directions were antialiased by
/// different code, and "the icons look slightly different in Arabic" is not a
/// bug anybody would ever find.
///
/// The direction itself comes from [Directionality], which publishes it to a
/// subtree. [Icon.textDirection] overrides it for one icon; when it is null and
/// the icon mirrors, the ambient value is read - and its absence is an error,
/// not a silent left-to-right, for the reason [Directionality.of] gives. An
/// icon that does **not** mirror never reads it and therefore never needs one,
/// which keeps a checkmark usable in a tree with no locale in it.
///
/// The rule itself is [mirrorsInDirection] and the transform is
/// [horizontalMirror], both from `directionality.dart`, rather than a second
/// copy of "negate x and add the width" written here.
library;

import 'dart:typed_data';

import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../graphics/color.dart';
import '../graphics/display_list.dart';
import '../layout/render_box.dart';
import '../rendering/text/font_registry.dart';
import '../text/cmap.dart';
import '../text/shaper.dart';
import '../text/typeface.dart';
import 'control.dart';
import 'directionality.dart';
import 'element.dart';
import 'theme.dart';
import 'widget.dart';

/// The size an icon takes when nothing says otherwise.
///
/// Sixteen rather than a multiple of the ambient font size: an icon beside a
/// label wants to match the label's *cap height*, not its em box, and the two
/// differ by enough that deriving one from the other looks wrong at every size
/// but one. `ThemeData` carries no icon size to read, so this is a constant
/// rather than a theme lookup - the same trade `kDefaultUiFontSize` makes.
const double kDefaultIconSize = 16.0;

/// Supplies size and colour defaults to descendant [Icon] widgets.
final class IconTheme extends InheritedWidget {
  const IconTheme({
    super.key,
    required this.data,
    required super.child,
  });

  final IconThemeData data;

  static IconThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data ??
      const IconThemeData();

  static IconThemeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data;

  @override
  bool updateShouldNotify(IconTheme oldWidget) =>
      !identical(data, oldWidget.data);
}

/// Which glyph, in which font, an icon is.
///
/// Two integers and a string: cheap to compare, safe to hold in a `const`, and
/// - unlike a decoded image - it costs nothing until it is drawn.
final class IconData {
  const IconData(
    this.codePoint, {
    this.fontFamily,
    this.matchTextDirection = false,
  });

  /// The Unicode code point in [fontFamily]. Icon fonts almost always use the
  /// Private Use Area, `U+E000`..`U+F8FF`.
  final int codePoint;

  /// The family to look up through `FontRegistry.faceFor`, or null to use the
  /// interface face.
  ///
  /// Null is the useful default for the framework's own controls, which draw
  /// their marks from whatever face is already loaded; an application that
  /// ships an icon font registers it once with `FontRegistry.registerTypeface`
  /// and names it here.
  final String? fontFamily;

  /// Whether this icon means something directional and must flip in a
  /// right-to-left interface.
  ///
  /// False for the overwhelming majority. See the library comment for what
  /// setting it changes about how the glyph is drawn.
  final bool matchTextDirection;

  @override
  bool operator ==(Object other) =>
      other is IconData &&
      other.codePoint == codePoint &&
      other.fontFamily == fontFamily &&
      other.matchTextDirection == matchTextDirection;

  @override
  int get hashCode => Object.hash(codePoint, fontFamily, matchTextDirection);

  @override
  String toString() => 'IconData(U+'
      '${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}'
      '${fontFamily == null ? '' : ', $fontFamily'}'
      '${matchTextDirection ? ', mirrors' : ''})';
}

/// A single glyph, drawn at a square size in one colour.
final class Icon extends RenderObjectWidget {
  const Icon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.textDirection,
  });

  final IconData icon;

  /// The side of the square box, in logical pixels. Defaults to
  /// [kDefaultIconSize].
  final double? size;

  /// The glyph colour, or null to take the ambient icon theme.
  final Color? color;

  /// The reading order, overriding the ambient [Directionality].
  ///
  /// Null - the usual case - reads the ambient value, and only for an icon that
  /// declared [IconData.matchTextDirection]. An icon that does not mirror never
  /// asks, so it stays usable in a subtree that has no reading direction at all.
  final TextDirection? textDirection;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderIcon createRenderObject(BuildContext context) => RenderIcon(
        icon,
        size: _sizeFrom(context),
        color: _colorFrom(context),
        textDirection: _directionFrom(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderIcon renderObject,
  ) {
    renderObject
      ..icon = icon
      ..iconSize = _sizeFrom(context)
      ..color = _colorFrom(context)
      ..textDirection = _directionFrom(context);
  }

  /// Resolves from both icon and application themes and subscribes to them.
  /// Render-object elements can rebuild inherited values through
  /// `updateRenderObject`; without the dependency, a const icon retained the
  /// light palette after a live switch to dark mode.
  Color _colorFrom(BuildContext context) {
    final IconThemeData? local = IconTheme.maybeOf(context);
    final ThemeData? theme =
        context.dependOnInheritedWidgetOfExactType<Theme>()?.data;
    return color ??
        local?.color ??
        theme?.iconTheme.color ??
        theme?.foreground ??
        const Color(0xFF111111);
  }

  double _sizeFrom(BuildContext context) {
    final IconThemeData? local = IconTheme.maybeOf(context);
    final ThemeData? theme =
        context.dependOnInheritedWidgetOfExactType<Theme>()?.data;
    return size ?? local?.size ?? theme?.iconTheme.size ?? kDefaultIconSize;
  }

  /// The ambient reading direction. Directional icons subscribe so a retained
  /// const subtree is repainted when the locale changes.
  TextDirection _directionFrom(BuildContext context) {
    final TextDirection? explicit = textDirection;
    if (explicit != null) return explicit;
    if (!icon.matchTextDirection) return TextDirection.leftToRight;
    return Directionality.of(context);
  }
}

/// The render node behind [Icon].
final class RenderIcon extends RenderBox {
  RenderIcon(
    IconData icon, {
    double size = kDefaultIconSize,
    Color color = const Color(0xFF111111),
    TextDirection textDirection = TextDirection.leftToRight,
  })  : _icon = icon,
        _iconSize = size,
        _color = color,
        _textDirection = textDirection;

  IconData _icon;
  double _iconSize;
  Color _color;
  TextDirection _textDirection;

  /// The resolved face, cleared whenever anything it was resolved from
  /// changes. Resolution walks the registry and may open a font file, so it is
  /// emphatically not something to redo per paint.
  ScaledTypeface? _font;
  bool _resolved = false;

  IconData get icon => _icon;

  set icon(IconData value) {
    if (value == _icon) return;
    _icon = value;
    _invalidateFont();
    // The glyph changes but the box does not: an icon is a square of its
    // declared size whatever is in it.
    markNeedsPaint();
  }

  double get iconSize => _iconSize;

  set iconSize(double value) {
    if (value == _iconSize) return;
    _iconSize = value;
    _invalidateFont();
    markNeedsLayout();
  }

  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  TextDirection get textDirection => _textDirection;

  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    // Only a mirroring icon looks different, but the check is cheaper than the
    // repaint it would save.
    if (_icon.matchTextDirection) markNeedsPaint();
  }

  void _invalidateFont() {
    _font = null;
    _resolved = false;
  }

  /// The face this icon draws from, or null when the family is not installed.
  ///
  /// Null is the honest answer and it is why [hasGlyph] exists: an application
  /// that forgot to register its icon font gets a question it can ask rather
  /// than a row of empty squares.
  ScaledTypeface? get font {
    if (_resolved) return _font;
    _resolved = true;
    final String? family = _icon.fontFamily;
    if (family == null) {
      _font = FontRegistry.instance.uiFont(_iconSize);
      return _font;
    }
    final Typeface? face = FontRegistry.instance.faceFor(family);
    _font = face?.atSize(_iconSize);
    return _font;
  }

  /// The glyph for [IconData.codePoint], or [notdefGlyph] when the face does
  /// not have it.
  int get glyphId {
    final ScaledTypeface? face = font;
    if (face == null) return notdefGlyph;
    return face.typeface.glyphForCodePoint(_icon.codePoint);
  }

  /// Whether anything will actually be drawn.
  ///
  /// False for a missing family, a code point the family does not carry, and a
  /// glyph with no outline - a space, or an icon font's own blank. Reported
  /// rather than left to be discovered, on the same principle as
  /// `EmojiResolution.drawable`.
  bool get hasGlyph {
    final ScaledTypeface? face = font;
    if (face == null) return false;
    final int glyph = face.typeface.glyphForCodePoint(_icon.codePoint);
    return glyph != notdefGlyph && face.typeface.hasOutline(glyph);
  }

  /// Whether this icon is drawn as a filled outline rather than through the
  /// glyph cache.
  ///
  /// True exactly when [IconData.matchTextDirection] is set, in both reading
  /// directions. See the library comment for why the route does not change with
  /// the direction.
  bool get drawsAsPath => _icon.matchTextDirection;

  /// Whether the glyph is being reflected, which needs both the icon's consent
  /// and a right-to-left reading direction.
  ///
  /// The rule is [mirrorsInDirection]'s, not a second copy of it: a render
  /// object has no [BuildContext], which is exactly the case that free function
  /// exists for.
  bool get isMirrored => mirrorsInDirection(
        _textDirection,
        matchTextDirection: _icon.matchTextDirection,
      );

  @override
  void performLayout() {
    size = constraints.constrain(Size(_iconSize, _iconSize));
  }

  // An icon is square and does not shrink: unlike text there is no smaller
  // arrangement of it, so the minimum and the maximum are the same number and
  // reporting a smaller minimum would be a lie a grid column acts on.

  @override
  double computeMinIntrinsicWidth(double height) => _iconSize;

  @override
  double computeMaxIntrinsicWidth(double height) => _iconSize;

  @override
  double computeMinIntrinsicHeight(double width) => _iconSize;

  @override
  double computeMaxIntrinsicHeight(double width) => _iconSize;

  /// An icon sits on the text baseline, so a row that aligns a label and an
  /// icon by baseline puts them where a reader expects.
  ///
  /// The value is [_baselineOffset]'s, which is the same number `paint` draws
  /// at - the property `RenderText` also keeps, and for the same reason: what a
  /// row aligns to and what is drawn cannot be allowed to disagree.
  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    if (baseline != TextBaseline.alphabetic) {
      return hasSize ? size.height : null;
    }
    return _baselineOffset;
  }

  /// Where the glyph's baseline sits inside the icon's box.
  ///
  /// The em box - ascent above the baseline, descent below - is centred in the
  /// square. For a face whose ascent and descent sum to one em, which is the
  /// usual shape of an icon font, that puts the em box exactly on the box and
  /// the icon fills its declared size.
  double get _baselineOffset {
    final ScaledTypeface? face = font;
    if (face == null) return _iconSize;
    final double emHeight = face.ascent + face.descent;
    return (_iconSize - emHeight) / 2 + face.ascent;
  }

  /// Centres the glyph's actual ink instead of its advance/em box.
  ///
  /// Icon fonts frequently keep asymmetric side bearings and vertical font
  /// metrics for compatibility. Centring those metrics makes a geometrically
  /// symmetric icon look visibly shifted inside a square button.
  ({double penX, double baselineY}) _glyphPlacement(
    ScaledTypeface face,
    int glyph,
    Offset offset,
  ) {
    final String? family = _icon.fontFamily;
    if (family != Icons.materialFontFamily &&
        family != TablerIcons.fontFamily &&
        family != 'Phosphor') {
      return (
        penX:
            (offset.dx + (_iconSize - face.advanceOf(glyph)) / 2).roundToDouble(),
        baselineY: (offset.dy + _baselineOffset).roundToDouble(),
      );
    }
    final Rect bounds = face.typeface.outlineOf(glyph).bounds;
    if (bounds.isEmpty) {
      return (
        penX:
            (offset.dx + (_iconSize - face.advanceOf(glyph)) / 2).roundToDouble(),
        baselineY: (offset.dy + _baselineOffset).roundToDouble(),
      );
    }
    // Snapped to whole pixels. An icon outline is drawn on a 16- or 24-unit
    // grid with 1-unit stems, and half a pixel of offset turns a crisp 1 px
    // stem into two 50 % grey ones - which is what "the icons look blurry"
    // always turns out to be. Snapping also collapses the glyph cache's
    // subpixel buckets to one, so every 16 px chevron in a toolbar shares a
    // single rasterised mask.
    return (
      penX: (offset.dx + _iconSize / 2 - bounds.center.dx * face.scale)
          .roundToDouble(),
      baselineY: (offset.dy + _iconSize / 2 + bounds.center.dy * face.scale)
          .roundToDouble(),
    );
  }

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    final ScaledTypeface face = font ?? (throw _missingFont());
    final int glyph = face.typeface.glyphForCodePoint(_icon.codePoint);
    if (glyph == notdefGlyph) return;
    if (_color.alpha == 0) return;

    final ({double penX, double baselineY}) glyphPlacement =
        _glyphPlacement(face, glyph, offset);
    final double penX = glyphPlacement.penX;
    final double baselineY = glyphPlacement.baselineY;
    final int paintId = list.addPaint(colorArgb: _color.value, antiAlias: true);

    if (!drawsAsPath) {
      // The ordinary route: one glyph, one run, through the cache every label
      // in the framework already fills.
      list.drawGlyphRun(
        list.addFont(face),
        paintId,
        penX,
        baselineY,
        _oneGlyph(glyph),
        _zeroOffset,
        1,
      );
      return;
    }

    // The mirroring route. The outline arrives in font units with y up, so the
    // first transform scales it to the pixel size, flips y for a y-down
    // surface, and puts the pen and baseline where the glyph route would have
    // put them - in the icon's *own* coordinates, `0..iconSize` on both axes.
    final double scale = face.scale;
    final Transform2D glyphToBox = Transform2D(
      scale,
      0,
      0,
      -scale,
      penX - offset.dx,
      baselineY - offset.dy,
    );
    // Then the reflection about that box, and only then the move into the
    // parent's coordinates. Composing in this order is what lets the mirror be
    // `horizontalMirror`'s - a box-local reflection with no offset in it - and
    // keeps the sign convention in one file.
    final Transform2D toParent = Transform2D.translation(offset.dx, offset.dy);
    final Transform2D placement = isMirrored
        ? toParent.multiply(horizontalMirror(_iconSize)).multiply(glyphToBox)
        : toParent.multiply(glyphToBox);
    final Path outline = face.typeface.outlineOf(glyph).transform(placement);
    if (outline.isEmpty) return;
    list.drawPath(list.addPath(outline), paintId);
  }

  StateError _missingFont() => StateError(
        'RenderIcon has no face for $_icon. The family is not registered with '
        'FontRegistry, so there is nothing to draw; ask hasGlyph before '
        'painting if a missing icon font is a state this application expects.',
      );

  /// One-element scratch buffers, reused across paints.
  ///
  /// A glyph run's operands are typed lists and an icon's run has exactly one
  /// entry, so allocating a pair per paint would put two allocations on the
  /// path of every icon in every frame for no information.
  static final Int32List _glyphScratch = Int32List(1);
  static final Float32List _zeroOffset = Float32List(2);

  static Int32List _oneGlyph(int glyph) => _glyphScratch..[0] = glyph;
}

/// Which way a [Chevron] points.
///
/// [back] and [forward] follow the reading order and therefore mirror in a
/// right-to-left interface; [up] and [down] do not, because up is up.
enum ChevronDirection { up, down, back, forward }

/// A chevron drawn from two strokes, with no font involved.
///
/// The framework's controls draw this mark from their own render objects - a
/// combo box's drop-down marker, a tree's disclosure, a spin box's arrows - and
/// this is the same mark for chrome that is composed from widgets instead, such
/// as a calendar's month strip. It exists because the alternative was a
/// Unicode triangle from [Icons], and `U+25B8` is missing from most interface
/// faces: the button came out empty on Windows and looked like a bug, which is
/// how the framework learned that a control's *own* marks cannot depend on
/// what the system font happens to carry.
final class Chevron extends RenderObjectWidget {
  const Chevron({
    super.key,
    this.direction = ChevronDirection.down,
    this.size,
    this.color,
    this.thickness = 1.5,
  });

  final ChevronDirection direction;

  /// The side of the square the mark is centred in; null takes the icon size.
  final double? size;

  /// Null takes the ambient icon colour, then the theme's secondary text.
  final Color? color;

  final double thickness;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  RenderChevron createRenderObject(BuildContext context) => RenderChevron()
    ..direction = _resolved(context)
    ..extent = _extent(context)
    ..color = _color(context)
    ..thickness = thickness;

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderChevron renderObject,
  ) {
    renderObject
      ..direction = _resolved(context)
      ..extent = _extent(context)
      ..color = _color(context)
      ..thickness = thickness;
  }

  double _extent(BuildContext context) =>
      size ?? IconTheme.maybeOf(context)?.size ?? Theme.of(context).iconSize;

  Color _color(BuildContext context) =>
      color ??
      IconTheme.maybeOf(context)?.color ??
      Theme.of(context).foregroundSecondary;

  /// The direction after mirroring, which only [back] and [forward] do.
  ChevronDirection _resolved(BuildContext context) {
    if (direction == ChevronDirection.up || direction == ChevronDirection.down) {
      return direction;
    }
    final bool rtl = Directionality.maybeOf(context)?.isRightToLeft ?? false;
    if (!rtl) return direction;
    return direction == ChevronDirection.back
        ? ChevronDirection.forward
        : ChevronDirection.back;
  }
}

/// The render object behind [Chevron].
final class RenderChevron extends RenderBox {
  ChevronDirection _direction = ChevronDirection.down;
  double _extent = 16;
  Color _color = const Color(0xFF5A6472);
  double _thickness = 1.5;

  ChevronDirection get direction => _direction;

  set direction(ChevronDirection value) {
    if (value == _direction) return;
    _direction = value;
    markNeedsPaint();
  }

  double get extent => _extent;

  set extent(double value) {
    if (value == _extent) return;
    _extent = value;
    markNeedsLayout();
  }

  Color get color => _color;

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double get thickness => _thickness;

  set thickness(double value) {
    if (value == _thickness) return;
    _thickness = value;
    markNeedsPaint();
  }

  @override
  void performLayout() => size = constraints.constrain(Size(_extent, _extent));

  @override
  double computeMinIntrinsicWidth(double height) => _extent;

  @override
  double computeMaxIntrinsicWidth(double height) => _extent;

  @override
  double computeMinIntrinsicHeight(double width) => _extent;

  @override
  double computeMaxIntrinsicHeight(double width) => _extent;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    // Snapped to whole pixels for the same reason [RenderIcon] snaps its pen:
    // a 1.5 px stroke on a half-pixel centre rasterises as two grey ones.
    final double cx = (offset.dx + size.width / 2).roundToDouble();
    final double cy = (offset.dy + size.height / 2).roundToDouble();
    final double span = (_extent * 0.22).clamp(3.0, 6.0).roundToDouble();
    final List<Offset> points = switch (_direction) {
      ChevronDirection.down => <Offset>[
          Offset(cx - span, cy - span / 2),
          Offset(cx, cy + span / 2),
          Offset(cx + span, cy - span / 2),
        ],
      ChevronDirection.up => <Offset>[
          Offset(cx - span, cy + span / 2),
          Offset(cx, cy - span / 2),
          Offset(cx + span, cy + span / 2),
        ],
      ChevronDirection.forward => <Offset>[
          Offset(cx - span / 2, cy - span),
          Offset(cx + span / 2, cy),
          Offset(cx - span / 2, cy + span),
        ],
      ChevronDirection.back => <Offset>[
          Offset(cx + span / 2, cy - span),
          Offset(cx - span / 2, cy),
          Offset(cx + span / 2, cy + span),
        ],
    };
    paintPolyline(list, points, _thickness, _color);
  }
}

/// The code points the framework's own controls draw.
///
/// Deliberately small. A framework that ships an icon *set* has to ship the
/// font too, and picking one is a licensing decision rather than an engineering
/// one; these are the marks the controls in `controls.dart` draw by hand today,
/// named so that a theme can replace them with a real icon font by registering
/// one and changing [IconData.fontFamily].
///
/// The code points are the standard Unicode ones rather than Private Use Area
/// values, so a reasonably complete interface face draws them with no icon font
/// installed at all - `test/fonts/DejaVuSans.ttf` carries all seven. A subset
/// face may not, which is what [RenderIcon.hasGlyph] is for.
abstract final class Icons {
  static const String materialFontFamily = 'Material Icons';

  static const IconData article =
      IconData(0xEF42, fontFamily: materialFontFamily);
  static const IconData contentCopy =
      IconData(0xE14D, fontFamily: materialFontFamily);
  static const IconData darkMode =
      IconData(0xE51C, fontFamily: materialFontFamily);
  static const IconData fitScreen =
      IconData(0xEA10, fontFamily: materialFontFamily);
  static const IconData folderOpen =
      IconData(0xE2C8, fontFamily: materialFontFamily);
  static const IconData fullscreen =
      IconData(0xE5D0, fontFamily: materialFontFamily);
  static const IconData fullscreenExit =
      IconData(0xE5D1, fontFamily: materialFontFamily);
  static const IconData lightMode =
      IconData(0xE518, fontFamily: materialFontFamily);
  static const IconData moreVert =
      IconData(0xE5D4, fontFamily: materialFontFamily);
  static const IconData navigateBefore = IconData(
    0xE408,
    fontFamily: materialFontFamily,
    matchTextDirection: true,
  );
  static const IconData navigateNext = IconData(
    0xE409,
    fontFamily: materialFontFamily,
    matchTextDirection: true,
  );
  static const IconData refresh =
      IconData(0xE5D5, fontFamily: materialFontFamily);
  static const IconData search =
      IconData(0xE8B6, fontFamily: materialFontFamily);
  static const IconData selectAll =
      IconData(0xE162, fontFamily: materialFontFamily);
  static const IconData zoomIn =
      IconData(0xE8FF, fontFamily: materialFontFamily);
  static const IconData zoomOut =
      IconData(0xE900, fontFamily: materialFontFamily);

  /// `U+2713` CHECK MARK - a checked box.
  static const IconData check = IconData(0x2713);

  /// `U+25CF` BLACK CIRCLE - a selected radio button.
  static const IconData radioSelected = IconData(0x25CF);

  /// `U+2500` BOX DRAWINGS LIGHT HORIZONTAL - a tri-state box's mixed mark.
  static const IconData indeterminate = IconData(0x2500);

  /// `U+25B8` BLACK RIGHT-POINTING SMALL TRIANGLE - a collapsed disclosure.
  ///
  /// Mirrors: a disclosure triangle points along the reading order, so it faces
  /// the other way in a right-to-left interface.
  static const IconData chevronForward =
      IconData(0x25B8, matchTextDirection: true);

  /// `U+25C2` BLACK LEFT-POINTING SMALL TRIANGLE - "previous".
  ///
  /// Mirrors, for the same reason [chevronForward] does: previous is the way
  /// the reader came from, which is the right in a right-to-left interface.
  static const IconData chevronBack =
      IconData(0x25C2, matchTextDirection: true);

  /// `U+25BE` BLACK DOWN-POINTING SMALL TRIANGLE - an expanded disclosure, and
  /// a combo box's drop-down marker. Does not mirror: down is down.
  static const IconData chevronDown = IconData(0x25BE);

  /// `U+2190` LEFTWARDS ARROW - "back", which follows the reading order.
  static const IconData back = IconData(0x2190, matchTextDirection: true);

  /// `U+00D7` MULTIPLICATION SIGN - close.
  static const IconData close = IconData(0xD7);
}

/// Named glyphs from the bundled Tabler Icons 3.46 outline font.
///
/// Tabler uses a consistent 24-unit visual grid and is distributed under the
/// MIT license. This focused public set covers common application chrome; more
/// names can be added without changing [Icon] or the font-loading contract.
abstract final class TablerIcons {
  static const String fontFamily = 'Tabler Icons';

  static const IconData adjustments = IconData(0xEA03, fontFamily: fontFamily);
  static const IconData arrowsMaximize =
      IconData(0xEA28, fontFamily: fontFamily);
  static const IconData chevronLeft = IconData(
    0xEA60,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );
  static const IconData chevronRight = IconData(
    0xEA61,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );
  static const IconData columns = IconData(0xEB83, fontFamily: fontFamily);
  static const IconData copy = IconData(0xEA7A, fontFamily: fontFamily);
  static const IconData cursorText = IconData(0xEE6D, fontFamily: fontFamily);
  static const IconData download = IconData(0xEA96, fontFamily: fontFamily);
  static const IconData fileText = IconData(0xEAA2, fontFamily: fontFamily);
  static const IconData focus = IconData(0xEBD3, fontFamily: fontFamily);
  static const IconData folder = IconData(0xEAAD, fontFamily: fontFamily);
  static const IconData folderOpen = IconData(0xFAF7, fontFamily: fontFamily);
  static const IconData hand = IconData(0xEC2E, fontFamily: fontFamily);
  static const IconData moon = IconData(0xEAF8, fontFamily: fontFamily);
  static const IconData printer = IconData(0xEB0E, fontFamily: fontFamily);
  static const IconData rotateClockwise =
      IconData(0xEB15, fontFamily: fontFamily);
  static const IconData search = IconData(0xEB1C, fontFamily: fontFamily);
  static const IconData sun = IconData(0xEB30, fontFamily: fontFamily);
  static const IconData zoomIn = IconData(0xEB56, fontFamily: fontFamily);
  static const IconData zoomOut = IconData(0xEB57, fontFamily: fontFamily);
}
