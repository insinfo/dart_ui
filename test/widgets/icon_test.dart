/// Icons, from the widget down to the bytes.
///
/// Ahem is what makes these assertions exact. Every glyph in that face is a
/// solid box spanning the full em horizontally and rising 0.8 em above the
/// baseline while descending 0.2 below - so an [Icon] of it at size 40 must
/// come out as a fully covered 40x40 square with nothing outside it. That turns
/// "is the icon centred", "is the box the right size" and "did the ascent get
/// added twice" into equality on integers rather than into a matter of opinion.
///
/// DejaVu Sans appears where the point is a real, asymmetric outline: the
/// mirroring tests need a glyph whose reflection is different from itself, and
/// a solid box is not one.
library;

import 'dart:io';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/rect.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/color.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/layout/render_box.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/text/font_registry.dart';
import 'package:dart_ui/src/rendering/text/framework_fonts.dart';
import 'package:dart_ui/src/rendering/text/glyph_cache.dart';
import 'package:dart_ui/src/text/shaper.dart';
import 'package:dart_ui/src/text/typeface.dart';
import 'package:dart_ui/src/widgets/basic.dart';
import 'package:dart_ui/src/widgets/directionality.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/icon.dart';
import 'package:dart_ui/src/widgets/phosphor_icons.dart';
import 'package:dart_ui/src/widgets/widget.dart';
import 'package:test/test.dart';

/// Ahem's `X`, which is the solid em box every exact assertion below rests on.
const IconData block = IconData(0x58, fontFamily: 'AhemIcons');

/// Ahem's `p`, which occupies only the descender: 1 em wide and 0.2 em tall,
/// sitting *below* the baseline. The asymmetry is what makes it able to catch a
/// baseline computed the wrong way round.
const IconData descender = IconData(0x70, fontFamily: 'AhemIcons');

/// DejaVu's `U+2190` LEFTWARDS ARROW - directional, so it mirrors.
const IconData arrow =
    IconData(0x2190, fontFamily: 'DejaVuIcons', matchTextDirection: true);

/// The same arrow, declared not to mirror, so the two routes can be compared.
const IconData fixedArrow = IconData(0x2190, fontFamily: 'DejaVuIcons');

Typeface _face(String name) =>
    Typeface.parse(File('test/fonts/$name').readAsBytesSync());

(BuildOwner, PipelineOwner) _mounted(
  Widget root,
  Size viewport, {
  bool tight = true,
}) {
  final PipelineOwner pipeline = PipelineOwner(
    rootConstraints:
        tight ? BoxConstraints.tight(viewport) : BoxConstraints.loose(viewport),
  );
  final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
    ..updateRoot(root);
  pipeline.flushLayout();
  return (owner, pipeline);
}

/// The tree, laid out, painted and rasterised onto a white surface.
Framebuffer _render(Widget root, Size viewport) {
  final (BuildOwner owner, PipelineOwner pipeline) = _mounted(root, viewport);
  addTearDown(owner.dispose);
  final DisplayList list = DisplayList();
  pipeline.flushPaint(list);
  final Framebuffer surface = Framebuffer.allocate(
    width: viewport.width.round(),
    height: viewport.height.round(),
  )..clear(255, 255, 255, 255);
  // A fresh cache per render: a shared one would let one test's rasterisation
  // answer another's.
  rasterizeDisplayList(list, surface, glyphCache: GlyphCache());
  return surface;
}

/// The bounding box of everything that is not the white background.
Rect? _inkBounds(Framebuffer surface) {
  int? left;
  int? top;
  int? right;
  int? bottom;
  for (int y = 0; y < surface.height; y++) {
    for (int x = 0; x < surface.width; x++) {
      final int offset = surface.offsetOf(x, y);
      if (surface.pixels[offset] == 255 &&
          surface.pixels[offset + 1] == 255 &&
          surface.pixels[offset + 2] == 255) {
        continue;
      }
      left = left == null || x < left ? x : left;
      top = top == null || y < top ? y : top;
      right = right == null || x + 1 > right ? x + 1 : right;
      bottom = bottom == null || y + 1 > bottom ? y + 1 : bottom;
    }
  }
  if (left == null) return null;
  return Rect.fromLTRB(
    left.toDouble(),
    top!.toDouble(),
    right!.toDouble(),
    bottom!.toDouble(),
  );
}

/// One channel of the pixel at ([x], [y]).
int _blueAt(Framebuffer surface, int x, int y) =>
    surface.pixels[surface.offsetOf(x, y)];

int _redAt(Framebuffer surface, int x, int y) =>
    surface.pixels[surface.offsetOf(x, y) + 2];

void main() {
  setUpAll(() {
    // Two parses of the same file, deliberately. `registerTypeface` is a no-op
    // for a face it already holds - `useTypeface` registers under the font's
    // own family - so registering the *same instance* under a second name
    // would silently do nothing, and every lookup by that name would miss.
    FontRegistry.instance
      ..useTypeface(_face('ahem.ttf'), source: 'test/fonts/ahem.ttf')
      ..registerTypeface(
        _face('ahem.ttf'),
        family: 'AhemIcons',
        source: 'ahem-icons',
      )
      ..registerTypeface(
        _face('DejaVuSans.ttf'),
        family: 'DejaVuIcons',
        source: 'dejavu-icons',
      );
    final FrameworkFontLoadResult bundled = FrameworkFonts.install();
    expect(bundled.tablerIconFontLoaded, isTrue);
    expect(bundled.phosphorIconFontLoaded, isTrue);
  });
  tearDownAll(FontRegistry.instance.reset);

  group('IconData', () {
    test('is a value, so a rebuild with the same icon is not a change', () {
      expect(const IconData(0xE801), const IconData(0xE801));
      expect(
        const IconData(0xE801, fontFamily: 'A'),
        isNot(const IconData(0xE801, fontFamily: 'B')),
      );
      expect(
        const IconData(0xE801),
        isNot(const IconData(0xE801, matchTextDirection: true)),
      );
      expect(
        const IconData(0xE801).hashCode,
        const IconData(0xE801).hashCode,
      );
    });

    test('prints as a code point rather than as a number', () {
      expect(const IconData(0x2713).toString(), contains('U+2713'));
      expect(
        const IconData(0x2190, fontFamily: 'Nav', matchTextDirection: true)
            .toString(),
        contains('mirrors'),
      );
    });
  });

  group('layout', () {
    test('an icon is a square of its declared size', () {
      final (BuildOwner owner, _) = _mounted(
          const Icon(block, size: 24), const Size(100, 100),
          tight: false);
      addTearDown(owner.dispose);
      final RenderIcon render = owner.renderRoot! as RenderIcon;
      expect(render.size, const Size(24, 24));
    });

    test('the default size is the declared constant', () {
      final (BuildOwner owner, _) =
          _mounted(const Icon(block), const Size(100, 100), tight: false);
      addTearDown(owner.dispose);
      expect(
        (owner.renderRoot! as RenderIcon).size,
        const Size(kDefaultIconSize, kDefaultIconSize),
      );
    });

    test('intrinsics report the same number both ways: an icon cannot shrink',
        () {
      final RenderIcon render = RenderIcon(block, size: 32);
      expect(render.getMinIntrinsicWidth(double.infinity), 32);
      expect(render.getMaxIntrinsicWidth(double.infinity), 32);
      expect(render.getMinIntrinsicHeight(double.infinity), 32);
      expect(render.getMaxIntrinsicHeight(double.infinity), 32);
    });

    test('a tight parent still wins', () {
      final (BuildOwner owner, _) =
          _mounted(const Icon(block, size: 80), const Size(20, 20));
      addTearDown(owner.dispose);
      expect((owner.renderRoot! as RenderIcon).size, const Size(20, 20));
    });

    test('an update changes the size and re-lays out', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(100, 100)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(const Icon(block, size: 10));
      addTearDown(owner.dispose);
      pipeline.flushLayout();
      expect((owner.renderRoot! as RenderIcon).size, const Size(10, 10));

      owner.updateRoot(const Icon(block, size: 30));
      pipeline.flushLayout();
      expect((owner.renderRoot! as RenderIcon).size, const Size(30, 30));
    });
  });

  group('bundled icon optical alignment', () {
    test('Tabler ink is centred inside the declared square', () {
      for (final IconData icon in <IconData>[
        TablerIcons.folderOpen,
        TablerIcons.search,
        TablerIcons.sun,
        TablerIcons.zoomIn,
      ]) {
        final Framebuffer surface = _render(
          Icon(icon, size: 20, color: const Color(0xFF000000)),
          const Size(20, 20),
        );
        final Rect? ink = _inkBounds(surface);
        expect(ink, isNotNull, reason: '$icon must be present in the font');
        expect(ink!.center.dx, closeTo(10, 1), reason: '$icon horizontally');
        expect(ink.center.dy, closeTo(10, 1), reason: '$icon vertically');
      }
    });

    test('Phosphor ink is centred inside the declared square', () {
      for (final IconData icon in <IconData>[
        PhosphorIcons.floppyDisk,
        PhosphorIcons.folderOpen,
        PhosphorIcons.magnifyingGlass,
        PhosphorIcons.moon,
      ]) {
        final Framebuffer surface = _render(
          Icon(icon, size: 20, color: const Color(0xFF000000)),
          const Size(20, 20),
        );
        final Rect? ink = _inkBounds(surface);
        expect(ink, isNotNull, reason: '$icon must be present in the font');
        expect(ink!.center.dx, closeTo(10, 1), reason: '$icon horizontally');
        expect(ink.center.dy, closeTo(10, 1), reason: '$icon vertically');
      }
    });
  });

  group('the glyph route, in exact pixels', () {
    test('Ahem at 40 fills its box precisely and nothing outside it', () {
      final Framebuffer surface = _render(
        const Icon(block, size: 40, color: Color(0xFF000000)),
        const Size(40, 40),
      );

      expect(_inkBounds(surface), const Rect.fromLTRB(0, 0, 40, 40));
      // Every pixel, not just the bounds: Ahem's box is pixel aligned here, so
      // there is no antialiased fringe to excuse a partial value anywhere.
      for (int y = 0; y < 40; y++) {
        for (int x = 0; x < 40; x++) {
          expect(_blueAt(surface, x, y), 0, reason: '($x, $y)');
        }
      }
    });

    test('the icon is centred in a box larger than it', () {
      final Framebuffer surface = _render(
        const Align(
          child: Icon(block, size: 20, color: Color(0xFF000000)),
        ),
        const Size(60, 60),
      );
      expect(_inkBounds(surface), const Rect.fromLTRB(20, 20, 40, 40));
    });

    test('the descender glyph proves the baseline is where it says it is', () {
      // Ahem's `p` occupies only the 0.2 em below the baseline. In a 40-pixel
      // box whose em box is centred, the baseline sits at y = 32, so the ink is
      // the bottom eight rows and nothing above them. A baseline computed from
      // the top of the box, or with the ascent added twice, moves this.
      final Framebuffer surface = _render(
        const Icon(descender, size: 40, color: Color(0xFF000000)),
        const Size(40, 40),
      );
      expect(_inkBounds(surface), const Rect.fromLTRB(0, 32, 40, 40));
    });

    test('the baseline the render node reports is the one it draws at', () {
      final (BuildOwner owner, _) = _mounted(
        const Icon(block, size: 40),
        const Size(40, 40),
      );
      addTearDown(owner.dispose);
      final RenderIcon render = owner.renderRoot! as RenderIcon;
      expect(
        render.getDistanceToBaseline(TextBaseline.alphabetic),
        32,
        reason: 'Ahem rises 0.8 em above the baseline',
      );
    });

    test('the colour is the paint\'s, so one cached mask serves every theme',
        () {
      final Framebuffer red = _render(
        const Icon(block, size: 8, color: Color(0xFFFF0000)),
        const Size(8, 8),
      );
      expect(_redAt(red, 4, 4), 255);
      expect(_blueAt(red, 4, 4), 0);

      final Framebuffer blue = _render(
        const Icon(block, size: 8, color: Color(0xFF0000FF)),
        const Size(8, 8),
      );
      expect(_redAt(blue, 4, 4), 0);
      expect(_blueAt(blue, 4, 4), 255);
    });

    test('a fully transparent icon draws nothing at all', () {
      final Framebuffer surface = _render(
        const Icon(block, size: 20, color: Color(0x00000000)),
        const Size(20, 20),
      );
      expect(_inkBounds(surface), isNull);
    });

    test('half alpha composites, it does not replace', () {
      final Framebuffer surface = _render(
        const Icon(block, size: 8, color: Color(0x80000000)),
        const Size(8, 8),
      );
      // Black at alpha 128 over white: 0 + mul255(255, 127) = 127.
      expect(_blueAt(surface, 4, 4), 127);
    });
  });

  group('the face behind an icon', () {
    test('a registered family is found by name', () {
      final RenderIcon render = RenderIcon(block, size: 40);
      expect(render.font, isNotNull);
      expect(render.font!.pixelSize, 40);
      expect(render.hasGlyph, isTrue);
      expect(render.glyphId, isNot(0));
    });

    test('an unregistered family is reported, not substituted', () {
      final RenderIcon render =
          RenderIcon(const IconData(0xE800, fontFamily: 'NoSuchFamily'));
      expect(render.font, isNull);
      expect(render.hasGlyph, isFalse);
      expect(render.glyphId, 0);
    });

    test('a code point the face does not carry draws nothing', () {
      // U+E800 is in the Private Use Area and Ahem has nothing there.
      final RenderIcon render =
          RenderIcon(const IconData(0xE800, fontFamily: 'AhemIcons'), size: 20);
      expect(render.font, isNotNull);
      expect(render.hasGlyph, isFalse);

      final Framebuffer surface = _render(
        const Icon(IconData(0xE800, fontFamily: 'AhemIcons'), size: 20),
        const Size(20, 20),
      );
      expect(_inkBounds(surface), isNull);
    });

    test('no family at all falls back to the interface face', () {
      final RenderIcon render = RenderIcon(const IconData(0x58), size: 16);
      expect(render.font, isNotNull);
      expect(render.hasGlyph, isTrue);
    });

    test('changing the size re-resolves the face at the new one', () {
      final RenderIcon render = RenderIcon(block, size: 10);
      expect(render.font!.pixelSize, 10);
      render.iconSize = 40;
      expect(render.font!.pixelSize, 40);
    });
  });

  group('mirroring in a right-to-left interface', () {
    test('only an icon that asked for it takes the outline route', () {
      expect(RenderIcon(fixedArrow).drawsAsPath, isFalse);
      expect(RenderIcon(arrow).drawsAsPath, isTrue);
      // In both directions, so that the two are antialiased by the same code.
      expect(
        RenderIcon(arrow, textDirection: TextDirection.rightToLeft).drawsAsPath,
        isTrue,
      );
    });

    test('isMirrored needs both the icon\'s consent and the direction', () {
      expect(RenderIcon(arrow).isMirrored, isFalse);
      expect(
        RenderIcon(arrow, textDirection: TextDirection.rightToLeft).isMirrored,
        isTrue,
      );
      expect(
        RenderIcon(fixedArrow, textDirection: TextDirection.rightToLeft)
            .isMirrored,
        isFalse,
      );
    });

    test('a right-to-left arrow is the left-to-right one, reflected', () {
      const Size box = Size(40, 40);
      final Framebuffer ltr = _render(
        const Icon(
          arrow,
          size: 40,
          color: Color(0xFF000000),
          textDirection: TextDirection.leftToRight,
        ),
        box,
      );
      final Framebuffer rtl = _render(
        const Icon(
          arrow,
          size: 40,
          color: Color(0xFF000000),
          textDirection: TextDirection.rightToLeft,
        ),
        box,
      );

      // Not the same picture: an assertion that only checked the reflection
      // would pass for a symmetric glyph, or for one that never mirrored.
      expect(ltr.toPackedBytes(), isNot(rtl.toPackedBytes()));

      for (int y = 0; y < 40; y++) {
        for (int x = 0; x < 40; x++) {
          expect(
            _blueAt(ltr, x, y),
            closeTo(_blueAt(rtl, 39 - x, y), 2),
            reason: '($x, $y) against its reflection',
          );
        }
      }
    });

    test('an arrow that does not mirror is identical in both directions', () {
      final Framebuffer ltr = _render(
        const Icon(
          fixedArrow,
          size: 40,
          color: Color(0xFF000000),
          textDirection: TextDirection.leftToRight,
        ),
        const Size(40, 40),
      );
      final Framebuffer rtl = _render(
        const Icon(
          fixedArrow,
          size: 40,
          color: Color(0xFF000000),
          textDirection: TextDirection.rightToLeft,
        ),
        const Size(40, 40),
      );
      expect(ltr.toPackedBytes(), rtl.toPackedBytes());
    });

    test('the two routes place the same glyph in the same box', () {
      // The glyph route and the outline route are different rasterisers, so
      // their fringes differ by a pixel; what must not differ is where the ink
      // is. A mirroring icon that drew half a pixel to the left of a
      // non-mirroring one would show up as a jitter when a control switched.
      final Rect? glyphRoute = _inkBounds(
        _render(
          const Icon(fixedArrow, size: 40, color: Color(0xFF000000)),
          const Size(40, 40),
        ),
      );
      final Rect? pathRoute = _inkBounds(
        _render(
          const Icon(
            arrow,
            size: 40,
            color: Color(0xFF000000),
            textDirection: TextDirection.leftToRight,
          ),
          const Size(40, 40),
        ),
      );
      expect(glyphRoute, isNotNull);
      expect(pathRoute!.left, closeTo(glyphRoute!.left, 1));
      expect(pathRoute.top, closeTo(glyphRoute.top, 1));
      expect(pathRoute.right, closeTo(glyphRoute.right, 1));
      expect(pathRoute.bottom, closeTo(glyphRoute.bottom, 1));
    });
  });

  group('the ambient Directionality', () {
    test('a mirroring icon reads it, and mirrors under right-to-left', () {
      final Framebuffer ltr = _render(
        const Directionality(
          textDirection: TextDirection.leftToRight,
          child: Icon(arrow, size: 40, color: Color(0xFF000000)),
        ),
        const Size(40, 40),
      );
      final Framebuffer rtl = _render(
        const Directionality(
          textDirection: TextDirection.rightToLeft,
          child: Icon(arrow, size: 40, color: Color(0xFF000000)),
        ),
        const Size(40, 40),
      );

      expect(ltr.toPackedBytes(), isNot(rtl.toPackedBytes()));
      for (int y = 0; y < 40; y++) {
        for (int x = 0; x < 40; x++) {
          expect(_blueAt(ltr, x, y), closeTo(_blueAt(rtl, 39 - x, y), 2));
        }
      }
    });

    test('an explicit direction overrides the ambient one', () {
      final Framebuffer overridden = _render(
        const Directionality(
          textDirection: TextDirection.rightToLeft,
          child: Icon(
            arrow,
            size: 40,
            color: Color(0xFF000000),
            textDirection: TextDirection.leftToRight,
          ),
        ),
        const Size(40, 40),
      );
      final Framebuffer plain = _render(
        const Icon(
          arrow,
          size: 40,
          color: Color(0xFF000000),
          textDirection: TextDirection.leftToRight,
        ),
        const Size(40, 40),
      );
      expect(overridden.toPackedBytes(), plain.toPackedBytes());
    });

    test('an icon that does not mirror never asks for one', () {
      // The property that keeps a checkmark usable in a subtree with no locale:
      // reading a direction it would not act on would turn every tree in the
      // suite into one that needs a Directionality at its root.
      expect(
        _inkBounds(
          _render(
            const Icon(block, size: 20, color: Color(0xFF000000)),
            const Size(20, 20),
          ),
        ),
        isNotNull,
      );
    });

    test('a mirroring icon with no direction in scope fails loudly', () {
      expect(
        () => _mounted(
          const Icon(arrow, size: 40),
          const Size(40, 40),
        ),
        throwsA(isA<MissingDirectionalityError>()),
      );
    });
  });

  group('the widget layer', () {
    test('an icon does not claim hits of its own', () {
      final RenderIcon render = RenderIcon(block, size: 20);
      expect(render.hitTestSelf(const Offset(10, 10)), isFalse);
    });

    test('the named icons are code points, not private-use guesses', () {
      // They have to render in an ordinary interface face; DejaVu Sans, the
      // most complete face in this repository, carries all of them.
      final Typeface dejavu = _face('DejaVuSans.ttf');
      for (final IconData icon in <IconData>[
        Icons.check,
        Icons.radioSelected,
        Icons.indeterminate,
        Icons.chevronForward,
        Icons.chevronDown,
        Icons.back,
        Icons.close,
      ]) {
        expect(
          dejavu.coversCodePoint(icon.codePoint),
          isTrue,
          reason: '$icon',
        );
      }
    });

    test('the directional named icons are the ones that mirror', () {
      expect(Icons.back.matchTextDirection, isTrue);
      expect(Icons.chevronForward.matchTextDirection, isTrue);
      expect(Icons.chevronDown.matchTextDirection, isFalse);
      expect(Icons.check.matchTextDirection, isFalse);
      expect(Icons.close.matchTextDirection, isFalse);
    });

    test('an icon sits in a row beside a label', () {
      // The composition the whole feature exists for: a control with an icon
      // and a label in it, which nothing in this framework could express
      // before.
      final (BuildOwner owner, _) = _mounted(
        const Row(
          children: <Widget>[
            Icon(block, size: 12),
            Text('ok', fontSize: 12),
          ],
        ),
        const Size(120, 40),
      );
      addTearDown(owner.dispose);
      final List<RenderBox> children = <RenderBox>[];
      owner.rootElement!.collectRenderChildren(children);
      final RenderBox row = children.single;
      expect(row.size.width, greaterThan(12));
      expect(row.size.height, greaterThanOrEqualTo(12));
    });
  });
}
