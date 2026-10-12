/// The status bar: a themed strip whose message field takes the slack.
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

  RenderBox mount(Widget bar, {double width = 600}) {
    final BuildOwner owner = BuildOwner(
      pipelineOwner: PipelineOwner(
        rootConstraints: BoxConstraints(maxWidth: width, maxHeight: 400),
      ),
    );
    addTearDown(owner.dispose);
    owner.updateRoot(Column(children: <Widget>[bar]));
    owner.pipelineOwner.drawFrame(DisplayList());
    return owner.renderRoot!;
  }

  /// The bar's own box: the column's only child.
  RenderBox barOf(RenderBox root) {
    RenderBox? bar;
    root.visitChildren((RenderBox child) => bar ??= child);
    return bar!;
  }

  RenderText textNamed(RenderBox root, String text) {
    RenderText? found;
    void walk(RenderBox node) {
      if (node is RenderText && node.text == text) found = node;
      node.visitChildren(walk);
    }

    walk(root);
    return found ?? (throw StateError('no text "$text"'));
  }

  test('fixed fields keep their width and the message takes the rest', () {
    final RenderBox root = mount(const StatusBar(
      children: <Widget>[
        StatusBarItem(text: '12.5, 40.0 mm', width: 150),
        StatusBarItem.message(text: 'Ready'),
        StatusBarItem(text: '100%', separator: false),
      ],
    ));

    final RenderText coords = textNamed(root, '12.5, 40.0 mm');
    final RenderText message = textNamed(root, 'Ready');
    final RenderText zoom = textNamed(root, '100%');
    // The message starts after the fixed field, whatever its text measures.
    expect(message.globalOffset.dx, greaterThanOrEqualTo(150));
    // And the last field sits at the right edge, pushed there by the message.
    final double zoomRight = zoom.globalOffset.dx + zoom.size.width;
    expect(zoomRight, closeTo(600 - ThemeData.neutralLight.effectiveGap, 1));
    expect(coords.globalOffset.dx, lessThan(message.globalOffset.dx));
  });

  test('the height follows the theme unless given', () {
    final RenderBox themed = mount(const StatusBar(
      children: <Widget>[StatusBarItem.message(text: 'Ready')],
    ));
    expect(barOf(themed).size.height,
        StatusBar.defaultHeight(ThemeData.neutralLight));

    final RenderBox fixed = mount(const StatusBar(
      height: 40,
      children: <Widget>[StatusBarItem.message(text: 'Ready')],
    ));
    expect(barOf(fixed).size.height, 40);
  });

  test('a field that moves its digits does not move its neighbours', () {
    double messageX(String coords) {
      final RenderBox root = mount(StatusBar(
        children: <Widget>[
          StatusBarItem(text: coords, width: 150),
          const StatusBarItem.message(text: 'Ready'),
        ],
      ));
      return textNamed(root, 'Ready').globalOffset.dx;
    }

    expect(messageX('1, 2'), messageX('1234.5, 6789.0 mm'));
  });
}
