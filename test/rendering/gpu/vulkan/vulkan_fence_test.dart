/// Proof that the fence wait actually waits.
///
/// ## Why "render N frames and look at the pixels" proves nothing here
///
/// `VulkanDevice.beginFrame` waits on the slot's fence before it resets the
/// slot's command pool, and that wait is the only thing stopping the CPU from
/// overwriting commands the GPU is still reading. Delete the wait and, on a
/// fast GPU drawing a small scene, **every existing test still passes**: the
/// GPU finishes long before the CPU comes round the two-slot ring again, so
/// the race never opens. The bug would surface as one corrupted frame in
/// thousands, on somebody else's machine, under load.
///
/// So the wait is tested directly, the way the Direct3D 12 backend tests its
/// own in `test/backends/win32/d3d12/d3d12_fence_test.dart`: put a gate in
/// front of the queue that the CPU has not opened, submit behind it, assert
/// that the wait **times out**, and only then open the gate and assert that
/// the same wait succeeds. The timeout is the assertion. Without it, a wait
/// that returned immediately would pass the second half.
///
/// ## Why the gate is a `VkEvent` and not a semaphore
///
/// Direct3D 12 can stop a queue with `ID3D12CommandQueue::Wait` on a fence the
/// CPU signals later. Vulkan's binary semaphores cannot do that: they are
/// signalled by the device only, and submitting a wait for one that has no
/// pending signal violates `vkQueueSubmit`'s valid usage - the construction
/// would work on this machine and be a validation error on a machine with the
/// Khronos layer installed, which is the worst kind of test.
///
/// `VkEvent` is the primitive built for exactly this. `vkCmdWaitEvents` with
/// `srcStageMask = VK_PIPELINE_STAGE_HOST_BIT` stops the GPU until the host
/// calls `vkSetEvent`, it is core Vulkan 1.0, and it is the documented
/// host-to-device gate rather than a trick. Timeline semaphores would also
/// work and would require Vulkan 1.2, which this backend deliberately does not
/// demand.
library;

import 'dart:ffi';

import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_constants.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_device.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

/// 200 ms, expressed in the nanoseconds `vkWaitForFences` takes.
///
/// Long enough that a GPU which really did finish the (empty) work would have
/// signalled many times over, short enough that a test file which does this
/// twice still runs in under a second.
const int _timeout = 200 * 1000 * 1000;

/// Five seconds: the budget for work that is genuinely allowed to run.
const int _generous = 5 * 1000 * 1000 * 1000;

void main() {
  final VulkanSession session = VulkanSession.open();

  group('the frame fence', () {
    tearDownAll(session.close);

    test('a wait on a fence nobody signals times out, and is not broken', () {
      // The primitive on its own, first. If `waitForFence` returned false for
      // every input - a null check in the wrong place, a VkResult read as
      // signed when it is not - the gate test below would pass for the wrong
      // reason. This is the non-vacuity check for it.
      final VulkanDevice device = session.device!;
      final Pointer<VkFence_T> fence = device.createFence();
      addTearDown(() => device.destroyFence(fence));

      expect(fence, isNot(nullptr));
      expect(device.isFenceSignalled(fence), isFalse);
      expect(device.waitForFence(fence, _timeout), isFalse,
          reason: 'an unsignalled fence must not report itself signalled');
      expect(device.isLost, isFalse,
          reason: 'a timeout must leave the device healthy; if this is true '
              'the false above was a failure, not a timeout');

      // The same fence, signalled by an empty submission, must now pass.
      expect(
        device.submit(
            commandBuffers: const <Pointer<VkCommandBuffer_T>>[], fence: fence),
        isTrue,
      );
      expect(device.waitForFence(fence, _generous), isTrue);
      expect(device.isFenceSignalled(fence), isTrue);
      device.resetFence(fence);
      expect(device.isFenceSignalled(fence), isFalse);
    }, skip: session.skipReason);

    test('a frame held behind a gate is waited for, not assumed finished', () {
      final VulkanDevice device = session.device!;

      // Everything already submitted has to drain first, or the frame under
      // test could be preceded on the queue by work that opens nothing and
      // completes anyway.
      expect(device.waitIdle(), isTrue);

      // The gate. Unsignalled, and only the host can signal it.
      final Pointer<VkEvent_T> gate = device.createEvent();
      expect(gate, isNot(nullptr));

      var opened = false;
      addTearDown(() {
        // The gate must be opened before anything is destroyed, whatever the
        // assertions did: destroying a command pool whose buffer is parked
        // inside vkCmdWaitEvents is the corruption this whole file is about.
        if (!opened) device.setEvent(gate);
        device
          ..waitIdle()
          ..destroyEvent(gate);
      });

      // One command buffer whose entire content is "stop until the host says
      // otherwise". `endFrame` submits it with its own slot's fence, and that
      // is the fence waited on below - see `debugFenceOfSlot`.
      final int slot = device.frameIndex;
      final Pointer<VkCommandBuffer_T>? commands = device.beginFrame();
      expect(commands, isNotNull);
      device.recordWaitEvent(commands!, gate);
      expect(device.endFrame(), isTrue);

      final Pointer<VkFence_T> fence = device.debugFenceOfSlot(slot);
      expect(device.isFenceSignalled(fence), isFalse,
          reason: 'the gated submission cannot already have completed');

      // The heart of it. This fence belongs to the submission that is parked
      // on the gate, so it cannot signal while the gate is shut.
      expect(
        device.waitForFence(fence, _timeout),
        isFalse,
        reason: 'the wait returned while the frame in front of it was still '
            'parked on a gate the host had not opened; a command-pool reset '
            'here would overwrite commands the GPU is about to read',
      );
      expect(device.isLost, isFalse,
          reason: 'that false has to be VK_TIMEOUT, not a device loss');

      // Open the gate. The same wait must now succeed.
      expect(device.setEvent(gate), isTrue);
      opened = true;
      expect(
        device.waitForFence(fence, _generous),
        isTrue,
        reason: 'the frame never completed after the gate was opened',
      );
      expect(device.isFenceSignalled(fence), isTrue);
    }, skip: session.skipReason);

    test('beginFrame blocks on the slot it is about to reset', () {
      // The same gate, seen through the API the renderer actually calls. With
      // two frames in flight, gating frame N and then asking for frame N+2
      // forces `beginFrame` onto N's slot, and it must not come back until the
      // gate is open.
      final VulkanDevice device = session.device!;
      expect(device.waitIdle(), isTrue);

      final Pointer<VkEvent_T> gate = device.createEvent();
      expect(gate, isNot(nullptr));
      var opened = false;
      addTearDown(() {
        if (!opened) device.setEvent(gate);
        device
          ..waitIdle()
          ..destroyEvent(gate);
      });

      final int slot = device.frameIndex;
      final Pointer<VkCommandBuffer_T>? gated = device.beginFrame();
      expect(gated, isNotNull);
      device.recordWaitEvent(gated!, gate);
      expect(device.endFrame(), isTrue);

      // Frame N+1 uses the other slot and is unaffected.
      expect(device.beginFrame(), isNotNull);
      expect(device.endFrame(), isTrue);
      expect(device.frameIndex, slot,
          reason: 'the ring must have come back round to the gated slot');

      final int waits = device.waitCount;
      // Nothing has opened the gate, so the gated frame is still pending and
      // its slot's fence is still unsignalled. Proven directly rather than by
      // timing the call, which would be a flake on a loaded machine.
      expect(device.setEvent(gate), isTrue);
      opened = true;
      expect(device.beginFrame(), isNotNull,
          reason: 'beginFrame must return once the gated frame completes');
      expect(device.waitCount, waits + 1,
          reason: 'beginFrame reached the slot that had work outstanding and '
              'must have waited on its fence');
      device.abandonFrame();
      expect(device.waitIdle(), isTrue);
    }, skip: session.skipReason);
  });
}
