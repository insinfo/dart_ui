/// Frames in flight, and the fence that makes reusing their memory legal.
///
/// ## The rule this file exists to enforce
///
/// A `ID3D12CommandAllocator` owns the memory every command list recorded into
/// it. `Reset` frees all of it. It is legal **only once the GPU has finished
/// executing every list that was recorded there** - and nothing checks. The
/// runtime does not, the debug layer catches only some cases, and the symptom
/// of getting it wrong is not a crash: it is a frame that draws the previous
/// frame's geometry, or half of it, or nothing, intermittently, on one machine.
///
/// That is the single largest difference between Direct3D 11 and Direct3D 12
/// for a renderer being ported between them. Direct3D 11's device context hides
/// this behind an implicit rename; Direct3D 12 hands it to the caller. So this
/// file owns it, and it is the only place in the backend that calls
/// [D3d12CommandAllocator.reset].
///
/// ## How the wait is done, and how it is proved
///
/// One `ID3D12Fence` and a monotonically increasing counter. After a frame's
/// lists are executed, the queue is asked to signal the counter's next value -
/// `ID3D12CommandQueue::Signal` queues the write *behind* the work rather than
/// performing it, which is the entire reason the scheme is correct. The value
/// is remembered on the slot that was used. When that slot comes round again,
/// the CPU waits until the fence has reached it.
///
/// Proving that the wait waits is a real problem, because on a fast machine
/// with a trivial scene the GPU is usually already finished and the wait
/// returns without blocking - so a test that only counts frames proves nothing.
/// Two things are exposed instead:
///
///   * [debugResets] records, for every allocator reset, the value the slot
///     required and the fence's completed value at the moment of the reset.
///     `completed >= required` on every entry *is* the invariant, checked where
///     it actually matters rather than inferred.
///   * [debugWaitOn] waits on a caller-supplied fence with a timeout. A fence
///     nobody signals never completes, so a wait that returns false after 50 ms
///     and true after `Signal` is direct evidence that the primitive blocks.
///
/// Both are used by `test/backends/win32/d3d12/d3d12_fence_test.dart`.
///
/// ## The upload arena is part of the same lifetime
///
/// Vertex data and texture staging live in upload-heap buffers that the GPU
/// reads while the frame executes. Recycling one has exactly the same
/// precondition as resetting an allocator, so it is done in the same place, at
/// the same moment, behind the same wait. Keeping the two lifetimes together is
/// deliberate: a separate upload pool with its own fence logic would be a
/// second place to get this wrong.
library;

import 'dart:ffi';

import 'd3d12_arena.dart';
import 'd3d12_com.dart';
import 'd3d12_interfaces.dart';
import 'd3d12_library.dart';
import 'd3d12_structs.dart';

/// One recorded allocator reset, for the fence proof.
final class D3d12AllocatorReset {
  const D3d12AllocatorReset({
    required this.slot,
    required this.requiredValue,
    required this.completedValue,
    required this.blocked,
  });

  /// Which slot of the ring was reset.
  final int slot;

  /// The fence value the GPU had to reach before this reset was legal. Zero
  /// for a slot that has never been submitted, which is the first `frameCount`
  /// frames of the process.
  final int requiredValue;

  /// What `ID3D12Fence::GetCompletedValue` answered at the moment of the
  /// reset. **This must be >= [requiredValue].** That comparison is the
  /// invariant the whole file exists for.
  final int completedValue;

  /// Whether the CPU actually had to block. False means the GPU had already
  /// finished, which is the common case for a small scene and is exactly why a
  /// test that only counts blocks would be vacuous.
  final bool blocked;

  bool get isLegal => completedValue >= requiredValue;

  @override
  String toString() => 'D3d12AllocatorReset(slot $slot, required '
      '$requiredValue, completed $completedValue, '
      '${blocked ? 'blocked' : 'no wait'})';
}

/// A reserved run of upload-heap memory.
final class D3d12UploadRange {
  const D3d12UploadRange(this.cpu, this.gpuAddress, this.resource, this.offset);

  /// Where the CPU writes. The buffer is persistently mapped, so this is a
  /// plain pointer and there is no map/unmap pair per frame - which for a
  /// write-combined upload heap is the documented pattern and not a shortcut.
  final Pointer<Uint8> cpu;

  /// The virtual address the GPU sees, for a vertex or index buffer view.
  final int gpuAddress;

  /// The buffer this run belongs to, for a `CopyTextureRegion` source.
  final Pointer<Void> resource;

  /// Byte offset of this run inside [resource], for the same reason.
  final int offset;
}

/// One upload-heap buffer, persistently mapped.
final class _UploadBlock {
  _UploadBlock(this.resource, this.cpu, this.gpuAddress, this.capacity);

  final Pointer<Void> resource;
  final Pointer<Uint8> cpu;
  final int gpuAddress;
  final int capacity;
  int cursor = 0;
}

/// The per-frame state: an allocator, the fence value that releases it, and
/// the upload memory that frame's lists read from.
final class _FrameSlot {
  _FrameSlot(this.allocator);

  final D3d12CommandAllocator allocator;

  /// The fence value the GPU must reach before this slot may be reused. Zero
  /// until the slot has been submitted once.
  int fenceValue = 0;

  final List<_UploadBlock> upload = <_UploadBlock>[];

  void rewindUpload() {
    for (final _UploadBlock block in upload) {
      block.cursor = 0;
    }
  }
}

/// What [D3d12FrameRing.create] found.
final class D3d12FrameRingAttempt {
  const D3d12FrameRingAttempt(this.ring, this.diagnostic);

  final D3d12FrameRing? ring;

  /// Null on success; otherwise names the call that refused.
  final String? diagnostic;
}

/// The ring of command allocators, the command list, and the fence.
final class D3d12FrameRing {
  D3d12FrameRing._({
    required D3d12Library library,
    required D3d12Device device,
    required D3d12CommandQueue queue,
    required List<_FrameSlot> slots,
    required D3d12GraphicsCommandList list,
    required D3d12Fence fence,
    required int event,
  })  : _library = library,
        _device = device,
        _queue = queue,
        _slots = slots,
        _list = list,
        _fence = fence,
        _event = event;

  /// Frames the CPU may run ahead of the GPU.
  ///
  /// Two. Not one, which would serialise the CPU behind every frame and make
  /// the renderer's throughput the sum of both sides rather than the maximum.
  /// Not three, which buys latency tolerance a UI that renders on demand does
  /// not need and costs a whole frame's worth of upload memory. It is a
  /// constructor argument so a caller with a different answer can say so, and
  /// this is the default the tests use.
  static const int kDefaultFrameCount = 2;

  /// Bytes an upload block is created with when a frame first needs one.
  ///
  /// A quarter of a megabyte holds roughly 5400 quads of the 48-byte vertex
  /// layout, which is more than any UI frame this renderer has produced.
  /// Blocks are never freed until the device is - they are rewound - so this
  /// is the steady-state footprint of a frame that fits, and a frame that does
  /// not simply gets a second block.
  static const int kUploadBlockBytes = 256 * 1024;

  final D3d12Library _library;
  final D3d12Device _device;
  final D3d12CommandQueue _queue;
  final List<_FrameSlot> _slots;
  final D3d12GraphicsCommandList _list;
  final D3d12Fence _fence;
  final int _event;

  /// Scratch for `ExecuteCommandLists`, allocated once. A frame must not touch
  /// the heap.
  late final Pointer<Pointer<Void>> _listSlot =
      _library.allocator.allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());

  /// Scratch for the zero-length read range every upload-heap `Map` takes.
  late final Pointer<D3d12Range> _noRead =
      _library.allocator.allocate<D3d12Range>(sizeOf<D3d12Range>());

  int _frame = 0;
  int _signalled = 0;
  bool _recording = false;
  bool _disposed = false;
  int _waitCount = 0;

  final List<D3d12AllocatorReset> _resets = <D3d12AllocatorReset>[];

  /// How many allocator resets are remembered.
  ///
  /// Bounded, because this list grows once per frame and a window left open
  /// overnight would otherwise accumulate millions of records for a diagnostic
  /// nobody is reading. The oldest are dropped: the interesting entries are
  /// always the most recent ones, and a test that renders a handful of frames
  /// never reaches the limit.
  static const int kMaxRecordedResets = 256;

  /// Creates the ring, or names the call that refused.
  static D3d12FrameRingAttempt create({
    required D3d12Library library,
    required D3d12Device device,
    required D3d12CommandQueue queue,
    int frameCount = kDefaultFrameCount,
  }) {
    if (frameCount < 1) {
      throw ArgumentError.value(frameCount, 'frameCount', 'must be positive');
    }
    return D3d12Arena.using(library.allocator, (D3d12Arena arena) {
      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);

      final List<_FrameSlot> slots = <_FrameSlot>[];
      void unwind() {
        for (final _FrameSlot slot in slots) {
          slot.allocator.release();
        }
      }

      writeGuid(iid, D3d12Iids.commandAllocator);
      for (var i = 0; i < frameCount; i++) {
        final int hr = device.createCommandAllocator(
            device.pointer, d3d12CommandListTypeDirect, iid, out);
        if (comFailed(hr)) {
          unwind();
          return D3d12FrameRingAttempt(
            null,
            'CreateCommandAllocator($i) failed with ${hresultText(hr)}',
          );
        }
        slots.add(_FrameSlot(D3d12CommandAllocator(out.value)));
      }

      writeGuid(iid, D3d12Iids.graphicsCommandList);
      final int listHr = device.createCommandList(
        device.pointer,
        0,
        d3d12CommandListTypeDirect,
        slots.first.allocator.pointer,
        nullptr,
        iid,
        out,
      );
      if (comFailed(listHr)) {
        unwind();
        return D3d12FrameRingAttempt(
          null,
          'CreateCommandList failed with ${hresultText(listHr)}',
        );
      }
      final D3d12GraphicsCommandList list = D3d12GraphicsCommandList(out.value);
      // A freshly created list is already recording. Closing it here means
      // every later use is the same `Reset` / record / `Close` cycle, with no
      // first-frame special case to forget.
      list.close(list.pointer);

      writeGuid(iid, D3d12Iids.fence);
      final int fenceHr = device.createFence(device.pointer, 0, 0, iid, out);
      if (comFailed(fenceHr)) {
        list.release();
        unwind();
        return D3d12FrameRingAttempt(
          null,
          'CreateFence failed with ${hresultText(fenceHr)}',
        );
      }
      final D3d12Fence fence = D3d12Fence(out.value);

      final int event = library.createEventW(nullptr, 0, 0, nullptr);
      if (event == 0) {
        fence.release();
        list.release();
        unwind();
        return const D3d12FrameRingAttempt(
          null,
          'CreateEventW returned a null handle; a fence cannot be waited on '
          'without one',
        );
      }

      return D3d12FrameRingAttempt(
        D3d12FrameRing._(
          library: library,
          device: device,
          queue: queue,
          slots: slots,
          list: list,
          fence: fence,
          event: event,
        ),
        null,
      );
    });
  }

  int get frameCount => _slots.length;

  /// Which slot the frame in progress - or the next one - will use.
  int get frameIndex => _frame % _slots.length;

  /// The highest value the queue has been asked to signal. The GPU may not
  /// have reached it yet; that is what [D3d12Fence.completedValue] answers.
  int get signalledValue => _signalled;

  int get completedValue => _fence.completedValue;

  /// The fence the frames are ordered against.
  ///
  /// Exposed so a test can wait on it with a timeout through [debugWaitOn] and
  /// observe that the wait does not return while work is still queued. Nothing
  /// outside a test should signal it: the whole scheme depends on the *queue*
  /// setting the value behind the work rather than the CPU setting it early.
  D3d12Fence get fence => _fence;

  /// How many times the CPU actually blocked waiting for the GPU.
  int get waitCount => _waitCount;

  /// Every allocator reset this ring has performed. See the library comment:
  /// `completed >= required` on all of them is the invariant.
  List<D3d12AllocatorReset> get debugResets =>
      List<D3d12AllocatorReset>.unmodifiable(_resets);

  bool get isRecording => _recording;

  /// The open command list. Only valid between [begin] and [end].
  D3d12GraphicsCommandList get list => _list;

  /// Waits for the slot the next frame will use, resets its allocator and
  /// opens the command list.
  ///
  /// Returns null - and records nothing - when the wait or a reset failed,
  /// which is what a removed device looks like from here.
  D3d12GraphicsCommandList? begin({Pointer<Void>? initialPipelineState}) {
    if (_disposed || _recording) return null;
    final _FrameSlot slot = _slots[frameIndex];

    final int required = slot.fenceValue;
    final int before = _fence.completedValue;
    final bool blocked = before < required;
    if (blocked && !_waitForValue(required)) return null;
    if (_resets.length >= kMaxRecordedResets) _resets.removeAt(0);
    _resets.add(D3d12AllocatorReset(
      slot: frameIndex,
      requiredValue: required,
      // Re-read after the wait rather than reusing `before`: the number that
      // proves the reset legal is the one true at the moment of the reset.
      completedValue: _fence.completedValue,
      blocked: blocked,
    ));

    if (comFailed(slot.allocator.reset())) return null;
    slot.rewindUpload();
    final int hr = _list.reset(
      _list.pointer,
      slot.allocator.pointer,
      initialPipelineState ?? nullptr,
    );
    if (comFailed(hr)) return null;
    _recording = true;
    return _list;
  }

  /// Closes the list, executes it and queues the fence signal.
  ///
  /// [waitForCompletion] blocks until the GPU has finished it, which only a
  /// readback needs - a presenting frame must never do this, because it turns
  /// the whole point of a frame ring back into a serialised pipeline.
  ///
  /// Returns false when a call refused; the caller turns that into device loss.
  bool end({bool waitForCompletion = false}) {
    if (!_recording) return false;
    _recording = false;
    if (comFailed(_list.close(_list.pointer))) return false;

    _listSlot.value = _list.pointer;
    _queue.executeCommandLists(1, _listSlot);

    _signalled++;
    if (comFailed(_queue.signal(_fence.pointer, _signalled))) return false;
    _slots[frameIndex].fenceValue = _signalled;
    _frame++;
    if (!waitForCompletion) return true;
    return _waitForValue(_signalled);
  }

  /// Abandons an open recording without executing it.
  ///
  /// For the error path only: a target that could not build its scene must not
  /// leave the list open, or the next [begin] resets an allocator whose list
  /// is still recording and the runtime refuses.
  void abandon() {
    if (!_recording) return;
    _recording = false;
    _list.close(_list.pointer);
  }

  /// Blocks until the GPU has finished everything submitted so far.
  ///
  /// The precondition of `ResizeBuffers`, of releasing a render target, and of
  /// disposing the device. Returns false when the wait failed.
  bool waitIdle() {
    if (_disposed) return true;
    _signalled++;
    if (comFailed(_queue.signal(_fence.pointer, _signalled))) return false;
    return _waitForValue(_signalled);
  }

  /// Reserves [bytes] of upload memory for the frame in progress.
  ///
  /// [alignment] must be a power of two. Callers pass 256 for a texture row
  /// pitch, 512 for a placed subresource footprint and 4 for vertex data; the
  /// numbers are the API's own constants, see `d3d12_structs.dart`.
  ///
  /// The memory stays valid until this slot is reused, which is the same
  /// lifetime as the command list that reads it - see the library comment.
  D3d12UploadRange? reserveUpload(int bytes, {int alignment = 256}) {
    if (bytes <= 0) return null;
    final _FrameSlot slot = _slots[frameIndex];
    for (final _UploadBlock block in slot.upload) {
      final int start = alignUp(block.cursor, alignment);
      if (start + bytes <= block.capacity) {
        block.cursor = start + bytes;
        return D3d12UploadRange(
          Pointer<Uint8>.fromAddress(block.cpu.address + start),
          block.gpuAddress + start,
          block.resource,
          start,
        );
      }
    }

    final int capacity = bytes + alignment > kUploadBlockBytes
        ? alignUp(bytes + alignment, 65536)
        : kUploadBlockBytes;
    final _UploadBlock? block = _createUploadBlock(capacity);
    if (block == null) return null;
    slot.upload.add(block);
    final int start = alignUp(0, alignment);
    block.cursor = start + bytes;
    return D3d12UploadRange(
      Pointer<Uint8>.fromAddress(block.cpu.address + start),
      block.gpuAddress + start,
      block.resource,
      start,
    );
  }

  _UploadBlock? _createUploadBlock(int capacity) {
    return D3d12Arena.using(_library.allocator, (D3d12Arena arena) {
      final Pointer<D3d12HeapProperties> heap =
          arena<D3d12HeapProperties>(sizeOf<D3d12HeapProperties>());
      heap.ref
        ..type = d3d12HeapTypeUpload
        ..cpuPageProperty = 0
        ..memoryPoolPreference = 0
        ..creationNodeMask = 1
        ..visibleNodeMask = 1;
      final Pointer<D3d12ResourceDesc> desc =
          arena<D3d12ResourceDesc>(sizeOf<D3d12ResourceDesc>());
      desc.ref
        ..dimension = d3d12ResourceDimensionBuffer
        ..alignment = 0
        ..width = capacity
        ..height = 1
        ..depthOrArraySize = 1
        ..mipLevels = 1
        ..format = dxgiFormatUnknown
        ..layout = d3d12TextureLayoutRowMajor
        ..flags = d3d12ResourceFlagNone;
      desc.ref.sampleDesc
        ..count = 1
        ..quality = 0;

      final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>())
        ..let(D3d12Iids.resource);
      final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
      final int hr = _device.createCommittedResource(
        _device.pointer,
        heap,
        0,
        desc,
        d3d12ResourceStateGenericRead,
        nullptr,
        iid,
        out,
      );
      if (comFailed(hr)) return null;

      final D3d12Resource resource = D3d12Resource(out.value);
      final Pointer<Pointer<Void>> mapped = arena.allocatePointers(1);
      // A zero-length read range says the CPU will not read this memory, which
      // on a discrete adapter is what lets the driver leave it write-combined.
      _noRead.ref
        ..begin = 0
        ..end = 0;
      if (comFailed(resource.map(_noRead, mapped))) {
        resource.release();
        return null;
      }
      return _UploadBlock(
        resource.pointer,
        mapped.value.cast<Uint8>(),
        resource.gpuVirtualAddress,
        capacity,
      );
    });
  }

  /// Waits on [fence] for [value] with a timeout, using an event of its own.
  ///
  /// **For tests.** A fence nobody signals never completes, so this returning
  /// false after a bounded wait - and true once `Signal` has run - is the
  /// direct evidence that the frame path's wait actually blocks. See the
  /// library comment.
  ///
  /// Its own event rather than the ring's, because a timed-out wait leaves the
  /// shared event armed: the fence would set it later, and the next frame's
  /// wait would return immediately on a signal that was not its own. That is
  /// precisely the silent corruption this file exists to prevent, so the debug
  /// helper does not get to introduce it.
  bool debugWaitOn(D3d12Fence fence, int value, int timeoutMilliseconds) {
    if (fence.completedValue >= value) return true;
    final int event = _library.createEventW(nullptr, 0, 0, nullptr);
    if (event == 0) return false;
    try {
      if (comFailed(fence.setEventOnCompletion(value, event))) return false;
      return _library.waitForSingleObject(event, timeoutMilliseconds) ==
          kWaitObject0;
    } finally {
      _library.closeHandle(event);
    }
  }

  bool _waitForValue(int value) {
    if (_fence.completedValue >= value) return true;
    _waitCount++;
    if (comFailed(_fence.setEventOnCompletion(value, _event))) return false;
    return _library.waitForSingleObject(_event, kWaitInfinite) == kWaitObject0;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final _FrameSlot slot in _slots) {
      for (final _UploadBlock block in slot.upload) {
        ComObject(block.resource).release();
      }
      slot.allocator.release();
    }
    _list.release();
    _fence.release();
    _library
      ..closeHandle(_event)
      ..allocator.free(_listSlot);
    _library.allocator.free(_noRead);
  }
}

/// Writes the interface identifier [text] into this pointer and returns it.
///
/// A tiny extension rather than two statements because the alternative reads
/// as a bug: `arena<Guid>(sizeOf<Guid>())` followed by a bare `writeGuid` on the next line
/// invites a later edit that moves one and not the other, and an unwritten
/// `Guid` is sixteen zero bytes - which is a valid-looking IID that no object
/// implements, so the failure is `E_NOINTERFACE` from a call that names the
/// right interface.
extension _GuidTarget on Pointer<Guid> {
  void let(String text) => writeGuid(this, text);
}
