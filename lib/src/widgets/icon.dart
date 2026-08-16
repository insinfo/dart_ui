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
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import '../graphics/display_list.dart';
import '../layout/render_box.dart';
import '../rendering/text/font_registry.dart';
import '../text/cmap.dart';
import '../text/shaper.dart';
import '../text/typeface.dart';
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

  /// `0xAARRGGBB`, or null to take the ambient theme's foreground.
  final int? color;

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
        size: size ?? kDefaultIconSize,
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
      ..iconSize = size ?? kDefaultIconSize
      ..color = _colorFrom(context)
      ..textDirection = _directionFrom(context);
  }

  /// The theme's foreground, read **without** registering a dependency, for the
  /// reason `Text._sizeFrom` gives: a render-object element does not build, so
  /// subscribing it to the theme would schedule a rebuild that can never run.
  int _colorFrom(BuildContext context) =>
      color ??
      context.getInheritedWidgetOfExactType<Theme>()?.data.foreground ??
      0xFF111111;

  /// The ambient reading direction, read the same way and for the same reason.
  ///
  /// Deliberately **not** [Directionality.of], even though the policy is
  /// identical: `of` registers a dependency, and a dependency on a render-object
  /// element schedules a rebuild that this element's `performRebuild` does
  /// nothing with. The value still tracks a direction change, because changing a
  /// [Directionality] rebuilds its dependents and this icon is reached through
  /// whichever of them built it - the same chain `Text` relies on for its font
  /// size.
  ///
  /// The *failure* is `of`'s, though, and on purpose: an icon that asked to
  /// follow the reading order and was given none is a bug, not a reason to
  /// quietly stop mirroring for the users who would notice.
  TextDirection _directionFrom(BuildContext context) {
    final TextDirection? explicit = textDirection;
    if (explicit != null) return explicit;
    if (!icon.matchTextDirection) return TextDirection.leftToRight;
    final Directionality? scope =
        context.getInheritedWidgetOfExactType<Directionality>();
    if (scope == null) throw MissingDirectionalityError('Icon($icon)');
    return scope.textDirection;
  }
}

/// The render node behind [Icon].
final class RenderIcon extends RenderBox {
  RenderIcon(
    IconData icon, {
    double size = kDefaultIconSize,
    int color = 0xFF111111,
    TextDirection textDirection = TextDirection.leftToRight,
  })  : _icon = icon,
        _iconSize = size,
        _color = color,
        _textDirection = textDirection;

  IconData _icon;
  double _iconSize;
  int _color;
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

  int get color => _color;

  set color(int value) {
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

  /// Where the pen goes, so that the glyph's advance is centred horizontally.
  double _penOffset(ScaledTypeface face, int glyph) =>
      (_iconSize - face.advanceOf(glyph)) / 2;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(DisplayList list, Offset offset) {
    final ScaledTypeface face = font ?? (throw _missingFont());
    final int glyph = face.typeface.glyphForCodePoint(_icon.codePoint);
    if (glyph == notdefGlyph) return;
    if ((_color >> 24) & 0xFF == 0) return;

    final double penX = offset.dx + _penOffset(face, glyph);
    final double baselineY = offset.dy + _baselineOffset;
    final int paintId = list.addPaint(colorArgb: _color, antiAlias: true);

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

  /// `U+25BE` BLACK DOWN-POINTING SMALL TRIANGLE - an expanded disclosure, and
  /// a combo box's drop-down marker. Does not mirror: down is down.
  static const IconData chevronDown = IconData(0x25BE);

  /// `U+2190` LEFTWARDS ARROW - "back", which follows the reading order.
  static const IconData back = IconData(0x2190, matchTextDirection: true);

  /// `U+00D7` MULTIPLICATION SIGN - close.
  static const IconData close = IconData(0xD7);
}
