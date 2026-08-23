/// A [RasterSink] that answers "what did the player decide?" instead of
/// drawing.
///
/// This is the instrument the interpreter is tested with, and the one a
/// debugger reaches for when a frame comes out wrong: it turns a walk into a
/// list of value objects that say exactly which primitives survived culling,
/// in which order, under which device transform and clip. Comparing those is
/// how a transform-order or clip-nesting bug is caught; comparing pixels is
/// how it is missed, because a wrong matrix and a wrong clip produce the same
/// kind of wrong image.
///
/// Unlike everything else on the replay path this file is allowed to allocate,
/// and does: one call object per primitive, with the borrowed radii and glyph
/// buffers copied out. That copy is not incidental - it is the reference
/// implementation of the [RasterSink] contract that says those arrays are
/// scratch, and a sink that skipped it would report every glyph run as
/// whatever the last one contained.
library;

import 'dart:typed_data';

import '../../geometry/offset.dart';
import '../../geometry/rect.dart';
import '../../geometry/transform2d.dart';
import 'display_list_player.dart';

/// One recorded [RasterSink] call.
///
/// Sealed so a test can switch over the recording exhaustively and a new sink
/// method cannot be added without the recorder and its readers noticing.
sealed class RasterCall {
  const RasterCall();
}

final class BeginLayerCall extends RasterCall {
  const BeginLayerCall(this.deviceBounds, this.clip, this.paint);

  final Rect deviceBounds;
  final Rect clip;
  final ReplayPaint paint;

  @override
  String toString() => 'beginLayer($deviceBounds, clip: $clip, $paint)';
}

final class EndLayerCall extends RasterCall {
  const EndLayerCall();

  @override
  String toString() => 'endLayer()';
}

final class FillRectCall extends RasterCall {
  const FillRectCall(this.deviceRect, this.clip, this.paint);

  final Rect deviceRect;
  final Rect clip;
  final ReplayPaint paint;

  @override
  String toString() => 'fillDeviceRect($deviceRect, clip: $clip, $paint)';
}

final class FillRRectCall extends RasterCall {
  const FillRRectCall(this.deviceRect, this.clip, this.deviceRadii, this.paint);

  final Rect deviceRect;
  final Rect clip;

  /// A copy of the eight radii, in the encoder's corner order.
  final List<double> deviceRadii;

  final ReplayPaint paint;

  @override
  String toString() =>
      'fillDeviceRRect($deviceRect, clip: $clip, radii: $deviceRadii, $paint)';
}

final class DrawPathCall extends RasterCall {
  const DrawPathCall(this.path, this.transform, this.clip, this.paint);

  /// The interned path object, by identity: the player never opened it.
  final Object path;

  final Transform2D transform;
  final Rect clip;
  final ReplayPaint paint;

  @override
  String toString() => 'drawDevicePath($path, $transform, clip: $clip, $paint)';
}

final class DrawImageCall extends RasterCall {
  const DrawImageCall(
    this.image,
    this.sourceRect,
    this.deviceRect,
    this.clip,
    this.paint,
  );

  final Object image;
  final Rect sourceRect;
  final Rect deviceRect;
  final Rect clip;
  final ReplayPaint paint;

  @override
  String toString() => 'drawDeviceImage($image, src: $sourceRect, '
      'dst: $deviceRect, clip: $clip, $paint)';
}

final class DrawGlyphRunCall extends RasterCall {
  const DrawGlyphRunCall(
    this.fontId,
    this.deviceOrigin,
    this.transform,
    this.glyphIds,
    this.deviceOffsets,
    this.clip,
    this.paint,
  );

  final int fontId;
  final Offset deviceOrigin;
  final Transform2D transform;

  /// Copies trimmed to the run's glyph count, so a test never has to know how
  /// long the player's scratch buffers are.
  final List<int> glyphIds;

  /// `2 * glyphIds.length` device-space deltas from [deviceOrigin].
  final List<double> deviceOffsets;

  final Rect clip;
  final ReplayPaint paint;

  int get glyphCount => glyphIds.length;

  @override
  String toString() => 'drawDeviceGlyphRun(font: $fontId, $deviceOrigin, '
      '${glyphIds.length} glyphs, clip: $clip, $paint)';
}

/// Records every call the player makes, in order.
final class RecordingSink implements RasterSink, GradientRasterSink {
  final List<RasterCall> _calls = <RasterCall>[];

  /// The recording, oldest first.
  List<RasterCall> get calls => List<RasterCall>.unmodifiable(_calls);

  int get callCount => _calls.length;

  /// The single recorded call of type [T]. Fails loudly when there is not
  /// exactly one, because "the first fill" quietly ignoring a second fill is
  /// how a test passes while the player emits twice.
  T single<T extends RasterCall>() {
    final Iterable<T> matches = _calls.whereType<T>();
    if (matches.length != 1) {
      throw StateError(
        'expected exactly one $T in the recording, found ${matches.length}: '
        '$_calls',
      );
    }
    return matches.first;
  }

  List<T> allOf<T extends RasterCall>() => _calls.whereType<T>().toList();

  void clear() => _calls.clear();

  @override
  void beginLayer(Rect deviceBounds, Rect clip, ReplayPaint paint) =>
      _calls.add(BeginLayerCall(deviceBounds, clip, paint));

  @override
  void endLayer() => _calls.add(const EndLayerCall());

  @override
  void fillDeviceRect(Rect deviceRect, Rect clip, ReplayPaint paint) =>
      _calls.add(FillRectCall(deviceRect, clip, paint));

  @override
  void fillDeviceRRect(
    Rect deviceRect,
    Rect clip,
    Float32List deviceRadii,
    ReplayPaint paint,
  ) =>
      _calls.add(
        FillRRectCall(deviceRect, clip, List<double>.of(deviceRadii), paint),
      );

  @override
  void drawDevicePath(
    Object path,
    Transform2D transform,
    Rect clip,
    ReplayPaint paint,
  ) =>
      _calls.add(DrawPathCall(path, transform, clip, paint));

  @override
  void drawDeviceImage(
    Object image,
    Rect sourceRect,
    Rect deviceRect,
    Rect clip,
    ReplayPaint paint,
  ) =>
      _calls.add(
        DrawImageCall(image, sourceRect, deviceRect, clip, paint),
      );

  @override
  void drawDeviceGlyphRun(
    int fontId,
    Offset deviceOrigin,
    Transform2D transform,
    Int32List glyphIds,
    Float32List deviceOffsets,
    int glyphCount,
    Rect clip,
    ReplayPaint paint,
  ) =>
      _calls.add(
        DrawGlyphRunCall(
          fontId,
          deviceOrigin,
          transform,
          glyphIds.sublist(0, glyphCount),
          deviceOffsets.sublist(0, glyphCount * 2),
          clip,
          paint,
        ),
      );
}
