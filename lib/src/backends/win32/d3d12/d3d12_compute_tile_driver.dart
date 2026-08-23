/// Production Direct3D 12 adapter for the experimental compute-tile executor.
///
/// This is the first compute work this backend has ever issued, so the choices
/// that were *not* made are worth stating:
///
/// **No second queue and no second allocator ring.** A direct command list
/// supports compute as well as graphics, and the frame ring already owns the
/// one rule that matters - an allocator may not be reset until the GPU has
/// finished the lists recorded into it. A compute queue would buy asynchronous
/// overlap this pass cannot use, because it ends in a readback the CPU waits
/// on, and would add a second fence relationship to get wrong.
///
/// **No descriptor heap.** Every buffer here is raw or structured, and a root
/// descriptor takes a GPU virtual address directly - so a buffer reserved out of
/// the frame's upload arena is bound the moment it is written, with no
/// descriptor to create and no shader-visible heap slot whose lifetime has to
/// track it. See `d3d12_structs.dart` on the restriction that comes with it.
///
/// **No indirect dispatch.** The occupied-tile command count is produced by the
/// CPU that built the plan, so there is no GPU-side count to read back;
/// `Dispatch(commandCount, 1, 1)` already skips every empty tile. Indirect
/// argument buffers become the right tool when binning itself moves to the GPU,
/// and not before.
///
/// ## The one blocking wait, and why it is here
///
/// [runTilePass] closes the command list, executes it and waits on the fence,
/// because the next thing it does is read the coverage buffer on the CPU.
/// Mapping a readback buffer before the GPU has performed the copy returns
/// whatever was there before - which looks like a one-frame lag rather than a
/// missing wait. It is the same trade `D3d12OffscreenTarget.present` makes for
/// the same reason, and it is why this pass is a diagnostic and a parity oracle
/// rather than a frame path.
library;

import 'dart:ffi';
import 'dart:typed_data';

import '../../../foundation/diagnostics.dart';
import '../../../rendering/gpu/d3d12/d3d12_compute_tile_executor.dart';
import '../../../rendering/gpu/d3d12/d3d12_compute_tile_shader.dart';
import 'd3d12_arena.dart';
import 'd3d12_com.dart';
import 'd3d12_device.dart';
import 'd3d12_frame_ring.dart';
import 'd3d12_interfaces.dart';
import 'd3d12_library.dart';
import 'd3d12_structs.dart';

/// The token [D3d12ComputeTileDriver.createComputePipeline] returns.
const int _kComputePipelineToken = 1;

/// The smallest upload allocation this driver makes for a scene buffer.
///
/// An empty array still needs an address: a root SRV must name a real buffer
/// even when the shader never indexes it, and `reserveUpload` refuses a
/// zero-byte request. 256 is the alignment every allocation here uses anyway.
const int _kMinimumUploadBytes = 256;

/// The GPU virtual addresses of one staged scene.
final class _StagedScene {
  const _StagedScene({
    required this.segments,
    required this.draws,
    required this.bounds,
    required this.bins,
    required this.references,
    required this.commands,
    required this.referenceSegments,
    required this.tileSegments,
    required this.backdrops,
  });

  final int segments;
  final int draws;
  final int bounds;
  final int bins;
  final int references;
  final int commands;
  final int referenceSegments;
  final int tileSegments;
  final int backdrops;
}

/// Maps the compute-tile contract onto a [D3d12RenderDevice].
final class D3d12ComputeTileDriver implements ComputeTileD3d12Driver {
  D3d12ComputeTileDriver(this._device);

  final D3d12RenderDevice _device;

  /// The buffer path: root constants, six root SRVs and a root UAV.
  Pointer<Void> _bufferRootSignature = nullptr;
  Pointer<Void> _bufferPipeline = nullptr;
  D3dBlob? _bufferBlob;

  /// The composition path: the same layout except that the output is a
  /// one-descriptor table, because a root descriptor can only address a buffer
  /// and the composition output is a texture.
  Pointer<Void> _textureRootSignature = nullptr;
  Pointer<Void> _texturePipeline = nullptr;
  D3dBlob? _textureBlob;

  late final Pointer<Pointer<Void>> _heapSlot = _device.library.allocator
      .allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());

  /// The coverage UAV, grown to the largest pass and reused.
  Pointer<Void> _coverage = nullptr;
  int _coverageBytes = 0;
  int _coverageState = d3d12ResourceStateUnorderedAccess;

  Pointer<Void> _readback = nullptr;
  int _readbackBytes = 0;

  bool _disposed = false;

  late final Pointer<Uint32> _rootConstantScratch = _device.library.allocator
      .allocate<Uint32>(4 * kD3d12ComputeTileRootConstantCount);
  late final Pointer<D3d12Range> _range =
      _device.library.allocator.allocate<D3d12Range>(sizeOf<D3d12Range>());
  late final Pointer<Pointer<Void>> _mapped = _device.library.allocator
      .allocate<Pointer<Void>>(sizeOf<Pointer<Void>>());

  bool get isBuilt =>
      _bufferPipeline != nullptr && _texturePipeline != nullptr;

  @override
  int createComputePipeline() {
    _throwIfDisposed();
    if (isBuilt) return _kComputePipelineToken;
    return D3d12Arena.using(_device.library.allocator, (D3d12Arena arena) {
      try {
        _bufferRootSignature = _createRootSignature(arena, textureOutput: false);
        _bufferBlob = _compile(
          arena,
          kD3d12ComputeTileBufferShader,
          kD3d12ComputeTileBufferEntryPoint,
        );
        _bufferPipeline =
            _createPipelineState(arena, _bufferRootSignature, _bufferBlob!);

        _textureRootSignature =
            _createRootSignature(arena, textureOutput: true);
        _textureBlob = _compile(
          arena,
          kD3d12ComputeTileTextureShader,
          kD3d12ComputeTileTextureEntryPoint,
        );
        _texturePipeline =
            _createPipelineState(arena, _textureRootSignature, _textureBlob!);
      } on Object {
        // Partial construction must not survive: half a pipeline would be
        // reported as built by isBuilt on the next call.
        _releaseNativeObjects();
        rethrow;
      }
      return _kComputePipelineToken;
    });
  }

  D3dBlob _compile(D3d12Arena arena, String source, String entryPoint) {
    final Object compiled = _device.compileShader(
      arena,
      source,
      entryPoint,
      kD3d12ComputeTileTarget,
    );
    if (compiled is BackendDiagnostic) throw StateError('$compiled');
    return compiled as D3dBlob;
  }

  Pointer<Void> _createPipelineState(
    D3d12Arena arena,
    Pointer<Void> rootSignature,
    D3dBlob blob,
  ) {
    final Pointer<D3d12ComputePipelineStateDesc> desc =
        arena<D3d12ComputePipelineStateDesc>(
            sizeOf<D3d12ComputePipelineStateDesc>());
    desc.ref
      ..rootSignature = rootSignature
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
          message: 'CreateComputePipelineState refused a tile shader',
          detail: hresultText(hr),
        )}',
      );
    }
    return out.value;
  }

  @override
  void disposeComputePipeline(int pipeline) {
    if (pipeline != _kComputePipelineToken) return;
    _releaseNativeObjects();
  }

  @override
  Uint32List runTilePass({
    required int pipeline,
    required ComputeTileSceneUpload scene,
    required Uint32List rootConstants,
    required int coverageElements,
    required int groupCount,
  }) {
    _throwIfDisposed();
    if (pipeline != _kComputePipelineToken || !isBuilt) {
      throw StateError('the compute pipeline does not belong to this driver');
    }
    if (rootConstants.length != kD3d12ComputeTileRootConstantCount) {
      throw ArgumentError(
        'expected $kD3d12ComputeTileRootConstantCount root constants, got '
        '${rootConstants.length}',
      );
    }
    if (coverageElements <= 0 || groupCount <= 0) {
      throw ArgumentError('a tile pass needs coverage elements and groups');
    }
    if (_device.frames.isRecording) {
      // This pass ends in a fence wait, so it cannot share a command list with
      // a frame that has not finished recording: closing that list here would
      // present a half-built frame, and not closing it would map a buffer the
      // GPU has not written. Naming the conflict beats doing either.
      throw StateError(
        'a Direct3D 12 command list is already recording; the compute-tile '
        'pass owns its own list because it waits for the GPU',
      );
    }
    if (_device.isLost) throw StateError('the Direct3D 12 device is lost');

    // Before the list is opened, not after: growing either buffer waits for the
    // GPU to be idle, and a wait issued while a list is recording is legal but
    // reads as if the open list were part of what is being waited for.
    final int coverageBytes = coverageElements * 4;
    _ensureCoverage(coverageBytes);
    _ensureReadback(coverageBytes);

    if (_device.frames.begin() == null) {
      _device.markLost('a command list could not be opened for a tile pass');
      throw StateError('a command list could not be opened for a tile pass');
    }

    var completed = false;
    try {
      final _StagedScene staged = _stage(scene);

      _zeroCoverage(coverageBytes);

      final D3d12GraphicsCommandList list = _device.frames.list;
      for (var i = 0; i < rootConstants.length; i++) {
        _rootConstantScratch[i] = rootConstants[i];
      }
      list
        ..setPipelineState(list.pointer, _bufferPipeline)
        ..setComputeRootSignature(list.pointer, _bufferRootSignature)
        ..setComputeRoot32BitConstants(
          list.pointer,
          kD3d12ComputeTileRootConstantsSlot,
          kD3d12ComputeTileRootConstantCount,
          _rootConstantScratch.cast<Void>(),
          0,
        )
        ..setComputeRootUnorderedAccessView(
            list.pointer, kD3d12ComputeTileCoverageSlot, _coverageAddress);
      _bindScene(list, staged);
      list.dispatch(list.pointer, groupCount, 1, 1);

      // A transition out of UNORDERED_ACCESS is itself the synchronisation the
      // copy needs: the runtime orders the barrier after every write the
      // dispatch issued, so no separate UAV barrier is required here.
      _transitionCoverage(d3d12ResourceStateCopySource);
      list.copyBufferRegion(
          list.pointer, _readback, 0, _coverage, 0, coverageBytes);
      _transitionCoverage(d3d12ResourceStateUnorderedAccess);

      completed = true;
      if (!_device.frames.end(waitForCompletion: true)) {
        _device.markLost('the compute-tile command list did not complete');
        throw StateError('the compute-tile command list did not complete');
      }
      return _readCoverage(coverageElements);
    } finally {
      // A throw before `end` would otherwise leave the list recording, and the
      // next `begin` would reset an allocator whose list is still open.
      if (!completed && _device.frames.isRecording) _device.frames.abandon();
    }
  }

  @override
  void dispatchDrawIntoCoverageTexture({
    required int pipeline,
    required ComputeTileSceneUpload scene,
    required Uint32List rootConstants,
    required int groupCount,
    required int coverageDescriptorIndex,
  }) {
    _throwIfDisposed();
    if (pipeline != _kComputePipelineToken || !isBuilt) {
      throw StateError('the compute pipeline does not belong to this driver');
    }
    if (rootConstants.length != kD3d12ComputeTileRootConstantCount) {
      throw ArgumentError(
        'expected $kD3d12ComputeTileRootConstantCount root constants, got '
        '${rootConstants.length}',
      );
    }
    if (groupCount <= 0) return;
    if (!_device.frames.isRecording) {
      // The opposite precondition to runTilePass, and deliberately so: this
      // pass produces no readback, so it belongs *inside* the caller's frame,
      // between the same dense batches the ordered submitter puts it between.
      throw StateError(
        'no Direct3D 12 command list is open for a compute composition '
        'dispatch',
      );
    }

    final _StagedScene staged = _stage(scene);

    final D3d12GraphicsCommandList list = _device.frames.list;
    for (var i = 0; i < rootConstants.length; i++) {
      _rootConstantScratch[i] = rootConstants[i];
    }
    _heapSlot.value = _device.shaderVisibleHeap;
    list
      ..setDescriptorHeaps(list.pointer, 1, _heapSlot)
      ..setPipelineState(list.pointer, _texturePipeline)
      ..setComputeRootSignature(list.pointer, _textureRootSignature)
      ..setComputeRoot32BitConstants(
        list.pointer,
        kD3d12ComputeTileRootConstantsSlot,
        kD3d12ComputeTileRootConstantCount,
        _rootConstantScratch.cast<Void>(),
        0,
      )
      ..setComputeRootDescriptorTable(
        list.pointer,
        kD3d12ComputeTileCoverageSlot,
        _device.gpuDescriptorHandleFor(coverageDescriptorIndex),
      );
    _bindScene(list, staged);
    list.dispatch(list.pointer, groupCount, 1, 1);
  }

  /// Stages the nine read-only scene buffers into the frame's upload arena.
  ///
  /// Nine addresses in one record rather than nine locals at each call site:
  /// the two dispatch paths bind exactly the same set, and a set that drifted
  /// between them would be a shader reading one plan's bins against another
  /// plan's segments.
  _StagedScene _stage(ComputeTileSceneUpload scene) => _StagedScene(
        segments: _stageFloats(scene.segments),
        draws: _stageUints(scene.draws),
        bounds: _stageFloats(scene.bounds),
        bins: _stageUints(scene.bins),
        references: _stageUints(scene.references),
        commands: _stageUints(scene.commands),
        referenceSegments: _stageUints(scene.referenceSegments),
        tileSegments: _stageUints(scene.tileSegments),
        backdrops: _stageInts(scene.referenceBackdrops),
      );

  void _bindScene(D3d12GraphicsCommandList list, _StagedScene staged) {
    list
      ..setComputeRootShaderResourceView(
          list.pointer, kD3d12ComputeTileSegmentsSlot, staged.segments)
      ..setComputeRootShaderResourceView(
          list.pointer, kD3d12ComputeTileDrawsSlot, staged.draws)
      ..setComputeRootShaderResourceView(
          list.pointer, kD3d12ComputeTileBoundsSlot, staged.bounds)
      ..setComputeRootShaderResourceView(
          list.pointer, kD3d12ComputeTileBinsSlot, staged.bins)
      ..setComputeRootShaderResourceView(
          list.pointer, kD3d12ComputeTileReferencesSlot, staged.references)
      ..setComputeRootShaderResourceView(
          list.pointer, kD3d12ComputeTileCommandsSlot, staged.commands)
      ..setComputeRootShaderResourceView(list.pointer,
          kD3d12ComputeTileReferenceSegmentsSlot, staged.referenceSegments)
      ..setComputeRootShaderResourceView(
          list.pointer, kD3d12ComputeTileTileSegmentsSlot, staged.tileSegments)
      ..setComputeRootShaderResourceView(
          list.pointer, kD3d12ComputeTileBackdropsSlot, staged.backdrops);
  }

  @override
  void discardNativeResources() {
    _bufferRootSignature = nullptr;
    _bufferPipeline = nullptr;
    _bufferBlob = null;
    _textureRootSignature = nullptr;
    _texturePipeline = nullptr;
    _textureBlob = null;
    _coverage = nullptr;
    _coverageBytes = 0;
    _coverageState = d3d12ResourceStateUnorderedAccess;
    _readback = nullptr;
    _readbackBytes = 0;
  }

  /// Releases the native objects and then the host-side scratch.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _releaseNativeObjects();
    _device.library.allocator
      ..free(_rootConstantScratch)
      ..free(_range)
      ..free(_mapped)
      ..free(_heapSlot);
  }

  /// Disposes after device removal, where releasing an object is undefined.
  void disposeAfterDeviceLoss() {
    if (_disposed) return;
    discardNativeResources();
    dispose();
  }

  // -------------------------------------------------------------------
  // Staging and resources
  // -------------------------------------------------------------------

  int get _coverageAddress => D3d12Resource(_coverage).gpuVirtualAddress;

  int _stageFloats(Float32List values) {
    final int bytes = values.lengthInBytes;
    final D3d12UploadRange range = _reserve(bytes);
    if (values.isNotEmpty) {
      range.cpu
          .cast<Float>()
          .asTypedList(values.length)
          .setRange(0, values.length, values);
    }
    return range.gpuAddress;
  }

  int _stageInts(Int32List values) {
    final int bytes = values.lengthInBytes;
    final D3d12UploadRange range = _reserve(bytes);
    if (values.isNotEmpty) {
      range.cpu
          .cast<Int32>()
          .asTypedList(values.length)
          .setRange(0, values.length, values);
    }
    return range.gpuAddress;
  }

  int _stageUints(Uint32List values) {
    final int bytes = values.lengthInBytes;
    final D3d12UploadRange range = _reserve(bytes);
    if (values.isNotEmpty) {
      range.cpu
          .cast<Uint32>()
          .asTypedList(values.length)
          .setRange(0, values.length, values);
    }
    return range.gpuAddress;
  }

  D3d12UploadRange _reserve(int bytes) {
    final int size = bytes < _kMinimumUploadBytes ? _kMinimumUploadBytes : bytes;
    final D3d12UploadRange? range =
        _device.frames.reserveUpload(size, alignment: 256);
    if (range == null) {
      throw StateError('a compute-tile scene buffer of $size bytes did not '
          'fit in an upload buffer');
    }
    return range;
  }

  void _ensureCoverage(int bytes) {
    if (_coverage != nullptr && _coverageBytes >= bytes) return;
    if (_coverage != nullptr) {
      // The GPU may still be reading the old buffer. Nothing else in this
      // driver is in flight - runTilePass waits before it returns - but the
      // device's own frames may be, and the ring's idle wait is the only
      // honest answer to "is anybody still using this".
      _device.frames.waitIdle();
      _coverage = releaseCom(_coverage);
    }
    _coverage = _createUavBuffer(bytes);
    if (_coverage == nullptr) {
      throw StateError('a $bytes byte compute coverage buffer was refused');
    }
    _coverageBytes = bytes;
    _coverageState = d3d12ResourceStateUnorderedAccess;
  }

  void _ensureReadback(int bytes) {
    if (_readback != nullptr && _readbackBytes >= bytes) return;
    if (_readback != nullptr) {
      _device.frames.waitIdle();
      _readback = releaseCom(_readback);
    }
    _readback = _device.createReadbackBuffer(bytes);
    if (_readback == nullptr) {
      throw StateError('a $bytes byte compute readback buffer was refused');
    }
    _readbackBytes = bytes;
  }

  /// Fills the coverage buffer with zeros through a copy from upload memory.
  ///
  /// A default-heap resource's initial contents are undefined, and the shader
  /// writes only the pixels of *occupied* tiles - so every other element would
  /// carry whatever the allocation happened to contain, and the comparison
  /// against the CPU oracle would depend on the driver's allocator. Clearing
  /// through `ClearUnorderedAccessViewUint` would need both a shader-visible
  /// and a non-shader-visible descriptor for the same UAV, which is two
  /// descriptor heaps to own for one memset.
  void _zeroCoverage(int bytes) {
    final D3d12UploadRange? zeros =
        _device.frames.reserveUpload(bytes, alignment: 256);
    if (zeros == null) {
      throw StateError('a $bytes byte zero-fill did not fit in an upload '
          'buffer');
    }
    zeros.cpu.asTypedList(bytes).fillRange(0, bytes, 0);
    _transitionCoverage(d3d12ResourceStateCopyDest);
    final D3d12GraphicsCommandList list = _device.frames.list;
    list.copyBufferRegion(
        list.pointer, _coverage, 0, zeros.resource, zeros.offset, bytes);
    _transitionCoverage(d3d12ResourceStateUnorderedAccess);
  }

  void _transitionCoverage(int state) {
    if (_coverageState == state) return;
    _device.transitionResource(_coverage, _coverageState, state);
    _coverageState = state;
  }

  Uint32List _readCoverage(int elements) {
    final D3d12Resource resource = D3d12Resource(_readback);
    _range.ref
      ..begin = 0
      ..end = elements * 4;
    if (comFailed(resource.map(_range, _mapped))) {
      _device.markLost('the compute readback buffer could not be mapped');
      throw StateError('the compute readback buffer could not be mapped');
    }
    final Uint32List result = Uint32List(elements);
    result.setRange(
      0,
      elements,
      _mapped.value.cast<Uint32>().asTypedList(elements),
    );
    // A zero-length written range: the CPU only read.
    _range.ref
      ..begin = 0
      ..end = 0;
    resource.unmap(_range);
    return result;
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

  /// Serialises and creates one of the two layouts.
  ///
  /// They differ in a single parameter: the buffer path binds its output as a
  /// root UAV, which takes a GPU virtual address, and the texture path cannot -
  /// a root descriptor addresses only raw and structured buffers - so it binds
  /// a one-descriptor table into the device's shader-visible heap instead.
  Pointer<Void> _createRootSignature(
    D3d12Arena arena, {
    required bool textureOutput,
  }) {
    final Pointer<D3d12DescriptorRange> range =
        arena<D3d12DescriptorRange>(sizeOf<D3d12DescriptorRange>());
    range.ref
      ..rangeType = d3d12DescriptorRangeTypeUav
      ..numDescriptors = 1
      ..baseShaderRegister = 0
      ..registerSpace = 0
      ..offsetInDescriptorsFromTableStart = 0;

    final Pointer<D3d12RootParameter> parameters = arena<D3d12RootParameter>(
        sizeOf<D3d12RootParameter>() * kD3d12ComputeTileRootParameterCount);
    parameters[kD3d12ComputeTileRootConstantsSlot]
      ..parameterType = d3d12RootParameterTypeConstants
      ..field8 = 0 // ShaderRegister: b0
      ..fieldC = 0 // RegisterSpace
      ..field10 = kD3d12ComputeTileRootConstantCount
      // A compute root signature may only use SHADER_VISIBILITY_ALL: the
      // per-stage values name graphics stages a compute pipeline does not have.
      ..shaderVisibility = d3d12ShaderVisibilityAll;
    for (var slot = kD3d12ComputeTileFirstSrvSlot;
        slot <= kD3d12ComputeTileLastSrvSlot;
        slot++) {
      parameters[slot]
        ..parameterType = d3d12RootParameterTypeSrv
        ..field8 = slot - kD3d12ComputeTileFirstSrvSlot // t0..t8
        ..fieldC = 0
        ..shaderVisibility = d3d12ShaderVisibilityAll;
    }
    if (textureOutput) {
      parameters[kD3d12ComputeTileCoverageSlot]
        ..parameterType = d3d12RootParameterTypeDescriptorTable
        ..field8 = 1 // NumDescriptorRanges
        ..field10 = range.address // pDescriptorRanges -> u0
        ..shaderVisibility = d3d12ShaderVisibilityAll;
    } else {
      parameters[kD3d12ComputeTileCoverageSlot]
        ..parameterType = d3d12RootParameterTypeUav
        ..field8 = 0 // u0
        ..fieldC = 0
        ..shaderVisibility = d3d12ShaderVisibilityAll;
    }

    final Pointer<D3d12RootSignatureDesc> desc =
        arena<D3d12RootSignatureDesc>(sizeOf<D3d12RootSignatureDesc>());
    desc.ref
      ..numParameters = kD3d12ComputeTileRootParameterCount
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
          message: 'the compute-tile root signature could not be serialised',
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
          message: 'CreateRootSignature refused the compute-tile layout',
          detail: hresultText(createHr),
        )}',
      );
    }
    return out.value;
  }

  void _releaseNativeObjects() {
    if (_bufferPipeline != nullptr) _bufferPipeline = releaseCom(_bufferPipeline);
    if (_texturePipeline != nullptr) {
      _texturePipeline = releaseCom(_texturePipeline);
    }
    if (_bufferRootSignature != nullptr) {
      _bufferRootSignature = releaseCom(_bufferRootSignature);
    }
    if (_textureRootSignature != nullptr) {
      _textureRootSignature = releaseCom(_textureRootSignature);
    }
    _bufferBlob?.release();
    _textureBlob?.release();
    _bufferBlob = null;
    _textureBlob = null;
    if (_coverage != nullptr) _coverage = releaseCom(_coverage);
    if (_readback != nullptr) _readback = releaseCom(_readback);
    _coverageBytes = 0;
    _readbackBytes = 0;
    _coverageState = d3d12ResourceStateUnorderedAccess;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the compute-tile Direct3D 12 driver is disposed');
    }
  }
}
