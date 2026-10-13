// Adapted from material_color_utilities (Dart), the colour science behind
// Material 3's dynamic colour: CAM16, HCT and tonal palettes.
//
// Copyright 2021 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// The copy of the license is in assets/fonts/Apache-2.0.txt.

/// HCT (hue, chroma, tone) and the tonal palettes Material 3 builds a colour
/// scheme from.
///
/// Hue and chroma are CAM16's, tone is CIE L*: two colours with the same tone
/// have the same contrast against anything, whatever their hue. That is what
/// lets `ColorScheme.fromSeed` promise readable text on every role: the roles
/// are *tones* of a palette, and tone differences are contrast ratios.
///
/// The solver here searches the colour by Newton's method on CAM16 lightness
/// and, when the requested chroma is out of the sRGB gamut, bisects chroma down
/// to the gamut's edge. The library this is adapted from finds the same edge
/// geometrically; the two agree to within a unit in an 8-bit channel.
library;

import 'dart:math' as math;

/// sRGB -> XYZ (D65), XYZ in 0..100.
const List<List<double>> _srgbToXyz = <List<double>>[
  <double>[0.41233895, 0.35762064, 0.18051042],
  <double>[0.2126, 0.7152, 0.0722],
  <double>[0.01932141, 0.11916382, 0.95034478],
];

const List<List<double>> _xyzToSrgb = <List<double>>[
  <double>[3.2413774792388685, -1.5376652402851851, -0.49885366846268053],
  <double>[-0.9691452513005321, 1.8758853451067872, 0.04156585616912061],
  <double>[0.05562093689691305, -0.20395524564742123, 1.0571799111220335],
];

const List<double> _whitePointD65 = <double>[95.047, 100.0, 108.883];

const List<List<double>> _xyzToCam16Rgb = <List<double>>[
  <double>[0.401288, 0.650173, -0.051461],
  <double>[-0.250268, 1.204414, 0.045854],
  <double>[-0.002079, 0.048952, 0.953127],
];

const List<List<double>> _cam16RgbToXyz = <List<double>>[
  <double>[1.8620678, -1.0112547, 0.14918678],
  <double>[0.38752654, 0.62144744, -0.00897398],
  <double>[-0.0158415, -0.03412294, 1.0499644],
];

/// Helpers between ARGB integers, XYZ and L*.
abstract final class ColorUtils {
  static int argbFromRgb(int r, int g, int b) =>
      0xFF000000 | ((r & 255) << 16) | ((g & 255) << 8) | (b & 255);

  /// A gamma-encoded 0..255 channel as linear 0..100.
  static double linearized(int component) {
    final double normalized = component / 255.0;
    return normalized <= 0.040449936
        ? normalized / 12.92 * 100.0
        : math.pow((normalized + 0.055) / 1.055, 2.4).toDouble() * 100.0;
  }

  /// A linear 0..100 channel as gamma-encoded 0..255, clamped.
  static int delinearized(double rgbComponent) {
    final double normalized = rgbComponent / 100.0;
    final double delinearized = normalized <= 0.0031308
        ? normalized * 12.92
        : 1.055 * math.pow(normalized, 1.0 / 2.4).toDouble() - 0.055;
    return (delinearized * 255.0).round().clamp(0, 255);
  }

  static int argbFromLinrgb(List<double> linrgb) => argbFromRgb(
        delinearized(linrgb[0]),
        delinearized(linrgb[1]),
        delinearized(linrgb[2]),
      );

  static int argbFromXyz(double x, double y, double z) {
    const List<List<double>> m = _xyzToSrgb;
    return argbFromLinrgb(<double>[
      m[0][0] * x + m[0][1] * y + m[0][2] * z,
      m[1][0] * x + m[1][1] * y + m[1][2] * z,
      m[2][0] * x + m[2][1] * y + m[2][2] * z,
    ]);
  }

  static List<double> xyzFromArgb(int argb) {
    final double r = linearized((argb >> 16) & 255);
    final double g = linearized((argb >> 8) & 255);
    final double b = linearized(argb & 255);
    const List<List<double>> m = _srgbToXyz;
    return <double>[
      m[0][0] * r + m[0][1] * g + m[0][2] * b,
      m[1][0] * r + m[1][1] * g + m[1][2] * b,
      m[2][0] * r + m[2][1] * g + m[2][2] * b,
    ];
  }

  static double _labF(double t) {
    const double e = 216.0 / 24389.0;
    const double kappa = 24389.0 / 27.0;
    return t > e ? math.pow(t, 1.0 / 3.0).toDouble() : (kappa * t + 16) / 116;
  }

  static double _labInvf(double ft) {
    const double e = 216.0 / 24389.0;
    const double kappa = 24389.0 / 27.0;
    final double ft3 = ft * ft * ft;
    return ft3 > e ? ft3 : (116 * ft - 16) / kappa;
  }

  /// CIE L* (0..100) of a relative luminance Y (0..100).
  static double lstarFromY(double y) => _labF(y / 100.0) * 116.0 - 16.0;

  /// Relative luminance Y (0..100) of an L*.
  static double yFromLstar(double lstar) =>
      100.0 * _labInvf((lstar + 16.0) / 116.0);

  static double lstarFromArgb(int argb) => lstarFromY(xyzFromArgb(argb)[1]);

  /// The grey with this L*.
  static int argbFromLstar(double lstar) {
    final int component = delinearized(yFromLstar(lstar));
    return argbFromRgb(component, component, component);
  }

  static double sanitizeDegrees(double degrees) {
    final double d = degrees % 360.0;
    return d < 0 ? d + 360.0 : d;
  }
}

/// The conditions a colour is seen under; [standard] is sRGB's: a D65 white,
/// a mid-grey surround of L* 50, an average surround.
final class ViewingConditions {
  ViewingConditions._({
    required this.n,
    required this.aw,
    required this.nbb,
    required this.ncb,
    required this.c,
    required this.nc,
    required this.rgbD,
    required this.fl,
    required this.fLRoot,
    required this.z,
  });

  factory ViewingConditions._make() {
    const List<double> whitePoint = _whitePointD65;
    final double adaptingLuminance =
        (200.0 / math.pi) * ColorUtils.yFromLstar(50.0) / 100.0;
    const double backgroundLstar = 50.0;
    const double surround = 2.0;
    const List<List<double>> m = _xyzToCam16Rgb;
    final double rW = whitePoint[0] * m[0][0] +
        whitePoint[1] * m[0][1] +
        whitePoint[2] * m[0][2];
    final double gW = whitePoint[0] * m[1][0] +
        whitePoint[1] * m[1][1] +
        whitePoint[2] * m[1][2];
    final double bW = whitePoint[0] * m[2][0] +
        whitePoint[1] * m[2][1] +
        whitePoint[2] * m[2][2];
    const double f = 0.8 + surround / 10.0;
    final double c = f >= 0.9
        ? _lerp(0.59, 0.69, (f - 0.9) * 10.0)
        : _lerp(0.525, 0.59, (f - 0.8) * 10.0);
    double d =
        f * (1.0 - (1.0 / 3.6) * math.exp((-adaptingLuminance - 42.0) / 92.0));
    d = d.clamp(0.0, 1.0);
    const double nc = f;
    final List<double> rgbD = <double>[
      d * (100.0 / rW) + 1.0 - d,
      d * (100.0 / gW) + 1.0 - d,
      d * (100.0 / bW) + 1.0 - d,
    ];
    final double k = 1.0 / (5.0 * adaptingLuminance + 1.0);
    final double k4 = k * k * k * k;
    final double k4F = 1.0 - k4;
    final double fl = (k4 * adaptingLuminance) +
        (0.1 *
            k4F *
            k4F *
            math.pow(5.0 * adaptingLuminance, 1.0 / 3.0).toDouble());
    final double n = ColorUtils.yFromLstar(backgroundLstar) / whitePoint[1];
    final double z = 1.48 + math.sqrt(n);
    final double nbb = 0.725 / math.pow(n, 0.2).toDouble();
    final double ncb = nbb;
    final List<double> rgbAFactors = <double>[
      math.pow(fl * rgbD[0] * rW / 100.0, 0.42).toDouble(),
      math.pow(fl * rgbD[1] * gW / 100.0, 0.42).toDouble(),
      math.pow(fl * rgbD[2] * bW / 100.0, 0.42).toDouble(),
    ];
    final List<double> rgbA = <double>[
      (400.0 * rgbAFactors[0]) / (rgbAFactors[0] + 27.13),
      (400.0 * rgbAFactors[1]) / (rgbAFactors[1] + 27.13),
      (400.0 * rgbAFactors[2]) / (rgbAFactors[2] + 27.13),
    ];
    final double aw = (2.0 * rgbA[0] + rgbA[1] + 0.05 * rgbA[2]) * nbb;
    return ViewingConditions._(
      n: n,
      aw: aw,
      nbb: nbb,
      ncb: ncb,
      c: c,
      nc: nc,
      rgbD: rgbD,
      fl: fl,
      fLRoot: math.pow(fl, 0.25).toDouble(),
      z: z,
    );
  }

  static final ViewingConditions standard = ViewingConditions._make();

  final double n;
  final double aw;
  final double nbb;
  final double ncb;
  final double c;
  final double nc;
  final List<double> rgbD;
  final double fl;
  final double fLRoot;
  final double z;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// A colour in CAM16: lightness [j], [chroma] and [hue], plus the UCS
/// coordinates distances are measured in.
final class Cam16 {
  Cam16._(this.hue, this.chroma, this.j, this.jstar, this.astar, this.bstar);

  final double hue;
  final double chroma;
  final double j;
  final double jstar;
  final double astar;
  final double bstar;

  static Cam16 fromInt(int argb) {
    final List<double> xyz = ColorUtils.xyzFromArgb(argb);
    return fromXyz(xyz[0], xyz[1], xyz[2]);
  }

  static Cam16 fromXyz(double x, double y, double z) {
    final ViewingConditions vc = ViewingConditions.standard;
    const List<List<double>> m = _xyzToCam16Rgb;
    final double rC = m[0][0] * x + m[0][1] * y + m[0][2] * z;
    final double gC = m[1][0] * x + m[1][1] * y + m[1][2] * z;
    final double bC = m[2][0] * x + m[2][1] * y + m[2][2] * z;
    final double rD = vc.rgbD[0] * rC;
    final double gD = vc.rgbD[1] * gC;
    final double bD = vc.rgbD[2] * bC;
    double adapt(double d) {
      final double af = math.pow(vc.fl * d.abs() / 100.0, 0.42).toDouble();
      return d.sign * 400.0 * af / (af + 27.13);
    }

    final double rA = adapt(rD);
    final double gA = adapt(gD);
    final double bA = adapt(bD);
    final double a = (11.0 * rA + -12.0 * gA + bA) / 11.0;
    final double b = (rA + gA - 2.0 * bA) / 9.0;
    final double u = (20.0 * rA + 20.0 * gA + 21.0 * bA) / 20.0;
    final double p2 = (40.0 * rA + 20.0 * gA + bA) / 20.0;
    final double hue =
        ColorUtils.sanitizeDegrees(math.atan2(b, a) * 180.0 / math.pi);
    final double hueRadians = hue * math.pi / 180.0;
    final double ac = p2 * vc.nbb;
    final double j = 100.0 * math.pow(ac / vc.aw, vc.c * vc.z).toDouble();
    final double huePrime = hue < 20.14 ? hue + 360 : hue;
    final double eHue =
        0.25 * (math.cos(huePrime * math.pi / 180.0 + 2.0) + 3.8);
    final double p1 = 50000.0 / 13.0 * eHue * vc.nc * vc.ncb;
    final double t = p1 * math.sqrt(a * a + b * b) / (u + 0.305);
    final double alpha = math.pow(t, 0.9).toDouble() *
        math.pow(1.64 - math.pow(0.29, vc.n), 0.73).toDouble();
    final double chroma = alpha * math.sqrt(j / 100.0);
    return _withUcs(hue, chroma, j, hueRadians);
  }

  static Cam16 fromJch(double j, double c, double h) =>
      _withUcs(h, c, j, h * math.pi / 180.0);

  static Cam16 _withUcs(double hue, double chroma, double j, double hRad) {
    final double m = chroma * ViewingConditions.standard.fLRoot;
    final double jstar = (1.0 + 100.0 * 0.007) * j / (1.0 + 0.007 * j);
    final double mstar = 1.0 / 0.0228 * math.log(1.0 + 0.0228 * m);
    return Cam16._(
        hue, chroma, j, jstar, mstar * math.cos(hRad), mstar * math.sin(hRad));
  }

  /// The perceptual distance to [other] (CAM16-UCS ΔE').
  double distance(Cam16 other) {
    final double dJ = jstar - other.jstar;
    final double dA = astar - other.astar;
    final double dB = bstar - other.bstar;
    final double dEPrime = math.sqrt(dJ * dJ + dA * dA + dB * dB);
    return 1.41 * math.pow(dEPrime, 0.63).toDouble();
  }
}

/// A colour by hue (0..360), chroma (0..~150) and tone (L*, 0..100).
final class Hct {
  Hct._(int argb) : _argb = argb {
    final Cam16 cam = Cam16.fromInt(argb);
    hue = cam.hue;
    chroma = cam.chroma;
    tone = ColorUtils.lstarFromArgb(argb);
  }

  /// The colour [argb] is, in HCT.
  factory Hct.fromInt(int argb) => Hct._(argb);

  /// The colour closest to [hue], [chroma] and [tone] that sRGB can show:
  /// the tone and hue are kept, and the chroma lowered when it does not fit.
  factory Hct.from(double hue, double chroma, double tone) =>
      Hct._(HctSolver.solveToInt(hue, chroma, tone));

  final int _argb;
  late final double hue;
  late final double chroma;
  late final double tone;

  int toInt() => _argb;
}

/// Finds the sRGB colour for an HCT triple.
abstract final class HctSolver {
  static final List<List<double>> _linrgbFromScaled = _scaledMatrix();

  /// sRGB linear (0..100) from the scaled, adapted cone responses: the
  /// inverse of the chromatic adaptation folded with CAM16 -> XYZ -> sRGB.
  static List<List<double>> _scaledMatrix() {
    final ViewingConditions vc = ViewingConditions.standard;
    final List<List<double>> out = <List<double>>[
      <double>[0, 0, 0],
      <double>[0, 0, 0],
      <double>[0, 0, 0],
    ];
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        double sum = 0;
        for (int k = 0; k < 3; k++) {
          sum += _xyzToSrgb[r][k] * _cam16RgbToXyz[k][c];
        }
        out[r][c] = sum * 100.0 / (vc.fl * vc.rgbD[c]);
      }
    }
    return out;
  }

  static double _inverseChromaticAdaptation(double adapted) {
    final double abs = adapted.abs();
    final double base = math.max(0.0, 27.13 * abs / (400.0 - abs));
    return adapted.sign * math.pow(base, 1.0 / 0.42).toDouble();
  }

  /// The colour at [chroma] on the hue plane whose relative luminance is [y],
  /// or null when it is outside sRGB.
  static int? _findResultByJ(double hueRadians, double chroma, double y) {
    double j = math.sqrt(y) * 11.0;
    final ViewingConditions vc = ViewingConditions.standard;
    final double tInnerCoeff =
        1 / math.pow(1.64 - math.pow(0.29, vc.n), 0.73).toDouble();
    final double eHue = 0.25 * (math.cos(hueRadians + 2.0) + 3.8);
    final double p1 = eHue * (50000.0 / 13.0) * vc.nc * vc.ncb;
    final double hSin = math.sin(hueRadians);
    final double hCos = math.cos(hueRadians);
    final List<List<double>> m = _linrgbFromScaled;
    for (int round = 0; round < 5; round++) {
      final double jNormalized = j / 100.0;
      final double alpha =
          chroma == 0.0 || j == 0.0 ? 0.0 : chroma / math.sqrt(jNormalized);
      final double t = math.pow(alpha * tInnerCoeff, 1.0 / 0.9).toDouble();
      final double ac =
          vc.aw * math.pow(jNormalized, 1.0 / vc.c / vc.z).toDouble();
      final double p2 = ac / vc.nbb;
      final double gamma = 23.0 *
          (p2 + 0.305) *
          t /
          (23.0 * p1 + 11 * t * hCos + 108.0 * t * hSin);
      final double a = gamma * hCos;
      final double b = gamma * hSin;
      final double rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0;
      final double gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0;
      final double bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0;
      final double rS = _inverseChromaticAdaptation(rA);
      final double gS = _inverseChromaticAdaptation(gA);
      final double bS = _inverseChromaticAdaptation(bA);
      final List<double> linrgb = <double>[
        m[0][0] * rS + m[0][1] * gS + m[0][2] * bS,
        m[1][0] * rS + m[1][1] * gS + m[1][2] * bS,
        m[2][0] * rS + m[2][1] * gS + m[2][2] * bS,
      ];
      if (linrgb[0] < -0.01 || linrgb[1] < -0.01 || linrgb[2] < -0.01) {
        return null;
      }
      final double fnj =
          0.2126 * linrgb[0] + 0.7152 * linrgb[1] + 0.0722 * linrgb[2];
      if (fnj <= 0) return null;
      if (round == 4 || (fnj - y).abs() < 0.002) {
        if (linrgb[0] > 100.01 || linrgb[1] > 100.01 || linrgb[2] > 100.01) {
          return null;
        }
        return ColorUtils.argbFromLinrgb(<double>[
          math.max(0, linrgb[0]),
          math.max(0, linrgb[1]),
          math.max(0, linrgb[2]),
        ]);
      }
      // Newton's step on J, with Y ~ J^2 near the answer.
      j = j - (fnj - y) * j / (2 * fnj);
    }
    return null;
  }

  static int solveToInt(double hueDegrees, double chroma, double lstar) {
    if (chroma < 0.0001 || lstar < 0.0001 || lstar > 99.9999) {
      return ColorUtils.argbFromLstar(lstar);
    }
    final double hueRadians =
        ColorUtils.sanitizeDegrees(hueDegrees) / 180.0 * math.pi;
    final double y = ColorUtils.yFromLstar(lstar);
    final int? exact = _findResultByJ(hueRadians, chroma, y);
    if (exact != null) return exact;
    // Out of gamut: the most chroma sRGB has at this hue and tone.
    double low = 0.0;
    double high = chroma;
    int? best;
    for (int i = 0; i < 24; i++) {
      final double mid = (low + high) / 2;
      final int? found = _findResultByJ(hueRadians, mid, y);
      if (found == null) {
        high = mid;
      } else {
        best = found;
        low = mid;
      }
    }
    return best ?? ColorUtils.argbFromLstar(lstar);
  }
}

/// Every tone of one hue at one chroma - a row of Material 3's palettes.
final class TonalPalette {
  TonalPalette.of(this.hue, this.chroma);

  /// The palette [argb] belongs to, at its own hue and chroma.
  factory TonalPalette.fromInt(int argb) {
    final Hct hct = Hct.fromInt(argb);
    return TonalPalette.of(hct.hue, hct.chroma);
  }

  final double hue;
  final double chroma;
  final Map<double, int> _cache = <double, int>{};

  /// The colour at [tone] (0 black .. 100 white), as ARGB.
  int tone(double tone) =>
      _cache.putIfAbsent(tone, () => Hct.from(hue, chroma, tone).toInt());
}
