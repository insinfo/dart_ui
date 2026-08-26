/// The palette's accessibility contract, checked arithmetically.
///
/// A colour scheme is the one part of a design system that cannot be reviewed
/// by looking: "the grey label reads fine on my monitor" is exactly the
/// judgement WCAG's contrast ratio exists to replace. So every built-in theme
/// is measured here, pair by pair, against the two thresholds that matter:
///
///   * **4.5:1** for text against the surface it sits on (WCAG 2.2 SC 1.4.3,
///     AA, normal-size text);
///   * **3:1** for a control's own boundary and for a graphical mark that
///     carries meaning - an outline, a focus ring, a chevron (SC 1.4.11).
///
/// Disabled text is deliberately absent: SC 1.4.3 exempts it, and a disabled
/// control that met the contrast of an enabled one would stop reading as
/// disabled. It is measured all the same, against a floor low enough to allow
/// the "switched off" reading and high enough to keep it legible.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  const Map<String, ThemeData> themes = <String, ThemeData>{
    'neutral-light': ThemeData.neutralLight,
    'neutral-dark': ThemeData.neutralDark,
    'material-light': ThemeData.materialLight,
    'material-dark': ThemeData.materialDark,
    'fluent-light': ThemeData.fluentLight,
    'high-contrast-dark': ThemeData.highContrastDark,
  };

  group('text contrast is at least 4.5:1', () {
    themes.forEach((String name, ThemeData theme) {
      test(name, () {
        // Body text on each of the four surfaces it can land on.
        for (final (String where, Color background) in <(String, Color)>[
          ('surfaceBase', theme.surfaceBase),
          ('surface', theme.surface),
          ('surfaceAlternate', theme.surfaceAlternate),
          ('surfaceRaised', theme.surfaceRaised),
        ]) {
          expect(
            _contrast(theme.foreground, background),
            greaterThanOrEqualTo(4.5),
            reason: '$name: foreground on $where',
          );
          expect(
            _contrast(theme.foregroundSecondary, background),
            greaterThanOrEqualTo(4.5),
            reason: '$name: secondary text on $where',
          );
        }

        // A label on top of the accent - a primary button, a checked box, a
        // selected day - and a label on top of a selection or a subtle accent
        // wash, which keep the ordinary foreground.
        expect(
          _contrast(theme.colorScheme.onPrimary, theme.accent),
          greaterThanOrEqualTo(4.5),
          reason: '$name: onPrimary on accent',
        );
        expect(
          _contrast(theme.colorScheme.onPrimary, theme.accentHovered),
          greaterThanOrEqualTo(4.5),
          reason: '$name: onPrimary on the hovered accent',
        );
        expect(
          _contrast(theme.colorScheme.onPrimary, theme.accentPressed),
          greaterThanOrEqualTo(4.5),
          reason: '$name: onPrimary on the pressed accent',
        );
        expect(
          _contrast(theme.onSelection, theme.selection),
          greaterThanOrEqualTo(4.5),
          reason: '$name: text on a selected row',
        );
        expect(
          _contrast(theme.foreground, theme.accentSubtle),
          greaterThanOrEqualTo(4.5),
          reason: '$name: text on the subtle accent wash',
        );
        expect(
          _contrast(theme.foreground, theme.hoverSurface),
          greaterThanOrEqualTo(4.5),
          reason: '$name: text on a hovered row',
        );
        expect(
          _contrast(theme.foreground, theme.pressedSurface),
          greaterThanOrEqualTo(4.5),
          reason: '$name: text on a pressed control',
        );
      });
    });
  });

  group('boundaries and marks are at least 3:1', () {
    themes.forEach((String name, ThemeData theme) {
      test(name, () {
        // The outline of something the user can aim at, against the two
        // surfaces such a control sits on.
        expect(
          _contrast(theme.borderStrong, theme.surfaceAlternate),
          greaterThanOrEqualTo(3.0),
          reason: '$name: an input outline on content',
        );
        expect(
          _contrast(theme.borderStrong, theme.surface),
          greaterThanOrEqualTo(3.0),
          reason: '$name: an input outline on a panel',
        );
        // The focus ring has to be findable on everything it can appear over.
        for (final (String where, Color background) in <(String, Color)>[
          ('surface', theme.surface),
          ('surfaceAlternate', theme.surfaceAlternate),
          ('surfaceRaised', theme.surfaceRaised),
        ]) {
          expect(
            _contrast(theme.focusRing, background),
            greaterThanOrEqualTo(3.0),
            reason: '$name: the focus ring on $where',
          );
        }
        // A filled accent control against the ground it sits on: without this
        // a primary button on a tinted panel loses its own edge.
        expect(
          _contrast(theme.accent, theme.surface),
          greaterThanOrEqualTo(3.0),
          reason: '$name: an accent fill on a panel',
        );
        // The accent-coloured mark on a selected toolbar button.
        expect(
          _contrast(theme.accent, theme.accentSubtle),
          greaterThanOrEqualTo(3.0),
          reason: '$name: an accent glyph on the subtle accent wash',
        );
      });
    });
  });

  group('the surface ladder only ever goes one way', () {
    themes.forEach((String name, ThemeData theme) {
      test(name, () {
        // `surfaceSunken` is the only step that goes *down* from the window's
        // own ground, and the whole reason it exists is that a document has to
        // read as paper lying on something. A theme that filled it in lighter
        // than `surfaceBase` would have inverted the one relationship the
        // token is named for - and nothing in a rendered canvas would say so
        // except a page that stopped looking like a page.
        expect(
          _relativeLuminance(theme.surfaceSunken),
          lessThanOrEqualTo(_relativeLuminance(theme.surfaceBase) + 1e-9),
          reason: '$name: the canvas well must not be lighter than the window',
        );
        // And it has to be distinguishable from the page laid on it, or the
        // hierarchy is a hierarchy on paper only. High contrast is exempt:
        // every one of its surfaces is pure black by design, and there the
        // page is told apart by its border alone.
        if (!theme.highContrast) {
          expect(
            _contrast(theme.surfaceAlternate, theme.surfaceSunken),
            greaterThanOrEqualTo(1.15),
            reason: '$name: the page has to be a real step above the desk - '
                'this step is what separates them, because the 3:1 outline '
                'that would do it instead is unreachable against any desk '
                'light enough to be a surface',
          );
        }
      });
    });
  });

  group('disabled reads as disabled without becoming invisible', () {
    themes.forEach((String name, ThemeData theme) {
      test(name, () {
        final double onSurface =
            _contrast(theme.disabledForeground, theme.surface);
        expect(onSurface, greaterThanOrEqualTo(2.0),
            reason: '$name: disabled text is still readable');
        // High contrast is the deliberate exception: its whole point is that
        // nothing is dimmed, so its disabled colour is a hue change instead.
        if (!theme.highContrast) {
          expect(
            onSurface,
            lessThan(_contrast(theme.foreground, theme.surface)),
            reason: '$name: disabled must be dimmer than enabled',
          );
        }
      });
    });
  });

  test('the type scale keeps one source of truth for the base size', () {
    for (final ThemeData theme in themes.values) {
      expect(theme.fontSize, theme.textTheme.base,
          reason: '${theme.name}: a control label and a Text must agree');
      expect(theme.textTheme.bodyMedium.fontSize, theme.fontSize);
      expect(theme.textTheme.labelSmall.fontSize, theme.fontSize - 2);
      expect(theme.textTheme.titleMedium.fontSize, theme.fontSize + 2);
      expect(theme.textTheme.bodyMedium.height, greaterThan(1.0),
          reason: 'wrapped text needs leading, and it is a multiplier');
    }
  });

  test('every metric lands on the spacing grid', () {
    for (final ThemeData theme in themes.values) {
      for (final ThemeDensity density in ThemeDensity.values) {
        final ThemeData at = theme.copyWith(density: density);
        expect(at.effectiveControlHeight % 4, 0,
            reason: '${theme.name}/$density: control height off the grid');
        expect(at.effectiveRowHeight % 4, 0,
            reason: '${theme.name}/$density: row height off the grid');
        expect(at.effectiveControlPadding % 4, 0,
            reason: '${theme.name}/$density: padding off the grid');
        expect(at.effectiveGap % 4, 0,
            reason: '${theme.name}/$density: gap off the grid');
        // A row is denser than a control at every step: a list whose rows are
        // as tall as buttons shows a third fewer of them.
        expect(at.effectiveRowHeight, lessThan(at.effectiveControlHeight));
      }
    }
  });
}

/// The WCAG 2.2 contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final double la = _relativeLuminance(a);
  final double lb = _relativeLuminance(b);
  final double lighter = la > lb ? la : lb;
  final double darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// WCAG relative luminance: sRGB channels linearised, then weighted.
double _relativeLuminance(Color color) {
  double channel(int shift) {
    final double srgb = ((color.value >> shift) & 0xFF) / 255.0;
    return srgb <= 0.03928 ? srgb / 12.92 : _pow((srgb + 0.055) / 1.055, 2.4);
  }

  return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
}

/// `x^y` for the one exponent this file needs, without importing dart:math
/// into a test whose whole subject is colour arithmetic.
double _pow(double x, double y) {
  // Exponentiation by the identity x^y = e^(y ln x), expanded far enough that
  // the result matches dart:math to more decimal places than a colour has.
  double ln(double v) {
    final double z = (v - 1) / (v + 1);
    double sum = 0;
    double term = z;
    for (int i = 1; i <= 39; i += 2) {
      sum += term / i;
      term *= z * z;
    }
    return 2 * sum;
  }

  final double t = y * ln(x);
  double sum = 1;
  double term = 1;
  for (int i = 1; i <= 30; i++) {
    term *= t / i;
    sum += term;
  }
  return sum;
}
