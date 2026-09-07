/// The circuit: a closed centreline, the walls either side of it, and the two
/// questions the whole game asks of it every step.
///
/// Those questions are *"how far round am I?"* and *"how far off the middle am
/// I?"*, and answering both with one projection is what makes the rest cheap:
///
///   * lap counting is the first answer accumulated with the wrap removed;
///   * the walls are the second answer clamped;
///   * the grass is the second answer compared against the road's half width;
///   * the opponent's racing line is the first answer plus a look-ahead.
///
/// A polygon-soup collision test would answer none of them. It is also the
/// wrong shape for this track, which is a ribbon and not a room: swept along a
/// centreline, "outside the wall" is a scalar, and the response is a clamp of
/// that scalar rather than a contact manifold. `rapier`'s and `cannon-es`'
/// broad phase plus SAT would be strictly more code producing strictly less
/// information.
///
/// ## The centreline
///
/// Catmull-Rom through the control points, closed, because it interpolates
/// them: a designer moving a point moves the track *through* that point, which
/// a B-spline does not do and which turns "make turn 4 tighter" into a hunt.
/// The curve is then resampled at a fixed arc-length step, which is what makes
/// [TrackPath.frameAt] uniform - a spline parameter is not distance, and a
/// track sampled by parameter has samples bunched in the corners and stretched
/// on the straights, so the kerb texture would visibly change size around the
/// lap.
library;

import 'dart:math' as math;

/// One point on the centreline, with the frame the track carries there.
final class TrackSample {
  const TrackSample({
    required this.x,
    required this.z,
    required this.tangentX,
    required this.tangentZ,
    required this.normalX,
    required this.normalZ,
    required this.distance,
    required this.curvature,
  });

  final double x;
  final double z;

  /// Unit vector along the direction of travel.
  final double tangentX;
  final double tangentZ;

  /// Unit vector to the **right of travel**, which is `(-tangentZ, tangentX)`.
  ///
  /// The same handedness `KartBody.rightX` uses, and for the same reason: a
  /// lateral offset that meant "right" for the track and "left" for the kart
  /// would make the wall response push the kart further into the wall on
  /// exactly one side of the circuit.
  final double normalX;
  final double normalZ;

  /// Arc length from the start line to here, metres.
  final double distance;

  /// Signed curvature, 1/m, positive turning toward [normalX].
  ///
  /// An *estimate*, from the turn between the two two-metre chords either
  /// side, and good to about ten per cent - the resampling puts each sample on
  /// a chord of the spline rather than on the spline, and a millimetre of
  /// perpendicular error over a two-metre baseline is a few per cent of a
  /// gentle corner's turn angle. That is fine for what reads it: the opponent
  /// picks a corner speed as `sqrt(a / k)`, so ten per cent of curvature is
  /// five per cent of a speed it then approaches with a controller anyway.
  /// Nothing that decides a lap depends on it.
  final double curvature;
}

/// Where a point is, in the track's own coordinates.
final class TrackProjection {
  const TrackProjection({
    required this.distance,
    required this.lateral,
    required this.sampleIndex,
    required this.sample,
  });

  /// Arc length of the nearest point on the centreline, metres, in
  /// `[0, TrackPath.length)`.
  final double distance;

  /// Signed distance from the centreline, metres, positive to the right of
  /// travel.
  final double lateral;

  /// Which sample the search settled on, to be fed back as the next call's
  /// hint.
  final int sampleIndex;

  final TrackSample sample;
}

/// A closed circuit of constant width.
final class TrackPath {
  TrackPath._(this._samples, this.length, this.halfWidth, this.wallThickness);

  /// Builds the centreline from [controlPoints], closed, resampled every
  /// [sampleSpacing] metres.
  ///
  /// Throws when the loop is degenerate. That check is not defensive
  /// programming: a control list with a repeated point produces a zero-length
  /// segment, the tangent there is `0/0`, and the first thing anybody sees is
  /// a kart teleporting to NaN with nothing on screen to say why.
  factory TrackPath.fromControlPoints(
    List<(double, double)> controlPoints, {
    double halfWidth = 5.6,
    double wallThickness = 0.7,
    double sampleSpacing = 2.0,
    int smoothingPasses = 40,
  }) {
    if (controlPoints.length < 4) {
      throw ArgumentError.value(
        controlPoints.length,
        'controlPoints',
        'a closed Catmull-Rom loop needs at least four points',
      );
    }

    // Step 1: walk the spline densely by parameter, accumulating arc length.
    // Sixteen sub-steps per segment is well past the point where halving it
    // changes the measured length by more than a millimetre on this geometry,
    // and the cost is paid once at startup.
    const int subSteps = 48;
    final List<double> rawX = <double>[];
    final List<double> rawZ = <double>[];
    final int n = controlPoints.length;
    for (int i = 0; i < n; i++) {
      final (double p0x, double p0z) = controlPoints[(i - 1 + n) % n];
      final (double p1x, double p1z) = controlPoints[i];
      final (double p2x, double p2z) = controlPoints[(i + 1) % n];
      final (double p3x, double p3z) = controlPoints[(i + 2) % n];
      for (int step = 0; step < subSteps; step++) {
        final double t = step / subSteps;
        rawX.add(_catmullRom(p0x, p1x, p2x, p3x, t));
        rawZ.add(_catmullRom(p0z, p1z, p2z, p3z, t));
      }
    }

    final int rawCount = rawX.length;

    // Step 1b: round off the pinches.
    //
    // Catmull-Rom interpolates its control points, which is what makes the
    // shape editable - and it means the curve's tangent at a control point is
    // whatever `(p2 - p0) / 2` happens to be. Where two placed points meet at
    // seventy degrees the curve does not turn *through* seventy degrees over
    // the segment; it turns most of it within a couple of metres of the
    // vertex, and the measured radius there was 8.7 m on an eleven-metre-wide
    // track. That is not a corner, it is a wall with a gap in it: no speed
    // takes it, the opponent brakes to walking pace for it, and the only
    // symptom from the cockpit is that turn 3 is impossible.
    //
    // Forty Laplacian passes over a polyline sampled every 74 cm spread that
    // turn over about four metres, which brings the tightest radius on this
    // circuit from 8.7 m to something a kart can hold. It shortens the lap by
    // under a percent - a smoothed curve cuts its own corners - and it is
    // applied to the dense polyline rather than to the control points so that
    // the shape a designer typed is still the shape they get.
    for (int pass = 0; pass < smoothingPasses; pass++) {
      final List<double> nextX = List<double>.of(rawX);
      final List<double> nextZ = List<double>.of(rawZ);
      for (int i = 0; i < rawCount; i++) {
        final int back = (i - 1 + rawCount) % rawCount;
        final int ahead = (i + 1) % rawCount;
        nextX[i] = rawX[i] + 0.5 * (rawX[back] + rawX[ahead] - 2 * rawX[i]);
        nextZ[i] = rawZ[i] + 0.5 * (rawZ[back] + rawZ[ahead] - 2 * rawZ[i]);
      }
      rawX.setAll(0, nextX);
      rawZ.setAll(0, nextZ);
    }

    final List<double> rawDistance = List<double>.filled(rawCount + 1, 0);
    for (int i = 0; i < rawCount; i++) {
      final int next = (i + 1) % rawCount;
      final double dx = rawX[next] - rawX[i];
      final double dz = rawZ[next] - rawZ[i];
      rawDistance[i + 1] = rawDistance[i] + math.sqrt(dx * dx + dz * dz);
    }
    final double total = rawDistance[rawCount];
    if (!total.isFinite || total < 1) {
      throw ArgumentError.value(
        controlPoints,
        'controlPoints',
        'the loop is degenerate: its total length is $total',
      );
    }

    // Step 2: resample at a uniform arc-length spacing. The count is rounded
    // so the last sample joins the first exactly; a track whose seam is a
    // fraction of a metre long has one kerb quad the wrong size, right on the
    // start line where everybody looks.
    final int count = math.max(16, (total / sampleSpacing).round());
    final double spacing = total / count;
    final List<double> xs = List<double>.filled(count, 0);
    final List<double> zs = List<double>.filled(count, 0);
    int cursor = 0;
    for (int i = 0; i < count; i++) {
      final double wanted = i * spacing;
      while (cursor + 1 < rawCount && rawDistance[cursor + 1] < wanted) {
        cursor++;
      }
      final double span = rawDistance[cursor + 1] - rawDistance[cursor];
      final double t = span <= 0 ? 0.0 : (wanted - rawDistance[cursor]) / span;
      final int next = (cursor + 1) % rawCount;
      xs[i] = rawX[cursor] + (rawX[next] - rawX[cursor]) * t;
      zs[i] = rawZ[cursor] + (rawZ[next] - rawZ[cursor]) * t;
    }

    // Step 3: the frame at each sample, from the neighbours either side. A
    // forward difference would make every tangent point half a sample ahead,
    // which tilts the kerbs and biases the wall by a centimetre or two - small
    // enough to look like a physics bug rather than a geometry one.
    final List<TrackSample> samples = <TrackSample>[];
    for (int i = 0; i < count; i++) {
      final int back = (i - 1 + count) % count;
      final int ahead = (i + 1) % count;
      double tx = xs[ahead] - xs[back];
      double tz = zs[ahead] - zs[back];
      final double len = math.sqrt(tx * tx + tz * tz);
      tx /= len;
      tz /= len;
      // Curvature from the turn between the two half-segments, per metre.
      final double inX = xs[i] - xs[back];
      final double inZ = zs[i] - zs[back];
      final double outX = xs[ahead] - xs[i];
      final double outZ = zs[ahead] - zs[i];
      final double cross = inX * outZ - inZ * outX;
      final double inLen = math.sqrt(inX * inX + inZ * inZ);
      final double outLen = math.sqrt(outX * outX + outZ * outZ);
      final double turn = math.asin(
        (cross / (inLen * outLen)).clamp(-1.0, 1.0),
      );
      samples.add(TrackSample(
        x: xs[i],
        z: zs[i],
        tangentX: tx,
        tangentZ: tz,
        normalX: -tz,
        normalZ: tx,
        distance: i * spacing,
        // Negated so that positive curvature turns toward `normal`, which is
        // the right of travel: `cross` is positive for a left turn in this
        // handedness.
        curvature: -turn / ((inLen + outLen) * 0.5),
      ));
    }
    return TrackPath._(samples, total, halfWidth, wallThickness);
  }

  final List<TrackSample> _samples;

  /// One lap, metres.
  final double length;

  /// Half the drivable road, metres. Outside this is grass; outside
  /// `halfWidth + wallThickness` is a wall.
  final double halfWidth;

  /// How much grass there is between the road's edge and the wall.
  final double wallThickness;

  /// Where the wall actually is, from the centreline.
  double get wallOffset => halfWidth + wallThickness;

  List<TrackSample> get samples => _samples;

  int get sampleCount => _samples.length;

  double get sampleSpacing => length / _samples.length;

  /// The sample at [index], wrapped. Dart's `%` on a positive divisor is
  /// already non-negative, so a negative index wraps from the end.
  TrackSample sampleAt(int index) => _samples[index % _samples.length];

  /// The frame at arc length [distance], interpolated between samples.
  TrackSample frameAt(double distance) {
    final int count = _samples.length;
    final double spacing = length / count;
    double s = distance % length;
    if (s < 0) s += length;
    final double exact = s / spacing;
    final int i = exact.floor() % count;
    final int j = (i + 1) % count;
    final double t = exact - exact.floor();
    final TrackSample a = _samples[i];
    final TrackSample b = _samples[j];
    double tx = a.tangentX + (b.tangentX - a.tangentX) * t;
    double tz = a.tangentZ + (b.tangentZ - a.tangentZ) * t;
    final double len = math.sqrt(tx * tx + tz * tz);
    if (len > 0) {
      tx /= len;
      tz /= len;
    }
    return TrackSample(
      x: a.x + (b.x - a.x) * t,
      z: a.z + (b.z - a.z) * t,
      tangentX: tx,
      tangentZ: tz,
      normalX: -tz,
      normalZ: tx,
      distance: s,
      curvature: a.curvature + (b.curvature - a.curvature) * t,
    );
  }

  /// Where `(x, z)` is on the track.
  ///
  /// [hint] is the sample index the caller was at last step. With one, only a
  /// window around it is searched, which turns a per-step O(samples) scan into
  /// a constant - and it is *checked*: when the best sample in the window is
  /// at the window's edge the search falls back to the whole track, because a
  /// kart that was reset, rammed or driven backwards through a hairpin can
  /// legitimately be nowhere near its hint. Trusting the window without that
  /// check is how a kart that spins gets stuck reporting the wrong half of the
  /// lap and counts a lap it never drove.
  TrackProjection project(double x, double z, {int? hint}) {
    final int count = _samples.length;
    const int window = 12;
    int best = -1;
    double bestDistance = double.infinity;

    void consider(int index) {
      final TrackSample sample = _samples[index];
      final double dx = x - sample.x;
      final double dz = z - sample.z;
      final double squared = dx * dx + dz * dz;
      if (squared < bestDistance) {
        bestDistance = squared;
        best = index;
      }
    }

    if (hint != null) {
      for (int offset = -window; offset <= window; offset++) {
        consider((hint + offset) % count);
      }
      final int relative = ((best - hint + count) % count);
      // Two ways the window can be wrong, and both have to be checked.
      //
      // The best sample sitting *on* the window's edge means the real nearest
      // one is probably outside it. And a best sample that is nonetheless
      // implausibly far away means the query point is nowhere near this part
      // of the circuit at all - which happens the moment a kart is reset, is
      // rammed off the road, or is handed a hint from before a spin. Only the
      // first check was here at first, and it let a point on the far side of
      // the track project onto sample zero and report a lap it had not driven.
      final double reach = (wallOffset + 12) * (wallOffset + 12);
      if (relative == window ||
          relative == count - window ||
          bestDistance > reach) {
        best = -1;
      }
    }
    if (best < 0) {
      bestDistance = double.infinity;
      for (int i = 0; i < count; i++) {
        consider(i);
      }
    }

    // Refine against the two segments meeting at the nearest sample. Reporting
    // the sample's own arc length instead would quantise progress to the
    // sample spacing, and the lap counter would then step in two-metre jumps -
    // visible as a lap time that is only ever a multiple of the time it takes
    // to cross one sample.
    final int previous = (best - 1 + count) % count;
    final (double sA, double dA) = _projectOntoSegment(previous, best, x, z);
    final (double sB, double dB) =
        _projectOntoSegment(best, (best + 1) % count, x, z);
    final bool useA = dA.abs() < dB.abs();
    double s = useA ? sA : sB;
    s %= length;
    if (s < 0) s += length;
    return TrackProjection(
      distance: s,
      lateral: useA ? dA : dB,
      sampleIndex: best,
      sample: frameAt(s),
    );
  }

  /// Projects onto the segment from sample [a] to sample [b], returning
  /// (arc length, signed lateral offset). The parameter is clamped to the
  /// segment so a point beyond its end reports the end, which is what makes
  /// the caller's comparison between two segments meaningful.
  (double, double) _projectOntoSegment(int a, int b, double x, double z) {
    final TrackSample p = _samples[a];
    final TrackSample q = _samples[b];
    final double ex = q.x - p.x;
    final double ez = q.z - p.z;
    final double lengthSquared = ex * ex + ez * ez;
    if (lengthSquared <= 0) return (p.distance, 0);
    final double t =
        (((x - p.x) * ex + (z - p.z) * ez) / lengthSquared).clamp(0.0, 1.0);
    final double px = p.x + ex * t;
    final double pz = p.z + ez * t;
    final double segmentLength = math.sqrt(lengthSquared);
    final double nx = -ez / segmentLength;
    final double nz = ex / segmentLength;
    return (p.distance + segmentLength * t, (x - px) * nx + (z - pz) * nz);
  }

  static double _catmullRom(
    double p0,
    double p1,
    double p2,
    double p3,
    double t,
  ) {
    final double t2 = t * t;
    final double t3 = t2 * t;
    return 0.5 *
        ((2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
  }
}

/// The circuit this demo ships with.
///
/// A ninety-metre main straight into a fast right, a medium right, a
/// left-right chicane that punishes a late brake, a hairpin, and two linked
/// lefts back onto the straight. The shape is hand-placed rather than
/// generated: a radial function guarantees a loop that never crosses itself
/// and produces corners that all feel the same, and one circuit that plays
/// well is the whole point.
///
/// `track_test.dart` checks that it never comes within a road's width of
/// itself, which is the failure a hand-placed loop actually has.
/// Index zero is the start line, and it is on the straight rather than in a
/// corner: the grid sits seven to thirteen metres *behind* it, so a start line
/// placed at an apex would leave the whole field pointing across the road for
/// the countdown.
const List<(double, double)> kCircuitControlPoints = <(double, double)>[
  (2, 16), // start / finish, on the main straight
  (3, 54),
  (16, 90), // turn 1 entry
  (48, 112), // turn 1: the fast right across the top
  (86, 102),
  (106, 72), // turn 2
  (100, 44),
  (88, 22), // turn 3: the chicane's left
  (94, -8), // turn 4: the chicane's right
  (92, -40),
  (62, -58), // turn 5: the slow right
  (28, -50),
  (-4, -64),
  (-32, -58), // turn 6: the long right at the bottom
  (-38, -32),
  (-10, -10), // turn 7: back onto the straight
];

/// The circuit, built.
TrackPath buildCircuit() =>
    TrackPath.fromControlPoints(kCircuitControlPoints, halfWidth: 5.8);
