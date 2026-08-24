/// The focus ring: an accessibility requirement, asserted on the pixels.
///
/// "Focus is visible" is a claim about what was drawn, so this reads the
/// display list rather than a flag. Three things have to hold, and each has
/// broken at least once:
///
///   * a control focused **by keyboard** draws the ring;
///   * the same control focused **by pointer** does not - a ring after every
///     click is noise, and it is why the ring is `:focus-visible` and not
///     `:focus`;
///   * the ring is drawn *outside* the control's own box, in the theme's
///     [ThemeData.focusRing], as a **stroke** and with the control's radius -
///     a square halo around a rounded button is the tell that the ring was
///     drawn by a different piece of code than the control.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      FontRegistry.instance.useFontFile('test/fonts/Roboto-Regular.ttf'),
      isTrue,
    );
  });
  tearDownAll(FontRegistry.instance.reset);

  test('a keyboard focus draws a ring outside the control, in the ring colour',
      () {
    final BuildOwner owner = _owner();
    owner.updateRoot(Button(label: 'OK', onPressed: () {}));
    owner.pipelineOwner.drawFrame(DisplayList());
    final RenderButton button = owner.renderRoot! as RenderButton;

    button.focusNode!.requestFocus(FocusChangeReason.traversal);
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);

    const ThemeData theme = ThemeData.neutralLight;
    final List<_Stroke> rings = _strokesOf(list, theme.focusRing);
    expect(rings, hasLength(1), reason: 'exactly one ring, and it is a stroke');

    final _Stroke ring = rings.single;
    expect(ring.width, theme.focusRingWidth);
    expect(ring.rounded, isTrue, reason: 'a rounded control gets a round halo');
    // Outside the control: the ring never eats a pixel of what it marks.
    expect(ring.rect.left, lessThan(0));
    expect(ring.rect.top, lessThan(0));
    expect(ring.rect.right, greaterThan(button.size.width));
    expect(ring.rect.bottom, greaterThan(button.size.height));
    // And not far outside it either - two pixels of ring, not a frame.
    expect(ring.rect.left, greaterThan(-4));
    expect(ring.rect.top, greaterThan(-4));

    owner.dispose();
  });

  test('a pointer focus draws no ring at all', () {
    final BuildOwner owner = _owner();
    owner.updateRoot(Button(label: 'OK', onPressed: () {}));
    owner.pipelineOwner.drawFrame(DisplayList());
    final RenderButton button = owner.renderRoot! as RenderButton;

    button.focusNode!.requestFocus(FocusChangeReason.pointer);
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);

    expect(button.hasFocus, isTrue);
    expect(_strokesOf(list, ThemeData.neutralLight.focusRing), isEmpty);
    owner.dispose();
  });

  test('the ring follows the control it marks, not a fixed shape', () {
    // A check box is a small rounded square, so its ring is smaller and its
    // radius is the small one; the ring is still one stroke of the same width.
    final BuildOwner owner = _owner();
    owner.updateRoot(CheckBox(label: 'On', value: true, onChanged: (_) {}));
    owner.pipelineOwner.drawFrame(DisplayList());
    final RenderToggle box = owner.renderRoot! as RenderToggle;

    box.focusNode!.requestFocus(FocusChangeReason.traversal);
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);

    final _Stroke ring =
        _strokesOf(list, ThemeData.neutralLight.focusRing).single;
    expect(ring.width, ThemeData.neutralLight.focusRingWidth);
    // The indicator, not the whole hit box: the ring marks the box the user
    // sees, and the label beside it is not part of that box.
    expect(ring.rect.width, lessThan(box.size.width));
    expect(ring.rect.height, closeTo(box.indicatorExtent + 3, 1.0));
    owner.dispose();
  });

  test('high contrast widens the ring rather than recolouring it', () {
    final BuildOwner owner = _owner();
    owner.updateRoot(
      Theme(
        data: ThemeData.highContrastDark,
        child: Button(label: 'OK', onPressed: () {}),
      ),
    );
    owner.pipelineOwner.drawFrame(DisplayList());
    final RenderButton button = _find<RenderButton>(owner.renderRoot!);

    button.focusNode!.requestFocus(FocusChangeReason.traversal);
    final DisplayList list = DisplayList();
    owner.pipelineOwner.drawFrame(list);

    final _Stroke ring =
        _strokesOf(list, ThemeData.highContrastDark.focusRing).single;
    expect(ring.width, 3.0);
    owner.dispose();
  });
}

BuildOwner _owner({Size size = const Size(200, 60)}) => BuildOwner(
      pipelineOwner: PipelineOwner(rootConstraints: BoxConstraints.tight(size)),
    );

T _find<T extends RenderBox>(RenderBox root) {
  T? found;
  void walk(RenderBox node) {
    if (found != null) return;
    if (node is T) {
      found = node;
      return;
    }
    node.visitChildren(walk);
  }

  walk(root);
  if (found == null) throw StateError('no $T in the tree');
  return found!;
}

/// One stroked shape read back out of a display list.
final class _Stroke {
  const _Stroke(this.rect, this.width, {required this.rounded});

  final Rect rect;
  final double width;
  final bool rounded;
}

/// Every stroked rectangle or rounded rectangle painted in [color].
List<_Stroke> _strokesOf(DisplayList list, Color color) {
  final reader = DisplayListReader(list);
  final List<_Stroke> strokes = <_Stroke>[];
  while (reader.moveNext()) {
    if (reader.opcode != opDrawRect && reader.opcode != opDrawRRect) continue;
    final int paint = reader.intAt(0);
    if (list.paintColor(paint) != color.value) continue;
    if (list.paintStyle(paint) != paintStyleStroke) continue;
    strokes.add(
      _Stroke(
        Rect.fromLTRB(
          reader.floatAt(0),
          reader.floatAt(1),
          reader.floatAt(2),
          reader.floatAt(3),
        ),
        list.paintStrokeWidth(paint),
        rounded: reader.opcode == opDrawRRect,
      ),
    );
  }
  return strokes;
}
