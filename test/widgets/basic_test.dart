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
}
