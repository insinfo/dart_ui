/// Fixed-shape boxes.
library;

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  RenderAspectRatio laidOut(
    RenderAspectRatio node,
    BoxConstraints constraints,
  ) {
    final owner = PipelineOwner(rootConstraints: constraints)..root = node;
    owner.flushLayout();
    return node;
  }

  test('takes the widest box the constraints allow', () {
    final child = MeasuredBox(const Size(5, 5));
    final node = RenderAspectRatio(aspectRatio: 16 / 9, child: child);

    laidOut(node, BoxConstraints.loose(const Size(320, 1000)));

    expect(node.size, const Size(320, 180));
    expect(child.size, const Size(320, 180));
  });

  test('falls back to the height when the width is unbounded', () {
    final node = RenderAspectRatio(aspectRatio: 2);

    laidOut(node, BoxConstraints(maxHeight: 50));

    expect(node.size, const Size(100, 50));
  });

  test('shrinks to the height limit rather than breaking the shape', () {
    final node = RenderAspectRatio(aspectRatio: 2);

    laidOut(node, BoxConstraints.loose(const Size(400, 50)));

    expect(node.size, const Size(100, 50));
  });

  test('a minimum it cannot honour is the last thing to give', () {
    // 2:1 in a box at most 400 wide, at most 50 tall and at least 200 wide.
    // The height limit pulls it down to 100x50, the width minimum pushes it
    // back out to 200x100, and the height limit then clamps the result: the
    // constraint wins and the shape is what breaks, visibly, at 200x50.
    final node = RenderAspectRatio(aspectRatio: 2);

    laidOut(node, BoxConstraints(minWidth: 200, maxWidth: 400, maxHeight: 50));

    expect(node.size, const Size(200, 50));
  });

  test('a tight constraint wins, and the ratio breaks visibly', () {
    final node = RenderAspectRatio(aspectRatio: 2);

    laidOut(node, BoxConstraints.tight(const Size(100, 100)));

    expect(node.size, const Size(100, 100));
  });

  test('unbounded on both axes is an error, not a guess', () {
    final node = RenderAspectRatio(aspectRatio: 2);

    expect(() => laidOut(node, BoxConstraints()), throwsStateError);
  });

  test('the child never argues with the ratio', () {
    final child = MeasuredBox(const Size(10, 500));
    final node = RenderAspectRatio(aspectRatio: 1, child: child);

    laidOut(node, BoxConstraints.loose(const Size(80, 1000)));

    expect(node.size, const Size(80, 80));
    expect(child.size, const Size(80, 80));
  });

  test('a ratio of zero or infinity is refused', () {
    expect(() => RenderAspectRatio(aspectRatio: 0), throwsArgumentError);
    expect(
      () => RenderAspectRatio(aspectRatio: double.infinity),
      throwsArgumentError,
    );
    expect(() => RenderAspectRatio(aspectRatio: -1), throwsArgumentError);
  });

  test('changing the ratio re-lays it out', () {
    final node = RenderAspectRatio(aspectRatio: 1);
    final owner = PipelineOwner(
      rootConstraints: BoxConstraints.loose(const Size(200, 1000)),
    )..root = node;
    owner.flushLayout();

    expect(node.size, const Size(200, 200));

    node.aspectRatio = 4;
    owner.flushLayout();

    expect(node.size, const Size(200, 50));
  });
}
