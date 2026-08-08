/// Deciding what one logical pixel is worth on X11.
///
/// This is the least determinate part of the backend, and it is worth being
/// explicit about why. Win32 has `GetDpiForWindow`: a per-monitor answer, from
/// the system, that changes as the window moves. macOS has `backingScaleFactor`
/// on the screen the window is on. **X11 has no equivalent at all.** The core
/// protocol reports one screen with one physical size, and that size is
/// frequently a fiction: a multi-head RANDR screen reports the bounding box of
/// every monitor, and a monitor with no EDID reports whatever the driver
/// invented, historically 1m x 1m to make the arithmetic land on 96 dpi.
///
/// So there is no *correct* source, only a defensible order. This is the one
/// used here, first match wins:
///
///  1. **[X11ScaleSource.explicit]** - a scale the embedder passed in. An
///     escape hatch that needs no guessing is the only thing that always
///     works, and it is what a support ticket gets resolved with.
///  2. **[X11ScaleSource.dartUiEnvironment]** - `DART_UI_SCALE`. Same escape
///     hatch, reachable without recompiling, and what CI pins so that a golden
///     test does not depend on the runner's X server.
///  3. **[X11ScaleSource.gdkScaleEnvironment]** - `GDK_SCALE`.
///  4. **[X11ScaleSource.qtScaleEnvironment]** - `QT_SCALE_FACTOR`.
///
///     Both of these are before Xft.dpi *because that is what GTK and Qt
///     themselves do*. In GTK, `GDK_SCALE` overrides everything the session
///     configured; in Qt, `QT_SCALE_FACTOR` overrides the platform plugin. A
///     user who exported one of them did so to force every window on their
///     desktop to a size, and an application that ignored it would be the only
///     one on the screen at the wrong size. Consistency with the neighbours
///     beats theoretical purity here.
///  5. **[X11ScaleSource.xftDpi]** - `Xft.dpi` from the X resource database
///     (the `RESOURCE_MANAGER` property on the root window), as `dpi / 96`.
///     This is what the desktop environment writes when the user moves the
///     scaling slider, it lives on the display rather than in one process's
///     environment, and it can change while running - which is why the window
///     watches root PropertyNotify for it and emits a scale-changed event.
///  6. **[X11ScaleSource.physicalSize]** - derived from the screen's reported
///     millimetres. Last, heavily sanity-checked, and *only believed when it
///     lands at 1.5x or more*. Below that the evidence is too weak: an
///     EDID-less monitor claiming 102 dpi would otherwise push every
///     application on an ordinary desktop to a 1.0625 scale, blurring text to
///     fix a problem nobody had. A screen genuinely dense enough to need 2x
///     will clear the bar by a mile.
///  7. **[X11ScaleSource.defaultUnity]** - 1.0. Being predictably wrong beats
///     being unpredictably right.
///
/// Whichever source wins, it is reported through [X11ScaleResolution.toDiagnostic]
/// so that a user on a HiDPI screen can read one log line and see *why* they
/// got the scale they got. That is the actual requirement: not to be right on
/// every desktop, which is impossible, but never to be silently wrong.
///
/// Deferred: per-output RANDR geometry. `RRGetScreenResources` +
/// `RRGetOutputInfo` + `RRGetCrtcInfo` would give the physical size of the
/// monitor the window is actually on, and with it a real per-monitor scale and
/// a real [WindowScaleChangedEvent] on a monitor change. It needs
/// `libxcb-randr` and three chained round trips, and it improves only case 6 -
/// the one deliberately distrusted. The extension is detected and reported by
/// the probe so the gap is visible; see `X11WindowingBackend.probe`.
library;

import 'dart:math' as math;

import '../../foundation/diagnostics.dart';

/// Where a resolved scale came from. Ordered by the precedence above.
enum X11ScaleSource {
  explicit,
  dartUiEnvironment,
  gdkScaleEnvironment,
  qtScaleEnvironment,
  xftDpi,
  physicalSize,
  defaultUnity,
}

/// The X11 convention for "unscaled": 96 dots per inch.
const double x11BaselineDpi = 96.0;

/// Below this, a scale derived from physical size is not believed. See the
/// library comment for the reasoning.
const double x11PhysicalScaleThreshold = 1.5;

/// A resolved scale plus the evidence for it.
final class X11ScaleResolution {
  const X11ScaleResolution({
    required this.scale,
    required this.source,
    required this.evidence,
    this.desktopScale,
  });

  /// Physical pixels per logical unit, for allocating surfaces.
  final double scale;

  final X11ScaleSource source;

  /// The raw value that produced [scale] - `Xft.dpi: 144`, `GDK_SCALE=2`,
  /// `1920px / 340mm`. Kept separate from the source so a log line carries
  /// both what was consulted and what it said.
  final String evidence;

  /// The user's text-size setting, when the display published one. Null means
  /// no separate desktop scale was found and [scale] serves for both.
  ///
  /// Kept apart from [scale] because they answer different questions: [scale]
  /// sizes a framebuffer, this sizes text. On X11 only `Xft.dpi` speaks to the
  /// second, and an application that conflated them would resize its whole
  /// layout when the user only asked for bigger fonts.
  final double? desktopScale;

  double get effectiveDesktopScale => desktopScale ?? scale;

  /// One greppable line for the CI log and for bug reports.
  BackendDiagnostic toDiagnostic() => BackendDiagnostic.note(
        'x11 scale ${_format(scale)} from ${source.name}',
        detail: evidence,
      );

  @override
  String toString() =>
      'X11ScaleResolution(${_format(scale)}, ${source.name}, $evidence)';

  static String _format(double value) => value.toStringAsFixed(3);
}

/// The screen dimensions the core protocol reports, as candidate 6 needs them.
final class X11PhysicalScreen {
  const X11PhysicalScreen({
    required this.widthInPixels,
    required this.heightInPixels,
    required this.widthInMillimetres,
    required this.heightInMillimetres,
  });

  final int widthInPixels;
  final int heightInPixels;
  final int widthInMillimetres;
  final int heightInMillimetres;

  /// Horizontal dots per inch, or null when the reported millimetres are not
  /// plausible for a display.
  ///
  /// The bounds are wide on purpose: they exist to reject the placeholders
  /// (0mm, and the 1000mm x 1000mm that a driver with no EDID hands back),
  /// not to second-guess an unusual but real monitor.
  double? get dotsPerInch {
    if (widthInPixels <= 0 || widthInMillimetres <= 0) return null;
    if (widthInMillimetres < 50 || widthInMillimetres > 2000) return null;
    final dpi = widthInPixels * 25.4 / widthInMillimetres;
    if (dpi < 48 || dpi > 480) return null;
    return dpi;
  }
}

/// Parses `Xft.dpi` out of an X resource database string.
///
/// The database is the raw text of the `RESOURCE_MANAGER` property: one
/// `resource:\tvalue` per line, comments starting with `!`, and no promise
/// about ordering or whitespace. Returns null when the resource is absent or
/// not a usable number, which is the common case on a bare X server.
///
/// Pure and separately testable, because this parser runs on every desktop the
/// framework will ever meet and a display is not needed to exercise it.
double? parseXftDpi(String resourceDatabase) {
  for (final rawLine in const LineSplitter().convert(resourceDatabase)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('!')) continue;
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    if (line.substring(0, colon).trim() != 'Xft.dpi') continue;
    final value = double.tryParse(line.substring(colon + 1).trim());
    // A zero or negative dpi is a broken entry, not a request for an
    // infinitely small window.
    if (value == null || value <= 0) return null;
    return value;
  }
  return null;
}

/// Splits on the line terminators an X resource database may use.
///
/// `dart:convert`'s `LineSplitter` is not imported here to keep this file free
/// of a dependency for four lines of code, and because the resource database
/// uses `\n` exclusively in practice while `\r\n` shows up when the value was
/// pasted from a Windows editor into an xrdb file.
final class LineSplitter {
  const LineSplitter();

  List<String> convert(String value) => value.split(RegExp(r'\r\n|\r|\n'));
}

/// Snaps [raw] to a scale a rasteriser is happy with, and clamps it.
///
/// Quarter steps rather than free-floating doubles: 1.0, 1.25, 1.5, 1.75, 2.0
/// are the values desktops actually offer, and snapping keeps a `Xft.dpi: 143`
/// from producing 1.4895833 - a number that turns every integer layout
/// coordinate into a fraction for no benefit anyone can see.
///
/// The upper clamp is 4.0. Higher is not a display, it is a typo, and
/// allocating a framebuffer for it is how a mistyped environment variable
/// becomes an out-of-memory kill.
double snapX11Scale(double raw) {
  if (!raw.isFinite || raw <= 0) return 1.0;
  final clamped = math.min(4.0, math.max(0.5, raw));
  return (clamped * 4).roundToDouble() / 4;
}

/// Parses a scale written in an environment variable.
///
/// `GDK_SCALE` is documented as an integer and `QT_SCALE_FACTOR` as a double;
/// both are parsed as doubles because a user who wrote `GDK_SCALE=1.5` meant
/// something, and refusing it would leave them at 1.0 with no explanation.
double? parseScaleEnvironment(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final parsed = double.tryParse(trimmed);
  if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
  return parsed;
}

/// Runs the precedence documented at the top of this file.
///
/// Every input is passed in rather than read from the ambient environment, so
/// the whole decision is testable on a machine with no X server - which is the
/// only way this logic gets covered at all, given that CI runs it under Xvfb
/// where every source but the last is absent.
X11ScaleResolution resolveX11Scale({
  double? explicitScale,
  String? dartUiScaleEnvironment,
  String? gdkScaleEnvironment,
  String? qtScaleFactorEnvironment,
  String? resourceDatabase,
  X11PhysicalScreen? screen,
}) {
  // Xft.dpi is read up front even when something above it wins, because it is
  // the only source that speaks to the *desktop* (text) scale, and the two are
  // reported separately.
  final xftDpi =
      resourceDatabase == null ? null : parseXftDpi(resourceDatabase);
  final desktopScale =
      xftDpi == null ? null : snapX11Scale(xftDpi / x11BaselineDpi);

  if (explicitScale != null && explicitScale > 0) {
    return X11ScaleResolution(
      scale: snapX11Scale(explicitScale),
      source: X11ScaleSource.explicit,
      evidence: 'embedder requested $explicitScale',
      desktopScale: desktopScale,
    );
  }

  final fromDartUi = parseScaleEnvironment(dartUiScaleEnvironment);
  if (fromDartUi != null) {
    return X11ScaleResolution(
      scale: snapX11Scale(fromDartUi),
      source: X11ScaleSource.dartUiEnvironment,
      evidence: 'DART_UI_SCALE=${dartUiScaleEnvironment!.trim()}',
      desktopScale: desktopScale,
    );
  }

  final fromGdk = parseScaleEnvironment(gdkScaleEnvironment);
  if (fromGdk != null) {
    return X11ScaleResolution(
      scale: snapX11Scale(fromGdk),
      source: X11ScaleSource.gdkScaleEnvironment,
      evidence: 'GDK_SCALE=${gdkScaleEnvironment!.trim()}',
      desktopScale: desktopScale,
    );
  }

  final fromQt = parseScaleEnvironment(qtScaleFactorEnvironment);
  if (fromQt != null) {
    return X11ScaleResolution(
      scale: snapX11Scale(fromQt),
      source: X11ScaleSource.qtScaleEnvironment,
      evidence: 'QT_SCALE_FACTOR=${qtScaleFactorEnvironment!.trim()}',
      desktopScale: desktopScale,
    );
  }

  if (xftDpi != null) {
    return X11ScaleResolution(
      scale: snapX11Scale(xftDpi / x11BaselineDpi),
      source: X11ScaleSource.xftDpi,
      evidence: 'RESOURCE_MANAGER Xft.dpi=$xftDpi',
      desktopScale: desktopScale,
    );
  }

  final dpi = screen?.dotsPerInch;
  if (dpi != null) {
    final candidate = snapX11Scale(dpi / x11BaselineDpi);
    if (candidate >= x11PhysicalScaleThreshold) {
      return X11ScaleResolution(
        scale: candidate,
        source: X11ScaleSource.physicalSize,
        evidence: '${screen!.widthInPixels}px / '
            '${screen.widthInMillimetres}mm = ${dpi.toStringAsFixed(1)}dpi',
        desktopScale: desktopScale,
      );
    }
    return X11ScaleResolution(
      scale: 1.0,
      source: X11ScaleSource.defaultUnity,
      evidence: 'physical size gave ${dpi.toStringAsFixed(1)}dpi '
          '(scale ${candidate.toStringAsFixed(2)}), below the '
          '${x11PhysicalScaleThreshold}x trust threshold',
      desktopScale: desktopScale,
    );
  }

  return X11ScaleResolution(
    scale: 1.0,
    source: X11ScaleSource.defaultUnity,
    evidence: screen == null
        ? 'no scale source available'
        : 'no scale source available; screen reported '
            '${screen.widthInMillimetres}mm x '
            '${screen.heightInMillimetres}mm',
    desktopScale: desktopScale,
  );
}
