/// The display-list interpreter: encoded commands in, device-space primitives
/// out.
///
/// The player owns the part of rendering that is pure bookkeeping - walking
/// the stream, composing transforms, intersecting clips, resolving resource
/// ids, culling what cannot be seen - and hands whatever survives to a
/// [RasterSink]. It never touches a pixel.
///
/// ## Why a sink instead of the rasteriser
///
/// Two reasons, and neither is testability alone. First, the interpreter is a
/// state machine whose bugs are transform-order and clip-nesting bugs; those
/// are provable against a recording sink and invisible in a golden image,
/// where an off-by-one clip and a wrong matrix look the same. Second, the same
/// walk has to feed things that are not a CPU rasteriser: a GPU command
/// encoder, a damage-region collector, a debug dump. A sink keeps all of them
/// peers instead of making one of them the interpreter's dependency.
///
/// Everything the sink receives is already in device space, already clipped
/// against a non-empty rectangle, and already resolved from ids to objects.
/// The sink's job is to put colour on pixels.
///
/// ## The transform approximation, stated on purpose
///
/// Rectangles reach the sink as [Transform2D.transformRect] gives them: the
/// axis-aligned bounding box of the transformed rectangle. Under translation,
/// scale, and 90-degree-multiple rotation that box *is* the shape, so the
/// result is exact. Under an arbitrary rotation or a skew it is not: the true
/// image is a rotated quadrilateral and the box is strictly larger, so a fill
/// covers pixels the shape does not, and a clip lets pixels through that the
/// shape would have removed. The clip direction is at least conservative in
/// the safe sense that nothing visible is wrongly removed; the fill direction
/// is simply wrong, which is why `test/rendering/replay` asserts the inflated
/// box explicitly rather than letting it pass as a rounding detail.
///
/// What changes when rotated fills are supported: not this call. A rotated
/// rectangle is a different primitive - four device-space corners, or a path -
/// and it arrives as a new [RasterSink] method (`fillDeviceQuad`) that the
/// player selects when the current transform is not axis-aligned.
/// [RasterSink.fillDeviceRect] keeps meaning "an axis-aligned box of solid
/// colour", which is the one shape a scanline filler can do without a
/// coverage pass. The same holds for the rounded-rectangle radii, which are
/// scaled by the transform's axis lengths and are only a faithful description
/// of the shape while the transform is axis-aligned.
///
/// ## A stroked rectangle leaves here as a path
///
/// [RasterSink.fillDeviceRect] and [RasterSink.fillDeviceRRect] receive
/// *device* geometry and no matrix, which is fine for a fill and impossible
/// for a stroke: [ReplayPaint.strokeWidth] is in the coordinates the command
/// was written in, so turning it into a device width needs the transform that
/// those two methods deliberately do not carry. Rather than widen them - and
/// with them every sink that implements them - a rectangle or rounded
/// rectangle drawn with a stroke-bearing style is rebuilt here as its
/// *centreline path* in local space and sent to [RasterSink.drawDevicePath],
/// which does carry the matrix. One consequence is worth stating: the sink
/// strokes in local units and transforms the outline, so a 2 px stroke under
/// a 2x scale is 4 device pixels wide, exactly as the shape it outlines
/// doubles.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/path.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import '../../graphics/display_list.dart';
import '../../graphics/display_list_opcodes.dart';
import '../../graphics/display_list_reader.dart';
import '../../graphics/gradient.dart';
import 'replay_state.dart';

/// A paint, resolved out of the resource table and flattened.
///
/// Value semantics so a recording sink can be compared field by field, and
/// interned by the player so that a frame drawing ten thousand rectangles in
/// three colours allocates three of these, not ten thousand.
final class ReplayPaint {
  const ReplayPaint({
    required this.argbColor,
    required this.style,
    required this.strokeWidth,
    required this.blendMode,
    required this.antiAlias,
    this.fillRule = pathFillRuleNonZero,
  });

  /// Non-premultiplied 0xAARRGGBB, exactly as the encoder stored it. The
  /// conversion to the framebuffer's premultiplied BGRA belongs to the sink,
  /// which is the only side that knows the surface format.
  final int argbColor;

  /// One of the `paintStyle*` constants.
  final int style;

  /// In the coordinates the command was written in, not device pixels: the
  /// sink scales it, because only it knows whether it strokes geometry before
  /// or after transforming it.
  ///
  /// It is the *only* stroke attribute on the wire. The encoded paint record
  /// is two ints and one float - colour, a flag word holding style, blend mode
  /// and antialias, and this width - with no operand for cap, join or miter
  /// limit, so a sink that strokes has to supply them. `StrokeStyle`'s
  /// defaults (butt cap, miter join, miter limit 4) are the answer, and they
  /// are not an arbitrary pick: they are the same defaults every drawing API
  /// this list can be produced from starts a paint at, so nothing that can
  /// currently be *encoded* renders differently for the omission. When a
  /// producer grows a way to say otherwise, the flag word has free bits at
  /// 3..7 for a cap and a join, and the miter limit needs a second float -
  /// which is the change to make then, and dead wire format now.
  final double strokeWidth;

  /// One of the `blendMode*` constants.
  final int blendMode;

  final bool antiAlias;

  /// One of the `pathFillRule*` constants. Stroke outlines always override
  /// this to non-zero because that is part of the stroker's contract.
  final int fillRule;

  @override
  bool operator ==(Object other) =>
      other is ReplayPaint &&
      other.argbColor == argbColor &&
      other.style == style &&
      other.strokeWidth == strokeWidth &&
      other.blendMode == blendMode &&
      other.antiAlias == antiAlias &&
      other.fillRule == fillRule;

  @override
  int get hashCode => Object.hash(
      argbColor, style, strokeWidth, blendMode, antiAlias, fillRule);

  @override
  String toString() => 'ReplayPaint(0x${argbColor.toRadixString(16)}, '
      'style: $style, strokeWidth: $strokeWidth, blend: $blendMode, '
      'aa: $antiAlias, fillRule: $fillRule)';
}

/// The resource tables an encoded list's ids point into.
///
/// An interface rather than a direct [DisplayList] dependency because ids and
/// buffers travel apart: a list received from another isolate arrives as two
/// typed arrays with its resources rebuilt on the receiving side, and a test
/// wants to answer for three paints without building an encoder. The methods
/// mirror [DisplayList]'s accessors so that the common case,
/// [DisplayListResources], is pure forwarding.
abstract interface class ReplayResources {
  int paintColor(int id);
  int paintStyle(int id);
  double paintStrokeWidth(int id);
  int paintBlendMode(int id);
  bool paintAntiAlias(int id);
  int paintFillRule(int id);
  Gradient? paintGradient(int id);

  /// The path object that was interned under [id]. Opaque to the player -
  /// the display list stores paths as `Object` and offers no bounds, which is
  /// exactly why path geometry is handed to the sink untouched.
  Object pathAt(int id);

  Object imageAt(int id);

  /// The font interned under [id]: a face *at a size*, since the glyph-run
  /// opcode carries no size of its own.
  ///
  /// Opaque here for the same reason [pathAt] is. The player positions a run
  /// without ever asking what a glyph looks like - the offsets arrive already
  /// computed - so it has no use for the face, and resolving the id is left to
  /// the sink that will rasterize with it. That is why [RasterSink] receives
  /// the raw `fontId`: a sink that draws text holds these resources anyway,
  /// and one that does not should not be handed a face it has no rasterizer
  /// for.
  Object fontAt(int id);
}

/// [ReplayResources] backed by the list that encoded the stream.
final class DisplayListResources implements ReplayResources {
  const DisplayListResources(this._list);

  final DisplayList _list;

  @override
  int paintColor(int id) => _list.paintColor(id);

  @override
  int paintStyle(int id) => _list.paintStyle(id);

  @override
  double paintStrokeWidth(int id) => _list.paintStrokeWidth(id);

  @override
  int paintBlendMode(int id) => _list.paintBlendMode(id);

  @override
  bool paintAntiAlias(int id) => _list.paintAntiAlias(id);

  @override
  int paintFillRule(int id) => _list.paintFillRule(id);

  @override
  Gradient? paintGradient(int id) => _list.paintGradient(id);

  @override
  Object pathAt(int id) => _list.pathAt(id);

  @override
  Object imageAt(int id) => _list.imageAt(id);

  @override
  Object fontAt(int id) => _list.fontAt(id);
}

/// Where the player sends what survived transform, clip, and culling.
///
/// Contract for every method:
///
///   * all rectangles and offsets are device space, in pixels;
///   * `clip` is non-empty and overlaps the primitive. A primitive that is
///     entirely clipped out is never delivered at all, so an implementation
///     needs no "is any of this visible" test of its own - but it must still
///     honour `clip`, because the primitive is only guaranteed to *overlap*
///     it, not to be inside it;
///   * arrays passed in are borrowed for the duration of the call and are
///     reused by the player afterwards. An implementation that keeps them
///     must copy - see `RecordingSink` for the pattern.
///
/// The interface is deliberately small. Every method here is a shape a
/// rasteriser can implement without inventing policy, and anything the player
/// cannot express with them is refused loudly rather than approximated into
/// one of them.
abstract interface class RasterSink {
  /// Opens an offscreen scope for `saveLayer`.
  ///
  /// [deviceBounds] is the layer's declared bounds, already clipped; [paint]
  /// carries the alpha and blend mode the layer is composited back with.
  /// Layers are always delivered as balanced begin/end pairs, even when the
  /// bounds are empty, so an implementation can keep a stack.
  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint);

  /// Closes the innermost layer and composites it.
  void endLayer();

  /// Fills an axis-aligned device rectangle with a solid colour.
  ///
  /// Exact when the transform is axis-aligned; the bounding box of the true
  /// shape otherwise. See the library comment - the fix is a new method, not
  /// a change to this one.
  ///
  /// The player only ever calls this with `paintStyleFill`; a stroke-bearing
  /// style reaches [drawDevicePath] instead, because the width would need a
  /// matrix this method does not carry.
  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint);

  /// Fills a rounded rectangle. [deviceRadii] holds eight values in the
  /// encoder's order - top-left x/y, top-right, bottom-right, bottom-left -
  /// scaled into device space. Borrowed: copy it to keep it.
  ///
  /// Fill styles only, for the reason [fillDeviceRect] gives.
  void fillDeviceRRect(
    Rect deviceRect,
    Rect clip,
    Float32List deviceRadii,
    ReplayPaint paint,
  );

  /// Draws a path the player never inspected.
  ///
  /// [path] is whatever object the producer interned, and [transform] is the
  /// local-to-device matrix it must be flattened with. The player cannot cull
  /// this against anything tighter than the clip, because the display list
  /// gives it no path bounds.
  ///
  /// Two exceptions to "never inspected", both from the same decision: a
  /// stroked rectangle and a stroked rounded rectangle arrive here as a
  /// centreline the player built, which is always a `Path` even when the
  /// producer's own paths are some other object. See the library comment.
  ///
  /// This is also the only method that can be handed a stroke-bearing style,
  /// and the only one that can act on one, since the width it carries is in
  /// [transform]'s source space. With `paintStyleFillAndStroke` the fill is
  /// drawn first and the stroke over it - the other order hides the inner
  /// half of the stroke under the fill, and the shape comes out with a border
  /// half the width that was asked for.
  void drawDevicePath(
    Object path,
    Transform2D transform,
    Rect clip,
    ReplayPaint paint,
  );

  /// Blits [sourceRect] of [image] - in image pixels, untransformed - into
  /// [deviceRect].
  void drawDeviceImage(
    Object image,
    Rect sourceRect,
    Rect deviceRect,
    Rect clip,
    ReplayPaint paint,
  );

  /// Draws a shaped run.
  ///
  /// [deviceOrigin] and the [deviceOffsets] pairs are already in device space,
  /// the offsets being deltas from the origin; do not transform them again.
  /// [transform] is supplied so glyph outlines can be scaled and hinted for
  /// the device, which is a different use of the same matrix. [glyphIds] and
  /// [deviceOffsets] are borrowed scratch buffers longer than [glyphCount] -
  /// read only the first [glyphCount] ids and the first `2 * glyphCount`
  /// offsets.
  void drawDeviceGlyphRun(
    int fontId,
    Offset deviceOrigin,
    Transform2D transform,
    Int32List glyphIds,
    Float32List deviceOffsets,
    int glyphCount,
    Rect clip,
    ReplayPaint paint,
  );
}

/// A command that decodes correctly but that this player will not execute.
///
/// Always thrown, never skipped. A skipped command is a picture that is quietly
/// wrong in a way that looks like a rasteriser bug, and the cost of finding it
/// later dwarfs the cost of failing here - so the message carries the opcode
/// name and the word offset, which is enough to point at the exact command in
/// a dumped buffer.
final class UnsupportedCommandException implements Exception {
  const UnsupportedCommandException({
    required this.opcode,
    required this.commandIndex,
    required this.wordOffset,
    required this.reason,
  });

  final int opcode;
  final int commandIndex;

  /// Offset of the command's header in the word stream.
  final int wordOffset;

  final String reason;

  @override
  String toString() => 'UnsupportedCommandException: ${opcodeName(opcode)} '
      '(command $commandIndex at word $wordOffset): $reason';
}

/// Walks an encoded display list and drives a [RasterSink].
///
/// Long-lived by design: one player per surface, replayed every frame. All of
/// its scratch state - the save stack, the paint cache, the glyph buffers -
/// survives [play] so that a steady-state frame allocates only the geometry
/// objects it hands to the sink.
final class DisplayListPlayer {
  DisplayListPlayer(this.sink);

  final RasterSink sink;

  final ReplayState _state = ReplayState();

  /// Paint ids resolved during the current walk. Ids are dense and frame-local,
  /// so a list indexed by id is the whole cache.
  final List<ReplayPaint?> _paints = <ReplayPaint?>[];

  /// The save depths at which a `saveLayer` opened a layer, so that the
  /// matching `restore` knows whether it also has to close one.
  Uint32List _layerDepths = Uint32List(8);
  int _layerCount = 0;

  /// Scratch for the rounded-rectangle radii handed to the sink.
  final Float32List _radii = Float32List(8);

  /// Builds the centreline of a stroked rectangle. Reused rather than
  /// allocated per command so that a frame full of borders grows its buffers
  /// once; only the finished [Path] is new each time, and that one has to be,
  /// since it leaves this object and a sink is entitled to keep it.
  final PathBuilder _shapeBuilder = PathBuilder();

  // Sized once at the encoder's hard limit rather than grown, because that
  // limit exists precisely so a run cannot be unbounded; the pair costs 6 KB
  // and only for lists that actually carry text.
  Int32List? _glyphIds;
  Float32List? _glyphOffsets;

  /// Transform and clip as of the last command executed. Useful when a sink
  /// throws and the surrounding code wants to report where the walk was.
  ReplayState get state => _state;

  /// Replays [reader] from the start.
  ///
  /// [deviceBounds] is the surface, and becomes the root clip; [deviceTransform]
  /// maps the coordinates the list was written in onto device pixels, which is
  /// where a device pixel ratio or a scroll offset enters.
  ///
  /// Throws [UnbalancedRestoreException] or [UnbalancedSaveException] on a
  /// malformed scope structure, [UnsupportedCommandException] on a command
  /// this player cannot execute, and `DisplayListFormatException` from the
  /// reader on a corrupt buffer. Nothing is caught: a frame that cannot be
  /// interpreted must not be half-drawn.
  void play(
    DisplayListReader reader,
    ReplayResources resources, {
    required Rect deviceBounds,
    Transform2D deviceTransform = Transform2D.identity,
  }) {
    _state.reset(
      deviceBounds: deviceBounds,
      deviceTransform: deviceTransform,
    );
    // Resource ids are frame-local: a cached paint from the previous list
    // would answer with the wrong colour under the same id.
    _paints.clear();
    _layerCount = 0;

    reader.rewind();
    while (reader.moveNext()) {
      switch (reader.opcode) {
        case opSave:
          _state.save();
        case opSaveLayer:
          _saveLayer(reader, resources);
        case opRestore:
          _restore(reader);
        case opTransform:
          _state.concat(
            Transform2D(
              reader.floatAt(0),
              reader.floatAt(1),
              reader.floatAt(2),
              reader.floatAt(3),
              reader.floatAt(4),
              reader.floatAt(5),
            ),
          );
        case opClipRect:
          _clipRect(reader);
        case opDrawRect:
          _drawRect(reader, resources);
        case opDrawRRect:
          _drawRRect(reader, resources);
        case opDrawPath:
          _drawPath(reader, resources);
        case opDrawImage:
          _drawImage(reader, resources);
        case opDrawGlyphRun:
          _drawGlyphRun(reader, resources);
        case opClipPath:
          throw _unsupported(
            reader,
            'clipping to a path needs a clip mask; the replay state carries a '
            'rectangle, and the display list stores paths as opaque objects '
            'with no bounds to approximate one from',
          );
        default:
          // The reader rejects unknown opcodes before they reach here, so this
          // means a known opcode that this switch forgot - which must fail
          // just as loudly as a corrupt one.
          throw _unsupported(reader, 'no handler in this player');
      }
    }

    if (_state.saveDepth != 0) {
      throw UnbalancedSaveException(_state.saveDepth);
    }
  }

  // ---------------------------------------------------------------------
  // Commands
  // ---------------------------------------------------------------------

  void _saveLayer(DisplayListReader reader, ReplayResources resources) {
    final Rect bounds = _state.deviceBoundsOf(_rectOperand(reader, 0));
    final Rect clipped = _state.clip.intersect(bounds);
    // The pair is emitted even when the layer is entirely clipped out, so the
    // sink's layer stack stays balanced without it having to mirror the
    // player's culling decisions.
    sink.beginLayer(clipped, _state.clip, _paint(reader.paintId, resources));

    if (_layerCount == _layerDepths.length) {
      final Uint32List grown = Uint32List(_layerDepths.length * 2);
      grown.setRange(0, _layerCount, _layerDepths);
      _layerDepths = grown;
    }
    _layerDepths[_layerCount++] = _state.saveDepth;

    _state.save();
    // The declared bounds are a promise that nothing outside them is drawn;
    // honouring it here means the layer's contents get culled too, not just
    // its composite.
    _state.clipDeviceRect(bounds);
  }

  void _restore(DisplayListReader reader) {
    if (_state.saveDepth == 0) {
      throw UnbalancedRestoreException(
        commandIndex: reader.commandIndex,
        wordOffset: reader.headerOffset,
      );
    }
    final bool closesLayer = _layerCount > 0 &&
        _layerDepths[_layerCount - 1] == _state.saveDepth - 1;
    _state.restore();
    if (closesLayer) {
      _layerCount--;
      // After the pop, so the sink composites the layer under the transform
      // and clip that were in force when it was opened.
      sink.endLayer();
    }
  }

  void _clipRect(DisplayListReader reader) {
    if (reader.clipOp != clipOpIntersect) {
      throw _unsupported(
        reader,
        'a difference clip is not a rectangle, and the replay state carries '
        'only a rectangle; it needs the same mask stage clipPath does',
      );
    }
    _state.clipDeviceRect(_state.deviceBoundsOf(_rectOperand(reader, 0)));
  }

  void _drawRect(DisplayListReader reader, ReplayResources resources) {
    if (_state.clip.isEmpty) return;
    final ReplayPaint paint = _paint(reader.paintId, resources);
    final Rect local = _rectOperand(reader, 0);
    if (_strokes(reader, paint)) {
      _shapeBuilder.reset();
      _shapeBuilder.addRect(local);
      _drawCentreline(paint);
      return;
    }
    final Rect device = _state.deviceBoundsOf(local);
    if (!device.intersects(_state.clip)) return;
    sink.fillDeviceRect(device, _state.clip, paint);
  }

  void _drawRRect(DisplayListReader reader, ReplayResources resources) {
    if (_state.clip.isEmpty) return;
    final ReplayPaint paint = _paint(reader.paintId, resources);
    final Rect local = _rectOperand(reader, 0);
    if (_strokes(reader, paint)) {
      // Local radii, not the device ones computed below: the whole point of
      // the path route is that the sink applies the transform itself, so
      // pre-scaling here would apply it twice.
      for (var i = 0; i < 8; i++) {
        _radii[i] = reader.floatAt(4 + i);
      }
      _shapeBuilder.reset();
      _shapeBuilder.addRoundedRectRadii(local, _radii);
      _drawCentreline(paint);
      return;
    }
    final Rect device = _state.deviceBoundsOf(local);
    if (!device.intersects(_state.clip)) return;

    // Radii scale with the axis they belong to, so the x radii take the length
    // of the transformed x axis and the y radii that of the y axis. This is
    // exact for scale and rotation and merely plausible under skew - the same
    // caveat the bounding-box fill carries, and for the same reason.
    final Transform2D t = _state.transform;
    final double scaleX = _hypot(t.a, t.b);
    final double scaleY = _hypot(t.c, t.d);
    for (var i = 0; i < 8; i += 2) {
      _radii[i] = reader.floatAt(4 + i) * scaleX;
      _radii[i + 1] = reader.floatAt(5 + i) * scaleY;
    }
    sink.fillDeviceRRect(device, _state.clip, _radii, paint);
  }

  void _drawPath(DisplayListReader reader, ReplayResources resources) {
    if (_state.clip.isEmpty) return;
    sink.drawDevicePath(
      resources.pathAt(reader.pathId),
      _state.transform,
      _state.clip,
      _paint(reader.paintId, resources),
    );
  }

  void _drawImage(DisplayListReader reader, ReplayResources resources) {
    if (_state.clip.isEmpty) return;
    final Rect device = _state.deviceBoundsOf(_rectOperand(reader, 4));
    if (!device.intersects(_state.clip)) return;
    sink.drawDeviceImage(
      resources.imageAt(reader.imageId),
      _rectOperand(reader, 0),
      device,
      _state.clip,
      _paint(reader.paintId, resources),
    );
  }

  void _drawGlyphRun(DisplayListReader reader, ReplayResources resources) {
    if (_state.clip.isEmpty) return;
    final int count = reader.glyphCount;
    final Int32List ids = _glyphIds ??= Int32List(kMaxGlyphsPerRun);
    final Float32List offsets =
        _glyphOffsets ??= Float32List(kMaxGlyphsPerRun * 2);

    final Transform2D t = _state.transform;
    for (var i = 0; i < count; i++) {
      ids[i] = reader.glyphIdAt(i);
      // Only the linear part: the offsets are deltas from the run origin, and
      // the translation is already in the origin.
      final double x = reader.glyphOffsetXAt(i);
      final double y = reader.glyphOffsetYAt(i);
      offsets[i * 2] = t.a * x + t.c * y;
      offsets[i * 2 + 1] = t.b * x + t.d * y;
    }

    sink.drawDeviceGlyphRun(
      reader.fontId,
      t.transformOffset(Offset(reader.floatAt(0), reader.floatAt(1))),
      t,
      ids,
      offsets,
      count,
      _state.clip,
      _paint(reader.paintId, resources),
    );
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  /// Reads four consecutive float operands as a rectangle.
  Rect _rectOperand(DisplayListReader reader, int first) => Rect.fromLTRB(
        reader.floatAt(first),
        reader.floatAt(first + 1),
        reader.floatAt(first + 2),
        reader.floatAt(first + 3),
      );

  /// Interns a paint for the duration of the walk.
  ReplayPaint _paint(int id, ReplayResources resources) {
    while (_paints.length <= id) {
      _paints.add(null);
    }
    final ReplayPaint? cached = _paints[id];
    if (cached != null) return cached;
    final gradient = resources.paintGradient(id);
    if (gradient != null) {
      throw UnsupportedError(
        'gradient paint replay is not implemented yet; the display-list '
        'resource was preserved as $gradient instead of being rendered as '
        'an incorrect solid colour',
      );
    }
    final ReplayPaint paint = ReplayPaint(
      argbColor: resources.paintColor(id),
      style: resources.paintStyle(id),
      strokeWidth: resources.paintStrokeWidth(id),
      blendMode: resources.paintBlendMode(id),
      antiAlias: resources.paintAntiAlias(id),
      fillRule: resources.paintFillRule(id),
    );
    _paints[id] = paint;
    return paint;
  }

  /// Whether [paint] puts ink outside the shape's own area.
  ///
  /// Also the one place a style byte is validated. The encoder rejects an
  /// unknown style, so reaching the default here means a corrupt or
  /// hand-written buffer, and guessing "probably a fill" would draw a solid
  /// block wherever a future style meant something else.
  bool _strokes(DisplayListReader reader, ReplayPaint paint) =>
      switch (paint.style) {
        paintStyleFill => false,
        paintStyleStroke || paintStyleFillAndStroke => true,
        _ => throw _unsupported(
            reader,
            'paint style ${paint.style} is not fill, stroke or fillAndStroke; '
            'nothing here knows what it would draw',
          ),
      };

  /// Sends the centreline just built into [_shapeBuilder] to the sink.
  ///
  /// Deliberately without the device-bounds cull the fill routes do. A stroke
  /// reaches half its width outside the shape and a miter join further still,
  /// so a cull here would have to inflate by the join's allowance to be safe -
  /// and the sink's filler already culls the *outline's* real bounds against
  /// the same clip, which is both exact and free.
  ///
  /// A `fillAndStroke` shape goes through here whole rather than being split
  /// into a fast rectangle fill plus a stroke: the two halves must be drawn
  /// under one paint, and splitting them would need a second [ReplayPaint]
  /// that the id-keyed intern cache has no room for. The sink draws the fill
  /// first; see `RasterSink.drawDevicePath`.
  void _drawCentreline(ReplayPaint paint) {
    sink.drawDevicePath(
      _shapeBuilder.build(),
      _state.transform,
      _state.clip,
      paint,
    );
  }

  UnsupportedCommandException _unsupported(
    DisplayListReader reader,
    String reason,
  ) =>
      UnsupportedCommandException(
        opcode: reader.opcode,
        commandIndex: reader.commandIndex,
        wordOffset: reader.headerOffset,
        reason: reason,
      );

  /// Length of the vector (x, y) - the factor a unit length along that axis is
  /// scaled by.
  static double _hypot(double x, double y) => math.sqrt(x * x + y * y);
}
