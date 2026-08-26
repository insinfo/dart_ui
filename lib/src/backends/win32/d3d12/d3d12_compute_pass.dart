/// A reusable Direct3D 12 compute pass: root descriptors, a kernel chain, and
/// one readback.
///
/// The compute-tile driver next to this one issues a single dispatch, so it
/// keeps its plumbing inline. The stages of a Vello-style rasterizer do not:
/// each of them is a *chain* of kernels over a shared set of buffers, with a
/// barrier between every link and a readback at the end, and the second one
/// written made it obvious that the chain, the barriers, the zero-fill, the
/// grow-and-reuse of the default-heap buffers and the sectioned readback are
/// the same code every time. Only the register layout and the kernel list
/// differ.
///
/// So they live here once. What a stage supplies is a shader source, the names
/// of its entry points, how many read-only and read-write buffers its root
/// signature declares, and - per run - the uploads, the buffer sizes, the
/// dispatch sizes and which buffers to read back.
///
/// ## The barrier, and why it is a UAV barrier
///
/// `D3d12RenderDevice.transitionResource` is the only barrier this backend had
/// issued before this file, and a transition is the wrong tool between two
/// dispatches: the buffers stay in `UNORDERED_ACCESS` throughout, and a
/// transition whose before and after states are equal is an error rather than a
/// barrier. What orders two dispatches that touch the same UAV is
/// `D3D12_RESOURCE_BARRIER_TYPE_UAV`, and the null-resource form of it - which
/// orders every unordered access rather than one resource - is what this
/// records, because a chain's links generally cross more than one buffer and
/// naming them individually is one chance per link to forget one.
///
/// ## One command list, one wait
///
/// A run ends in a readback the CPU maps, so it closes its own list and waits
/// on the fence. Mapping before the copy has run returns whatever was in the
/// buffer before, which reads as a one-frame lag rather than as a missing wait.
/// That is why these passes are diagnostics and parity oracles rather than
/// frame paths: the shape that keeps its results on the device is a different
/// entry point, and it belongs next to this one rather than instead of it.
///
/// ## Every stage buffer is zeroed first
///
/// A default-heap resource's initial contents are undefined, and a kernel that
/// skips an element would otherwise leave the *previous* run's correct-looking
/// value there. Zeroing turns that into a zero, which an oracle comparison
/// catches.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import 'd3d12_arena.dart';
import 'd3d12_com.dart';
import 'd3d12_device.dart';
import 'd3d12_frame_ring.dart';
import 'd3d12_interfaces.dart';
import 'd3d12_library.dart';
import 'd3d12_structs.dart';

/// `D3D12_RESOURCE_BARRIER_TYPE_UAV`.
///
/// Declared here rather than in `d3d12_structs.dart` because this file is the
/// only caller; the transition arm and the UAV arm of `D3D12_RESOURCE_BARRIER`
/// start with the same `Type`/`Flags`/`pResource` triple, so the existing
/// struct writes the right bytes.
const int _kResourceBarrierTypeUav = 1;

/// The smallest upload allocation made for a scene buffer.
///
/// A root SRV must name a real buffer even when the shader never indexes it,
/// and `reserveUpload` refuses a zero-byte request.
const int _kMinimumUploadBytes = 256;

/// Alignment between the sections of the shared readback buffer.
const int _kReadbackAlignment = 256;

/// `D3DCOMPILE_IEEE_STRICTNESS`.
///
/// Offered because the flatten stage needs it: its first output is an *integer*
/// segment count derived from `ceil(sqrt(...))`, and an optimiser free to
/// reassociate the expression can move that integer by one - which does not
/// shift a pixel, it shifts every later segment in the buffer. Strictness does
/// not forbid multiply-add contraction, so it does not make a float comparison
/// exact; it removes the transformations that are free to be arbitrarily wrong.
const int kD3d12CompileIeeeStrictness = 1 << 13;

/// One dispatch in a chain: which compiled entry point, and how many groups.
final class D3d12ComputeStage {
  const D3d12ComputeStage(this.entryPoint, this.groups);

  /// Index into the pass's entry-point list.
  final int entryPoint;

  /// Thread groups on x. A stage of zero groups is skipped.
  final int groups;
}

/// A compute pass over `srvCount` read-only and `uavCount` read-write buffers.
///
/// Root parameter 0 is the root constants; parameters `1 .. srvCount` are root
/// SRVs at `t0..`; the rest are root UAVs at `u0..`. All of them are root
/// descriptors rather than a descriptor table: a root descriptor takes a GPU
/// virtual address, so an upload-arena allocation is bound the moment it is
/// written and a default-heap buffer needs no descriptor whose lifetime tracks
/// it. Each costs two DWORDs of the 64 a root signature has.
final class D3d12ComputePass {
  D3d12ComputePass(
    this._device, {
    required this.label,
    required this.source,
    required this.entryPoints,
    required this.rootConstantCount,
    required this.srvCount,
    required this.uavCount,
    required this.target,
    this.compileFlags = 0,
    this.deviceZeroFill = true,
  });

  /// Names the pass in every diagnostic it can raise.
  final String label;

  final String source;
  final List<String> entryPoints;
  final int rootConstantCount;
  final int srvCount;
  final int uavCount;

  /// The `D3DCompile` profile, for example `cs_5_0`.
  final String target;

  final int compileFlags;

  /// Whether the per-run zero-fill copies from a device-local buffer of zeros
  /// rather than from a fresh upload allocation the CPU memsets.
  ///
  /// True is the production answer and the only one a caller should pick; see
  /// [_zero] for what the other one costs. It stays selectable because that
  /// cost is a *claim*, and
  /// `test/rendering/gpu/compute/d3d12_compute_raster_pipeline_test.dart`
  /// measures both shapes in the same run on the same machine rather than
  /// asking anyone to believe a comment.
  final bool deviceZeroFill;

  final D3d12RenderDevice _device;

  Pointer<Void> _rootSignature = nullptr;
  final List<Pointer<Void>> _pipelines = <Pointer<Void>>[];
  final List<D3dBlob> _blobs = <D3dBlob>[];
  final List<_StageBuffer> _buffers = <_StageBuffer>[];

  late final _Readback _readback = _Readback(_device, label);

  /// A default-heap buffer of zeros, as wide as the widest stage buffer.
  ///
  /// See [_zero]: this is what the per-run memset became.
  Pointer<Void> _zeros = nullptr;
  int _zerosBytes = 0;
  bool _zerosNeedFilling = false;

  bool _disposed = false;

  late final Pointer<Uint32> _rootConstantScratch =
      _device.library.allocator.allocate<Uint32>(4 * rootConstantCount);
  late final Pointer<D3d12ResourceBarrier> _barrier = _device.library.allocator
      .allocate<D3d12ResourceBarrier>(sizeOf<D3d12ResourceBarrier>());

  bool get isBuilt =>
      _rootSignature != nullptr && _pipelines.length == entryPoints.length;

  bool get isDisposed => _disposed;

  /// Serialises the root signature and compiles every entry point.
  void build() {
    _throwIfDisposed();
    if (isBuilt) return;
    D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      try {
        _rootSignature = _createRootSignature(arena);
        for (final String entryPoint in entryPoints) {
          final D3dBlob blob = _compile(arena, entryPoint);
          _blobs.add(blob);
          _pipelines.add(_createPipelineState(arena, blob, entryPoint));
        }
      } on Object {
        // Partial construction must not survive: four pipelines out of five
        // would be reported as built by isBuilt on the next call.
        release();
        rethrow;
      }
      return null;
    });
  }

  /// Runs one chain and returns the requested buffers, in the order asked for.
  ///
  /// [uavBytes] sizes every read-write buffer, in slot order; each is grown if
  /// needed and zeroed. [reads] names the slots to copy back.
  ///
  /// One list, one fence, one map: this is the oracle shape. A caller that
  /// wants several passes to share a submission uses [D3d12ComputeChain]
  /// instead, which reuses the same recording code without the fence between
  /// the passes.
  List<Uint8List> run({
    required Uint32List rootConstants,
    required List<TypedData> uploads,
    required List<int> uavBytes,
    required List<D3d12ComputeStage> stages,
    required List<int> reads,
  }) {
    _throwIfDisposed();
    _validate(rootConstants, uploads, uavBytes);
    if (_device.frames.isRecording) {
      throw StateError(
        'a Direct3D 12 command list is already recording; the $label pass owns '
        'its own list because it waits for the GPU',
      );
    }
    if (_device.isLost) throw StateError('the Direct3D 12 device is lost');

    // Before the list is opened, not after: growing a buffer waits for the GPU
    // to be idle, and a wait issued while a list is recording reads as if the
    // open list were part of what is being waited for.
    _ensureBuffers(uavBytes);
    final List<int> sections = <int>[];
    final List<int> sizes = <int>[];
    var cursor = 0;
    for (final int slot in reads) {
      sections.add(cursor);
      sizes.add(uavBytes[slot]);
      cursor = alignUp(cursor + uavBytes[slot], _kReadbackAlignment);
    }
    if (cursor > 0) _readback.ensure(cursor);

    if (_device.frames.begin() == null) {
      _device.markLost('a command list could not be opened for $label');
      throw StateError('a command list could not be opened for $label');
    }

    var completed = false;
    try {
      final D3d12GraphicsCommandList list = _device.frames.list;
      record(
        list,
        rootConstants: rootConstants,
        uploads: uploads,
        uavBytes: uavBytes,
        stages: stages,
      );
      for (var i = 0; i < reads.length; i++) {
        copyOutSlot(
            list, _readback.pointer, reads[i], sections[i], uavBytes[reads[i]]);
      }

      completed = true;
      if (!_device.frames.end(waitForCompletion: true)) {
        _device.markLost('the $label command list did not complete');
        throw StateError('the $label command list did not complete');
      }
      return _readback.read(sections, sizes, cursor);
    } finally {
      // A throw before `end` would otherwise leave the list recording, and the
      // next `begin` would reset an allocator whose list is still open.
      if (!completed && _device.frames.isRecording) _device.frames.abandon();
    }
  }

  /// Records the uploads, the zero-fill, the root bindings and the whole
  /// dispatch chain into [list], which the caller has already opened.
  ///
  /// Everything [run] does except opening the list, sizing the buffers, copying
  /// out and waiting. Split out for [D3d12ComputeChain]: the point of the
  /// chained entry point is that it records *this* into a list it shares with
  /// other passes, so the two shapes cannot drift into recording different
  /// things.
  ///
  /// [reserve] must have been called first, outside the open list.
  void record(
    D3d12GraphicsCommandList list, {
    required Uint32List rootConstants,
    required List<TypedData> uploads,
    required List<int> uavBytes,
    required List<D3d12ComputeStage> stages,
  }) {
    final List<int> addresses = <int>[
      for (final TypedData data in uploads) _stage(data),
    ];
    for (var slot = 0; slot < uavCount; slot++) {
      _zero(list, _buffers[slot], uavBytes[slot]);
    }

    for (var i = 0; i < rootConstants.length; i++) {
      _rootConstantScratch[i] = rootConstants[i];
    }
    list.setComputeRootSignature(list.pointer, _rootSignature);
    list.setComputeRoot32BitConstants(
      list.pointer,
      0,
      rootConstantCount,
      _rootConstantScratch.cast<Void>(),
      0,
    );
    for (var slot = 0; slot < srvCount; slot++) {
      list.setComputeRootShaderResourceView(
          list.pointer, 1 + slot, addresses[slot]);
    }
    for (var slot = 0; slot < uavCount; slot++) {
      list.setComputeRootUnorderedAccessView(
          list.pointer, 1 + srvCount + slot, _buffers[slot].address);
    }

    for (final D3d12ComputeStage stage in stages) {
      if (stage.groups <= 0) continue;
      list
        ..setPipelineState(list.pointer, _pipelines[stage.entryPoint])
        ..dispatch(list.pointer, stage.groups, 1, 1);
      _uavBarrier(list);
    }
  }

  /// Sizes and, if needed, reallocates the read-write buffers.
  ///
  /// Separate from [record] because growing one waits for the GPU to be idle,
  /// and a wait issued while a list is recording reads as if the open list were
  /// part of what is being waited for. A chained caller reserves for *every*
  /// pass before it opens its list.
  void reserve(
      Uint32List rootConstants, List<TypedData> uploads, List<int> uavBytes) {
    _throwIfDisposed();
    _validate(rootConstants, uploads, uavBytes);
    _ensureBuffers(uavBytes);
  }

  /// The byte size of read-write slot [slot], as the last [reserve] set it.
  int slotBytes(int slot) => _buffers[slot].bytes;

  void _validate(
      Uint32List rootConstants, List<TypedData> uploads, List<int> uavBytes) {
    if (!isBuilt) {
      throw StateError('the $label compute pass is not built');
    }
    if (rootConstants.length != rootConstantCount) {
      throw ArgumentError(
        'the $label pass expects $rootConstantCount root constants, got '
        '${rootConstants.length}',
      );
    }
    if (uploads.length != srvCount) {
      throw ArgumentError(
        'the $label pass declares $srvCount read-only buffers, got '
        '${uploads.length}',
      );
    }
    if (uavBytes.length != uavCount) {
      throw ArgumentError(
        'the $label pass declares $uavCount read-write buffers, got '
        '${uavBytes.length}',
      );
    }
  }

  /// Releases every native object this pass owns.
  void release() {
    for (var i = 0; i < _pipelines.length; i++) {
      if (_pipelines[i] != nullptr) _pipelines[i] = releaseCom(_pipelines[i]);
    }
    _pipelines.clear();
    for (final D3dBlob blob in _blobs) {
      blob.release();
    }
    _blobs.clear();
    if (_rootSignature != nullptr) _rootSignature = releaseCom(_rootSignature);
    for (final _StageBuffer buffer in _buffers) {
      if (buffer.pointer != nullptr) {
        buffer.pointer = releaseCom(buffer.pointer);
      }
      buffer
        ..bytes = 0
        ..state = d3d12ResourceStateUnorderedAccess;
    }
    _buffers.clear();
    if (_zeros != nullptr) _zeros = releaseCom(_zeros);
    _zerosBytes = 0;
    _zerosNeedFilling = false;
    _readback.release();
  }

  /// Forgets objects invalidated by device removal without releasing them.
  void discard() {
    _rootSignature = nullptr;
    _pipelines.clear();
    _blobs.clear();
    _buffers.clear();
    _zeros = nullptr;
    _zerosBytes = 0;
    _zerosNeedFilling = false;
    _readback.discard();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    release();
    _readback.dispose();
    _device.library.allocator
      ..free(_rootConstantScratch)
      ..free(_barrier);
  }

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    discard();
    dispose();
  }

  // -------------------------------------------------------------------
  // Recording
  // -------------------------------------------------------------------

  /// One `D3D12_RESOURCE_BARRIER_TYPE_UAV` with a null resource: order every
  /// unordered access, not one buffer's.
  void _uavBarrier(D3d12GraphicsCommandList list) {
    _barrier.ref
      ..type = _kResourceBarrierTypeUav
      ..flags = 0
      ..resource = nullptr
      ..subresource = 0
      ..stateBefore = 0
      ..stateAfter = 0
      ..tail = 0;
    list.resourceBarrier(list.pointer, 1, _barrier);
  }

  /// Copies read-write slot [slot] into [readback] at byte [destination].
  ///
  /// The readback resource is a parameter rather than this pass's own, so that
  /// a [D3d12ComputeChain] can gather several passes' sections into one buffer
  /// and map it once.
  void copyOutSlot(
    D3d12GraphicsCommandList list,
    Pointer<Void> readback,
    int slot,
    int destination,
    int bytes,
  ) {
    if (bytes <= 0) return;
    final _StageBuffer buffer = _buffers[slot];
    _transition(buffer, d3d12ResourceStateCopySource);
    list.copyBufferRegion(
        list.pointer, readback, destination, buffer.pointer, 0, bytes);
    _transition(buffer, d3d12ResourceStateUnorderedAccess);
  }

  void _transition(_StageBuffer buffer, int state) {
    if (buffer.state == state) return;
    _device.transitionResource(buffer.pointer, buffer.state, state);
    buffer.state = state;
  }

  /// Fills a stage buffer with zeros, copying from the device-local source.
  ///
  /// `ClearUnorderedAccessViewUint` would need both a shader-visible and a
  /// non-shader-visible descriptor for the same UAV, which is two descriptor
  /// heaps to own for one memset - the trade `D3d12ComputeTileDriver` states.
  /// So it is a copy. What changed is *where it copies from*.
  ///
  /// It used to copy from a fresh upload allocation the CPU zeroed every run.
  /// Upload memory is write-combined, and this file's own benchmark measured
  /// what that costs: quadrupling the stage buffers, with every dispatch size
  /// unchanged, roughly doubled the cost of a submission - about 1 GB/s, which
  /// is a write-combined memset and nothing else. On the largest scene that was
  /// two thirds of everything a submission cost.
  ///
  /// Now [_ensureZeros] keeps one default-heap buffer of zeros, filled once
  /// when it grows, and every run copies from *it*. The CPU touches nothing per
  /// run, and the copy is device-local to device-local.
  void _zero(D3d12GraphicsCommandList list, _StageBuffer buffer, int bytes) {
    if (bytes <= 0) return;
    if (!deviceZeroFill) {
      _zeroFromUpload(list, buffer, bytes);
      return;
    }
    _fillZerosIfNeeded(list);
    _transition(buffer, d3d12ResourceStateCopyDest);
    list.copyBufferRegion(list.pointer, buffer.pointer, 0, _zeros, 0, bytes);
    _transition(buffer, d3d12ResourceStateUnorderedAccess);
  }

  /// The shape [deviceZeroFill] replaced: a fresh upload allocation, memset by
  /// the CPU, every run. Kept so the difference can be measured rather than
  /// asserted.
  void _zeroFromUpload(
      D3d12GraphicsCommandList list, _StageBuffer buffer, int bytes) {
    final D3d12UploadRange? zeros =
        _device.frames.reserveUpload(bytes, alignment: 256);
    if (zeros == null) {
      throw StateError(
        'a $bytes byte zero-fill for a $label buffer did not fit in an upload '
        'buffer',
      );
    }
    zeros.cpu.asTypedList(bytes).fillRange(0, bytes, 0);
    _transition(buffer, d3d12ResourceStateCopyDest);
    list.copyBufferRegion(
        list.pointer, buffer.pointer, 0, zeros.resource, zeros.offset, bytes);
    _transition(buffer, d3d12ResourceStateUnorderedAccess);
  }

  /// Writes the zeros into [_zeros], once per growth, from upload memory.
  ///
  /// Recorded into the same list rather than in a submission of its own: a
  /// separate one would need a fence before the copies that read it, and a
  /// fence is the thing this whole file is trying to stop paying.
  void _fillZerosIfNeeded(D3d12GraphicsCommandList list) {
    if (!_zerosNeedFilling) return;
    final D3d12UploadRange? source =
        _device.frames.reserveUpload(_zerosBytes, alignment: 256);
    if (source == null) {
      throw StateError(
        'a $_zerosBytes byte zero-fill source for $label did not fit in an '
        'upload buffer',
      );
    }
    source.cpu.asTypedList(_zerosBytes).fillRange(0, _zerosBytes, 0);
    _device.transitionResource(
        _zeros, d3d12ResourceStateUnorderedAccess, d3d12ResourceStateCopyDest);
    list.copyBufferRegion(
        list.pointer, _zeros, 0, source.resource, source.offset, _zerosBytes);
    _device.transitionResource(
        _zeros, d3d12ResourceStateCopyDest, d3d12ResourceStateCopySource);
    _zerosNeedFilling = false;
  }

  int _stage(TypedData data) {
    final int bytes = data.lengthInBytes;
    final int size =
        bytes < _kMinimumUploadBytes ? _kMinimumUploadBytes : bytes;
    final D3d12UploadRange? range =
        _device.frames.reserveUpload(size, alignment: 256);
    if (range == null) {
      throw StateError(
        'a $label scene buffer of $size bytes did not fit in an upload buffer',
      );
    }
    if (bytes > 0) {
      range.cpu.asTypedList(bytes).setRange(
            0,
            bytes,
            Uint8List.view(data.buffer, data.offsetInBytes, bytes),
          );
    }
    return range.gpuAddress;
  }

  // -------------------------------------------------------------------
  // Resources
  // -------------------------------------------------------------------

  void _ensureBuffers(List<int> uavBytes) {
    while (_buffers.length < uavCount) {
      _buffers.add(_StageBuffer(_buffers.length));
    }
    var widest = 0;
    for (final int bytes in uavBytes) {
      if (bytes > widest) widest = bytes;
    }
    _ensureZeros(widest);
    for (var slot = 0; slot < uavCount; slot++) {
      final _StageBuffer buffer = _buffers[slot];
      // A root UAV still needs a real address even for a chain that never
      // indexes it, so an empty slot gets the minimum allocation rather than
      // a null pointer the runtime would reject.
      final int bytes = uavBytes[slot] < _kMinimumUploadBytes
          ? _kMinimumUploadBytes
          : uavBytes[slot];
      if (buffer.pointer != nullptr && buffer.bytes >= bytes) continue;
      if (buffer.pointer != nullptr) {
        _device.frames.waitIdle();
        buffer.pointer = releaseCom(buffer.pointer);
      }
      buffer.pointer = _createUavBuffer(bytes);
      if (buffer.pointer == nullptr) {
        throw StateError(
          'a $bytes byte $label buffer for slot $slot was refused',
        );
      }
      buffer
        ..bytes = bytes
        ..state = d3d12ResourceStateUnorderedAccess;
    }
  }

  /// Grows the zero source to [bytes] and marks it as needing a fill.
  ///
  /// Never shrinks, for the reason the stage buffers never shrink: a scene that
  /// was large once is usually large again, and a shrink is a free allocation
  /// plus a wait for idle in exchange for memory nobody asked back.
  void _ensureZeros(int bytes) {
    if (!deviceZeroFill) return;
    final int size =
        bytes < _kMinimumUploadBytes ? _kMinimumUploadBytes : bytes;
    if (_zeros != nullptr && _zerosBytes >= size) return;
    if (_zeros != nullptr) {
      _device.frames.waitIdle();
      _zeros = releaseCom(_zeros);
    }
    _zeros = _createUavBuffer(size);
    if (_zeros == nullptr) {
      throw StateError('a $size byte $label zero source was refused');
    }
    _zerosBytes = size;
    _zerosNeedFilling = true;
  }

  Pointer<Void> _createUavBuffer(int bytes) =>
      D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
        final Pointer<D3d12HeapProperties> heap =
            arena<D3d12HeapProperties>(sizeOf<D3d12HeapProperties>());
        heap.ref
          ..type = d3d12HeapTypeDefault
          ..cpuPageProperty = 0
          ..memoryPoolPreference = 0
          ..creationNodeMask = 1
          ..visibleNodeMask = 1;
        final Pointer<D3d12ResourceDesc> desc =
            arena<D3d12ResourceDesc>(sizeOf<D3d12ResourceDesc>());
        desc.ref
          ..dimension = d3d12ResourceDimensionBuffer
          ..alignment = 0
          ..width = bytes
          ..height = 1
          ..depthOrArraySize = 1
          ..mipLevels = 1
          ..format = dxgiFormatUnknown
          ..layout = d3d12TextureLayoutRowMajor
          ..flags = d3d12ResourceFlagAllowUnorderedAccess;
        desc.ref.sampleDesc
          ..count = 1
          ..quality = 0;
        final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
        writeGuid(iid, D3d12Iids.resource);
        final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
        final int hr = _device.nativeDevice.createCommittedResource(
          _device.nativeDevice.pointer,
          heap,
          0,
          desc,
          d3d12ResourceStateUnorderedAccess,
          nullptr,
          iid,
          out,
        );
        return comFailed(hr) ? nullptr : out.value;
      });

  /// Compiles one entry point out of [source].
  ///
  /// Not `D3d12RenderDevice.compileShader`, which passes no flags: a stage that
  /// needs [kD3d12CompileIeeeStrictness] cannot ask for it there.
  D3dBlob _compile(D3d12Arena arena, String entryPoint) {
    final Pointer<Uint8> text = arena.allocateAscii(source);
    final Pointer<Uint8> name = arena.allocateAscii('dart_ui_$label.hlsl');
    final Pointer<Uint8> entry = arena.allocateAscii(entryPoint);
    final Pointer<Uint8> profile = arena.allocateAscii(target);
    final Pointer<Pointer<Void>> code = arena.allocatePointers(1);
    final Pointer<Pointer<Void>> errors = arena.allocatePointers(1);
    final int hr = _device.library.compile(
      text,
      source.length,
      name,
      nullptr,
      nullptr,
      entry,
      profile,
      compileFlags,
      0,
      code,
      errors,
    );
    if (comFailed(hr)) {
      final String detail = errors.value == nullptr
          ? hresultText(hr)
          : '${hresultText(hr)}: ${D3dBlob(errors.value).text}';
      if (errors.value != nullptr) ComObject(errors.value).release();
      throw StateError(
        '${BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: '$target failed to compile $label:$entryPoint',
          detail: detail,
        )}',
      );
    }
    if (errors.value != nullptr) ComObject(errors.value).release();
    return D3dBlob(code.value);
  }

  Pointer<Void> _createPipelineState(
    D3d12Arena arena,
    D3dBlob blob,
    String entryPoint,
  ) {
    final Pointer<D3d12ComputePipelineStateDesc> desc =
        arena<D3d12ComputePipelineStateDesc>(
            sizeOf<D3d12ComputePipelineStateDesc>());
    desc.ref
      ..rootSignature = _rootSignature
      ..nodeMask = 0
      ..flags = d3d12PipelineStateFlagNone;
    desc.ref.cs
      ..shaderBytecode = blob.data
      ..bytecodeLength = blob.length;

    final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
    writeGuid(iid, D3d12Iids.pipelineState);
    final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
    final int hr = _device.nativeDevice.createComputePipelineState(
      _device.nativeDevice.pointer,
      desc,
      iid,
      out,
    );
    if (comFailed(hr)) {
      throw StateError(
        '${BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'CreateComputePipelineState refused $label:$entryPoint',
          detail: hresultText(hr),
        )}',
      );
    }
    return out.value;
  }

  Pointer<Void> _createRootSignature(D3d12Arena arena) {
    final int parameterCount = 1 + srvCount + uavCount;
    final Pointer<D3d12RootParameter> parameters = arena<D3d12RootParameter>(
        sizeOf<D3d12RootParameter>() * parameterCount);
    parameters[0]
      ..parameterType = d3d12RootParameterTypeConstants
      ..field8 = 0 // ShaderRegister: b0
      ..fieldC = 0 // RegisterSpace
      ..field10 = rootConstantCount
      // A compute root signature may only use SHADER_VISIBILITY_ALL: the
      // per-stage values name graphics stages a compute pipeline does not have.
      ..shaderVisibility = d3d12ShaderVisibilityAll;
    for (var slot = 0; slot < srvCount; slot++) {
      parameters[1 + slot]
        ..parameterType = d3d12RootParameterTypeSrv
        ..field8 = slot // t0..
        ..fieldC = 0
        ..shaderVisibility = d3d12ShaderVisibilityAll;
    }
    for (var slot = 0; slot < uavCount; slot++) {
      parameters[1 + srvCount + slot]
        ..parameterType = d3d12RootParameterTypeUav
        ..field8 = slot // u0..
        ..fieldC = 0
        ..shaderVisibility = d3d12ShaderVisibilityAll;
    }

    final Pointer<D3d12RootSignatureDesc> desc =
        arena<D3d12RootSignatureDesc>(sizeOf<D3d12RootSignatureDesc>());
    desc.ref
      ..numParameters = parameterCount
      ..parameters = parameters
      ..numStaticSamplers = 0
      ..staticSamplers = nullptr
      ..flags = d3d12RootSignatureFlagNone;

    final Pointer<Pointer<Void>> blobOut = arena.allocatePointers(1);
    final Pointer<Pointer<Void>> errorOut = arena.allocatePointers(1);
    final int hr = _device.library.serializeRootSignature(
      desc.cast<Void>(),
      d3dRootSignatureVersion10,
      blobOut,
      errorOut,
    );
    if (comFailed(hr)) {
      final String detail = errorOut.value == nullptr
          ? hresultText(hr)
          : '${hresultText(hr)}: ${D3dBlob(errorOut.value).text}';
      if (errorOut.value != nullptr) ComObject(errorOut.value).release();
      throw StateError(
        '${BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the $label root signature could not be serialised',
          detail: detail,
        )}',
      );
    }
    final D3dBlob blob = D3dBlob(blobOut.value);
    final Pointer<Guid> iid = arena<Guid>(sizeOf<Guid>());
    writeGuid(iid, D3d12Iids.rootSignature);
    final Pointer<Pointer<Void>> out = arena.allocatePointers(1);
    final int createHr = _device.nativeDevice.createRootSignature(
      _device.nativeDevice.pointer,
      0,
      blob.data,
      blob.length,
      iid,
      out,
    );
    blob.release();
    if (comFailed(createHr)) {
      throw StateError(
        '${BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'CreateRootSignature refused the $label layout',
          detail: hresultText(createHr),
        )}',
      );
    }
    return out.value;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the $label compute pass is disposed');
    }
  }
}

/// One default-heap UAV buffer, grown to the largest run and reused.
final class _StageBuffer {
  _StageBuffer(this.slot);

  final int slot;
  Pointer<Void> pointer = nullptr;
  int bytes = 0;
  int state = d3d12ResourceStateUnorderedAccess;

  int get address => D3d12Resource(pointer).gpuVirtualAddress;
}

/// A readback buffer, its map scratch, and the sectioned copy out of it.
///
/// Owned by a [D3d12ComputePass] for its own single-pass shape, and by a
/// [D3d12ComputeChain] for the shared one - the sections of a chained
/// submission come from several passes, so the buffer they land in cannot
/// belong to any one of them.
final class _Readback {
  _Readback(this._device, this._label);

  final D3d12RenderDevice _device;
  final String _label;

  Pointer<Void> pointer = nullptr;
  int _bytes = 0;

  late final Pointer<D3d12Range> _range =
      _device.library.allocator.allocate<D3d12Range>(sizeOf<D3d12Range>());
  late final Pointer<Pointer<Void>> _mapped = _device.library.allocator
      .allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());

  /// Grows the buffer to at least [bytes]. Waits for idle before releasing the
  /// old one, which the GPU may still be copying into.
  void ensure(int bytes) {
    if (pointer != nullptr && _bytes >= bytes) return;
    if (pointer != nullptr) {
      _device.frames.waitIdle();
      pointer = releaseCom(pointer);
    }
    pointer = _device.createReadbackBuffer(bytes);
    if (pointer == nullptr) {
      throw StateError('a $bytes byte $_label readback buffer was refused');
    }
    _bytes = bytes;
  }

  /// Copies [sections] of [sizes] bytes each out of the mapped buffer.
  List<Uint8List> read(List<int> sections, List<int> sizes, int total) {
    if (sections.isEmpty) return const <Uint8List>[];
    final D3d12Resource resource = D3d12Resource(pointer);
    _range.ref
      ..begin = 0
      ..end = total;
    if (comFailed(resource.map(_range, _mapped))) {
      _device.markLost('the $_label readback buffer could not be mapped');
      throw StateError('the $_label readback buffer could not be mapped');
    }
    final int base = _mapped.value.address;
    final List<Uint8List> result = <Uint8List>[];
    for (var i = 0; i < sections.length; i++) {
      final int bytes = sizes[i];
      final Uint8List copy = Uint8List(bytes);
      if (bytes > 0) {
        copy.setRange(
          0,
          bytes,
          Pointer<Uint8>.fromAddress(base + sections[i]).asTypedList(bytes),
        );
      }
      result.add(copy);
    }
    // A zero-length written range: the CPU only read.
    _range.ref
      ..begin = 0
      ..end = 0;
    resource.unmap(_range);
    return result;
  }

  void release() {
    if (pointer != nullptr) pointer = releaseCom(pointer);
    _bytes = 0;
  }

  /// Forgets the resource without releasing it, after device removal.
  void discard() {
    pointer = nullptr;
    _bytes = 0;
  }

  void dispose() {
    release();
    _device.library.allocator
      ..free(_range)
      ..free(_mapped);
  }
}

/// One pass's share of a chained submission.
///
/// The same five arguments [D3d12ComputePass.run] takes, named so that a list
/// of them reads as the pipeline it is.
final class D3d12ComputeWork {
  const D3d12ComputeWork(
    this.pass, {
    required this.rootConstants,
    required this.uploads,
    required this.uavBytes,
    required this.stages,
    this.reads = const <int>[],
  });

  final D3d12ComputePass pass;
  final Uint32List rootConstants;
  final List<TypedData> uploads;
  final List<int> uavBytes;
  final List<D3d12ComputeStage> stages;

  /// Read-write slots of [pass] to copy back. Empty is legal and is the point:
  /// a stage whose output only the next stage reads never leaves the device.
  final List<int> reads;
}

/// Several passes, one command list, one fence.
///
/// [D3d12ComputePass.run] is the oracle shape: it ends in a readback the CPU
/// maps, so it closes its list and waits. Measured on an Intel UHD at feature
/// level 12_1 that costs about 0.8 ms per pass almost regardless of the scene,
/// which is more than the CPU planner it was meant to replace takes to do
/// strictly more work. A pipeline of stages paying that per stage is a pipeline
/// that cannot win.
///
/// This is the other shape. It records every pass into one list, in order, with
/// a UAV barrier between the passes as well as inside them, and submits once.
/// [run] still ends in a fence because a caller that asked to read something
/// has to wait for it; [submit] does not wait at all, and the difference
/// between the two is how the fence wait gets separated from the submission
/// cost rather than guessed at.
///
/// ## What a chained pass may not do
///
/// Grow a buffer. [D3d12ComputePass.reserve] runs for every pass before the
/// list opens, because growing waits for idle and a wait inside an open list
/// reads as if the list itself were being waited for. That is also why a
/// chained caller cannot use the overflow retry the single-pass executors have:
/// the retry needs the total the pass computed, and the total is on the device
/// until somebody waits. A chained caller carries the previous frame's budget
/// forward instead.
final class D3d12ComputeChain {
  D3d12ComputeChain(this._device, {required this.label});

  /// Names the chain in every diagnostic it can raise.
  final String label;

  final D3d12RenderDevice _device;

  late final _Readback _readback = _Readback(_device, label);

  /// How many command lists this chain has submitted.
  ///
  /// A counter rather than a log: the thing worth asserting about a chained
  /// pipeline is that N stages cost *one* submission, and a test that reads
  /// this proves it without a profiler.
  int get submissions => _submissions;
  int _submissions = 0;

  /// How many of those submissions ended in a fence wait.
  int get waits => _waits;
  int _waits = 0;

  bool _disposed = false;

  bool get isDisposed => _disposed;

  /// Records [work] into one list, submits it, waits, and returns each pass's
  /// requested buffers - outer list per work item, inner in `reads` order.
  List<List<Uint8List>> run(List<D3d12ComputeWork> work) =>
      _record(work, readBack: true);

  /// Records [work] into one list and submits it without waiting.
  ///
  /// Nothing is read, so nothing has to have finished. The frame ring lets the
  /// CPU run two submissions ahead of the GPU, and the third `begin` waits on
  /// the first one's fence - so a caller that submits in a loop measures the
  /// GPU's throughput rather than its latency, which is the number a frame path
  /// actually pays.
  void submit(List<D3d12ComputeWork> work) => _record(work, readBack: false);

  List<List<Uint8List>> _record(
    List<D3d12ComputeWork> work, {
    required bool readBack,
  }) {
    _throwIfDisposed();
    if (work.isEmpty) return const <List<Uint8List>>[];
    if (_device.frames.isRecording) {
      throw StateError(
        'a Direct3D 12 command list is already recording; the $label chain '
        'owns its own list',
      );
    }
    if (_device.isLost) throw StateError('the Direct3D 12 device is lost');

    // Every pass, before the list opens: see the class comment.
    for (final D3d12ComputeWork item in work) {
      item.pass.reserve(item.rootConstants, item.uploads, item.uavBytes);
    }

    final List<int> sections = <int>[];
    final List<int> sizes = <int>[];
    var cursor = 0;
    if (readBack) {
      for (final D3d12ComputeWork item in work) {
        for (final int slot in item.reads) {
          sections.add(cursor);
          sizes.add(item.uavBytes[slot]);
          cursor = alignUp(cursor + item.uavBytes[slot], _kReadbackAlignment);
        }
      }
      if (cursor > 0) _readback.ensure(cursor);
    }

    if (_device.frames.begin() == null) {
      _device.markLost('a command list could not be opened for $label');
      throw StateError('a command list could not be opened for $label');
    }

    var completed = false;
    try {
      final D3d12GraphicsCommandList list = _device.frames.list;
      for (final D3d12ComputeWork item in work) {
        item.pass.record(
          list,
          rootConstants: item.rootConstants,
          uploads: item.uploads,
          uavBytes: item.uavBytes,
          stages: item.stages,
        );
      }
      if (readBack) {
        var section = 0;
        for (final D3d12ComputeWork item in work) {
          for (final int slot in item.reads) {
            item.pass.copyOutSlot(
              list,
              _readback.pointer,
              slot,
              sections[section],
              item.uavBytes[slot],
            );
            section++;
          }
        }
      }

      completed = true;
      _submissions++;
      if (readBack) _waits++;
      if (!_device.frames.end(waitForCompletion: readBack)) {
        _device.markLost('the $label command list did not complete');
        throw StateError('the $label command list did not complete');
      }
      if (!readBack) return const <List<Uint8List>>[];

      final List<Uint8List> flat = _readback.read(sections, sizes, cursor);
      final List<List<Uint8List>> result = <List<Uint8List>>[];
      var section = 0;
      for (final D3d12ComputeWork item in work) {
        result.add(flat.sublist(section, section + item.reads.length));
        section += item.reads.length;
      }
      return result;
    } finally {
      // A throw before `end` would otherwise leave the list recording, and the
      // next `begin` would reset an allocator whose list is still open.
      if (!completed && _device.frames.isRecording) _device.frames.abandon();
    }
  }

  /// Waits for every submission this chain has made.
  ///
  /// A caller that used [submit] and now wants to touch a buffer, or to stop a
  /// clock, calls this. It is the fence the chained shape does not pay per
  /// stage, paid once at the end instead.
  bool finish() {
    _throwIfDisposed();
    return _device.frames.waitIdle();
  }

  void release() => _readback.release();

  /// Forgets objects invalidated by device removal without releasing them.
  void discard() => _readback.discard();

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _readback.dispose();
  }

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    discard();
    dispose();
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the $label compute chain is disposed');
    }
  }
}
