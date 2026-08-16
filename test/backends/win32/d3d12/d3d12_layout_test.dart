/// The Direct3D 12 structures, checked against the x64 ABI by arithmetic.
///
/// None of this needs a GPU, a driver or a device: `sizeOf` and
/// `offsetOf`-by-construction are computed by the Dart FFI layout engine from
/// the declarations alone. It is still gated on Windows, for the reason the
/// library comment of `d3d12_structs.dart` records: every test this backend
/// adds has to skip with a declared reason on the Linux and macOS runners.
///
/// ## Why offsets and not only sizes
///
/// A wrong size is a missing or extra field and `sizeOf` finds it. A field at
/// the wrong *offset* inside a union that was flattened by hand is invisible
/// to `sizeOf`, and this file has already had one: the `Texture2D` arm of
/// `D3D12_SHADER_RESOURCE_VIEW_DESC` started four bytes early because the
/// union is eight-byte aligned, and the struct came to 40 bytes either way.
/// The runtime read `MipLevels` where `MostDetailedMip` was written, got a
/// mip count of zero, and removed the device - several calls later, so the
/// error named a call that was innocent.
///
/// So the four flattened unions are checked field by field, by writing a
/// distinct value into each field and reading the struct back as raw bytes.
/// That is the only check that would have caught the bug above.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_com.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_structs.dart';
import 'package:test/test.dart';

/// Null on Windows; the reason to skip everywhere else.
final String? _skip = Platform.isWindows
    ? null
    : 'the Direct3D 12 structure layouts are asserted against the Windows x64 '
        'ABI and are only meaningful on a Windows host';

void main() {
  group('every structure is the size the x64 ABI requires', () {
    // The numbers come from the Windows SDK headers, computed by the ABI's own
    // rules: fields in declaration order, each aligned to its own width, the
    // whole padded to its widest member.
    const Map<String, int> expected = <String, int>{
      'Guid': 16,
      'DXGI_SAMPLE_DESC': 8,
      'DXGI_SWAP_CHAIN_DESC1': 48,
      // 128 wide chars, four UINTs, three SIZE_Ts, a LUID and a UINT, padded
      // from 308 to 312 by the eight-byte alignment the SIZE_Ts impose.
      'DXGI_ADAPTER_DESC1': 312,
      'D3D12_COMMAND_QUEUE_DESC': 16,
      'D3D12_DESCRIPTOR_HEAP_DESC': 16,
      'D3D12_HEAP_PROPERTIES': 20,
      // The UINT64 Alignment after a UINT Dimension is what makes this 56 and
      // not 48; the four bytes of padding at offset 4 are load-bearing.
      'D3D12_RESOURCE_DESC': 56,
      'D3D12_RESOURCE_BARRIER': 32,
      'D3D12_VIEWPORT': 24,
      'D3D12_RECT': 16,
      'D3D12_VERTEX_BUFFER_VIEW': 16,
      'D3D12_INDEX_BUFFER_VIEW': 16,
      'D3D12_RANGE': 16,
      'D3D12_SHADER_BYTECODE': 16,
      'D3D12_STREAM_OUTPUT_DESC': 32,
      'D3D12_RENDER_TARGET_BLEND_DESC': 40,
      'D3D12_BLEND_DESC': 328,
      'D3D12_RASTERIZER_DESC': 44,
      'D3D12_DEPTH_STENCILOP_DESC': 16,
      'D3D12_DEPTH_STENCIL_DESC': 52,
      'D3D12_INPUT_ELEMENT_DESC': 32,
      'D3D12_INPUT_LAYOUT_DESC': 16,
      'D3D12_CACHED_PIPELINE_STATE': 16,
      'D3D12_GRAPHICS_PIPELINE_STATE_DESC': 656,
      'D3D12_DESCRIPTOR_RANGE': 20,
      'D3D12_ROOT_PARAMETER': 32,
      'D3D12_STATIC_SAMPLER_DESC': 52,
      'D3D12_ROOT_SIGNATURE_DESC': 40,
      'D3D12_SHADER_RESOURCE_VIEW_DESC': 40,
      'D3D12_SUBRESOURCE_FOOTPRINT': 20,
      'D3D12_PLACED_SUBRESOURCE_FOOTPRINT': 32,
      'D3D12_TEXTURE_COPY_LOCATION': 48,
      'D3D12_MESSAGE': 32,
    };

    final Map<String, int> actual = <String, int>{
      'Guid': sizeOf<Guid>(),
      'DXGI_SAMPLE_DESC': sizeOf<DxgiSampleDesc>(),
      'DXGI_SWAP_CHAIN_DESC1': sizeOf<DxgiSwapChainDesc1>(),
      'DXGI_ADAPTER_DESC1': sizeOf<DxgiAdapterDesc1>(),
      'D3D12_COMMAND_QUEUE_DESC': sizeOf<D3d12CommandQueueDesc>(),
      'D3D12_DESCRIPTOR_HEAP_DESC': sizeOf<D3d12DescriptorHeapDesc>(),
      'D3D12_HEAP_PROPERTIES': sizeOf<D3d12HeapProperties>(),
      'D3D12_RESOURCE_DESC': sizeOf<D3d12ResourceDesc>(),
      'D3D12_RESOURCE_BARRIER': sizeOf<D3d12ResourceBarrier>(),
      'D3D12_VIEWPORT': sizeOf<D3d12Viewport>(),
      'D3D12_RECT': sizeOf<D3d12Rect>(),
      'D3D12_VERTEX_BUFFER_VIEW': sizeOf<D3d12VertexBufferView>(),
      'D3D12_INDEX_BUFFER_VIEW': sizeOf<D3d12IndexBufferView>(),
      'D3D12_RANGE': sizeOf<D3d12Range>(),
      'D3D12_SHADER_BYTECODE': sizeOf<D3d12ShaderBytecode>(),
      'D3D12_STREAM_OUTPUT_DESC': sizeOf<D3d12StreamOutputDesc>(),
      'D3D12_RENDER_TARGET_BLEND_DESC': sizeOf<D3d12RenderTargetBlendDesc>(),
      'D3D12_BLEND_DESC': sizeOf<D3d12BlendDesc>(),
      'D3D12_RASTERIZER_DESC': sizeOf<D3d12RasterizerDesc>(),
      'D3D12_DEPTH_STENCILOP_DESC': sizeOf<D3d12DepthStencilOpDesc>(),
      'D3D12_DEPTH_STENCIL_DESC': sizeOf<D3d12DepthStencilDesc>(),
      'D3D12_INPUT_ELEMENT_DESC': sizeOf<D3d12InputElementDesc>(),
      'D3D12_INPUT_LAYOUT_DESC': sizeOf<D3d12InputLayoutDesc>(),
      'D3D12_CACHED_PIPELINE_STATE': sizeOf<D3d12CachedPipelineState>(),
      'D3D12_GRAPHICS_PIPELINE_STATE_DESC':
          sizeOf<D3d12GraphicsPipelineStateDesc>(),
      'D3D12_DESCRIPTOR_RANGE': sizeOf<D3d12DescriptorRange>(),
      'D3D12_ROOT_PARAMETER': sizeOf<D3d12RootParameter>(),
      'D3D12_STATIC_SAMPLER_DESC': sizeOf<D3d12StaticSamplerDesc>(),
      'D3D12_ROOT_SIGNATURE_DESC': sizeOf<D3d12RootSignatureDesc>(),
      'D3D12_SHADER_RESOURCE_VIEW_DESC': sizeOf<D3d12ShaderResourceViewDesc>(),
      'D3D12_SUBRESOURCE_FOOTPRINT': sizeOf<D3d12SubresourceFootprint>(),
      'D3D12_PLACED_SUBRESOURCE_FOOTPRINT':
          sizeOf<D3d12PlacedSubresourceFootprint>(),
      'D3D12_TEXTURE_COPY_LOCATION': sizeOf<D3d12TextureCopyLocation>(),
      'D3D12_MESSAGE': sizeOf<D3d12Message>(),
    };

    test('all of them, compared in one map', () {
      // One expectation rather than thirty-four, so a drifted struct shows the
      // whole table and the reader can see which neighbours moved with it.
      expect(actual, expected);
    }, skip: _skip);
  });

  group('the flattened unions put their fields where the union does', () {
    test('D3D12_SHADER_RESOURCE_VIEW_DESC keeps its Texture2D arm at 16', () {
      // The bug this whole file exists for. The union's widest member starts
      // with a UINT64, so it is eight-byte aligned and begins at offset 16 -
      // not at 12, where the third UINT ends. Both layouts are 40 bytes.
      final _Scratch scratch = _Scratch(sizeOf<D3d12ShaderResourceViewDesc>());
      final Pointer<D3d12ShaderResourceViewDesc> desc =
          scratch.pointer.cast<D3d12ShaderResourceViewDesc>();
      desc.ref
        ..format = 0x11111111
        ..viewDimension = 0x22222222
        ..shader4ComponentMapping = 0x33333333
        ..mostDetailedMip = 0x44444444
        ..mipLevels = 0x55555555
        ..planeSlice = 0x66666666;

      expect(scratch.wordAt(0), 0x11111111, reason: 'Format');
      expect(scratch.wordAt(4), 0x22222222, reason: 'ViewDimension');
      expect(scratch.wordAt(8), 0x33333333, reason: 'Shader4ComponentMapping');
      expect(scratch.wordAt(12), 0,
          reason: 'the four bytes that align the union to eight must stay '
              'padding; a field here is the whole bug');
      expect(scratch.wordAt(16), 0x44444444, reason: 'MostDetailedMip');
      expect(scratch.wordAt(20), 0x55555555, reason: 'MipLevels');
      expect(scratch.wordAt(24), 0x66666666, reason: 'PlaneSlice');
      scratch.free();
    }, skip: _skip);

    test('D3D12_RESOURCE_BARRIER puts the transition arm at 8', () {
      final _Scratch scratch = _Scratch(sizeOf<D3d12ResourceBarrier>());
      final Pointer<D3d12ResourceBarrier> barrier =
          scratch.pointer.cast<D3d12ResourceBarrier>();
      barrier.ref
        ..type = 0x11111111
        ..flags = 0x22222222
        ..resource = Pointer<Void>.fromAddress(0x3333333344444444)
        ..subresource = 0x55555555
        ..stateBefore = 0x66666666
        ..stateAfter = 0x77777777;

      expect(scratch.wordAt(0), 0x11111111, reason: 'Type');
      expect(scratch.wordAt(4), 0x22222222, reason: 'Flags');
      // The union is pointer-aligned, so pResource lands at 8 with no padding
      // between it and Flags.
      expect(scratch.wordAt(8), 0x44444444, reason: 'pResource low half');
      expect(scratch.wordAt(12), 0x33333333, reason: 'pResource high half');
      expect(scratch.wordAt(16), 0x55555555, reason: 'Subresource');
      expect(scratch.wordAt(20), 0x66666666, reason: 'StateBefore');
      expect(scratch.wordAt(24), 0x77777777, reason: 'StateAfter');
      scratch.free();
    }, skip: _skip);

    test('D3D12_ROOT_PARAMETER overlays both arms on the same 16 bytes', () {
      // The union at offset 8 is 16 bytes wide. A descriptor table writes
      // NumDescriptorRanges at 8 and pDescriptorRanges at 16; root constants
      // write ShaderRegister at 8, RegisterSpace at 12 and Num32BitValues at
      // 16. Both are the same struct with different meanings, which is exactly
      // what the flattening claims.
      final _Scratch scratch = _Scratch(sizeOf<D3d12RootParameter>());
      final Pointer<D3d12RootParameter> parameter =
          scratch.pointer.cast<D3d12RootParameter>();
      parameter.ref
        ..parameterType = 0x11111111
        ..field8 = 0x22222222
        ..fieldC = 0x33333333
        ..field10 = 0x4444444455555555
        ..shaderVisibility = 0x66666666;

      expect(scratch.wordAt(0), 0x11111111, reason: 'ParameterType');
      expect(scratch.wordAt(4), 0, reason: 'padding before the union');
      expect(scratch.wordAt(8), 0x22222222);
      expect(scratch.wordAt(12), 0x33333333);
      expect(scratch.wordAt(16), 0x55555555, reason: 'union low half');
      expect(scratch.wordAt(20), 0x44444444, reason: 'union high half');
      expect(scratch.wordAt(24), 0x66666666, reason: 'ShaderVisibility');
      scratch.free();
    }, skip: _skip);

    test('D3D12_TEXTURE_COPY_LOCATION overlays footprint and index at 16', () {
      // A subresource index occupies the first four bytes of the union, which
      // is where the little-endian UINT64 `offset` of the placed footprint
      // starts - so writing the index into `offset` writes it where the
      // runtime reads it. That equivalence is what the upload path relies on.
      final _Scratch scratch = _Scratch(sizeOf<D3d12TextureCopyLocation>());
      final Pointer<D3d12TextureCopyLocation> location =
          scratch.pointer.cast<D3d12TextureCopyLocation>();
      location.ref
        ..resource = Pointer<Void>.fromAddress(0x1111111122222222)
        ..type = 0x33333333;
      location.ref.placedFootprint.offset = 7;
      location.ref.placedFootprint.footprint
        ..format = 0x44444444
        ..width = 0x55555555
        ..height = 0x66666666
        ..depth = 0x77777777
        ..rowPitch = 0x08888888;

      expect(scratch.wordAt(0), 0x22222222, reason: 'pResource low half');
      expect(scratch.wordAt(8), 0x33333333, reason: 'Type');
      expect(scratch.wordAt(16), 7,
          reason: 'Offset low half, which is also SubresourceIndex');
      expect(scratch.wordAt(20), 0, reason: 'Offset high half');
      expect(scratch.wordAt(24), 0x44444444, reason: 'Footprint.Format');
      expect(scratch.wordAt(28), 0x55555555, reason: 'Footprint.Width');
      expect(scratch.wordAt(32), 0x66666666, reason: 'Footprint.Height');
      expect(scratch.wordAt(36), 0x77777777, reason: 'Footprint.Depth');
      expect(scratch.wordAt(40), 0x08888888, reason: 'Footprint.RowPitch');
      scratch.free();
    }, skip: _skip);
  });

  group('the helpers the layouts depend on', () {
    test('alignUp rounds to the API constants and leaves multiples alone', () {
      expect(alignUp(0, d3d12TextureDataPitchAlignment), 0);
      expect(alignUp(1, d3d12TextureDataPitchAlignment), 256);
      expect(alignUp(256, d3d12TextureDataPitchAlignment), 256);
      expect(alignUp(257, d3d12TextureDataPitchAlignment), 512);
      expect(alignUp(513, d3d12TextureDataPlacementAlignment), 1024);
    }, skip: _skip);

    test('writeGuid parses the form the headers spell an IID in', () {
      final _Scratch scratch = _Scratch(sizeOf<Guid>());
      final Pointer<Guid> guid = scratch.pointer.cast<Guid>();
      // ID3D12Device's IID, with the braces the headers use, so the parser is
      // checked on the form that is actually pasted out of a header.
      writeGuid(guid, '{189819f1-1db6-4b57-be54-1821339b85f7}');
      expect(guid.ref.data1, 0x189819f1);
      expect(guid.ref.data2, 0x1db6);
      expect(guid.ref.data3, 0x4b57);
      expect(<int>[for (var i = 0; i < 8; i++) guid.ref.data4[i]],
          <int>[0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7]);
      scratch.free();
    }, skip: _skip);

    test('a mistyped IID throws at the constant instead of at the call', () {
      final _Scratch scratch = _Scratch(sizeOf<Guid>());
      expect(
        () => writeGuid(scratch.pointer.cast<Guid>(), '189819f1-1db6-4b57'),
        throwsArgumentError,
      );
      scratch.free();
    }, skip: _skip);

    test('hresultText names the codes a graphics backend meets', () {
      // Hex, because that is how the codes are documented; Dart prints the
      // sign-extended negative, which is unsearchable.
      expect(hresultText(0), '0x00000000');
      expect(hresultText(0x887A0005.toSigned(32)),
          '0x887A0005 (DXGI_ERROR_DEVICE_REMOVED)');
      expect(comFailed(0), isFalse);
      // S_FALSE succeeds and several DXGI calls return it, which is why the
      // test is the sign bit and not `hr != 0`.
      expect(comFailed(1), isFalse);
      expect(comFailed(0x80004005.toSigned(32)), isTrue);
    }, skip: _skip);
  });
}

/// Zeroed native scratch, read back as little-endian 32-bit words.
///
/// `calloc` would come from `package:ffi`, which this framework does not
/// depend on; a typed list handed to `Pointer.fromAddress` is not legal
/// either, because Dart does not pin it. So the bytes come from a native
/// allocation and are read through a `Uint8List` view of it.
final class _Scratch {
  _Scratch(this.byteCount) : pointer = _allocateZeroed(byteCount);

  final int byteCount;
  final Pointer<Uint8> pointer;

  Uint8List get bytes => pointer.asTypedList(byteCount);

  int wordAt(int offset) =>
      ByteData.sublistView(bytes).getUint32(offset, Endian.little);

  void free() => _free(pointer);

  static final DynamicLibrary _kernel = DynamicLibrary.open('kernel32.dll');
  static final int _heap = _kernel
      .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap')();
  static final Pointer<Void> Function(int, int, int) _alloc =
      _kernel.lookupFunction<Pointer<Void> Function(IntPtr, Uint32, IntPtr),
          Pointer<Void> Function(int, int, int)>('HeapAlloc');
  static final int Function(int, int, Pointer<Void>) _release =
      _kernel.lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Void>),
          int Function(int, int, Pointer<Void>)>('HeapFree');

  static Pointer<Uint8> _allocateZeroed(int byteCount) =>
      _alloc(_heap, 0x8 /* HEAP_ZERO_MEMORY */, byteCount).cast<Uint8>();

  static void _free(Pointer<Uint8> pointer) =>
      _release(_heap, 0, pointer.cast<Void>());
}
