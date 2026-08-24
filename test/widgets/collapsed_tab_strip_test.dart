/// The collapsed tab strip, and the rotated labels it was built to avoid.
///
/// This file exists because the strip used to stack its label one character
/// above another. That was not a design choice: both rasterizers refused a
/// glyph run under a rotated transform, so a turned label would have drawn on
/// a GPU backend and thrown on the software one, and the widget worked around
/// the limit rather than around the reader.
///
/// The limit is gone - see `glyphMasksFit` in `rendering/text/glyph_raster.dart`
/// and ADR 0007 - so the assertions here are about the label being *one turned
/// run* and not a column of single characters. Two things separate those, and
/// both are checked: a turned run is as tall as the shaped line is wide, where
/// a stack is as tall as its character count times a fixed advance; and a
/// turned run rasterizes on the CPU backend, which is what a stack was there
/// to guarantee.
library;

// Imported by library rather than through `package:dart_ui/dart_ui.dart`, the
// way the renderer's own tests do: the barrel pulls in every widget in the
// framework, and this file needs one of them.
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/layout/render_box.dart';
import 'package:dart_ui/src/layout/render_flex.dart';
import 'package:dart_ui/src/rendering/cpu_renderer.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/text/font_registry.dart';
import 'package:dart_ui/src/text/shaper.dart' show TextDirection;
import 'package:dart_ui/src/text/typeface.dart';
import 'package:dart_ui/src/widgets/basic.dart';
import 'package:dart_ui/src/widgets/directionality.dart';
import 'package:dart_ui/src/widgets/docking/collapsed_tab_strip.dart';
import 'package:dart_ui/src/widgets/element.dart';
import 'package:dart_ui/src/widgets/theme.dart';
import 'package:dart_ui/src/widgets/widget.dart';
import 'package:test/test.dart';

/// The strip's own default, and the size every measurement below is taken at.
const double kLabelSize = 10;

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  /// The width the label's line occupies when it is *not* turned, which is the
  /// height the strip has to reserve for it once it is.
  double lineWidth(String label) {
    final ScaledTypeface face = FontRegistry.instance.uiFont(kLabelSize)!;
    return uiTextPainter.measure(label, face).width;
  }

  test('the label is as tall as the shaped line is wide', () {
    // The assertion that tells a turned run from a stack of characters. At
    // 10 px "Transformations" shapes to a line in the sixties of pixels;
    // stacked at the 11 px advance the old code used, the same fifteen
    // characters would have been 165 px tall. The two are not close, and no
    // font choice makes them close.
    const String label = 'Transformations';
    final _Harness harness = _Harness(<CollapsedTab>[
      const CollapsedTab(id: 'x', label: label, closable: false),
    ])
      ..frame();

    final Size? box = harness.labelSize();
    expect(box, isNotNull, reason: 'the strip has to have built a label');
    expect(box!.height, closeTo(lineWidth(label), 0.5));
    expect(box.height, lessThan(label.length * 11.0),
        reason: 'a stack of characters would be taller than the shaped line');
    expect(box.width, lessThanOrEqualTo(26),
        reason: 'and no wider than the strip it lives in');
    expect(harness.sizeOf(CollapsedTabStrip)!.width, 26);
    harness.dispose();
  });

  test('a longer label makes a taller label box, by the width it added', () {
    // The relationship rather than a single number: whatever the face's
    // metrics are, the difference between two labels' boxes has to be the
    // difference between the two shaped lines. A stack would grow by the
    // difference in *character count* instead, which for these two strings is
    // a different number.
    final _Harness short = _Harness(<CollapsedTab>[
      const CollapsedTab(id: 'a', label: 'Fill', closable: false),
    ])
      ..frame();
    final _Harness long = _Harness(<CollapsedTab>[
      const CollapsedTab(
          id: 'a', label: 'Align and Distribute', closable: false),
    ])
      ..frame();

    final double grew =
        long.labelSize()!.height - short.labelSize()!.height;
    expect(grew,
        closeTo(lineWidth('Align and Distribute') - lineWidth('Fill'), 0.5));
    short.dispose();
    long.dispose();
  });

  test('the strip rasterizes on the software backend, ink and all', () {
    // The regression this whole change is about. Before it, this call raised
    // `UnsupportedCapabilityError` from `_deviceFont` the moment a rotated
    // glyph run reached the CPU sink - which is precisely why the widget did
    // not emit one.
    final _Harness harness = _Harness(<CollapsedTab>[
      const CollapsedTab(id: 'x', label: 'Transformations', closable: false),
    ]);
    final DisplayList frame = harness.frame();

    final Framebuffer surface = Framebuffer.allocate(width: 64, height: 200)
      ..clear(255, 255, 255, 255);
    rasterizeDisplayList(frame, surface);

    expect(_hasInk(surface), isTrue,
        reason: 'a strip that drew nothing would pass every size assertion '
            'above and still be invisible');
    harness.dispose();
  });
}

/// Whether any pixel differs from the white the surface was cleared to.
bool _hasInk(Framebuffer surface) {
  for (int y = 0; y < surface.height; y++) {
    for (int x = 0; x < surface.width; x++) {
      final int offset = surface.offsetOf(x, y);
      if (surface.pixels[offset] != 255 ||
          surface.pixels[offset + 1] != 255 ||
          surface.pixels[offset + 2] != 255) {
        return true;
      }
    }
  }
  return false;
}

/// Mounts one strip headless and drives frames the way a display would.
final class _Harness {
  _Harness(this.tabs) {
    owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(64, 400)),
      ),
    );
    owner.updateRoot(_root());
  }

  final List<CollapsedTab> tabs;
  late final BuildOwner owner;

  Widget _root() => Directionality(
        textDirection: TextDirection.leftToRight,
        child: Theme(
          data: ThemeData.neutralLight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              CollapsedTabStrip(
                tabs: tabs,
                selectedId: null,
                labelFontSize: kLabelSize,
              ),
            ],
          ),
        ),
      );

  DisplayList frame({int maxPasses = 8}) {
    late DisplayList list;
    for (int pass = 0; pass < maxPasses; pass++) {
      owner.buildScope();
      list = DisplayList();
      owner.pipelineOwner.drawFrame(list);
      if (!owner.hasScheduledBuilds) return list;
    }
    return list;
  }

  /// The turned label's box, found by render-object type name.
  ///
  /// By name because `_RenderVerticalLabel` is private to
  /// `collapsed_tab_strip.dart` and should stay that way - it is an
  /// implementation detail of one widget, not API - while the box it lays out
  /// is exactly what this file is about. A test that cannot name a type it
  /// must not export is the right place for this trade.
  Size? labelSize() {
    Size? found;
    void walk(RenderBox node) {
      if (found != null) return;
      if (node.runtimeType.toString().contains('RenderVerticalLabel')) {
        found = node.size;
        return;
      }
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found;
  }

  Size? sizeOf(Type type) {
    Size? found;
    void walk(Element element) {
      if (found != null) return;
      if (element.widget.runtimeType == type) {
        final RenderBox? render = _firstRender(element);
        if (render != null) {
          found = render.size;
          return;
        }
      }
      element.visitChildren(walk);
    }

    walk(owner.rootElement!);
    return found;
  }

  static RenderBox? _firstRender(Element element) {
    RenderBox? found;
    void walk(Element node) {
      if (found != null) return;
      if (node is RenderObjectElement) {
        found = node.renderObject;
        return;
      }
      node.visitChildren(walk);
    }

    walk(element);
    return found;
  }

  void dispose() => owner.dispose();
}
