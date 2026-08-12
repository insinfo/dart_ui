library;

import 'dart:typed_data';

/// A geometric vector used in TrueType projection and movement.
/// Represents a normalized direction.
final class TTVector {
  TTVector(this.x, this.y);
  double x;
  double y;

  void setFrom(TTVector other) {
    x = other.x;
    y = other.y;
  }
}

/// The state of the TrueType graphics engine.
/// Modified by instructions like SVPB, SVTCA, SROUND, etc.
final class GraphicsState {
  GraphicsState() {
    reset();
  }

  bool autoFlip = true;
  double controlValueCutIn = 0.0;
  int deltaBase = 9;
  int deltaShift = 3;

  final TTVector dualProjectionVector = TTVector(1.0, 0.0);
  final TTVector freeVector = TTVector(1.0, 0.0);
  final TTVector projectionVector = TTVector(1.0, 0.0);

  int instructControl = 0;
  int loop = 1;
  double minimumDistance = 1.0;

  int roundState = 1; // 1 = round to grid

  int rp0 = 0;
  int rp1 = 0;
  int rp2 = 0;

  int zp0 = 1;
  int zp1 = 1;
  int zp2 = 1;

  double singleWidthCutIn = 0.0;
  double singleWidthValue = 0.0;

  /// Resets the graphics state to defaults before executing a glyph program.
  void reset() {
    autoFlip = true;
    controlValueCutIn = 17.0 / 16.0;
    deltaBase = 9;
    deltaShift = 3;

    dualProjectionVector.x = 1.0;
    dualProjectionVector.y = 0.0;
    freeVector.x = 1.0;
    freeVector.y = 0.0;
    projectionVector.x = 1.0;
    projectionVector.y = 0.0;

    instructControl = 0;
    loop = 1;
    minimumDistance = 1.0;
    roundState = 1;

    rp0 = 0;
    rp1 = 0;
    rp2 = 0;

    zp0 = 1;
    zp1 = 1;
    zp2 = 1;

    singleWidthCutIn = 0.0;
    singleWidthValue = 0.0;
  }
}

/// A Zone represents a collection of points.
/// Zone 0 is the Twilight Zone (used for temporary points).
/// Zone 1 is the Glyph Zone (the actual points of the current glyph).
final class Zone {
  Zone({required int maxPoints})
      : curX = Float64List(maxPoints),
        curY = Float64List(maxPoints),
        orgX = Float64List(maxPoints),
        orgY = Float64List(maxPoints),
        tags = Uint8List(maxPoints);

  final Float64List curX;
  final Float64List curY;

  /// Original (unhinted) coordinates
  final Float64List orgX;
  final Float64List orgY;

  /// Point tags (on-curve, touched-x, touched-y)
  final Uint8List tags;

  /// Contour boundaries (necessary for IUP)
  List<int> contourEnds = const <int>[];
}
