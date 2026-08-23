/// `VkDevice`, its one queue, the per-frame command pools, and the
/// synchronisation that makes reusing them safe.
///
/// ## What the fence is actually protecting
///
/// A `VkCommandPool` owns the memory its command buffers were recorded into.
/// `vkResetCommandPool` hands that memory back for reuse **immediately**, and
/// the specification's rule is that no command buffer allocated from the pool
/// may be "pending execution" when it happens. Nothing checks it at run time
/// on a release driver: resetting a pool whose commands the GPU has not
/// finished reading overwrites them mid-flight, and what comes out is a
/// corrupted draw, a device loss, or - most often - a frame that is subtly
/// wrong once every few thousand frames on one machine.
///
/// So there is one pool per frame in flight and one fence per pool, and
/// [beginFrame] waits on the fence before it resets the pool. That wait is the
/// only thing standing between this renderer and that bug, which is why
/// `vulkan_fence_test.dart` proves the wait *waits* rather than proving that N
/// frames render: a renderer that never waited at all would draw a small scene
/// on a fast GPU perfectly, every time, until the day it did not.
///
/// ## Two frames in flight
///
/// The same number the Direct3D 12 backend uses and for the same reason: one
/// means the CPU blocks on the GPU every frame and the two never overlap;
/// three adds a frame of input latency to buy throughput a UI does not need.
/// Two lets the CPU record frame N+1 while the GPU runs frame N, which is the
/// whole point of the ring, and costs one extra command pool.
library;

import 'dart:ffi';

import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import 'vulkan_bindings.dart';
import 'vulkan_constants.dart';
import 'vulkan_ffi.g.dart';
import 'vulkan_instance.dart';
import 'vulkan_library.dart';
import 'vulkan_memory.dart';
import 'vulkan_wsi_bindings.dart';

/// A device, or the diagnostics explaining why there is none.
final class VulkanDeviceAttempt {
  const VulkanDeviceAttempt(this.device, this.diagnostics);

  final VulkanDevice? device;
  final List<BackendDiagnostic> diagnostics;

  String get failureText => diagnostics
      .where((BackendDiagnostic d) => d.isFailure)
      .map((BackendDiagnostic d) => d.toString())
      .join('; ');
}

/// One logical device, its queue, and the frame ring.
final class VulkanDevice {
  VulkanDevice._({
    required this.physicalDevice,
    required this.handle,
    required this.api,
    required this.queue,
    required this.queueFamily,
    required this.presentQueue,
    required this.presentQueueFamily,
    required this.enabledExtensions,
    required this.swapchainApi,
    required this.allocator,
    required List<_FrameSlot> slots,
  }) : _slots = slots;

  /// A wait long enough that reaching it means something is wrong, rather than
  /// that the GPU was busy. Ten seconds; a frame that has not finished by then
  /// is a hang, and returning from the wait lets the caller say so instead of
  /// blocking the process forever.
  static const int kFrameTimeoutNanoseconds = 10 * 1000 * 1000 * 1000;

  static const int kDefaultFramesInFlight = 2;

  final VulkanPhysicalDevice physicalDevice;
  final Pointer<VkDevice_T> handle;
  final VulkanDeviceApi api;
  final Pointer<VkQueue_T> queue;
  final int queueFamily;

  /// The queue `vkQueuePresentKHR` is called on.
  ///
  /// Identical to [queue] on every desktop driver seen so far, and deliberately
  /// not *assumed* to be: Vulkan permits a physical device whose graphics
  /// family cannot present and whose presenting family cannot draw, and a
  /// backend that presented on the graphics queue there would fail validation
  /// and then fail to show anything. When the two families coincide the two
  /// fields hold the same handle and nothing extra is created.
  final Pointer<VkQueue_T> presentQueue;

  /// The family [presentQueue] came from. Equal to [queueFamily] unless the
  /// device forced them apart.
  final int presentQueueFamily;

  /// Whether the two queues are one queue.
  ///
  /// Load-bearing for a swapchain: images shared between two families need
  /// `VK_SHARING_MODE_CONCURRENT` and the family list, and getting that wrong
  /// is undefined behaviour rather than an error.
  bool get hasUnifiedQueues => queueFamily == presentQueueFamily;

  /// Device extensions this device was created with, in the order asked for.
  ///
  /// Kept because "was `VK_KHR_swapchain` enabled?" has to be answerable after
  /// the fact: the command table for it resolves to null either way, and a null
  /// function pointer cannot say whether the extension was refused or never
  /// requested.
  final List<String> enabledExtensions;

  /// The `VK_KHR_swapchain` command table, or null when the extension was not
  /// enabled - which is the normal state of an offscreen device.
  final VulkanSwapchainApi? swapchainApi;

  /// Whether this device can create a swapchain at all.
  bool get canPresent => swapchainApi != null;

  final VulkanMemoryAllocator allocator;

  final List<_FrameSlot> _slots;

  int _frame = 0;
  bool _recording = false;
  bool _disposed = false;
  bool _lost = false;

  /// How many frames have been submitted. Also the index the ring is on.
  int get frameCount => _frame;

  int get framesInFlight => _slots.length;

  int get frameIndex => _frame % _slots.length;

  /// True once a command returned `VK_ERROR_DEVICE_LOST`. Every later command
  /// on this device is undefined, so the flag is checked rather than the calls
  /// being retried.
  bool get isLost => _lost;

  bool get isRecording => _recording;

  /// The command buffer of the frame being recorded.
  Pointer<VkCommandBuffer_T> get commandBuffer {
    if (!_recording) {
      throw StateError('no frame is being recorded; call beginFrame first');
    }
    return _slots[frameIndex].commandBuffer;
  }

  /// How many times [beginFrame] actually blocked on a fence.
  ///
  /// Zero across a whole run means the ring is longer than it needs to be, or
  /// that the GPU is never the bottleneck. It is also the number that would
  /// stay at zero if the wait were accidentally removed, which is why it is
  /// recorded rather than inferred.
  int get waitCount => _waitCount;
  int _waitCount = 0;

  /// Opens a device on [physical], reporting rather than throwing.
  /// [extensions] are device extensions to enable; one that the device does not
  /// report is refused here rather than at `vkCreateDevice`, so the diagnostic
  /// names the extension instead of returning
  /// `VK_ERROR_EXTENSION_NOT_PRESENT`.
  ///
  /// [presentQueueFamily] is the family a swapchain will present on. Null means
  /// the graphics family, which is the answer on every desktop driver; a caller
  /// that has a surface asks it for the family and passes it, and this method
  /// creates a second queue only when it differs.
  static VulkanDeviceAttempt open(
    VulkanPhysicalDevice physical, {
    int framesInFlight = kDefaultFramesInFlight,
    List<String> extensions = const <String>[],
    int? presentQueueFamily,
  }) {
    if (framesInFlight < 1) {
      throw ArgumentError.value(
          framesInFlight, 'framesInFlight', 'must be at least 1');
    }
    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];
    final int? family = physical.graphicsQueueFamily;
    if (family == null) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: '${physical.name} has no queue family with '
            'VK_QUEUE_GRAPHICS_BIT',
        detail:
            'families: ${physical.queueFamilyFlags.map((int f) => '0x${f.toRadixString(16)}').join(', ')}',
      ));
      return VulkanDeviceAttempt(null, diagnostics);
    }

    final int present = presentQueueFamily ?? family;
    if (present < 0 || present >= physical.queueFamilyFlags.length) {
      diagnostics.add(BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: '${physical.name} has no queue family $present to present on',
        detail: 'the device reports ${physical.queueFamilyFlags.length} '
            'families',
      ));
      return VulkanDeviceAttempt(null, diagnostics);
    }

    if (extensions.isNotEmpty) {
      final Set<String> available = physical.extensionNames().toSet();
      final List<String> missing = <String>[
        for (final String name in extensions)
          if (!available.contains(name)) name,
      ];
      if (missing.isNotEmpty) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.missingLibrary,
          message: '${physical.name} does not support '
              '${missing.join(', ')}',
          detail: 'asked for ${extensions.join(', ')}',
        ));
        return VulkanDeviceAttempt(null, diagnostics);
      }
    }

    final NativeArena arena = NativeArena();
    try {
      final Pointer<Float> priorities = arena<Float>();
      priorities.value = 1;

      // One queue create-info per *distinct* family. Naming the same family
      // twice is not a redundancy Vulkan tolerates - it is
      // `VK_ERROR_INITIALIZATION_FAILED`, or a validation error saying so.
      final bool unified = present == family;
      final int queueInfoCount = unified ? 1 : 2;
      final Pointer<VkDeviceQueueCreateInfo> queueInfo =
          arena<VkDeviceQueueCreateInfo>(queueInfoCount);
      queueInfo[0]
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
        ..queueFamilyIndex = family
        ..queueCount = 1
        ..pQueuePriorities = priorities;
      if (!unified) {
        queueInfo[1]
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
          ..queueFamilyIndex = present
          ..queueCount = 1
          ..pQueuePriorities = priorities;
      }

      final Pointer<VkDeviceCreateInfo> info = arena<VkDeviceCreateInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
        ..queueCreateInfoCount = queueInfoCount
        ..pQueueCreateInfos = queueInfo
        ..enabledExtensionCount = extensions.length
        ..ppEnabledExtensionNames = _stringArray(arena, extensions);
      // No features are enabled. Everything this renderer draws - one vertex
      // format, one blend mode family, sampled 2D images - is guaranteed by
      // core Vulkan 1.0 with every feature off, and enabling a feature the
      // device does not have is `VK_ERROR_FEATURE_NOT_PRESENT` at creation.
      // Extensions are a different matter and are checked against the device's
      // own list above, so a refusal names what was missing.

      final Pointer<Pointer<VkDevice_T>> out = arena<Pointer<VkDevice_T>>();
      final int result = physical.instance.api
          .createDevice(physical.handle, info, nullptr, out);
      if (vkFailed(result)) {
        diagnostics.add(BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'vkCreateDevice refused ${physical.name}',
          detail: vkResultName(result),
        ));
        return VulkanDeviceAttempt(null, diagnostics);
      }

      final Pointer<VkDevice_T> device = out.value;
      final VulkanDeviceApi api;
      try {
        api = VulkanDeviceApi.bind(physical.instance.api, device);
      } on VulkanSymbolError catch (error) {
        diagnostics.add(BackendDiagnostic.missingSymbol(error.symbol,
            detail: 'at device level on ${physical.name}'));
        return VulkanDeviceAttempt(null, diagnostics);
      }

      final Pointer<Pointer<VkQueue_T>> queueOut = arena<Pointer<VkQueue_T>>();
      api.getDeviceQueue(device, family, 0, queueOut);
      final Pointer<VkQueue_T> graphicsQueue = queueOut.value;
      Pointer<VkQueue_T> presentQueue = graphicsQueue;
      if (present != family) {
        api.getDeviceQueue(device, present, 0, queueOut);
        presentQueue = queueOut.value;
      }

      final List<_FrameSlot> slots = <_FrameSlot>[];
      for (var i = 0; i < framesInFlight; i++) {
        final _FrameSlot? slot = _FrameSlot.create(api, device, family, arena);
        if (slot == null) {
          for (final _FrameSlot made in slots) {
            made.dispose(api, device);
          }
          api.destroyDevice(device, nullptr);
          diagnostics.add(BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'could not build frame slot $i of $framesInFlight',
          ));
          return VulkanDeviceAttempt(null, diagnostics);
        }
        slots.add(slot);
      }

      diagnostics.add(BackendDiagnostic.note(
        'Vulkan device on ${physical.name}, queue family $family'
        '${present == family ? '' : ' (present on $present)'}, '
        '$framesInFlight frames in flight'
        '${extensions.isEmpty ? '' : ', extensions ${extensions.join(', ')}'}',
      ));

      return VulkanDeviceAttempt(
        VulkanDevice._(
          physicalDevice: physical,
          handle: device,
          api: api,
          queue: graphicsQueue,
          queueFamily: family,
          presentQueue: presentQueue,
          presentQueueFamily: present,
          enabledExtensions: List<String>.unmodifiable(extensions),
          swapchainApi: extensions.contains(vkKhrSwapchainExtension)
              ? VulkanSwapchainApi.bind(physical.instance.api, device)
              : null,
          allocator: VulkanMemoryAllocator(
            api,
            device,
            physicalDevice: physical.handle,
            instanceApi: physical.instance.api,
            nonCoherentAtomSize: physical.nonCoherentAtomSize,
          ),
          slots: slots,
        ),
        diagnostics,
      );
    } finally {
      arena.dispose();
    }
  }

  /// A `const char* const*` for [values], or null when there are none.
  ///
  /// The twin of the one in `vulkan_instance.dart`. Duplicated rather than
  /// shared because sharing it would mean exporting an arena-allocating helper
  /// from a file whose public surface is a device, and four lines is a cheaper
  /// coupling than that.
  static Pointer<Pointer<Char>> _stringArray(
      NativeArena arena, List<String> values) {
    if (values.isEmpty) return nullptr;
    final Pointer<Pointer<Char>> array = arena<Pointer<Char>>(values.length);
    for (var i = 0; i < values.length; i++) {
      array[i] = arena.allocateAscii(values[i]).cast<Char>();
    }
    return array;
  }

  /// Waits for this slot's previous frame, resets its pool, and opens its
  /// command buffer.
  ///
  /// Returns null when the wait failed, which on a healthy device does not
  /// happen and on a lost one is the first thing that does. Null and not an
  /// exception: a lost device is section 23.12's ordinary case, not a bug in
  /// the caller.
  Pointer<VkCommandBuffer_T>? beginFrame() {
    _throwIfDisposed();
    if (_recording) {
      throw StateError('beginFrame was called twice without an endFrame');
    }
    final _FrameSlot slot = _slots[frameIndex];

    if (slot.submitted) {
      // The whole point of this class. See the library comment.
      if (!waitForFence(slot.fence, kFrameTimeoutNanoseconds)) return null;
      _waitCount++;
      if (!_check(api.resetFences(handle, 1, slot.fencePointer))) return null;
      slot.submitted = false;
    }

    // Resetting the pool rather than the individual buffer: the pool owns the
    // memory, and resetting it is the cheap bulk operation. It is only legal
    // because the fence above proved the GPU is done with everything that came
    // out of it.
    if (!_check(api.resetCommandPool(handle, slot.pool, 0))) return null;

    return using((NativeArena arena) {
      final Pointer<VkCommandBufferBeginInfo> begin =
          arena<VkCommandBufferBeginInfo>();
      begin.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        ..flags = VkCommandBufferUsageFlagBits
            .VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (!_check(api.beginCommandBuffer(slot.commandBuffer, begin))) {
        return null;
      }
      _recording = true;
      return slot.commandBuffer;
    });
  }

  /// Ends the frame's command buffer and submits it, signalling this slot's
  /// fence.
  ///
  /// [waitSemaphores] and [signalSemaphores] are for a swapchain, which this
  /// backend does not have yet; they are parameters rather than a later
  /// signature change because the acquire/present pair is the one thing whose
  /// shape is already fixed by the specification.
  bool endFrame({
    List<Pointer<VkSemaphore_T>> waitSemaphores =
        const <Pointer<VkSemaphore_T>>[],
    List<int> waitStages = const <int>[],
    List<Pointer<VkSemaphore_T>> signalSemaphores =
        const <Pointer<VkSemaphore_T>>[],
  }) {
    _throwIfDisposed();
    if (!_recording) throw StateError('no frame is being recorded');
    final _FrameSlot slot = _slots[frameIndex];
    _recording = false;

    if (!_check(api.endCommandBuffer(slot.commandBuffer))) return false;
    if (!submit(
      commandBuffers: <Pointer<VkCommandBuffer_T>>[slot.commandBuffer],
      waitSemaphores: waitSemaphores,
      waitStages: waitStages,
      signalSemaphores: signalSemaphores,
      fence: slot.fence,
    )) {
      return false;
    }
    slot.submitted = true;
    _frame++;
    return true;
  }

  /// Abandons the frame being recorded without submitting it.
  ///
  /// The pool is left as it is; the next [beginFrame] on this slot resets it.
  /// The slot's fence is deliberately *not* marked submitted, so nothing waits
  /// for work that was never queued - a wait for a fence nobody will signal is
  /// a ten-second hang followed by a wrong diagnosis.
  void abandonFrame() {
    if (!_recording) return;
    _recording = false;
    api.endCommandBuffer(_slots[frameIndex].commandBuffer);
  }

  /// One submission. Public because the fence test drives it directly.
  bool submit({
    required List<Pointer<VkCommandBuffer_T>> commandBuffers,
    List<Pointer<VkSemaphore_T>> waitSemaphores =
        const <Pointer<VkSemaphore_T>>[],
    List<int> waitStages = const <int>[],
    List<Pointer<VkSemaphore_T>> signalSemaphores =
        const <Pointer<VkSemaphore_T>>[],
    // Nullable rather than defaulting to `nullptr`, which `dart:ffi` types as
    // `Pointer<Never>` and Dart therefore refuses as a constant default for a
    // `Pointer<VkFence_T>`. Null means "signal nothing", which is what a
    // submission whose completion nobody waits for wants.
    Pointer<VkFence_T>? fence,
  }) {
    _throwIfDisposed();
    if (waitSemaphores.length != waitStages.length) {
      throw ArgumentError('every wait semaphore needs a stage to wait at; got '
          '${waitSemaphores.length} semaphores and ${waitStages.length} '
          'stages');
    }
    return using((NativeArena arena) {
      final Pointer<VkSubmitInfo> info = arena<VkSubmitInfo>();
      info.ref
        ..sType = VkStructureType.VK_STRUCTURE_TYPE_SUBMIT_INFO
        ..commandBufferCount = commandBuffers.length
        ..waitSemaphoreCount = waitSemaphores.length
        ..signalSemaphoreCount = signalSemaphores.length;

      if (commandBuffers.isNotEmpty) {
        final Pointer<Pointer<VkCommandBuffer_T>> list =
            arena<Pointer<VkCommandBuffer_T>>(commandBuffers.length);
        for (var i = 0; i < commandBuffers.length; i++) {
          list[i] = commandBuffers[i];
        }
        info.ref.pCommandBuffers = list;
      }
      if (waitSemaphores.isNotEmpty) {
        final Pointer<Pointer<VkSemaphore_T>> list =
            arena<Pointer<VkSemaphore_T>>(waitSemaphores.length);
        final Pointer<Uint32> stages = arena<Uint32>(waitStages.length);
        for (var i = 0; i < waitSemaphores.length; i++) {
          list[i] = waitSemaphores[i];
          stages[i] = waitStages[i];
        }
        info.ref
          ..pWaitSemaphores = list
          ..pWaitDstStageMask = stages;
      }
      if (signalSemaphores.isNotEmpty) {
        final Pointer<Pointer<VkSemaphore_T>> list =
            arena<Pointer<VkSemaphore_T>>(signalSemaphores.length);
        for (var i = 0; i < signalSemaphores.length; i++) {
          list[i] = signalSemaphores[i];
        }
        info.ref.pSignalSemaphores = list;
      }
      return _check(api.queueSubmit(queue, 1, info, fence ?? nullptr));
    });
  }

  /// Records [record] into a fresh command buffer, submits it and waits.
  ///
  /// For the things that happen outside the frame loop: uploading an atlas the
  /// first time, transitioning an image, copying a rendered image back. It is
  /// deliberately synchronous - it costs a full pipeline drain - and it is
  /// deliberately not used per frame.
  bool oneShot(void Function(Pointer<VkCommandBuffer_T> commands) record) {
    _throwIfDisposed();
    return using((NativeArena arena) {
      final _FrameSlot? slot =
          _FrameSlot.create(api, handle, queueFamily, arena);
      if (slot == null) return false;
      try {
        final Pointer<VkCommandBufferBeginInfo> begin =
            arena<VkCommandBufferBeginInfo>();
        begin.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
          ..flags = VkCommandBufferUsageFlagBits
              .VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (!_check(api.beginCommandBuffer(slot.commandBuffer, begin))) {
          return false;
        }
        record(slot.commandBuffer);
        if (!_check(api.endCommandBuffer(slot.commandBuffer))) return false;
        if (!submit(
          commandBuffers: <Pointer<VkCommandBuffer_T>>[slot.commandBuffer],
          fence: slot.fence,
        )) {
          return false;
        }
        return waitForFence(slot.fence, kFrameTimeoutNanoseconds);
      } finally {
        slot.dispose(api, handle);
      }
    });
  }

  /// Waits for every submission on the queue to finish.
  bool waitIdle() {
    _throwIfDisposed();
    if (!_check(api.deviceWaitIdle(handle))) return false;
    for (final _FrameSlot slot in _slots) {
      slot.submitted = false;
      api.resetFences(handle, 1, slot.fencePointer);
    }
    return true;
  }

  // -- synchronisation primitives -------------------------------------------

  Pointer<VkFence_T> createFence({bool signaled = false}) =>
      using((NativeArena arena) {
        final Pointer<VkFenceCreateInfo> info = arena<VkFenceCreateInfo>();
        info.ref
          ..sType = VkStructureType.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
          ..flags =
              signaled ? VkFenceCreateFlagBits.VK_FENCE_CREATE_SIGNALED_BIT : 0;
        final Pointer<Pointer<VkFence_T>> out = arena<Pointer<VkFence_T>>();
        if (vkFailed(api.createFence(handle, info, nullptr, out))) {
          return nullptr;
        }
        return out.value;
      });

  void destroyFence(Pointer<VkFence_T> fence) {
    if (fence != nullptr) api.destroyFence(handle, fence, nullptr);
  }

  Pointer<VkSemaphore_T> createSemaphore() => using((NativeArena arena) {
        final Pointer<VkSemaphoreCreateInfo> info =
            arena<VkSemaphoreCreateInfo>();
        info.ref.sType =
            VkStructureType.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        final Pointer<Pointer<VkSemaphore_T>> out =
            arena<Pointer<VkSemaphore_T>>();
        if (vkFailed(api.createSemaphore(handle, info, nullptr, out))) {
          return nullptr;
        }
        return out.value;
      });

  void destroySemaphore(Pointer<VkSemaphore_T> semaphore) {
    if (semaphore != nullptr) api.destroySemaphore(handle, semaphore, nullptr);
  }

  /// An unsignalled `VkEvent`.
  ///
  /// The one Vulkan primitive the **host** can signal while the device is
  /// already waiting on it, which makes it the exact counterpart of Direct3D
  /// 12's `ID3D12CommandQueue::Wait` on a fence the CPU signals later. See
  /// `vulkan_fence_test.dart`, which is the only caller.
  Pointer<VkEvent_T> createEvent() => using((NativeArena arena) {
        final Pointer<VkEventCreateInfo> info = arena<VkEventCreateInfo>();
        info.ref.sType = VkStructureType.VK_STRUCTURE_TYPE_EVENT_CREATE_INFO;
        final Pointer<Pointer<VkEvent_T>> out = arena<Pointer<VkEvent_T>>();
        if (vkFailed(api.createEvent(handle, info, nullptr, out))) {
          return nullptr;
        }
        return out.value;
      });

  void destroyEvent(Pointer<VkEvent_T> event) {
    if (event != nullptr) api.destroyEvent(handle, event, nullptr);
  }

  bool setEvent(Pointer<VkEvent_T> event) =>
      _check(api.setEvent(handle, event));

  /// Whether [fence] became signalled within [timeoutNanoseconds].
  ///
  /// False for `VK_TIMEOUT` and false for a failure, and the two are told
  /// apart by [isLost] - a timeout leaves the device healthy. Bounded rather
  /// than infinite because an unbounded wait on a fence nothing will signal is
  /// a hung process with no diagnostic, which is the worst outcome available.
  bool waitForFence(Pointer<VkFence_T> fence, int timeoutNanoseconds) =>
      using((NativeArena arena) {
        final Pointer<Pointer<VkFence_T>> list = arena<Pointer<VkFence_T>>();
        list.value = fence;
        final int result =
            api.waitForFences(handle, 1, list, vkTrue, timeoutNanoseconds);
        if (result == VkResult.VK_TIMEOUT) return false;
        return _check(result);
      });

  /// The fence the submission from slot [index] signals.
  ///
  /// For `vulkan_fence_test.dart`, which has to wait on *that* submission's
  /// fence and no other. Waiting on a fence from a separate empty submission
  /// would look equivalent and is not: Vulkan starts batches in order but does
  /// not promise they *complete* in order, so an empty batch behind a stalled
  /// one is permitted to signal first, and the test would be asserting
  /// something the specification does not guarantee.
  ///
  /// Not part of the renderer's own vocabulary - nothing outside a test has
  /// any business reaching into a slot - which is why it is named for the
  /// debugger rather than exposed as `fenceAt`.
  Pointer<VkFence_T> debugFenceOfSlot(int index) => _slots[index].fence;

  /// Whether [fence] is signalled right now, without waiting at all.
  bool isFenceSignalled(Pointer<VkFence_T> fence) =>
      api.getFenceStatus(handle, fence) == VkResult.VK_SUCCESS;

  void resetFence(Pointer<VkFence_T> fence) => using((NativeArena arena) {
        final Pointer<Pointer<VkFence_T>> list = arena<Pointer<VkFence_T>>();
        list.value = fence;
        api.resetFences(handle, 1, list);
      });

  /// Records a wait on a host-signalled [event] into [commands].
  ///
  /// `srcStageMask` is `HOST_BIT`, which the specification *requires* when the
  /// event is set by `vkSetEvent` rather than by `vkCmdSetEvent`; getting it
  /// wrong is a validation error rather than a wrong picture.
  void recordWaitEvent(
    Pointer<VkCommandBuffer_T> commands,
    Pointer<VkEvent_T> event, {
    int dstStage = VkPipelineStageFlagBits.VK_PIPELINE_STAGE_TRANSFER_BIT,
  }) {
    using((NativeArena arena) {
      final Pointer<Pointer<VkEvent_T>> list = arena<Pointer<VkEvent_T>>();
      list.value = event;
      api.cmdWaitEvents(
        commands,
        1,
        list,
        VkPipelineStageFlagBits.VK_PIPELINE_STAGE_HOST_BIT,
        dstStage,
        0,
        nullptr,
        0,
        nullptr,
        0,
        nullptr,
      );
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Idle first: destroying a command pool whose buffers are still executing
    // is exactly the corruption this class exists to prevent, and teardown is
    // where it is easiest to forget.
    if (!_lost) api.deviceWaitIdle(handle);
    allocator.dispose();
    for (final _FrameSlot slot in _slots) {
      slot.dispose(api, handle);
    }
    _slots.clear();
    api.destroyDevice(handle, nullptr);
  }

  /// True when [result] succeeded. Records device loss on the way past.
  bool _check(int result) {
    if (result == VkResult.VK_ERROR_DEVICE_LOST) _lost = true;
    return !vkFailed(result);
  }

  void _throwIfDisposed() {
    if (_disposed) throw StateError('this VulkanDevice is disposed');
  }

  @override
  String toString() => 'VulkanDevice(${physicalDevice.name}, family '
      '$queueFamily, ${_slots.length} frames, $_frame submitted)';
}

/// One frame in flight: a pool, the buffer recorded into it, and the fence
/// that says the GPU is done with both.
final class _FrameSlot {
  _FrameSlot(this.pool, this.commandBuffer, this.fence, this.fencePointer);

  final Pointer<VkCommandPool_T> pool;
  final Pointer<VkCommandBuffer_T> commandBuffer;
  final Pointer<VkFence_T> fence;

  /// A one-element array holding [fence], allocated once.
  ///
  /// `vkWaitForFences` and `vkResetFences` both take a pointer to an array,
  /// and building that array inside an arena on every frame would allocate and
  /// free eight bytes sixty times a second for no reason.
  final Pointer<Pointer<VkFence_T>> fencePointer;

  /// Whether work has been submitted with this slot's fence and not yet waited
  /// for. False for a slot that has never run, which is what stops the first
  /// two frames waiting on a fence nobody signalled.
  bool submitted = false;

  static _FrameSlot? create(
    VulkanDeviceApi api,
    Pointer<VkDevice_T> device,
    int queueFamily,
    NativeArena arena,
  ) {
    final Pointer<VkCommandPoolCreateInfo> poolInfo =
        arena<VkCommandPoolCreateInfo>();
    poolInfo.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
      // TRANSIENT says every buffer from this pool is short lived, which is
      // true - it is reset every frame - and lets a driver use a cheaper
      // allocation strategy. RESET_COMMAND_BUFFER is deliberately *not* set:
      // it would let a single buffer be reset on its own, which this design
      // never does, and it costs the driver the ability to pool the memory.
      ..flags = VkCommandPoolCreateFlagBits.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT
      ..queueFamilyIndex = queueFamily;
    final Pointer<Pointer<VkCommandPool_T>> poolOut =
        arena<Pointer<VkCommandPool_T>>();
    if (vkFailed(api.createCommandPool(device, poolInfo, nullptr, poolOut))) {
      return null;
    }

    final Pointer<VkCommandBufferAllocateInfo> bufferInfo =
        arena<VkCommandBufferAllocateInfo>();
    bufferInfo.ref
      ..sType = VkStructureType.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
      ..commandPool = poolOut.value
      ..level = VkCommandBufferLevel.VK_COMMAND_BUFFER_LEVEL_PRIMARY
      ..commandBufferCount = 1;
    final Pointer<Pointer<VkCommandBuffer_T>> bufferOut =
        arena<Pointer<VkCommandBuffer_T>>();
    if (vkFailed(api.allocateCommandBuffers(device, bufferInfo, bufferOut))) {
      api.destroyCommandPool(device, poolOut.value, nullptr);
      return null;
    }

    final Pointer<VkFenceCreateInfo> fenceInfo = arena<VkFenceCreateInfo>();
    fenceInfo.ref.sType = VkStructureType.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    final Pointer<Pointer<VkFence_T>> fenceOut = arena<Pointer<VkFence_T>>();
    if (vkFailed(api.createFence(device, fenceInfo, nullptr, fenceOut))) {
      api.destroyCommandPool(device, poolOut.value, nullptr);
      return null;
    }

    // Outside the arena: this one outlives the call.
    final Pointer<Pointer<VkFence_T>> held = NativeAllocator.instance
        .allocate<Pointer<VkFence_T>>(sizeOf<Pointer<VkFence_T>>());
    held.value = fenceOut.value;
    return _FrameSlot(poolOut.value, bufferOut.value, fenceOut.value, held);
  }

  void dispose(VulkanDeviceApi api, Pointer<VkDevice_T> device) {
    api
      ..destroyFence(device, fence, nullptr)
      // The pool's destruction frees its command buffers; freeing them first
      // would be legal and redundant.
      ..destroyCommandPool(device, pool, nullptr);
    NativeAllocator.instance.free(fencePointer);
  }
}
