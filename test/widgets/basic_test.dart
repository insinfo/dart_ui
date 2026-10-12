/// The widget faces of the section 25.3 layouts that were missing.
///
/// The render nodes have their own tests under `test/layout`; what is asserted
/// here is that the widget spelling reaches them - that a `Grid` really builds
/// a `RenderGrid` with the tracks it was given, and that an update re-lays the
/// tree out instead of quietly keeping the old geometry.
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

  (BuildOwner, PipelineOwner) mounted(Widget root, Size viewport) {
    final PipelineOwner pipeline = PipelineOwner(
      rootConstraints: BoxConstraints.tight(viewport),
    );
    final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
      ..updateRoot(root);
    pipeline.flushLayout();
    return (owner, pipeline);
  }

  group('Grid', () {
    test('builds a RenderGrid and gives it the declared tracks', () {
      final (BuildOwner owner, _) = mounted(
        Grid(
          columns: <GridTrack>[GridTrack.fixed(30), GridTrack.fraction()],
          columnGap: 10,
          children: const <Widget>[
            SizedBox(width: 5, height: 5),
            SizedBox(width: 5, height: 5),
          ],
        ),
        const Size(100, 40),
      );

      final RenderGrid grid = owner.renderRoot! as RenderGrid;
      expect(grid.columnSizes, <double>[30, 60]);
      expect(grid.childAt(1).offsetFromParent.dx, 40);
    });

    test('an update changes the tracks and re-lays the children out', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 40)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      owner.updateRoot(
        Grid(
          columns: <GridTrack>[GridTrack.fraction(), GridTrack.fraction()],
          children: const <Widget>[
            SizedBox(width: 5, height: 5),
            SizedBox(width: 5, height: 5),
          ],
        ),
      );
      pipeline.flushLayout();
      final RenderGrid grid = owner.renderRoot! as RenderGrid;
      expect(grid.columnSizes, <double>[50, 50]);

      owner.updateRoot(
        Grid(
          columns: <GridTrack>[GridTrack.fraction(3), GridTrack.fraction()],
          children: const <Widget>[
            SizedBox(width: 5, height: 5),
            SizedBox(width: 5, height: 5),
          ],
        ),
      );
      pipeline.flushLayout();

      expect(owner.renderRoot, same(grid));
      expect(grid.columnSizes, <double>[75, 25]);
      expect(grid.childAt(1).offsetFromParent.dx, 75);
    });

    test('a column sized to its content measures the text in it', () {
      final (BuildOwner owner, _) = mounted(
        const Grid(
          columns: <GridTrack>[GridTrack.auto, GridTrack.auto],
          children: <Widget>[
            Text('short', fontSize: 14),
            Text('a considerably longer label', fontSize: 14),
          ],
        ),
        const Size(600, 60),
      );

      final RenderGrid grid = owner.renderRoot! as RenderGrid;
      final RenderBox first = grid.childAt(0);
      final RenderBox second = grid.childAt(1);

      // The point: an auto column is the width of the text in it, which is only
      // knowable through the intrinsic protocol.
      expect(grid.columnSizes[0], first.getMaxIntrinsicWidth(double.infinity));
      expect(grid.columnSizes[1], second.getMaxIntrinsicWidth(double.infinity));
      expect(grid.columnSizes[1], greaterThan(grid.columnSizes[0]));
      expect(second.offsetFromParent.dx, grid.columnSizes[0]);
    });
  });

  group('Wrap', () {
    test('breaks a row of boxes into runs', () {
      final (BuildOwner owner, _) = mounted(
        const Wrap(
          spacing: 10,
          children: <Widget>[
            SizedBox(width: 40, height: 20),
            SizedBox(width: 40, height: 20),
            SizedBox(width: 40, height: 20),
          ],
        ),
        const Size(100, 60),
      );

      final RenderWrap wrap = owner.renderRoot! as RenderWrap;
      expect(wrap.runCount, 2);
      expect(wrap.childAt(1).offsetFromParent, const Offset(50, 0));
      expect(wrap.childAt(2).offsetFromParent, const Offset(0, 20));
    });

    test('an update to the spacing re-flows it', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.tight(const Size(100, 60)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline);

      owner.updateRoot(
        const Wrap(
          children: <Widget>[
            SizedBox(width: 40, height: 20),
            SizedBox(width: 40, height: 20),
          ],
        ),
      );
      pipeline.flushLayout();
      final RenderWrap wrap = owner.renderRoot! as RenderWrap;
      expect(wrap.runCount, 1);

      owner.updateRoot(
        const Wrap(
          spacing: 30,
          children: <Widget>[
            SizedBox(width: 40, height: 20),
            SizedBox(width: 40, height: 20),
          ],
        ),
      );
      pipeline.flushLayout();

      expect(wrap.runCount, 2);
    });
  });

  group('AspectRatio', () {
    test('shapes the box it is given', () {
      final (BuildOwner owner, _) = mounted(
        const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            child: AspectRatio(aspectRatio: 16 / 9),
          ),
        ),
        const Size(400, 400),
      );

      RenderBox? found;
      void search(RenderBox node) {
        if (node is RenderAspectRatio) found = node;
        node.visitChildren(search);
      }

      search(owner.renderRoot!);
      expect(found!.size, const Size(320, 180));
    });
  });

  group('Text', () {
    test('softWrap uses paragraph layout instead of clipping one line', () {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.loose(const Size(110, 300)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(
          const Text(
            'Uma descrição longa deve ocupar mais de uma linha.',
            fontSize: 14,
            softWrap: true,
          ),
        );
      addTearDown(owner.dispose);
      pipeline.flushLayout();

      final text = owner.renderRoot! as RenderText;
      expect(text.size.width, lessThanOrEqualTo(110));
      expect(
        text.size.height,
        greaterThan(FontRegistry.estimatedLineHeight(14)),
      );
    });

    // A newline always breaks, softWrap or not - Flutter's semantics, and
    // what the model viewer's two-line hint needed: until 12/10/2026 the
    // single-line path shaped the `\n` and drew a `.notdef` box between the
    // two sentences, on one line.
    RenderText laidOut(String text, {double maxWidth = 1000}) {
      final PipelineOwner pipeline = PipelineOwner(
        rootConstraints: BoxConstraints.loose(Size(maxWidth, 300)),
      );
      final BuildOwner owner = BuildOwner(pipelineOwner: pipeline)
        ..updateRoot(Text(text, fontSize: 14));
      addTearDown(owner.dispose);
      pipeline.flushLayout();
      return owner.renderRoot! as RenderText;
    }

    test('a newline breaks the line without softWrap', () {
      final RenderText one = laidOut('first line');
      final RenderText two = laidOut('first line\nsecond');
      expect(two.size.height, greaterThan(one.size.height * 1.5),
          reason: 'two lines, not one');
      expect(two.size.width, closeTo(one.size.width, 0.5),
          reason: 'as wide as its widest line: no box, no second sentence '
              'on the first line');
      expect(two.getMaxIntrinsicWidth(double.infinity),
          closeTo(one.size.width, 0.5));
    });

    test('without softWrap only the newline breaks, not the width', () {
      const String text = 'a first line much wider than the box it is given\nb';
      final RenderText narrow = laidOut(text, maxWidth: 60);
      final RenderText wide = laidOut(text);
      expect(narrow.size.height, wide.size.height,
          reason: 'the same two lines in a narrow box as in a wide one - the '
              'long line is clipped to the box, not wrapped at it');
      expect(narrow.size.width, 60);
    });
  });
}
