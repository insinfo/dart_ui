/// `Divider`, and the one thing the "just use a 1 px box" advice got wrong.
///
/// The geometry is the whole contract: the widget occupies [Divider.height] and
/// the line inside it is [Divider.thickness] thick and centred. Somebody who
/// reads the constructor as "a bar this thick" gets a 32 px black band instead
/// of a hairline with breathing room, so the two numbers are asserted apart.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

void main() {
  (BuildOwner, PipelineOwner) mounted(Widget root, Size viewport) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(root);
    pipeline.flushLayout();
    return (owner, pipeline);
  }

  RenderColoredBox line(BuildOwner owner) {
    final List<RenderColoredBox> found = <RenderColoredBox>[];
    void walk(RenderBox node) {
      if (node is RenderColoredBox) found.add(node);
      node.visitChildren(walk);
    }

    walk(owner.renderRoot!);
    return found.single;
  }

  test('the height is the space taken and the thickness is the line drawn', () {
    final (BuildOwner owner, _) = mounted(
      const Column(children: <Widget>[Divider(height: 32, thickness: 2)]),
      const Size(200, 100),
    );

    final RenderColoredBox rule = line(owner);
    expect(rule.size, const Size(200, 2), reason: 'the line');
    expect(owner.renderRoot!.size.height, 100);
    expect(rule.localToGlobal(Offset.zero).dy, 15,
        reason: 'centred in the 32 px the widget occupies');
    owner.dispose();
  });

  test('the indents shorten the line without moving the box', () {
    final (BuildOwner owner, _) = mounted(
      const Column(
        children: <Widget>[Divider(indent: 20, endIndent: 30)],
      ),
      const Size(200, 100),
    );

    final RenderColoredBox rule = line(owner);
    expect(rule.size.width, 150);
    expect(rule.localToGlobal(Offset.zero).dx, 20);
    owner.dispose();
  });

  test('the colour comes from the theme when none is given', () {
    final ThemeData theme = ThemeData.neutralLight.copyWith(
      border: const Color(0xFFAABBCC),
    );
    final (BuildOwner owner, _) = mounted(
      Theme(
        data: theme,
        child: const Column(children: <Widget>[Divider()]),
      ),
      const Size(200, 100),
    );

    expect(line(owner).color, theme.borderSubtle,
        reason: 'borderSubtle, the divider *inside* a surface - not border, '
            'which is the edge between two, and which the old advice named');
    owner.dispose();
  });

  test('an explicit colour wins', () {
    final (BuildOwner owner, _) = mounted(
      const Column(
        children: <Widget>[Divider(color: Color(0xFF010203))],
      ),
      const Size(200, 100),
    );

    expect(line(owner).color, const Color(0xFF010203));
    owner.dispose();
  });

  test('VerticalDivider is the transpose', () {
    final (BuildOwner owner, _) = mounted(
      const Row(children: <Widget>[VerticalDivider(width: 20, thickness: 3)]),
      const Size(200, 100),
    );

    final RenderColoredBox rule = line(owner);
    expect(rule.size, const Size(3, 100));
    expect(rule.localToGlobal(Offset.zero).dx, 8.5);
    owner.dispose();
  });
}
