/// The Material theme: Flutter's ThemeData defaults, ColorScheme.fromSeed's
/// Material 3 tonal palettes, the type scale, Colors and Icons, and Theme.of
/// resolving through the widget tree.
library;

import 'package:dart_ui/material.dart';
import 'package:dart_ui/src/widgets/theme.dart' as dui;
import 'package:test/test.dart';

double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('ColorScheme.fromSeed', () {
    test('matches the tones Flutter gives the baseline seed', () {
      final ColorScheme s =
          ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4));
      // Tonal spot: primary is tone 40 of the seed hue at chroma 36.
      expect(s.primary, const Color(0xFF65558F));
      expect(s.error, const Color(0xFFBA1A1A));
      expect(s.brightness, Brightness.light);
      expect(Hct.fromInt(s.primary.value).tone, closeTo(40, 0.6));
      expect(Hct.fromInt(s.primaryContainer.value).tone, closeTo(90, 0.6));
      expect(Hct.fromInt(s.surface.value).tone, closeTo(98, 0.6));
    });

    test('is deterministic and readable in both brightnesses', () {
      for (final Brightness b in Brightness.values) {
        final ColorScheme one =
            ColorScheme.fromSeed(seedColor: Colors.teal, brightness: b);
        final ColorScheme two =
            ColorScheme.fromSeed(seedColor: Colors.teal, brightness: b);
        expect(one, two);
        expect(_contrast(one.primary, one.onPrimary), greaterThan(4.5));
        expect(_contrast(one.surface, one.onSurface), greaterThan(7));
        expect(
          _contrast(one.primaryContainer, one.onPrimaryContainer),
          greaterThan(4.5),
        );
      }
      final ColorScheme dark = ColorScheme.fromSeed(
          seedColor: Colors.teal, brightness: Brightness.dark);
      expect(Hct.fromInt(dark.primary.value).tone, closeTo(80, 0.6));
      // The seed's hue survives.
      expect(
        (Hct.fromInt(dark.primary.value).hue -
                Hct.fromInt(Colors.teal.value).hue)
            .abs(),
        lessThan(6),
      );
    });

    test('an explicit role wins', () {
      final ColorScheme s = ColorScheme.fromSeed(
          seedColor: Colors.blue, primary: const Color(0xFF123456));
      expect(s.primary, const Color(0xFF123456));
    });
  });

  group('ThemeData', () {
    test('defaults are Material 3 with the baseline scheme', () {
      final ThemeData t = ThemeData();
      expect(t.useMaterial3, isTrue);
      expect(t.colorScheme.primary, const Color(0xFF6750A4));
      expect(t.scaffoldBackgroundColor, t.colorScheme.surface);
      expect(t.textTheme.headlineMedium!.fontSize, 28);
      expect(t.textTheme.bodyMedium!.fontSize, 14);
      expect(t.textTheme.bodyMedium!.color, t.colorScheme.onSurface);
      expect(ThemeData.dark().colorScheme.surface, const Color(0xFF141218));
    });

    test('colorSchemeSeed and brightness build the scheme', () {
      final ThemeData t =
          ThemeData(colorSchemeSeed: Colors.green, brightness: Brightness.dark);
      expect(t.brightness, Brightness.dark);
      expect(
          t.colorScheme,
          ColorScheme.fromSeed(
              seedColor: Colors.green, brightness: Brightness.dark));
      expect(
          () => ThemeData(
              colorSchemeSeed: Colors.green,
              colorScheme: const ColorScheme.light()),
          throwsArgumentError);
    });

    test('copyWith and AppBarTheme as data', () {
      final ThemeData t = ThemeData(
          appBarTheme: const AppBarTheme(backgroundColor: Colors.red));
      expect(t.appBarTheme.backgroundColor, Colors.red);
      final ThemeData u = t.copyWith(scaffoldBackgroundColor: Colors.white);
      expect(u.scaffoldBackgroundColor, Colors.white);
      expect(u.appBarTheme.backgroundColor, Colors.red);
    });

    test('maps onto the dart_ui theme', () {
      final ThemeData t = ThemeData(colorSchemeSeed: Colors.indigo);
      final dui.ThemeData d = t.dartUiTheme;
      expect(d.accent, t.colorScheme.primary);
      expect(d.foreground, t.colorScheme.onSurface);
      expect(d.controlStyle, ControlStyle.material);
    });
  });

  test('Colors carry their shades and Icons Flutter\'s names', () {
    expect(Colors.blue.value, 0xFF2196F3);
    expect(Colors.red[700], const Color(0xFFD32F2F));
    expect(Colors.blue.shade100, const Color(0xFFBBDEFB));
    expect(Colors.black54, const Color(0x8A000000));
    expect(Icons.add.codePoint, 0xE145);
    expect(Icons.arrow_back.matchTextDirection, isTrue);
    expect(Icons.home_outlined.codePoint, Icons.home.codePoint);
  });

  test('Theme.of resolves the Material theme and installs dart_ui\'s', () {
    final ThemeData data = ThemeData(colorSchemeSeed: Colors.orange);
    ThemeData? seen;
    dui.ThemeData? seenDui;
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(100, 100))),
    );
    addTearDown(owner.dispose);
    owner.updateRoot(Theme(
      data: data,
      child: Builder(builder: (BuildContext context) {
        seen = Theme.of(context);
        seenDui = dui.Theme.of(context);
        return const Material(child: SizedBox());
      }),
    ));
    owner.buildScope();
    expect(identical(seen, data), isTrue);
    expect(seenDui, same(data.dartUiTheme));
  });

  test('Material paints its colour and casts a shadow when raised', () {
    expect(materialShadows(0, Colors.black), isEmpty);
    expect(materialShadows(3, Colors.black), hasLength(2));
  });
}
