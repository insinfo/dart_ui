/// The frame arena: one display list reused, not one allocated per frame.
///
/// `FrameScheduler` used to construct a `DisplayList` inside every
/// `_handleFrame`, which defeated `DisplayList.reset` completely - and did it
/// up to eight times per presented frame, because `ApplicationWindow.drawFrame`
/// runs a settle loop and keeps only the last list. Every discarded list took
/// its arena with it: a `Uint32List(1024)` and a `Float32List(2048)` that then
/// had to double their way back up to the size of the content on the next
/// frame.
///
/// The assertions here are the two halves of the fix and they pull in opposite
/// directions, which is the point:
///
///   * the arena is **reused** - the same instance across settle passes, and
///     `bufferGrowths` stops rising once the content has been seen;
///   * the arena is **not reused while a presenter may still hold it** - the
///     ring turns on `advanceDisplayList`, once per presented frame, never
///     once per settle pass.
///
/// And, because a premature reset is a *visual* bug rather than a crash, every
/// reuse claim is paired with a byte-for-byte comparison of what the frame
/// encoded.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/geometry/offset.dart';
import 'package:dart_ui/src/geometry/size.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/display_list_pool.dart';
import 'package:dart_ui/src/layout/box_constraints.dart';
import 'package:dart_ui/src/layout/pipeline.dart';
import 'package:dart_ui/src/layout/render_box.dart';
import 'package:dart_ui/src/scheduler/frame_scheduler.dart';
import 'package:dart_ui/src/scheduler/manual_dispatcher.dart';
import 'package:test/test.dart';

void main() {
  group('DisplayListPool', () {
    test('hands out one arena until the ring is advanced', () {
      final pool = DisplayListPool();
      final DisplayList first = pool.current;

      expect(pool.size, 2);
      expect(identical(pool.current, first), isTrue);
      expect(identical(pool.current, first), isTrue);
      expect(pool.rotations, 0);
    });

    test('alternates between exactly two arenas', () {
      final pool = DisplayListPool();
      final DisplayList a = pool.current;
      pool.advance();
      final DisplayList b = pool.current;
      pool.advance();

      expect(identical(a, b), isFalse);
      expect(identical(pool.current, a), isTrue);
      expect(pool.rotations, 2);
    });

    test('a single-slot ring never rotates away from its one arena', () {
      final pool = DisplayListPool.single();
      final DisplayList only = pool.current;
      pool
        ..advance()
        ..advance();

      expect(pool.size, 1);
      expect(identical(pool.current, only), isTrue);
      expect(pool.rotations, 2);
    });

    test('a three-slot ring cycles in order', () {
      final pool = DisplayListPool(size: 3);
      final lists = <DisplayList>[
        pool.listAt(0),
        pool.listAt(1),
        pool.listAt(2),
      ];
      for (var i = 0; i < 7; i++) {
        expect(identical(pool.current, lists[i % 3]), isTrue,
            reason: 'turn $i');
        pool.advance();
      }
    });
  });

  group('FrameScheduler arena', () {
    test('a frame rewinds the arena instead of allocating one', () {
      final seen = <DisplayList>[];
      final scheduler = _scheduler(onFrame: seen.add);

      for (var i = 0; i < 5; i++) {
        scheduler
          ..scheduleFrame()
          ..pump();
      }

      expect(seen, hasLength(5));
      for (final DisplayList list in seen) {
        expect(identical(list, seen.first), isTrue);
      }
      scheduler.dispose();
    });

    test('the arena is reset per frame, so nothing accumulates', () {
      var painted = 0;
      final scheduler = _scheduler(onFrame: (DisplayList list) => painted++);
      final owner = scheduler.pipelineOwner
        ..rootConstraints = BoxConstraints.tight(const Size(40, 30))
        ..root = _StripeBox(stripes: 12);

      final counts = <int>[];
      final growths = <int>[];
      for (var i = 0; i < 6; i++) {
        scheduler
          ..scheduleFrame()
          ..pump();
        counts.add(scheduler.displayList.commandCount);
        growths.add(scheduler.displayList.bufferGrowths);
      }

      expect(painted, 6);
      expect(owner.needsLayout, isFalse);
      // Twelve stripes, every frame. An arena that was not rewound would show
      // 12, 24, 36...
      expect(counts, everyElement(counts.first));
      // The buffers reach the high-water mark and stop reallocating: the whole
      // reason reset() exists.
      expect(growths.last, growths[1]);
      scheduler.dispose();
    });

    test('a settle sequence encodes exactly what its last pass encoded', () {
      // What `ApplicationWindow.drawFrame` does: build, pump, and pump again
      // while the tree is still dirty, presenting only the last list. Every
      // pass must leave the arena holding one frame's worth of commands, and
      // the last pass must be byte-identical to the same content drawn in a
      // single pass.
      final settling = _scheduler(onFrame: (_) {});
      settling.pipelineOwner
        ..rootConstraints = BoxConstraints.tight(const Size(40, 30))
        ..root = _StripeBox(stripes: 9);
      for (var pass = 0; pass < _maxSettlePasses; pass++) {
        settling
          ..scheduleFrame()
          ..pump();
      }
      final _Encoded settled = _Encoded.of(settling.displayList);

      final single = _scheduler(onFrame: (_) {});
      single.pipelineOwner
        ..rootConstraints = BoxConstraints.tight(const Size(40, 30))
        ..root = _StripeBox(stripes: 9);
      single
        ..scheduleFrame()
        ..pump();
      final _Encoded once = _Encoded.of(single.displayList);

      expect(settled, once);
      settling.dispose();
      single.dispose();
    });

    test('a sequence of frames encodes identical bytes every time', () {
      final scheduler = _scheduler(onFrame: (_) {});
      scheduler.pipelineOwner
        ..rootConstraints = BoxConstraints.tight(const Size(64, 48))
        ..root = _StripeBox(stripes: 17);

      final frames = <_Encoded>[];
      for (var i = 0; i < 8; i++) {
        scheduler
          ..scheduleFrame()
          ..pump();
        frames.add(_Encoded.of(scheduler.displayList));
        // Presented: turn the ring, exactly as `drawFrame` does.
        scheduler.advanceDisplayList();
        scheduler.pipelineOwner.root!.markNeedsPaint();
      }

      for (final _Encoded frame in frames) {
        expect(frame, frames.first);
      }
      // Eight frames, two arenas: each was recorded into four times and both
      // hold the same picture.
      expect(scheduler.displayLists.rotations, 8);
      scheduler.dispose();
    });

    test('advancing hands the next frame a different arena', () {
      final seen = <DisplayList>[];
      final scheduler = _scheduler(onFrame: seen.add);

      scheduler
        ..scheduleFrame()
        ..pump()
        ..advanceDisplayList()
        ..scheduleFrame()
        ..pump()
        ..advanceDisplayList()
        ..scheduleFrame()
        ..pump();

      expect(seen, hasLength(3));
      // The presented list of frame 1 is untouched while frame 2 records, and
      // only becomes the recording arena again on frame 3 - by which time
      // frame 2's list is the one a presenter holds.
      expect(identical(seen[0], seen[1]), isFalse);
      expect(identical(seen[0], seen[2]), isTrue);
      scheduler.dispose();
    });

    test('a settle sequence never rotates the ring', () {
      final seen = <DisplayList>[];
      final scheduler = _scheduler(onFrame: seen.add);

      for (var pass = 0; pass < _maxSettlePasses; pass++) {
        scheduler
          ..scheduleFrame()
          ..pump();
      }
      scheduler.advanceDisplayList();

      expect(seen, hasLength(_maxSettlePasses));
      for (final DisplayList list in seen) {
        expect(identical(list, seen.first), isTrue);
      }
      expect(scheduler.displayLists.rotations, 1);
      expect(identical(scheduler.displayList, seen.first), isFalse);
      scheduler.dispose();
    });

    test('a frame that fails still reports through the reused arena', () {
      final seen = <DisplayList>[];
      final scheduler = FrameScheduler(
        dispatcher: ManualDispatcher(),
        onFrame: seen.add,
        onError: (_, __, ___) {},
      );
      scheduler.addFrameCallback((_) => throw StateError('broken'));

      scheduler
        ..scheduleFrame()
        ..pump()
        ..scheduleFrame()
        ..pump();

      expect(seen, hasLength(2));
      expect(identical(seen[0], seen[1]), isTrue);
      expect(seen.first.commandCount, 0);
      scheduler.dispose();
    });

    test('an injected pool is the one the frames record into', () {
      final pool = DisplayListPool(size: 3);
      final seen = <DisplayList>[];
      final scheduler = FrameScheduler(
        dispatcher: ManualDispatcher(),
        displayLists: pool,
        onFrame: seen.add,
      );

      scheduler
        ..scheduleFrame()
        ..pump()
        ..advanceDisplayList()
        ..scheduleFrame()
        ..pump();

      expect(identical(seen[0], pool.listAt(0)), isTrue);
      expect(identical(seen[1], pool.listAt(1)), isTrue);
      scheduler.dispose();
    });
  });
}

/// Mirrors `ApplicationWindow._maxSettlePasses`, which is private.
const int _maxSettlePasses = 8;

FrameScheduler _scheduler({required void Function(DisplayList) onFrame}) =>
    FrameScheduler(
      dispatcher: ManualDispatcher(),
      pipelineOwner: PipelineOwner(),
      onFrame: onFrame,
    );

/// A copy of everything a display list encodes, taken before the arena is
/// rewound.
///
/// A copy and not a view: the whole subject of this file is that the buffers
/// underneath are reused, so a comparison against a live buffer would compare
/// a frame with itself.
final class _Encoded {
  _Encoded(this.ops, this.floats, this.commandCount, this.paintCount);

  factory _Encoded.of(DisplayList list) => _Encoded(
        Uint32List.fromList(
          Uint32List.sublistView(list.opBuffer, 0, list.opLength),
        ),
        Float32List.fromList(
          Float32List.sublistView(list.floatBuffer, 0, list.floatLength),
        ),
        list.commandCount,
        list.paintCount,
      );

  final Uint32List ops;
  final Float32List floats;
  final int commandCount;
  final int paintCount;

  @override
  bool operator ==(Object other) {
    if (other is! _Encoded) return false;
    if (other.commandCount != commandCount) return false;
    if (other.paintCount != paintCount) return false;
    if (other.ops.length != ops.length) return false;
    if (other.floats.length != floats.length) return false;
    for (var i = 0; i < ops.length; i++) {
      if (other.ops[i] != ops[i]) return false;
    }
    for (var i = 0; i < floats.length; i++) {
      if (other.floats[i] != floats[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(commandCount, paintCount, ops.length);

  @override
  String toString() => '_Encoded($commandCount commands, ${ops.length} words, '
      '${floats.length} floats)';
}

/// A leaf that paints a fixed number of rectangles, so a frame has content
/// whose encoding can be compared word for word.
final class _StripeBox extends RenderBox {
  _StripeBox({required this.stripes});

  final int stripes;

  @override
  void performLayout() {
    size = constraints.largestFinite;
  }

  @override
  void paint(DisplayList list, Offset offset) {
    for (var i = 0; i < stripes; i++) {
      final int paint = list.addPaint(colorArgb: 0xFF000000 | (i * 0x010203));
      final double top = offset.dy + i * 2.0;
      list.drawRect(
        offset.dx,
        top,
        offset.dx + size.width,
        top + 1.5,
        paint,
      );
      list.drawRRectUniform(
        offset.dx + 1,
        top,
        offset.dx + 9,
        top + 1.5,
        0.5,
        0.5,
        paint,
      );
    }
  }
}
