/// [Shader] and [TileMode]: what a Flutter `Paint.shader` holds, and how a
/// gradient continues past its ends.
library;

import 'gradient.dart' show GradientSpread;

/// Something a paint samples per pixel instead of one colour - Flutter's
/// `Shader`.
///
/// The display list samples exactly one family natively: the linear and
/// radial [Gradient]s in `gradient.dart`, which extend this class. A
/// higher-level shader that the wire format cannot carry (a sweep gradient,
/// for instance) also extends it, and `Canvas` paints it by decomposition;
/// its documentation says how.
///
/// There is no image shader and no fragment program: the paint table holds
/// one colour or one gradient, nothing else.
abstract class Shader {
  /// Abstract const constructor, for subclasses.
  const Shader();
}

/// How a gradient is continued outside its 0..1 range - Flutter's `TileMode`.
enum TileMode {
  /// The edge colour extends forever.
  clamp,

  /// The ramp repeats.
  repeated,

  /// The ramp repeats, mirrored on every other repetition.
  mirror,

  /// Transparent outside the ramp. **Not supported by the display list**:
  /// painted as [clamp]. See [spread].
  decal;

  /// The display list's equivalent. [decal] has none and maps to
  /// [GradientSpread.pad], the documented approximation.
  GradientSpread get spread => switch (this) {
        TileMode.clamp || TileMode.decal => GradientSpread.pad,
        TileMode.repeated => GradientSpread.repeat,
        TileMode.mirror => GradientSpread.reflect,
      };
}
