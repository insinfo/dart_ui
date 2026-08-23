/// A geometry- and colour-typed canvas over one region of a display list.
///
/// ## Why this exists next to [DisplayList] rather than instead of it
///
/// `display_list.dart` takes bare doubles and interned integer ids because it
/// is the hot path of the whole framework and section 6.5 forbids allocating
/// per command. That is right for the render tree, which emits from generated
/// code paths where the paint id was computed once and reused.
///
/// It is wrong for the code a *user* writes. An application drawing a game
/// scene or an animation preview writes drawing code by hand, and hand-written
/// code that has to intern a paint before every rectangle gets the order
/// wrong, forgets to reset the transform, or clips in the parent's coordinate
/// space by accident - all three of which produce a picture that is subtly
/// misplaced rather than obviously broken.
///
/// So this is a thin, non-retained facade: it holds the list, the region and
/// the frame's time, and every method compiles down to the same encoder calls
/// the render tree makes. It allocates nothing per command except where the
/// underlying operation genuinely needs an object - a [Path] for a line,
/// because the wire format has no line opcode.
///
/// ## The coordinate space
///
/// A canvas is handed out already translated: its origin is the top-left of
/// the region it was created for, so a painter writes `0, 0` and means its own
/// top-left, exactly as it would in a standalone drawing API. That translation
/// is a real `save`/`transform` pair on the list, which is why the canvas must
/// be closed ([close]) and why the object is not reusable across frames.
///
/// Because the translation is on the list's own transform stack, everything
/// composes correctly with whatever the render tree pushed above it - a
/// `Transform` widget, a `ClipRect`, a `saveLayer` for opacity. There is no
/// second coordinate system and nothing to keep in sync.
library;

import '../foundation/frame_time.dart';
import '../geometry/offset.dart';
import '../geometry/path.dart';
import '../geometry/rect.dart';
import '../geometry/size.dart';
import '../geometry/transform2d.dart';
import 'color.dart';
import 'display_list.dart';
import 'display_list_geometry.dart';
import 'display_list_opcodes.dart';
import 'gradient.dart';

/// Drawing surface handed to a per-frame painter.
///
/// Created by whoever owns the region - in practice `PaintSurface`'s render
/// object - and valid only for the duration of one paint call. Holding one
/// past that draws into a display list that has already been submitted, which
/// is why nothing here retains it and why [isOpen] exists to catch it.
final class FrameCanvas {
  /// Opens a canvas over [region] of [list].
  ///
  /// Pushes a save, a translation to the region's top-left and - when [clip]
  /// is true, the default - a clip to the region. [close] pops all of it.
  ///
  /// Clipping defaults to on because the alternative default is a painter that
  /// silently draws over its neighbours: a widget's box is a promise about
  /// where it draws, and a canvas is the one place in the framework where that
  /// promise is made by a callback nobody can inspect.
  factory FrameCanvas.open(
    DisplayList list, {
    required Rect region,
    required FrameTime time,
    bool clip = true,
  }) {
    list.save();
    if (region.left != 0 || region.top != 0) {
      list.transform(1, 0, 0, 1, region.left, region.top);
    }
    if (clip) {
      list.clipRect(0, 0, region.width, region.height);
    }
    return FrameCanvas._(list, Size(region.width, region.height), time);
  }

  FrameCanvas._(this.list, this.size, this.time);

  /// The encoder underneath. Public because a painter that needs an opcode
  /// this facade does not wrap must not have to fork the facade - and because
  /// hiding it would be a pretence: the ids below are its ids.
  final DisplayList list;

  /// The painter's own box, with its origin at `(0, 0)`.
  final Size size;

  /// When this frame is, and how long since the previous one.
  ///
  /// The reason a painter can animate without rebuilding: everything it needs
  /// to know about time is here, so it never needs a `setState` to be told
  /// that time passed.
  final FrameTime time;

  int _saveDepth = 0;
  bool _open = true;

  /// Whether [close] has not run yet.
  bool get isOpen => _open;

  /// `Rect.fromLTWH(0, 0, size.width, size.height)`: what the painter may
  /// draw in.
  Rect get bounds => Rect.fromLTWH(0, 0, size.width, size.height);

  // -----------------------------------------------------------------------
  // Paints
  // -----------------------------------------------------------------------

  /// Interns a fill paint and returns its id.
  ///
  /// Ids are frame-local and deduplicated by value, so calling this once per
  /// shape costs a hash probe rather than an allocation. A painter drawing ten
  /// thousand particles in one colour therefore ends up with one paint.
  int fill(
    Color color, {
    int blendMode = blendModeSrcOver,
    bool antiAlias = true,
    Gradient? gradient,
    int fillRule = pathFillRuleNonZero,
  }) =>
      list.addPaint(
        colorArgb: color.value,
        blendMode: blendMode,
        antiAlias: antiAlias,
        gradient: gradient,
        fillRule: fillRule,
      );

  /// Interns a stroke paint of [width] and returns its id.
  int stroke(
    Color color, {
    double width = 1.0,
    int blendMode = blendModeSrcOver,
    bool antiAlias = true,
    Gradient? gradient,
  }) =>
      list.addPaint(
        colorArgb: color.value,
        style: paintStyleStroke,
        strokeWidth: width,
        blendMode: blendMode,
        antiAlias: antiAlias,
        gradient: gradient,
      );

  // -----------------------------------------------------------------------
  // State
  // -----------------------------------------------------------------------

  /// Pushes the transform and clip state.
  void save() {
    _requireOpen();
    _saveDepth++;
    list.save();
  }

  /// Pops one [save]. Throws rather than corrupting the list when unbalanced:
  /// a stray `restore` would pop the translation this canvas is standing on
  /// and move everything the *parent* draws afterwards.
  void restore() {
    _requireOpen();
    if (_saveDepth == 0) {
      throw StateError(
        'FrameCanvas.restore() with no matching save(). Restoring past the '
        'canvas would pop the translation that puts this painter in its own '
        'box, and every command after it - including the render tree\'s own - '
        'would be drawn in the wrong place.',
      );
    }
    _saveDepth--;
    list.restore();
  }

  /// Runs [body] between a [save] and a [restore], even if it throws.
  void saved(void Function() body) {
    save();
    try {
      body();
    } finally {
      restore();
    }
  }

  void translate(double dx, double dy) {
    _requireOpen();
    list.transform(1, 0, 0, 1, dx, dy);
  }

  void scale(double sx, [double? sy]) {
    _requireOpen();
    list.transform(sx, 0, 0, sy ?? sx, 0, 0);
  }

  /// Rotates by [radians] about the current origin.
  void rotate(double radians) {
    _requireOpen();
    list.transform2D(Transform2D.rotation(radians));
  }

  void transform(Transform2D value) {
    _requireOpen();
    list.transform2D(value);
  }

  void clipRect(Rect rect, {int op = clipOpIntersect}) {
    _requireOpen();
    list.clipRectangle(rect, op: op);
  }

  void clipPath(Path path, {int op = clipOpIntersect}) {
    _requireOpen();
    list.clipPath(list.addPath(path), op: op);
  }

  // -----------------------------------------------------------------------
  // Shapes
  // -----------------------------------------------------------------------

  void drawRect(Rect rect, int paintId) {
    _requireOpen();
    list.drawRectangle(rect, paintId);
  }

  /// [drawRect] with the paint interned for you.
  void fillRect(Rect rect, Color color) => drawRect(rect, fill(color));

  void strokeRect(Rect rect, Color color, {double width = 1.0}) =>
      drawRect(rect, stroke(color, width: width));

  void drawRRect(Rect rect, double radius, int paintId) {
    _requireOpen();
    list.drawRRectUniform(
      rect.left,
      rect.top,
      rect.right,
      rect.bottom,
      radius,
      radius,
      paintId,
    );
  }

  void fillRRect(Rect rect, double radius, Color color) =>
      drawRRect(rect, radius, fill(color));

  void drawPath(Path path, int paintId) {
    _requireOpen();
    list.drawPath(list.addPath(path), paintId);
  }

  void fillPath(Path path, Color color, {int fillRule = pathFillRuleNonZero}) =>
      drawPath(path, fill(color, fillRule: fillRule));

  void strokePath(Path path, Color color, {double width = 1.0}) =>
      drawPath(path, stroke(color, width: width));

  /// A straight segment.
  ///
  /// Allocates a two-point [Path], because the wire format has no line
  /// opcode - stated rather than hidden, since a particle system drawing
  /// 50000 lines a frame will see it. Batch those into one [Path] with many
  /// contours instead.
  void drawLine(Offset from, Offset to, Color color, {double width = 1.0}) {
    _requireOpen();
    final PathBuilder builder = PathBuilder()
      ..moveTo(from.dx, from.dy)
      ..lineTo(to.dx, to.dy);
    drawPath(builder.build(), stroke(color, width: width));
  }

  /// An axis-aligned ellipse filling [rect].
  void fillOval(Rect rect, Color color) => fillPath(Path.oval(rect), color);

  void strokeOval(Rect rect, Color color, {double width = 1.0}) =>
      strokePath(Path.oval(rect), color, width: width);

  void fillCircle(Offset center, double radius, Color color) => fillOval(
        Rect.fromLTWH(
          center.dx - radius,
          center.dy - radius,
          radius * 2,
          radius * 2,
        ),
        color,
      );

  /// Blits [source] of [image] into [destination].
  ///
  /// [image] is whatever the renderer in use accepts as an image resource; the
  /// display list interns it by identity and never inspects it, which is what
  /// keeps this file independent of any one renderer's texture type.
  void drawImage(
    Object image,
    Rect source,
    Rect destination, {
    Color tint = const Color(0xFFFFFFFF),
    int blendMode = blendModeSrcOver,
  }) {
    _requireOpen();
    list.drawImageRects(
      list.addImage(image),
      source,
      destination,
      fill(tint, blendMode: blendMode),
    );
  }

  /// Pops everything this canvas pushed. Idempotent.
  ///
  /// Called by the owner, not by the painter. An unbalanced [save] left by the
  /// painter is closed here rather than thrown on: the display list is already
  /// half written by the time the imbalance is visible, and leaving it
  /// unbalanced would displace every command the render tree emits *after*
  /// this widget - a bug that appears in a sibling and points nowhere near the
  /// painter that caused it.
  void close() {
    if (!_open) return;
    while (_saveDepth > 0) {
      _saveDepth--;
      list.restore();
    }
    list.restore();
    _open = false;
  }

  void _requireOpen() {
    if (!_open) {
      throw StateError(
        'this FrameCanvas was closed when its paint call returned. A canvas '
        'is valid for one frame; store what you want to draw, not the thing '
        'you draw with.',
      );
    }
  }

  @override
  String toString() =>
      'FrameCanvas(${size.width}x${size.height}, ${time.toString()})';
}
