/// The fence, proved to wait.
///
/// This is the test the whole Direct3D 12 port turns on. A command allocator's
/// memory may be reset **only** once the GPU has finished executing every list
/// recorded into it, nothing in the API checks, and getting it wrong does not
/// crash - it produces a frame that draws the previous frame's geometry, or
/// half of it, intermittently, on one machine. A renderer can be shipped for
/// months with that bug and pass every pixel test.
///
/// ## Why "run some frames and see" proves nothing
///
/// The obvious test - render N frames, assert they look right - is vacuous
/// here. On a fast machine with a small scene the GPU has already finished by
/// the time the CPU comes back round, so a renderer that never waited at all
/// would pass it, every time, and fail on a slower GPU or a heavier frame.
/// Counting the waits is barely better: a run where the count happens to be
/// zero is indistinguishable from a run with no wait in it.
///
/// ## What is proved instead
///
/// `ID3D12CommandQueue::Wait` makes the **queue** block until a fence reaches
/// a value. Signalling that fence is the CPU's choice, so the GPU can be held
/// still on purpose:
///
///   1. Put a gate fence in front of the queue at a value nobody has signalled.
///   2. Submit a frame. Its completion signal is now queued *behind* the gate
///      and cannot possibly have run.
///   3. Assert the ring's fence has not reached the frame's value, and that a
///      bounded wait on it **times out** - that is the wait blocking, observed
///      rather than inferred.
///   4. Signal the gate from the CPU. Assert the same wait now succeeds.
///   5. Assert the allocator reset that follows recorded a completed value at
///      or past the value that released it.
///
/// Step 3 is the proof. It is deterministic: it does not depend on how fast
/// the GPU is, because the GPU has been told not to start.
library;

import 'dart:ffi';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_com.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_frame_ring.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_interfaces.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_library.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_offscreen_target.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:test/test.dart';

import 'd3d12_session.dart';

/// Long enough that a working GPU would have finished the frame many times
/// over, short enough that a broken test does not hang the suite.
const int _timeoutMilliseconds = 200;

void main() {
  final D3d12Session session = D3d12Session.open();

  group('the frame fence', () {
    tearDownAll(session.close);

    test('a wait on a value nobody signals does not return', () {
      // The primitive, on its own. A fence created at 0 and never signalled
      // can never reach 1, so a wait that returns true here is a wait that is
      // not waiting - which is exactly the bug this file exists to exclude,
      // reduced to two lines.
      final D3d12RenderDevice device = session.device!;
      final D3d12Fence fence = _createFence(device);
      addTearDown(fence.release);

      expect(
        device.frames.debugWaitOn(fence, 1, _timeoutMilliseconds),
        isFalse,
        reason: 'a fence nobody signalled reported completion',
      );

      // ...and the same wait returns as soon as the value is reached, so the
      // false above is a genuine timeout and not a wait that always fails.
      expect(fence.signalFromCpu(1), 0);
      expect(
        device.frames.debugWaitOn(fence, 1, _timeoutMilliseconds),
        isTrue,
      );
    }, skip: session.skipReason);

    test('a frame held behind a gate is waited for, not assumed finished', () {
      final D3d12RenderDevice device = session.device!;
      final D3d12FrameRing frames = device.frames;

      // Everything already submitted has to be drained first, or the gate
      // below would be crossed by work that was already in flight and the
      // frame under test would complete anyway.
      expect(frames.waitIdle(), isTrue);

      final D3d12Fence gate = _createFence(device);
      addTearDown(gate.release);

      // The queue may not execute anything past this point until the gate
      // reaches 1. This is the whole trick: the GPU is stopped on purpose, so
      // the assertions below do not race it.
      expect(comFailed(device.queue.wait(gate.pointer, 1)), isFalse);

      // One empty frame, submitted behind the gate.
      expect(frames.begin(), isNotNull);
      expect(frames.end(), isTrue);
      final int target = frames.signalledValue;

      expect(
        frames.completedValue,
        lessThan(target),
        reason: 'the queue signalled a value whose work it has not run',
      );
      expect(
        frames.debugWaitOn(frames.fence, target, _timeoutMilliseconds),
        isFalse,
        reason: 'the wait returned while the frame was still queued behind a '
            'gate the CPU had not opened; an allocator reset here would free '
            'memory the GPU is about to read',
      );

      // Open the gate. The frame can now run, and the same wait must succeed.
      expect(gate.signalFromCpu(1), 0);
      expect(
        frames.debugWaitOn(frames.fence, target, 5000),
        isTrue,
        reason: 'the frame never completed after the gate was opened',
      );
      expect(frames.completedValue, greaterThanOrEqualTo(target));
    }, skip: session.skipReason);

    test('every allocator reset happened after its slot was released',
        () async {
      // The invariant itself, recorded where it is actually enforced rather
      // than inferred from the pixels. `completed >= required` on every entry
      // is what makes reusing an allocator legal.
      final D3d12RenderDevice device = session.device!;
      final D3d12OffscreenTarget target = session.target(32, 32);
      final int before = device.frames.debugResets.length;

      for (var frame = 0; frame < 8; frame++) {
        final DisplayList list = DisplayList();
        final int paint =
            list.addPaint(colorArgb: 0xFF000000 | (frame * 0x101010));
        list.drawRRect(2, 2, 30, 30, 6, 6, 6, 6, 6, 6, 6, 6, paint);
        await target.renderDisplayList(list, clearColor: 0xFF000000);
      }

      final List<D3d12AllocatorReset> resets =
          device.frames.debugResets.sublist(before);
      expect(resets, isNotEmpty);
      expect(
        resets.where((D3d12AllocatorReset r) => !r.isLegal),
        isEmpty,
        reason: 'an allocator was reset before the GPU had finished with it:\n'
            '${resets.where((D3d12AllocatorReset r) => !r.isLegal).join('\n')}',
      );
      // Non-vacuous: at least one reset had a real value to wait for, so the
      // comparison above was not "0 >= 0" eight times.
      expect(
        resets.any((D3d12AllocatorReset r) => r.requiredValue > 0),
        isTrue,
        reason: 'no slot had ever been submitted, so the invariant was never '
            'actually tested',
      );
      printOnFailure(resets.join('\n'));
      target.dispose();
    }, skip: session.skipReason);

    test('the ring runs two frames ahead and no more', () {
      // The number is a decision, not an accident - see
      // D3d12FrameRing.kDefaultFrameCount - and a slot count that drifted
      // would change how far the CPU may run ahead without anything else
      // noticing.
      expect(session.device!.frames.frameCount, 2);
    }, skip: session.skipReason);
  });
}

/// A fence at zero, created straight off the device.
///
/// Written here rather than added to [D3d12RenderDevice] as API: the renderer
/// itself needs exactly one fence, which the frame ring owns, and a public
/// `createFence` would invite a second ordering scheme beside it.
D3d12Fence _createFence(D3d12RenderDevice device) {
  final Allocator allocator = device.library.allocator;
  final Pointer<Guid> iid = allocator.allocate<Guid>(sizeOf<Guid>());
  final Pointer<Pointer<Void>> out =
      allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());
  try {
    writeGuid(iid, D3d12Iids.fence);
    final int hr = device.nativeDevice
        .createFence(device.nativeDevice.pointer, 0, 0, iid, out);
    expect(comFailed(hr), isFalse, reason: hresultText(hr));
    return D3d12Fence(out.value);
  } finally {
    allocator
      ..free(iid)
      ..free(out);
  }
}
