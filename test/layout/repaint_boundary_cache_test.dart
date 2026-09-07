/// The repaint boundary cache, and the one property that makes it usable:
/// **a cached frame is the frame the walk would have produced.**
///
/// A repaint boundary that changes what is drawn is not a slow optimisation,
/// it is a rendering bug - and the worst-shaped one available, because it
/// appears only on the second frame, only in the part of the tree that did not
/// change, and only in an application big enough for anyone to have put a
/// boundary in it. So the first and largest group here is not about speed at
/// all. It paints the same tree twice through the same pipeline, once with
/// [PipelineOwner.repaintBoundaryCaching] off and once on, and asserts that the
/// two display lists are the same command stream: same opcodes, same operand
/// counts, every float, and every resource id resolved through its own list.
/// That comparison is the whole reason the switch exists.
///
/// One case cannot be asserted that way and says so out loud. A boundary that
/// has *moved* replays under a translation, so its stream is deliberately not
/// word-identical to the walk's - it is `save`, `transform`, the same commands
/// as before, `restore`. What is identical is the picture, so that case is
/// rasterised on both paths and compared pixel for pixel, which is a stronger
/// claim about the only thing that matters and a weaker one about the bytes.
///
/// The second group counts walks. `RenderRepaintBoundary.paintCount` counts
/// actual subtree walks, so "a setState inside a boundary repaints only that
/// boundary" is an assertion about integers rather than about a profile.
library;

import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const int _red = 0xFFCC3311;
const int _green = 0xFF11CC33;
const int _blue = 0xFF3311CC;

void main() {
  group('a cached frame is the frame the walk would have produced', () {
    test('a static subtree', () {
      _expectEquivalent(
        frames: 4,
        build: () {
          final RenderBox root = _Mover(
            childOffset: const Offset(4, 6),
            child: RenderRepaintBoundary(
              child: _Stack(<RenderBox>[
                _Block(preferred: const Size(20, 10), color: _red),
                _Block(preferred: const Size(8, 8), color: _green),
              ]),
            ),
          );
          return (root, (int frame) {});
        },
      );
    });

    test('a subtree whose content changed', () {
      // The colour changes on every frame, so the cache is dropped and rebuilt
      // on every frame. That is the case a naive implementation gets right by
      // accident and a wrong invalidation gets wrong on frame two, drawing the
      // first frame's colour for ever.
      _expectEquivalent(
        frames: 4,
        build: () {
          final _Block block =
              _Block(preferred: const Size(20, 10), color: _red);
          final RenderBox root = _Mover(
            childOffset: const Offset(4, 6),
            child: RenderRepaintBoundary(child: block),
          );
          return (
            root,
            (int frame) => block.color = frame.isEven ? _red : _green,
          );
        },
      );
    });

    test('a subtree that resized', () {
      _expectEquivalent(
        frames: 4,
        build: () {
          final _Block block =
              _Block(preferred: const Size(20, 10), color: _red);
          final RenderBox root = _Mover(
            childOffset: const Offset(4, 6),
            child: RenderRepaintBoundary(child: block),
          );
          return (
            root,
            (int frame) => block.preferred = Size(10.0 + frame * 3, 10),
          );
        },
      );
    });

    test('nested boundaries, with the innermost one changing', () {
      // Splice of a splice. The inner boundary's ids have already been
      // rewritten once by the time the outer list reaches the frame, so this is
      // where a non-idempotent remap would paint the wrong colour.
      _expectEquivalent(
        frames: 4,
        build: () {
          final _Block inner =
              _Block(preferred: const Size(6, 6), color: _blue);
          final RenderBox root = _Mover(
            childOffset: const Offset(2, 2),
            child: RenderRepaintBoundary(
              child: _Stack(<RenderBox>[
                _Block(preferred: const Size(20, 20), color: _red),
                RenderRepaintBoundary(child: inner),
                _Block(preferred: const Size(4, 4), color: _green),
              ]),
            ),
          );
          return (
            root,
            (int frame) => inner.color = frame.isEven ? _blue : _green,
          );
        },
      );
    });

    test('a boundary that was never painted before', () {
      // Inserted on the third frame, into a tree the other boundaries have
      // been caching in since the first one. A cache keyed on anything but
      // "have I recorded this" would either splice nothing or splice a
      // sibling's bytes.
      _expectEquivalent(
        frames: 5,
        build: () {
          final _Stack stack = _Stack(<RenderBox>[
            _Block(preferred: const Size(20, 20), color: _red),
          ]);
          final RenderBox root = _Mover(
            childOffset: const Offset(2, 2),
            child: RenderRepaintBoundary(child: stack),
          );
          return (
            root,
            (int frame) {
              if (frame == 2) {
                stack.append(
                  RenderRepaintBoundary(
                    child: _Block(preferred: const Size(6, 6), color: _blue),
                  ),
                );
              }
            },
          );
        },
      );
    });

    test('a subtree that declares a content hint, which is never cached', () {
      // `DisplayList.appendFrom` refuses a sub-list carrying hint spans,
      // because a span records the value already merged with its enclosing
      // hints. The boundary has to notice and go back to walking; this asserts
      // that what it draws afterwards is still exactly the walk's stream.
      _expectEquivalent(
        frames: 4,
        build: () {
          final _Block block =
              _Block(preferred: const Size(12, 12), color: _red);
          final RenderBox root = _Mover(
            childOffset: const Offset(3, 3),
            child: RenderRepaintBoundary(
              child: RenderContentHint(
                hint: const ContentHint(motion: ContentMotionHint.animating),
                child: block,
              ),
            ),
          );
          return (
            root,
            (int frame) => block.color = frame.isEven ? _red : _green,
          );
        },
      );
    });

    test('a hint that encloses the boundary still applies to the splice', () {
      // The mirror image of the case above, and the one that is allowed to
      // cache: the hint is pushed on the *frame* list before the splice and
      // popped after it, so the run-length span covers the spliced words
      // exactly as it covers the walked ones.
      final DisplayList cached =
          _lastFrame(caching: true, frames: 3, build: _hintOverBoundary);
      final DisplayList walked =
          _lastFrame(caching: false, frames: 3, build: _hintOverBoundary);
      _expectSameStream(cached, walked);
      expect(cached.hasContentHints, isTrue,
          reason: 'the case is only interesting while a hint is in force');
      _expectSameHintSpans(cached, walked);
    });
  });

  group('a boundary that moved replays under a translation', () {
    test('the wrapper is exactly save, translate, restore', () {
      final _Moving scene = _Moving(caching: true);
      scene.frame();
      final DisplayList moved = scene.moveTo(const Offset(17, 9));

      final DisplayListReader reader = DisplayListReader(moved);
      expect(reader.moveNext(), isTrue);
      expect(reader.opcode, opSave);
      expect(reader.moveNext(), isTrue);
      expect(reader.opcode, opTransform);
      expect(
        <double>[for (int i = 0; i < 6; i++) reader.floatAt(i)],
        <double>[1, 0, 0, 1, 12, 4],
        reason: 'the boundary was recorded at (5, 5) and is now at (17, 9)',
      );
      // ... the recorded commands ...
      while (reader.moveNext() && reader.opcode != opRestore) {}
      expect(reader.opcode, opRestore);
      expect(reader.moveNext(), isFalse, reason: 'and nothing after it');
    });

    test('and paints the same pixels the walk would have', () async {
      // The one case the stream comparison cannot make, made against the only
      // thing that is actually being claimed. Both paths are rasterised by the
      // CPU renderer and the two framebuffers compared byte for byte.
      final _Moving cached = _Moving(caching: true);
      final _Moving walked = _Moving(caching: false);
      cached.frame();
      walked.frame();

      final DisplayList a = cached.moveTo(const Offset(17, 9));
      final DisplayList b = walked.moveTo(const Offset(17, 9));

      expect(await _pixels(a), await _pixels(b));
    });

    test(
        'a boundary that moves back onto its recorded offset stops '
        'translating', () {
      final _Moving scene = _Moving(caching: true);
      scene.frame();
      scene.moveTo(const Offset(17, 9));
      final DisplayList back = scene.moveTo(const Offset(5, 5));

      final DisplayListReader reader = DisplayListReader(back);
      expect(reader.moveNext(), isTrue);
      expect(reader.opcode, isNot(opSave),
          reason: 'no wrapper is needed when the delta is zero');
    });
  });

  group('what a boundary actually skips', () {
    test('a setState inside one repaints only that one', () {
      final _Panels scene = _Panels();
      scene.frame();
      expect(scene.left.paintCount, 1);
      expect(scene.right.paintCount, 1);

      scene.leftBlock.color = _green;
      scene.frame();

      expect(scene.left.paintCount, 2, reason: 'the boundary that changed');
      expect(scene.right.paintCount, 1,
          reason: 'its sibling has no reason to be walked again');
      expect(scene.rightBlock.paintCount, 1,
          reason: 'and neither has anything under that sibling');
    });

    test('a change outside a boundary does not invalidate it', () {
      final _Panels scene = _Panels();
      scene.frame();
      scene.outerBlock.color = _green;
      scene.frame();

      expect(scene.outerBlock.paintCount, 2);
      expect(scene.left.paintCount, 1);
      expect(scene.right.paintCount, 1);
    });

    test('nothing changing walks nothing, however many frames go by', () {
      final _Panels scene = _Panels();
      for (int i = 0; i < 8; i++) {
        scene.frame();
      }
      expect(scene.left.paintCount, 1);
      expect(scene.right.paintCount, 1);
      expect(scene.leftBlock.paintCount, 1);
    });

    test('moving a boundary reuses the recording', () {
      final _Moving scene = _Moving(caching: true);
      scene.frame();
      expect(scene.boundary.paintCount, 1);

      scene.moveTo(const Offset(17, 9));
      scene.moveTo(const Offset(3, 40));

      expect(scene.boundary.paintCount, 1,
          reason: 'a translation is not a reason to walk a subtree again');
    });

    test('resizing a boundary does not', () {
      final _Moving scene = _Moving(caching: true);
      scene.frame();
      scene.block.preferred = const Size(14, 14);
      scene.frame();

      expect(scene.boundary.paintCount, 2);
    });

    test('the dirty set holds one node however deep the change is', () {
      // The property `markNeedsPaint` stopping where it does is *for*: the
      // pipeline learns about one node, not about a chain of ancestors.
      final _Panels scene = _Panels();
      scene.frame();
      expect(scene.owner.nodesNeedingPaint, isEmpty);

      scene.leftBlock.color = _green;
      expect(scene.owner.nodesNeedingPaint, <RenderBox>[scene.leftBlock]);
    });

    test('a boundary containing a content hint gives up caching for good', () {
      // Named rather than worked around: `appendFrom` cannot replay hint spans
      // and this is what the boundary does about it. The refusal is sticky, so
      // the count keeps climbing exactly as it did before the cache existed -
      // and the first frame counts twice, because that is the frame on which
      // the recording is made, found to be unspliceable, and thrown away.
      final PipelineOwner owner = PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(64, 64)));
      final RenderRepaintBoundary boundary = RenderRepaintBoundary(
        child: RenderContentHint(
          hint: const ContentHint(motion: ContentMotionHint.animating),
          child: _Block(preferred: const Size(12, 12), color: _red),
        ),
      );
      owner.root = _Mover(childOffset: Offset.zero, child: boundary);

      owner.drawFrame(DisplayList());
      expect(boundary.paintCount, 2, reason: 'the discovery frame walks twice');
      owner.drawFrame(DisplayList());
      owner.drawFrame(DisplayList());
      expect(boundary.paintCount, 4, reason: 'and every frame after it once');
    });

    test('an outer boundary is invalidated by a change in an inner one', () {
      // The limitation, asserted so that nobody has to discover it from a
      // profile. `appendFrom` copies words rather than referencing a layer, so
      // the outer recording really does contain the inner one's bytes and
      // really is stale when they change. Nesting helps siblings, not
      // ancestors.
      final PipelineOwner owner = PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(64, 64)));
      final _Block inner = _Block(preferred: const Size(6, 6), color: _blue);
      final RenderRepaintBoundary innerBoundary =
          RenderRepaintBoundary(child: inner);
      final RenderRepaintBoundary outerBoundary = RenderRepaintBoundary(
        child: _Stack(<RenderBox>[
          _Block(preferred: const Size(20, 20), color: _red),
          innerBoundary,
        ]),
      );
      owner.root = _Mover(childOffset: Offset.zero, child: outerBoundary);

      owner.drawFrame(DisplayList());
      inner.color = _green;
      owner.drawFrame(DisplayList());

      expect(innerBoundary.paintCount, 2);
      expect(outerBoundary.paintCount, 2,
          reason: 'it inlined the inner one, so its bytes went stale too');
    });
  });

  group('the recording is dropped when it stops being true', () {
    test('detaching a boundary drops it', () {
      final PipelineOwner owner = PipelineOwner(
          rootConstraints: BoxConstraints.tight(const Size(64, 64)));
      final RenderRepaintBoundary boundary = RenderRepaintBoundary(
        child: _Block(preferred: const Size(10, 10), color: _red),
      );
      final _Mover host = _Mover(childOffset: Offset.zero, child: boundary);
      owner.root = host;
      owner.drawFrame(DisplayList());
      expect(boundary.paintCount, 1);

      host.child = null;
      host.child = boundary;
      owner.drawFrame(DisplayList());

      expect(boundary.paintCount, 2,
          reason: 'nothing invalidates a node that is off the tree, so it has '
              'to give the recording up on the way out');
    });

    test('turning the switch off drops every recording in the tree', () {
      final _Panels scene = _Panels();
      scene.frame();
      expect(scene.left.paintCount, 1);

      scene.owner
        ..repaintBoundaryCaching = false
        ..repaintBoundaryCaching = true;
      scene.frame();

      expect(scene.left.paintCount, 2);
      scene.frame();
      expect(scene.left.paintCount, 2, reason: 'and then caches again');
    });
  });
}

// ---------------------------------------------------------------------------
// The equivalence comparison
// ---------------------------------------------------------------------------

/// Runs the same scene twice, cached and walked, and asserts the last frame of
/// each is the same command stream.
void _expectEquivalent({
  required (RenderBox, void Function(int frame)) Function() build,
  required int frames,
  Size size = const Size(64, 64),
}) {
  final DisplayList cached =
      _lastFrame(caching: true, frames: frames, build: build, size: size);
  final DisplayList walked =
      _lastFrame(caching: false, frames: frames, build: build, size: size);
  _expectSameStream(cached, walked);
}

/// Builds a fresh tree, runs [frames] frames through a real [PipelineOwner],
/// and returns the display list of the last one.
///
/// Fresh per call on purpose: the two runs must not share a node, or the second
/// one would start from the first one's caches and prove nothing.
DisplayList _lastFrame({
  required (RenderBox, void Function(int frame)) Function() build,
  required bool caching,
  required int frames,
  Size size = const Size(64, 64),
}) {
  final (RenderBox root, void Function(int) mutate) = build();
  final PipelineOwner owner =
      PipelineOwner(rootConstraints: BoxConstraints.tight(size))
        ..repaintBoundaryCaching = caching
        ..root = root;
  DisplayList list = DisplayList();
  for (int frame = 0; frame < frames; frame++) {
    mutate(frame);
    list = DisplayList();
    owner.drawFrame(list);
  }
  return list;
}

/// Asserts that [spliced] and [direct] are the same command stream.
///
/// Deliberately the same comparison as `display_list_splice_test.dart`, one
/// level up: the two lists are entitled to number their resources differently,
/// and what they are not entitled to do is resolve them to different things.
void _expectSameStream(DisplayList spliced, DisplayList direct) {
  expect(spliced.commandCount, direct.commandCount,
      reason: 'a cached frame must not add or drop commands');

  final DisplayListReader a = DisplayListReader(spliced);
  final DisplayListReader b = DisplayListReader(direct);
  var index = 0;
  while (a.moveNext()) {
    expect(b.moveNext(), isTrue, reason: 'the walked list ran out first');
    final String at = 'command $index';
    expect(a.opcode, b.opcode, reason: '$at: opcode');
    expect(a.intOperandCount, b.intOperandCount, reason: '$at: int operands');
    expect(a.floatOperandCount, b.floatOperandCount,
        reason: '$at: float operands');
    for (var i = 0; i < a.floatOperandCount; i++) {
      expect(a.floatAt(i), b.floatAt(i), reason: '$at: float $i');
    }
    switch (a.opcode) {
      case opDrawRect:
      case opDrawRRect:
      case opSaveLayer:
        _expectSamePaint(spliced, a.paintId, direct, b.paintId, at);
      case opDrawPath:
        expect(identical(spliced.pathAt(a.pathId), direct.pathAt(b.pathId)),
            isTrue,
            reason: '$at: path');
        _expectSamePaint(spliced, a.paintId, direct, b.paintId, at);
      case opDrawImage:
        expect(identical(spliced.imageAt(a.imageId), direct.imageAt(b.imageId)),
            isTrue,
            reason: '$at: image');
        _expectSamePaint(spliced, a.paintId, direct, b.paintId, at);
      case opDrawGlyphRun:
        expect(identical(spliced.fontAt(a.fontId), direct.fontAt(b.fontId)),
            isTrue,
            reason: '$at: font');
        _expectSamePaint(spliced, a.paintId, direct, b.paintId, at);
    }
    index++;
  }
  expect(b.moveNext(), isFalse, reason: 'the cached list ran out first');
}

void _expectSamePaint(
  DisplayList spliced,
  int a,
  DisplayList direct,
  int b,
  String at,
) {
  expect(spliced.paintColor(a), direct.paintColor(b), reason: '$at: colour');
  expect(spliced.paintStyle(a), direct.paintStyle(b), reason: '$at: style');
  expect(spliced.paintStrokeWidth(a), direct.paintStrokeWidth(b),
      reason: '$at: stroke width');
  expect(spliced.paintBlendMode(a), direct.paintBlendMode(b),
      reason: '$at: blend mode');
  expect(spliced.paintAntiAlias(a), direct.paintAntiAlias(b),
      reason: '$at: anti-alias');
}

/// Asserts the two hint side tables advise the same op offsets identically.
void _expectSameHintSpans(DisplayList a, DisplayList b) {
  final ContentHintSpans left = a.contentHints;
  final ContentHintSpans right = b.contentHints;
  expect(left.spanCount, right.spanCount);
  for (int i = 0; i < left.spanCount; i++) {
    expect(left.spanStart(i), right.spanStart(i), reason: 'span $i start');
    expect(left.spanHint(i), right.spanHint(i), reason: 'span $i hint');
  }
}

/// Rasterises [list] on the CPU and hands back the raw bytes.
Future<Uint8List> _pixels(DisplayList list) async {
  final MemoryRenderTarget target = await memoryTarget(64, 64);
  await target.renderDisplayList(list, clearColor: 0xFF000000);
  return Uint8List.fromList(target.framebuffer.pixels);
}

(RenderBox, void Function(int)) _hintOverBoundary() {
  final _Block block = _Block(preferred: const Size(12, 12), color: _red);
  final RenderBox root = RenderContentHint(
    hint: const ContentHint(motion: ContentMotionHint.animating),
    child: _Mover(
      childOffset: const Offset(3, 3),
      child: RenderRepaintBoundary(child: block),
    ),
  );
  return (root, (int frame) {});
}

// ---------------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------------

/// Two boundaries side by side under a node that is not one.
///
/// The shape every "only that one repainted" assertion needs: something to
/// change, a sibling that must not notice, and an ancestor that must.
final class _Panels {
  _Panels() {
    left = RenderRepaintBoundary(child: leftBlock);
    right = RenderRepaintBoundary(child: rightBlock);
    owner = PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(64, 64)),
    )..root = _Stack(<RenderBox>[outerBlock, left, right]);
  }

  final _Block leftBlock = _Block(preferred: const Size(10, 10), color: _red);
  final _Block rightBlock = _Block(preferred: const Size(10, 10), color: _blue);
  final _Block outerBlock =
      _Block(preferred: const Size(30, 30), color: _green);
  late final RenderRepaintBoundary left;
  late final RenderRepaintBoundary right;
  late final PipelineOwner owner;

  void frame() => owner.drawFrame(DisplayList());
}

/// One boundary that a test can slide around.
final class _Moving {
  _Moving({required bool caching}) {
    boundary = RenderRepaintBoundary(child: block);
    host = _Mover(childOffset: const Offset(5, 5), child: boundary);
    owner = PipelineOwner(
      rootConstraints: BoxConstraints.tight(const Size(64, 64)),
    )
      ..repaintBoundaryCaching = caching
      ..root = host;
  }

  final _Block block = _Block(preferred: const Size(10, 10), color: _red);
  late final RenderRepaintBoundary boundary;
  late final _Mover host;
  late final PipelineOwner owner;

  DisplayList frame() {
    final DisplayList list = DisplayList();
    owner.drawFrame(list);
    return list;
  }

  DisplayList moveTo(Offset offset) {
    host.childOffset = offset;
    return frame();
  }
}

// ---------------------------------------------------------------------------
// Render nodes that exist only to be counted
// ---------------------------------------------------------------------------

/// A leaf that fills its box with one colour and counts its own walks.
final class _Block extends RenderBox {
  _Block({required Size preferred, required int color})
      : _preferred = preferred,
        _color = color;

  Size _preferred;
  int _color;

  /// How many times [paint] actually ran. The number every caching claim in
  /// this file is really about.
  int paintCount = 0;

  set preferred(Size value) {
    if (value == _preferred) return;
    _preferred = value;
    markNeedsLayout();
  }

  set color(int value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    size = constraints.constrain(_preferred);
  }

  @override
  void paint(DisplayList list, Offset offset) {
    paintCount++;
    final int paint = list.addPaint(colorArgb: _color);
    list.drawRect(
      offset.dx,
      offset.dy,
      offset.dx + size.width,
      offset.dy + size.height,
      paint,
    );
  }
}

/// A single-child box that places its child at an offset the test chooses.
///
/// The child is laid out loosely with `parentUsesSize: false`, which makes it a
/// relayout boundary: changing [childOffset] re-runs *this* node's layout and
/// leaves the child's alone, so the child's recording survives the move. That
/// is exactly the arrangement a scroll offset produces, and the reason the
/// translated splice is worth having.
final class _Mover extends RenderSingleChildBox {
  _Mover({required Offset childOffset, super.child})
      : _childOffset = childOffset;

  Offset _childOffset;

  set childOffset(Offset value) {
    if (value == _childOffset) return;
    _childOffset = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child != null) {
      child.layout(BoxConstraints.loose(constraints.biggest));
      child.parentData!.offset = _childOffset;
    }
    size = constraints.biggest;
  }
}

/// Children stacked at the origin, painted in order, all loosely constrained.
final class _Stack extends RenderBoxContainer<BoxParentData> {
  _Stack(List<RenderBox> children) {
    for (final RenderBox child in children) {
      add(child);
    }
  }

  void append(RenderBox child) => add(child);

  @override
  void performLayout() {
    for (int i = 0; i < childCount; i++) {
      childAt(i).layout(BoxConstraints.loose(constraints.biggest));
    }
    size = constraints.biggest;
  }
}
