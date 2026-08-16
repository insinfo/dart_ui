/// One thin Dart class per COM interface, with the vtable slot written down.
///
/// ## How to read a slot number
///
/// A COM vtable is the flattened list of every method the interface and its
/// bases declare, base first. So `ID3D12GraphicsCommandList::Close` is slot 9
/// because `IUnknown` contributes 3, `ID3D12Object` 4 more, `ID3D12DeviceChild`
/// one more, and `ID3D12CommandList` one more - 3 + 4 + 1 + 1 = 9. Every class
/// below states that arithmetic once, above its slot constants, because the
/// number is the ABI: there is no runtime check, and an index off by one calls
/// a different method with the wrong arguments.
///
/// ## Structures returned by value
///
/// Four methods here return a struct instead of taking an out-parameter:
/// `GetCPUDescriptorHandleForHeapStart`, `GetGPUDescriptorHandleForHeapStart`,
/// `GetGPUVirtualAddress` and `GetCompletedValue`. All four return exactly
/// eight bytes, and the x64 calling convention Windows uses returns a
/// trivially-copyable aggregate of 1, 2, 4 or 8 bytes in RAX - the same place
/// an integer of that width goes. They are therefore declared as `IntPtr` and
/// `Uint64` rather than as FFI structs, which is not a shortcut: it is the
/// same instruction sequence, and it keeps a descriptor handle an *integer* on
/// the Dart side, which is what offsetting one by
/// `GetDescriptorHandleIncrementSize` needs it to be.
///
/// The methods that return a *large* struct by value - `GetDesc` on a resource
/// or a descriptor heap - use a hidden first parameter under the same ABI and
/// are deliberately not bound here. This backend keeps its own record of every
/// resource it created instead of asking the runtime to describe it back.
library;

import 'dart:ffi';

import 'd3d12_com.dart';
import 'd3d12_structs.dart';

/// `ID3D10Blob` / `ID3DBlob`: a length and a pointer, which is all the shader
/// compiler and the root-signature serialiser hand back.
///
/// Slots: IUnknown 3, then GetBufferPointer, GetBufferSize.
final class D3dBlob {
  D3dBlob(this.pointer)
      : _getBufferPointer =
            comMethod<Pointer<Void> Function(Pointer<Void>)>(pointer, 3)
                .asFunction<Pointer<Void> Function(Pointer<Void>)>(),
        _getBufferSize = comMethod<IntPtr Function(Pointer<Void>)>(pointer, 4)
            .asFunction<int Function(Pointer<Void>)>();

  final Pointer<Void> pointer;
  final Pointer<Void> Function(Pointer<Void>) _getBufferPointer;
  final int Function(Pointer<Void>) _getBufferSize;

  Pointer<Void> get data => _getBufferPointer(pointer);
  int get length => _getBufferSize(pointer);

  /// The blob read as ASCII. Used for the compiler's error text, which is the
  /// difference between "the pixel shader failed" and a line number.
  String get text {
    final int size = length;
    if (size <= 0) return '';
    final Pointer<Uint8> bytes = data.cast<Uint8>();
    final StringBuffer buffer = StringBuffer();
    for (var i = 0; i < size; i++) {
      final int byte = bytes[i];
      if (byte == 0) break;
      buffer.writeCharCode(byte);
    }
    return buffer.toString().trim();
  }

  void release() => ComObject(pointer).release();
}

/// `ID3D12Device`.
///
/// Slots: IUnknown 3 + ID3D12Object 4 = 7 inherited, then the device's own in
/// header order.
final class D3d12Device {
  D3d12Device(this.pointer)
      : createCommandQueue = comMethod<
                Int32 Function(Pointer<Void>, Pointer<D3d12CommandQueueDesc>,
                    Pointer<Guid>, Pointer<Pointer<Void>>)>(pointer, 8)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D3d12CommandQueueDesc>,
                    Pointer<Guid>, Pointer<Pointer<Void>>)>(),
        createCommandAllocator = comMethod<
                Int32 Function(Pointer<Void>, Uint32, Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(pointer, 9)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(),
        createGraphicsPipelineState = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D3d12GraphicsPipelineStateDesc>,
                    Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(pointer, 10)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<D3d12GraphicsPipelineStateDesc>,
                    Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(),
        createCommandList = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Uint32,
                    Uint32,
                    Pointer<Void>,
                    Pointer<Void>,
                    Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(pointer, 12)
            .asFunction<
                int Function(Pointer<Void>, int, int, Pointer<Void>,
                    Pointer<Void>, Pointer<Guid>, Pointer<Pointer<Void>>)>(),
        createDescriptorHeap = comMethod<
                Int32 Function(Pointer<Void>, Pointer<D3d12DescriptorHeapDesc>,
                    Pointer<Guid>, Pointer<Pointer<Void>>)>(pointer, 14)
            .asFunction<
                int Function(Pointer<Void>, Pointer<D3d12DescriptorHeapDesc>,
                    Pointer<Guid>, Pointer<Pointer<Void>>)>(),
        getDescriptorHandleIncrementSize =
            comMethod<Uint32 Function(Pointer<Void>, Uint32)>(pointer, 15)
                .asFunction<int Function(Pointer<Void>, int)>(),
        createRootSignature = comMethod<
                Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, IntPtr,
                    Pointer<Guid>, Pointer<Pointer<Void>>)>(pointer, 16)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<Void>, int,
                    Pointer<Guid>, Pointer<Pointer<Void>>)>(),
        createShaderResourceView = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>,
                    Pointer<D3d12ShaderResourceViewDesc>, IntPtr)>(pointer, 18)
            .asFunction<
                void Function(Pointer<Void>, Pointer<Void>,
                    Pointer<D3d12ShaderResourceViewDesc>, int)>(),
        createRenderTargetView = comMethod<
                Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
                    IntPtr)>(pointer, 20)
            .asFunction<
                void Function(
                    Pointer<Void>, Pointer<Void>, Pointer<Void>, int)>(),
        createCommittedResource = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<D3d12HeapProperties>,
                    Uint32,
                    Pointer<D3d12ResourceDesc>,
                    Uint32,
                    Pointer<Void>,
                    Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(pointer, 27)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<D3d12HeapProperties>,
                    int,
                    Pointer<D3d12ResourceDesc>,
                    int,
                    Pointer<Void>,
                    Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(),
        createFence = comMethod<
                Int32 Function(Pointer<Void>, Uint64, Uint32, Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(pointer, 36)
            .asFunction<
                int Function(Pointer<Void>, int, int, Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(),
        getDeviceRemovedReason =
            comMethod<Int32 Function(Pointer<Void>)>(pointer, 37)
                .asFunction<int Function(Pointer<Void>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>, Pointer<D3d12CommandQueueDesc>,
      Pointer<Guid>, Pointer<Pointer<Void>>) createCommandQueue;
  final int Function(Pointer<Void>, int, Pointer<Guid>, Pointer<Pointer<Void>>)
      createCommandAllocator;
  final int Function(Pointer<Void>, Pointer<D3d12GraphicsPipelineStateDesc>,
      Pointer<Guid>, Pointer<Pointer<Void>>) createGraphicsPipelineState;
  final int Function(Pointer<Void>, int, int, Pointer<Void>, Pointer<Void>,
      Pointer<Guid>, Pointer<Pointer<Void>>) createCommandList;
  final int Function(Pointer<Void>, Pointer<D3d12DescriptorHeapDesc>,
      Pointer<Guid>, Pointer<Pointer<Void>>) createDescriptorHeap;
  final int Function(Pointer<Void>, int) getDescriptorHandleIncrementSize;
  final int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Guid>,
      Pointer<Pointer<Void>>) createRootSignature;
  final void Function(Pointer<Void>, Pointer<Void>,
      Pointer<D3d12ShaderResourceViewDesc>, int) createShaderResourceView;
  final void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int)
      createRenderTargetView;
  final int Function(
      Pointer<Void>,
      Pointer<D3d12HeapProperties>,
      int,
      Pointer<D3d12ResourceDesc>,
      int,
      Pointer<Void>,
      Pointer<Guid>,
      Pointer<Pointer<Void>>) createCommittedResource;
  final int Function(
          Pointer<Void>, int, int, Pointer<Guid>, Pointer<Pointer<Void>>)
      createFence;

  /// `S_OK` while the device is alive; `DXGI_ERROR_DEVICE_REMOVED` and friends
  /// once it is not. The only way to tell a lost device from a bug.
  final int Function(Pointer<Void>) getDeviceRemovedReason;

  void release() => ComObject(pointer).release();
}

/// `ID3D12CommandQueue`. Slots: 7 inherited from ID3D12Object, +1 for
/// ID3D12DeviceChild's `GetDevice` = 8, then the queue's own.
final class D3d12CommandQueue {
  D3d12CommandQueue(this.pointer)
      : _executeCommandLists = comMethod<
                Void Function(
                    Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(pointer, 10)
            .asFunction<
                void Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>(),
        _signal =
            comMethod<Int32 Function(Pointer<Void>, Pointer<Void>, Uint64)>(
                    pointer, 14)
                .asFunction<int Function(Pointer<Void>, Pointer<Void>, int)>(),
        _wait = comMethod<Int32 Function(Pointer<Void>, Pointer<Void>, Uint64)>(
                pointer, 15)
            .asFunction<int Function(Pointer<Void>, Pointer<Void>, int)>();

  final Pointer<Void> pointer;
  final void Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      _executeCommandLists;
  final int Function(Pointer<Void>, Pointer<Void>, int) _signal;
  final int Function(Pointer<Void>, Pointer<Void>, int) _wait;

  void executeCommandLists(int count, Pointer<Pointer<Void>> lists) =>
      _executeCommandLists(pointer, count, lists);

  /// Asks the GPU to set [value] on [fence] *after* everything already
  /// submitted has finished. This is the only ordering primitive the frame
  /// ring needs, and the whole reason it is correct: the signal is queued
  /// behind the work, not executed when the CPU calls it.
  int signal(Pointer<Void> fence, int value) => _signal(pointer, fence, value);

  int wait(Pointer<Void> fence, int value) => _wait(pointer, fence, value);

  void release() => ComObject(pointer).release();
}

/// `ID3D12CommandAllocator`. Slot 8 is `Reset`.
final class D3d12CommandAllocator {
  D3d12CommandAllocator(this.pointer)
      : _reset = comMethod<Int32 Function(Pointer<Void>)>(pointer, 8)
            .asFunction<int Function(Pointer<Void>)>();

  final Pointer<Void> pointer;
  final int Function(Pointer<Void>) _reset;

  /// Frees the memory every command list recorded into this allocator.
  ///
  /// **Only legal once the GPU has finished executing all of them.** The
  /// runtime does not check, the debug layer only catches some cases, and the
  /// symptom of getting it wrong is a frame that draws last frame's geometry
  /// or nothing at all. `D3d12FrameRing` is the one place this is called from,
  /// and it waits on a fence first.
  int reset() => _reset(pointer);

  void release() => ComObject(pointer).release();
}

/// `ID3D12GraphicsCommandList`. Slots: 8 inherited (ID3D12DeviceChild) plus
/// `ID3D12CommandList::GetType` = 9, then the graphics methods.
final class D3d12GraphicsCommandList {
  D3d12GraphicsCommandList(this.pointer)
      : close = comMethod<Int32 Function(Pointer<Void>)>(pointer, 9)
            .asFunction<int Function(Pointer<Void>)>(),
        reset = comMethod<
                Int32 Function(
                    Pointer<Void>, Pointer<Void>, Pointer<Void>)>(pointer, 10)
            .asFunction<
                int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>(),
        drawIndexedInstanced = comMethod<
                Void Function(Pointer<Void>, Uint32, Uint32, Uint32, Int32,
                    Uint32)>(pointer, 13)
            .asFunction<
                void Function(Pointer<Void>, int, int, int, int, int)>(),
        copyTextureRegion = comMethod<
                Void Function(
                    Pointer<Void>,
                    Pointer<D3d12TextureCopyLocation>,
                    Uint32,
                    Uint32,
                    Uint32,
                    Pointer<D3d12TextureCopyLocation>,
                    Pointer<Void>)>(pointer, 16)
            .asFunction<
                void Function(
                    Pointer<Void>,
                    Pointer<D3d12TextureCopyLocation>,
                    int,
                    int,
                    int,
                    Pointer<D3d12TextureCopyLocation>,
                    Pointer<Void>)>(),
        iaSetPrimitiveTopology =
            comMethod<Void Function(Pointer<Void>, Uint32)>(pointer, 20)
                .asFunction<void Function(Pointer<Void>, int)>(),
        rsSetViewports = comMethod<
                Void Function(
                    Pointer<Void>, Uint32, Pointer<D3d12Viewport>)>(pointer, 21)
            .asFunction<
                void Function(Pointer<Void>, int, Pointer<D3d12Viewport>)>(),
        rsSetScissorRects =
            comMethod<Void Function(Pointer<Void>, Uint32, Pointer<D3d12Rect>)>(
                    pointer, 22)
                .asFunction<
                    void Function(Pointer<Void>, int, Pointer<D3d12Rect>)>(),
        setPipelineState =
            comMethod<Void Function(Pointer<Void>, Pointer<Void>)>(pointer, 25)
                .asFunction<void Function(Pointer<Void>, Pointer<Void>)>(),
        resourceBarrier = comMethod<
                Void Function(Pointer<Void>, Uint32,
                    Pointer<D3d12ResourceBarrier>)>(pointer, 26)
            .asFunction<
                void Function(
                    Pointer<Void>, int, Pointer<D3d12ResourceBarrier>)>(),
        setDescriptorHeaps = comMethod<
                Void Function(
                    Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(pointer, 28)
            .asFunction<
                void Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>(),
        setGraphicsRootSignature =
            comMethod<Void Function(Pointer<Void>, Pointer<Void>)>(pointer, 30)
                .asFunction<void Function(Pointer<Void>, Pointer<Void>)>(),
        setGraphicsRootDescriptorTable =
            comMethod<Void Function(Pointer<Void>, Uint32, Uint64)>(pointer, 32)
                .asFunction<void Function(Pointer<Void>, int, int)>(),
        setGraphicsRoot32BitConstants = comMethod<
                Void Function(Pointer<Void>, Uint32, Uint32, Pointer<Void>,
                    Uint32)>(pointer, 36)
            .asFunction<
                void Function(Pointer<Void>, int, int, Pointer<Void>, int)>(),
        iaSetIndexBuffer = comMethod<
                Void Function(
                    Pointer<Void>, Pointer<D3d12IndexBufferView>)>(pointer, 43)
            .asFunction<
                void Function(Pointer<Void>, Pointer<D3d12IndexBufferView>)>(),
        iaSetVertexBuffers = comMethod<
                Void Function(Pointer<Void>, Uint32, Uint32,
                    Pointer<D3d12VertexBufferView>)>(pointer, 44)
            .asFunction<
                void Function(
                    Pointer<Void>, int, int, Pointer<D3d12VertexBufferView>)>(),
        omSetRenderTargets = comMethod<
                Void Function(Pointer<Void>, Uint32, Pointer<IntPtr>, Int32,
                    Pointer<IntPtr>)>(pointer, 46)
            .asFunction<
                void Function(Pointer<Void>, int, Pointer<IntPtr>, int,
                    Pointer<IntPtr>)>(),
        clearRenderTargetView = comMethod<
                Void Function(Pointer<Void>, IntPtr, Pointer<Float>, Uint32,
                    Pointer<D3d12Rect>)>(pointer, 48)
            .asFunction<
                void Function(Pointer<Void>, int, Pointer<Float>, int,
                    Pointer<D3d12Rect>)>();

  final Pointer<Void> pointer;

  final int Function(Pointer<Void>) close;
  final int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>) reset;
  final void Function(Pointer<Void>, int, int, int, int, int)
      drawIndexedInstanced;
  final void Function(
      Pointer<Void>,
      Pointer<D3d12TextureCopyLocation>,
      int,
      int,
      int,
      Pointer<D3d12TextureCopyLocation>,
      Pointer<Void>) copyTextureRegion;
  final void Function(Pointer<Void>, int) iaSetPrimitiveTopology;
  final void Function(Pointer<Void>, int, Pointer<D3d12Viewport>)
      rsSetViewports;
  final void Function(Pointer<Void>, int, Pointer<D3d12Rect>) rsSetScissorRects;
  final void Function(Pointer<Void>, Pointer<Void>) setPipelineState;
  final void Function(Pointer<Void>, int, Pointer<D3d12ResourceBarrier>)
      resourceBarrier;
  final void Function(Pointer<Void>, int, Pointer<Pointer<Void>>)
      setDescriptorHeaps;
  final void Function(Pointer<Void>, Pointer<Void>) setGraphicsRootSignature;
  final void Function(Pointer<Void>, int, int) setGraphicsRootDescriptorTable;
  final void Function(Pointer<Void>, int, int, Pointer<Void>, int)
      setGraphicsRoot32BitConstants;
  final void Function(Pointer<Void>, Pointer<D3d12IndexBufferView>)
      iaSetIndexBuffer;
  final void Function(Pointer<Void>, int, int, Pointer<D3d12VertexBufferView>)
      iaSetVertexBuffers;
  final void Function(Pointer<Void>, int, Pointer<IntPtr>, int, Pointer<IntPtr>)
      omSetRenderTargets;
  final void Function(
          Pointer<Void>, int, Pointer<Float>, int, Pointer<D3d12Rect>)
      clearRenderTargetView;

  void release() => ComObject(pointer).release();
}

/// `ID3D12Fence`. Slots: 8 inherited, then the fence's own three.
final class D3d12Fence {
  D3d12Fence(this.pointer)
      : _getCompletedValue =
            comMethod<Uint64 Function(Pointer<Void>)>(pointer, 8)
                .asFunction<int Function(Pointer<Void>)>(),
        _setEventOnCompletion =
            comMethod<Int32 Function(Pointer<Void>, Uint64, IntPtr)>(pointer, 9)
                .asFunction<int Function(Pointer<Void>, int, int)>(),
        _signal = comMethod<Int32 Function(Pointer<Void>, Uint64)>(pointer, 10)
            .asFunction<int Function(Pointer<Void>, int)>();

  final Pointer<Void> pointer;
  final int Function(Pointer<Void>) _getCompletedValue;
  final int Function(Pointer<Void>, int, int) _setEventOnCompletion;
  final int Function(Pointer<Void>, int) _signal;

  /// The highest value the GPU has reached. Monotonic, and the only honest
  /// answer to "has the GPU finished with frame N".
  int get completedValue => _getCompletedValue(pointer);

  int setEventOnCompletion(int value, int event) =>
      _setEventOnCompletion(pointer, value, event);

  /// Sets the fence *from the CPU*, immediately. Not what a frame uses -
  /// see [D3d12CommandQueue.signal] - but exactly what proves that a wait
  /// blocks: a fence that nobody signals never completes.
  int signalFromCpu(int value) => _signal(pointer, value);

  void release() => ComObject(pointer).release();
}

/// `ID3D12DescriptorHeap`. Slots: 8 inherited, `GetDesc` at 8,
/// `GetCPUDescriptorHandleForHeapStart` at 9, the GPU one at 10.
///
/// ## Both handle getters use a hidden return pointer, and that was measured
///
/// The library comment above says an eight-byte aggregate comes back in RAX
/// under the x64 calling convention. That is the rule, and **these two methods
/// do not follow it**: the Direct3D 12 runtime shipped with Windows returns
/// `D3D12_CPU_DESCRIPTOR_HANDLE` and `D3D12_GPU_DESCRIPTOR_HANDLE` through a
/// caller-allocated buffer whose address is passed after `this` and returned
/// in RAX. It is the same divergence that makes MinGW and Wine carry explicit
/// wrappers for exactly these two methods, and it is why they are bound here
/// as `Pointer<Void> Function(this, out)` rather than as `IntPtr Function(this)`.
///
/// It was not assumed. Reading them as a plain return gave
/// `0x2ab09a391c9` - an address one past an eight-byte boundary, which no
/// descriptor handle can be, because RAX held the *uninitialised* register the
/// runtime had taken for the return buffer. Writing a descriptor to it
/// corrupted whatever it pointed at, and the symptom appeared at the next
/// unrelated call as `DXGI_ERROR_DEVICE_REMOVED` or an access violation inside
/// `d3d12.dll` - never at the call that was wrong. Reading them this way gives
/// an aligned address and a device that survives.
///
/// The neighbouring cases are different and are deliberately left alone:
/// `GetGPUVirtualAddress` and `GetCompletedValue` return
/// `D3D12_GPU_VIRTUAL_ADDRESS` and `UINT64`, which are *typedefs for an
/// integer* and not aggregates at all, so they really do come back in RAX.
final class D3d12DescriptorHeap {
  /// [returnSlot] is eight bytes of scratch the caller owns and keeps alive
  /// for as long as this heap. It exists because of the convention above: the
  /// runtime writes the handle through a pointer, so somebody has to provide
  /// one, and allocating it per call would put a heap round trip on the path
  /// that builds a render-target view.
  D3d12DescriptorHeap(this.pointer, this._returnSlot)
      : _cpuStart =
            comMethod<Pointer<Void> Function(Pointer<Void>, Pointer<Uint64>)>(
                    pointer, 9)
                .asFunction<
                    Pointer<Void> Function(Pointer<Void>, Pointer<Uint64>)>(),
        _gpuStart =
            comMethod<Pointer<Void> Function(Pointer<Void>, Pointer<Uint64>)>(
                    pointer, 10)
                .asFunction<
                    Pointer<Void> Function(Pointer<Void>, Pointer<Uint64>)>();

  final Pointer<Void> pointer;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Uint64>) _cpuStart;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Uint64>) _gpuStart;

  final Pointer<Uint64> _returnSlot;

  int get cpuHandleStart {
    _cpuStart(pointer, _returnSlot);
    return _returnSlot.value;
  }

  int get gpuHandleStart {
    _gpuStart(pointer, _returnSlot);
    return _returnSlot.value;
  }

  void release() => ComObject(pointer).release();
}

/// `ID3D12Resource`. Slots: 8 inherited, then Map, Unmap, GetDesc,
/// GetGPUVirtualAddress.
final class D3d12Resource {
  D3d12Resource(this.pointer)
      : _map = comMethod<
                Int32 Function(Pointer<Void>, Uint32, Pointer<D3d12Range>,
                    Pointer<Pointer<Void>>)>(pointer, 8)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<D3d12Range>,
                    Pointer<Pointer<Void>>)>(),
        _unmap = comMethod<
                Void Function(
                    Pointer<Void>, Uint32, Pointer<D3d12Range>)>(pointer, 9)
            .asFunction<
                void Function(Pointer<Void>, int, Pointer<D3d12Range>)>(),
        _gpuAddress = comMethod<Uint64 Function(Pointer<Void>)>(pointer, 11)
            .asFunction<int Function(Pointer<Void>)>();

  final Pointer<Void> pointer;
  final int Function(
      Pointer<Void>, int, Pointer<D3d12Range>, Pointer<Pointer<Void>>) _map;
  final void Function(Pointer<Void>, int, Pointer<D3d12Range>) _unmap;
  final int Function(Pointer<Void>) _gpuAddress;

  /// The virtual address the GPU sees. Only defined for buffers, which is why
  /// nothing here calls it on a texture.
  int get gpuVirtualAddress => _gpuAddress(pointer);

  /// Maps subresource 0.
  ///
  /// [readRange] is `nullptr` for "the CPU may read everything" and a
  /// zero-length range for "the CPU will not read". Passing the zero-length
  /// range on an upload buffer is not decoration: on a discrete adapter it is
  /// what lets the driver skip making the write-combined memory readable.
  int map(Pointer<D3d12Range> readRange, Pointer<Pointer<Void>> out) =>
      _map(pointer, 0, readRange, out);

  void unmap(Pointer<D3d12Range> writtenRange) =>
      _unmap(pointer, 0, writtenRange);

  void release() => ComObject(pointer).release();
}

/// `IDXGIFactory4`. Slots: IUnknown 3 + IDXGIObject 4 = 7, IDXGIFactory adds
/// 5 (to 12), IDXGIFactory1 adds 2 (to 14), IDXGIFactory2 adds 11 (to 25),
/// IDXGIFactory3 adds 1 (to 26), IDXGIFactory4 adds 2.
final class DxgiFactory4 {
  DxgiFactory4(this.pointer)
      : _makeWindowAssociation =
            comMethod<Int32 Function(Pointer<Void>, IntPtr, Uint32)>(pointer, 8)
                .asFunction<int Function(Pointer<Void>, int, int)>(),
        _enumAdapters1 = comMethod<
                Int32 Function(
                    Pointer<Void>, Uint32, Pointer<Pointer<Void>>)>(pointer, 12)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<Pointer<Void>>)>(),
        _createSwapChainForHwnd = comMethod<
                Int32 Function(
                    Pointer<Void>,
                    Pointer<Void>,
                    IntPtr,
                    Pointer<DxgiSwapChainDesc1>,
                    Pointer<Void>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>(pointer, 15)
            .asFunction<
                int Function(
                    Pointer<Void>,
                    Pointer<Void>,
                    int,
                    Pointer<DxgiSwapChainDesc1>,
                    Pointer<Void>,
                    Pointer<Void>,
                    Pointer<Pointer<Void>>)>();

  final Pointer<Void> pointer;
  final int Function(Pointer<Void>, int, int) _makeWindowAssociation;
  final int Function(Pointer<Void>, int, Pointer<Pointer<Void>>) _enumAdapters1;
  final int Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<DxgiSwapChainDesc1>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Void>>) _createSwapChainForHwnd;

  /// `DXGI_ERROR_NOT_FOUND` when [index] is past the last adapter, which is
  /// how enumeration terminates rather than an error.
  int enumAdapters1(int index, Pointer<Pointer<Void>> out) =>
      _enumAdapters1(pointer, index, out);

  /// Stops DXGI installing its own window hook for Alt+Enter. A framework that
  /// owns its window has to decide about full screen itself, and a hook that
  /// changes the swap chain behind the renderer's back is exactly the kind of
  /// invisible state change section 6.6 is about.
  int makeWindowAssociation(int windowHandle, int flags) =>
      _makeWindowAssociation(pointer, windowHandle, flags);

  /// The first argument is the *command queue*, not the device.
  ///
  /// That is Direct3D 12's own rule and the most commonly mis-ported line from
  /// Direct3D 11: the swap chain has to know which queue's work it is
  /// presenting, because the flip is ordered against that queue and nothing
  /// else.
  int createSwapChainForHwnd(
    Pointer<Void> commandQueue,
    int windowHandle,
    Pointer<DxgiSwapChainDesc1> desc,
    Pointer<Pointer<Void>> out,
  ) =>
      _createSwapChainForHwnd(
          pointer, commandQueue, windowHandle, desc, nullptr, nullptr, out);

  void release() => ComObject(pointer).release();
}

/// `IDXGIAdapter1`. Slots: 7 inherited, EnumOutputs 7, GetDesc 8,
/// CheckInterfaceSupport 9, GetDesc1 10.
final class DxgiAdapter1 {
  DxgiAdapter1(this.pointer)
      : _getDesc1 =
            comMethod<Int32 Function(Pointer<Void>, Pointer<DxgiAdapterDesc1>)>(
                    pointer, 10)
                .asFunction<
                    int Function(Pointer<Void>, Pointer<DxgiAdapterDesc1>)>();

  final Pointer<Void> pointer;
  final int Function(Pointer<Void>, Pointer<DxgiAdapterDesc1>) _getDesc1;

  int getDesc1(Pointer<DxgiAdapterDesc1> out) => _getDesc1(pointer, out);

  void release() => ComObject(pointer).release();
}

/// `IDXGISwapChain3`. Slots: 7 inherited + GetDevice = 8, IDXGISwapChain adds
/// 10 (to 18), IDXGISwapChain1 adds 11 (to 29), IDXGISwapChain2 adds 7 (to
/// 36), then IDXGISwapChain3's own.
final class DxgiSwapChain3 {
  DxgiSwapChain3(this.pointer)
      : _present =
            comMethod<Int32 Function(Pointer<Void>, Uint32, Uint32)>(pointer, 8)
                .asFunction<int Function(Pointer<Void>, int, int)>(),
        _getBuffer = comMethod<
                Int32 Function(Pointer<Void>, Uint32, Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(pointer, 9)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<Guid>,
                    Pointer<Pointer<Void>>)>(),
        _resizeBuffers = comMethod<
                Int32 Function(Pointer<Void>, Uint32, Uint32, Uint32, Uint32,
                    Uint32)>(pointer, 13)
            .asFunction<int Function(Pointer<Void>, int, int, int, int, int)>(),
        _currentBackBufferIndex =
            comMethod<Uint32 Function(Pointer<Void>)>(pointer, 36)
                .asFunction<int Function(Pointer<Void>)>();

  final Pointer<Void> pointer;
  final int Function(Pointer<Void>, int, int) _present;
  final int Function(Pointer<Void>, int, Pointer<Guid>, Pointer<Pointer<Void>>)
      _getBuffer;
  final int Function(Pointer<Void>, int, int, int, int, int) _resizeBuffers;
  final int Function(Pointer<Void>) _currentBackBufferIndex;

  int present(int syncInterval, int flags) =>
      _present(pointer, syncInterval, flags);

  int getBuffer(int index, Pointer<Guid> iid, Pointer<Pointer<Void>> out) =>
      _getBuffer(pointer, index, iid, out);

  /// Every reference to every back buffer must be released before this, and
  /// the GPU must be idle. Both are the caller's job; see
  /// `D3d12WindowTarget.resize`, which is the only caller.
  int resizeBuffers(
    int bufferCount,
    int width,
    int height,
    int format,
    int flags,
  ) =>
      _resizeBuffers(pointer, bufferCount, width, height, format, flags);

  /// Which buffer the next frame must be drawn into.
  ///
  /// Under the flip model this advances on every [present] and is the *only*
  /// correct source for the index; a counter kept alongside it drifts the
  /// first time a present is skipped or fails.
  int get currentBackBufferIndex => _currentBackBufferIndex(pointer);

  void release() => ComObject(pointer).release();
}

/// `ID3D12Debug`. Slot 3 is the only method.
final class D3d12Debug {
  D3d12Debug(this.pointer)
      : _enableDebugLayer = comMethod<Void Function(Pointer<Void>)>(pointer, 3)
            .asFunction<void Function(Pointer<Void>)>();

  final Pointer<Void> pointer;
  final void Function(Pointer<Void>) _enableDebugLayer;

  /// Must be called **before** the device is created. A debug layer switched
  /// on afterwards applies to nothing.
  void enableDebugLayer() => _enableDebugLayer(pointer);

  void release() => ComObject(pointer).release();
}

/// `ID3D12InfoQueue`, the debug layer's message store.
///
/// Slots: IUnknown 3, then SetMessageCountLimit, ClearStoredMessages,
/// GetMessage, and three counters before `GetNumStoredMessages` at 8.
final class D3d12InfoQueue {
  D3d12InfoQueue(this.pointer)
      : _clearStoredMessages =
            comMethod<Void Function(Pointer<Void>)>(pointer, 4)
                .asFunction<void Function(Pointer<Void>)>(),
        _getMessage = comMethod<
                Int32 Function(Pointer<Void>, Uint64, Pointer<D3d12Message>,
                    Pointer<IntPtr>)>(pointer, 5)
            .asFunction<
                int Function(Pointer<Void>, int, Pointer<D3d12Message>,
                    Pointer<IntPtr>)>(),
        _getNumStoredMessages =
            comMethod<Uint64 Function(Pointer<Void>)>(pointer, 8)
                .asFunction<int Function(Pointer<Void>)>();

  final Pointer<Void> pointer;
  final void Function(Pointer<Void>) _clearStoredMessages;
  final int Function(Pointer<Void>, int, Pointer<D3d12Message>, Pointer<IntPtr>)
      _getMessage;
  final int Function(Pointer<Void>) _getNumStoredMessages;

  void clearStoredMessages() => _clearStoredMessages(pointer);

  int get storedMessageCount => _getNumStoredMessages(pointer);

  int getMessage(
    int index,
    Pointer<D3d12Message> message,
    Pointer<IntPtr> byteLength,
  ) =>
      _getMessage(pointer, index, message, byteLength);

  void release() => ComObject(pointer).release();
}
