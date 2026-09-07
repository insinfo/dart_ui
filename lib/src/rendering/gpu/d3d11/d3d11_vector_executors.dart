/// Approaches B and C on Direct3D 11: a retained tessellated mesh and a
/// stencil-then-cover pass.
///
/// `gl_tessellated_executor.dart` and `gl_stencil_cover_executor.dart` are the
/// reference, and the *policy* here is theirs verbatim - the same
/// backend-neutral [TessellatedPathMesh] and [StencilCoverDrawPlan], the same
/// least-recently-used byte budget over retained meshes, the same command walk
/// over a plan. What differs is everything about how the state gets set, and
/// the differences are not cosmetic. They are written down here because each
/// one is a place where a literal transliteration of the GL code compiles,
/// runs, and draws the wrong picture.
///
/// ## Difference 1: there is no `glColorMask`
///
/// GL's stencil executor turns colour writes off for the clear and the
/// accumulation with `glColorMask(0,0,0,0)` - a piece of output-merger state
/// independent of blending. Direct3D 11 has no such call. The colour write mask
/// is `RenderTargetWriteMask`, a **field of the blend state**, so a pass that
/// wants to accumulate winding without touching colour has to bind a *different
/// blend state object*. That is why [D3d11VectorPipeline] caches blend states
/// keyed by `(blendMode, colorWrites)` rather than by blend mode alone, and why
/// the accumulation binds one at all when it is drawing nothing visible.
///
/// ## Difference 2: `ClearDepthStencilView` ignores the scissor
///
/// `StencilCoverCapabilities.scissoredClear` exists because a stencil clear
/// that ignored its rectangle would wipe winding another draw in the same
/// submission still depends on. GL satisfies it by clearing under
/// `GL_SCISSOR_TEST`. D3D11's `ClearDepthStencilView` takes no rectangle and no
/// write mask: it writes every texel of the view.
///
/// So the clear here is **a draw**, not a clear: a quad over the group's
/// rectangle with `StencilPassOp = REPLACE`, the reference value the plan asked
/// for, and `StencilWriteMask` set to the group's mask. That honours both
/// halves of the contract the API call cannot - the rectangle and the mask -
/// and it is why [D3d11StencilCoverExecutor] uploads a third block of geometry
/// the GL executor has no equivalent of. The alternative, a full-view clear, is
/// correct only as long as no plan ever holds two draws whose windings overlap
/// in time, which is a property of the recorder rather than of this file and is
/// exactly the kind of invariant that gets broken silently.
///
/// ## Difference 3: winding, and why the rasteriser state says nothing about it
///
/// The non-zero fill accumulates `INCR_WRAP` on front faces and `DECR_WRAP` on
/// back faces, so "front" has to mean the same thing it means on GL or the sign
/// of every winding number flips and a non-zero fill draws its own complement.
/// GL sets `glFrontFace(GL_CW)` for its default (surface) orientation because
/// its window space is y-up while device space is y-down, so the projection
/// inverts the winding once. D3D11's window space is y-down like device space,
/// the projection flips clip y and the viewport transform flips it back, and
/// the net effect is that a triangle with positive signed area in device space
/// is clockwise on the render target - which is D3D11's *default* front face
/// (`FrontCounterClockwise = FALSE`). The two backends therefore agree, and
/// they agree by two different routes; setting `FrontCounterClockwise` here to
/// "match GL's `GL_CW`" would be reasoning about the wrong space and would
/// invert every non-zero fill.
///
/// ## Difference 4: one program instead of two
///
/// See `kD3d11VectorShaderSource`. Both routes consume a position-only vertex
/// and write one premultiplied colour, so they share a program, an input layout
/// and a constant buffer, and approach C sets the local-to-target rows to the
/// identity because its plan has already flattened into target space.
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../ffi/com.dart';
import '../../../ffi/native_memory.dart';
import '../../../foundation/diagnostics.dart';
import '../../../geometry/rect.dart';
import '../../../geometry/transform2d.dart';
import '../../../graphics/display_list_opcodes.dart';
import '../gpu_pipeline.dart';
import '../vector/cpu_tessellation.dart';
import '../vector/stencil_cover_draw_plan.dart';
import 'd3d11_bindings.dart';
import 'd3d11_shaders.dart';

/// A premultiplied solid paint for either promoted route.
///
/// One class for both, where GL has `TessellatedGlMaterial` and
/// `StencilGlMaterial`, because on this backend the two routes really do share
/// a pixel shader: the split on GL is an artefact of two files having grown
/// separately, and duplicating it here would duplicate the validation as well.
final class D3d11VectorMaterial {
  D3d11VectorMaterial({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
    this.blendMode = blendModeSrcOver,
  }) {
    for (final (String, double) channel in <(String, double)>[
      ('red', red),
      ('green', green),
      ('blue', blue),
      ('alpha', alpha),
    ]) {
      if (!channel.$2.isFinite || channel.$2 < 0 || channel.$2 > 1) {
        throw ArgumentError.value(channel.$2, channel.$1, 'must be 0..1');
      }
    }
    if (red > alpha || green > alpha || blue > alpha) {
      throw ArgumentError('colour channels must be premultiplied by alpha');
    }
    // Validated here rather than at draw time for the reason the recorder is
    // transactional: a blend mode this backend cannot express must refuse the
    // promotion before any earlier command of the frame has been issued.
    gpuBlendForMode(blendMode);
  }

  final double red;
  final double green;
  final double blue;
  final double alpha;
  final int blendMode;
}

/// The program, buffers and state objects approaches B and C share.
///
/// Owned by the device and created only when at least one of the two routes was
/// asked for, so a default build compiles one HLSL program exactly as it always
/// did and allocates none of this. Rebuilt whole after a device loss, like
/// every other pipeline object here: the COM pointers below belong to an
/// `ID3D11Device` that a removal has already destroyed.
final class D3d11VectorPipeline {
  D3d11VectorPipeline._(this._device, this._context, this._objects);

  /// Builds the pipeline, or returns the [BackendDiagnostic] that says what the
  /// driver refused.
  ///
  /// A diagnostic rather than a throw, because this runs inside device
  /// creation, where every other failure is reported the same way and a throw
  /// would take the whole backend selection down with it.
  static Object create({
    required D3d11Device device,
    required D3d11DeviceContext context,
    required D3dCompileFn compile,
  }) {
    final arena = NativeArena();
    final bag = ComBag();
    final pipeline = D3d11VectorPipeline._(device, context, bag);
    try {
      final Object vertex = _compile(
        compile,
        arena,
        kD3d11VectorProfileVertex,
        kD3d11VectorVertexEntryPoint,
      );
      if (vertex is BackendDiagnostic) return vertex;
      final Object pixel = _compile(
        compile,
        arena,
        kD3d11VectorProfilePixel,
        kD3d11VectorPixelEntryPoint,
      );
      if (pixel is BackendDiagnostic) {
        (vertex as D3dBlob).dispose();
        return pixel;
      }
      final vertexBlob = vertex as D3dBlob;
      final pixelBlob = pixel as D3dBlob;
      try {
        final BackendDiagnostic? failure =
            pipeline._build(arena, vertexBlob, pixelBlob);
        if (failure != null) return failure;
      } finally {
        vertexBlob.dispose();
        pixelBlob.dispose();
      }
      return pipeline;
    } on Object catch (error) {
      pipeline.dispose();
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the Direct3D 11 vector pipeline could not be built',
        detail: '$error',
      );
    } finally {
      arena.dispose();
    }
  }

  final D3d11Device _device;
  final D3d11DeviceContext _context;
  final ComBag _objects;

  /// Long-lived native scratch. One arena for the life of the pipeline so a
  /// frame performs no native allocation, which is the rule the rest of this
  /// backend already keeps.
  final NativeArena _arena = NativeArena();

  /// Scratch for one native descriptor at a time.
  ///
  /// 512 bytes, and the size is load-bearing rather than generous: the largest
  /// structure written here is `D3D11_BLEND_DESC`, which is two `BOOL`s plus
  /// **eight** 32-byte render-target descriptors - [sizeOfBlendDesc], 264
  /// bytes. A 256-byte block is eight bytes short of that, and the eight bytes
  /// it overruns land in whatever the arena handed out next; the symptom is not
  /// a wrong picture but a Dart heap that crashes minutes later, in an
  /// unrelated iteration, with no way back to this line.
  late final Pointer<Uint8> _desc = _arena.allocate<Uint8>(512);
  late final Pointer<Pointer<Void>> _out = _arena.allocateOutPointer();
  late final Pointer<Pointer<Void>> _slot = _arena.allocateOutPointer();
  // Byte counts, not element counts - `NativeArena.allocate` takes bytes, and
  // an array of four floats asked for as `allocate<Float>(4)` is one float with
  // three neighbours' worth of somebody else's memory after it. That mistake is
  // silent: the blend factors written past the end land in the arena's next
  // block and surface as a Dart heap crash in an unrelated iteration.
  late final Pointer<Uint32> _uint = _arena.allocate<Uint32>(16);
  late final Pointer<Uint32> _uintB = _arena.allocate<Uint32>(16);
  late final Pointer<Float> _float4 = _arena.allocate<Float>(16);
  late final Pointer<Uint8> _constants =
      _arena.allocate<Uint8>(kD3d11VectorConstantBytes);
  late final Pointer<Uint8> _mapped =
      _arena.allocate<Uint8>(sizeOfMappedSubresource);

  ComObject? _vertexShader;
  ComObject? _pixelShader;
  ComObject? _inputLayout;
  ComObject? _rasterizerState;
  ComObject? _constantBuffer;

  /// Blend state by `blendMode * 2 + (colorWrites ? 1 : 0)`. See difference 1.
  final Map<int, ComObject> _blendStates = <int, ComObject>{};

  /// Depth-stencil state by the packed key [_stencilKey] builds.
  final Map<int, ComObject> _stencilStates = <int, ComObject>{};

  /// The one dynamic vertex buffer both routes stream through.
  ///
  /// Approach C uploads a whole plan into it per submission; approach B uses it
  /// for nothing, because a retained mesh is the point of approach B and lives
  /// in its own immutable buffer.
  ComObject? _streamBuffer;
  int _streamBufferBytes = 0;

  /// Host staging for an upload, grown on demand and never shrunk.
  Pointer<Uint8> _staging = nullptr;
  int _stagingBytes = 0;

  bool _disposed = false;

  bool get isDisposed => _disposed;

  D3d11Device get device => _device;
  D3d11DeviceContext get context => _context;

  BackendDiagnostic? _build(
    NativeArena arena,
    D3dBlob vertexBlob,
    D3dBlob pixelBlob,
  ) {
    final int vsHr = hresult(_device.createVertexShader(
      _device.pointer,
      vertexBlob.bufferPointer,
      vertexBlob.bufferSize,
      nullptr,
      _out,
    ));
    if (failed(vsHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'CreateVertexShader refused the vector bytecode',
        detail: hresultName(vsHr),
      );
    }
    _vertexShader = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11VertexShader'));

    final int psHr = hresult(_device.createPixelShader(
      _device.pointer,
      pixelBlob.bufferPointer,
      pixelBlob.bufferSize,
      nullptr,
      _out,
    ));
    if (failed(psHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'CreatePixelShader refused the vector bytecode',
        detail: hresultName(psHr),
      );
    }
    _pixelShader = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11PixelShader'));

    // One element: `float2 POSITION0` at offset 0, tightly packed. Both routes
    // hand the input assembler exactly this and nothing else, which is what
    // makes the two-float stride below a fact rather than a convention.
    final Pointer<Uint8> element =
        arena.allocate<Uint8>(sizeOfInputElementDesc);
    element.cast<IntPtr>()[0] = arena.allocateAscii('POSITION').address;
    final fields = Pointer<Uint32>.fromAddress(element.address + 8);
    fields[0] = 0; // SemanticIndex
    fields[1] = dxgiFormatR32G32Float;
    fields[2] = 0; // InputSlot
    fields[3] = 0; // AlignedByteOffset
    fields[4] = d3d11InputPerVertexData;
    fields[5] = 0; // InstanceDataStepRate
    final int layoutHr = hresult(_device.createInputLayout(
      _device.pointer,
      element.cast(),
      1,
      vertexBlob.bufferPointer,
      vertexBlob.bufferSize,
      _out,
    ));
    if (failed(layoutHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the vector input layout does not match the vertex shader',
        detail: '${hresultName(layoutHr)}; the layout is one float2 POSITION0',
      );
    }
    _inputLayout = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11InputLayout'));

    final desc = _desc.cast<Uint32>();
    desc[0] = kD3d11VectorConstantBytes;
    desc[1] = d3d11UsageDefault;
    desc[2] = d3d11BindConstantBuffer;
    desc[3] = 0;
    desc[4] = 0;
    desc[5] = 0;
    final int cbHr = hresult(
        _device.createBuffer(_device.pointer, _desc.cast(), nullptr, _out));
    if (failed(cbHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the vector constant buffer could not be created',
        detail: hresultName(cbHr),
      );
    }
    _constantBuffer =
        _objects.keep(ComObject(_out.value, interfaceName: 'ID3D11Buffer'));

    // Scissoring on, culling off, and both for the reasons the dense state
    // gives. `MultisampleEnable` is the one that differs: it is TRUE here
    // because these are the only passes this backend runs against a
    // multisampled target, and while in Direct3D 10 and later it selects a line
    // antialiasing algorithm rather than enabling MSAA - the sample count of
    // the render target does that - declaring it keeps the intent readable.
    final rast = _desc.cast<Uint32>();
    rast[0] = d3d11FillSolid;
    rast[1] = d3d11CullNone;
    rast[2] = 0; // FrontCounterClockwise; see difference 3.
    rast[3] = 0; // DepthBias
    _desc.cast<Float>()[4] = 0; // DepthBiasClamp
    _desc.cast<Float>()[5] = 0; // SlopeScaledDepthBias
    rast[6] = 1; // DepthClipEnable
    rast[7] = 1; // ScissorEnable
    rast[8] = 1; // MultisampleEnable
    rast[9] = 0; // AntialiasedLineEnable
    final int rsHr = hresult(
        _device.createRasterizerState(_device.pointer, _desc.cast(), _out));
    if (failed(rsHr)) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: 'the vector rasterizer state could not be created',
        detail: hresultName(rsHr),
      );
    }
    _rasterizerState = _objects
        .keep(ComObject(_out.value, interfaceName: 'ID3D11RasterizerState'));
    return null;
  }

  static Object _compile(
    D3dCompileFn compile,
    NativeArena arena,
    String profile,
    String entryPoint,
  ) {
    final Pointer<Uint8> source = arena.allocateAscii(kD3d11VectorShaderSource);
    final Pointer<Pointer<Void>> code = arena.allocateOutPointer();
    final Pointer<Pointer<Void>> errors = arena.allocateOutPointer();
    final int hr = hresult(compile(
      source,
      kD3d11VectorShaderSource.length,
      arena.allocateAscii('dart_ui_d3d11_vector.hlsl'),
      nullptr,
      nullptr,
      arena.allocateAscii(entryPoint),
      arena.allocateAscii(profile),
      d3dCompilePackMatrixRowMajor |
          d3dCompileEnableStrictness |
          d3dCompileOptimizationLevel3,
      0,
      code,
      errors,
    ));
    String message = '';
    if (errors.value != nullptr) {
      final blob = D3dBlob(errors.value);
      message = blob.asText;
      blob.dispose();
    }
    if (failed(hr) || code.value == nullptr) {
      return BackendDiagnostic(
        kind: DiagnosticKind.incompatibleDevice,
        message: '$entryPoint failed to compile as $profile',
        detail: '${hresultName(hr)}: $message',
      );
    }
    return D3dBlob(code.value);
  }

  // -------------------------------------------------------------------
  // Per-pass state
  // -------------------------------------------------------------------

  int _viewportWidth = 0;
  int _viewportHeight = 0;
  int _scissorLeft = -1;
  int _scissorTop = -1;
  int _scissorRight = -1;
  int _scissorBottom = -1;
  int _boundBlendKey = -1;
  int _boundStencilKey = -1;
  int _boundStencilRef = -1;

  /// Binds the shared program for a pass into a [viewportWidth] x
  /// [viewportHeight] target.
  ///
  /// The caller has already bound the render target and its depth-stencil view:
  /// approach C needs a DSV and approach B must not have one, and only the
  /// device knows which target a pass is going into.
  void beginPass({required int viewportWidth, required int viewportHeight}) {
    _throwIfDisposed();
    if (viewportWidth <= 0 || viewportHeight <= 0) {
      throw ArgumentError('viewport must be positive');
    }
    _viewportWidth = viewportWidth;
    _viewportHeight = viewportHeight;
    _forgetPassState();
    final view = _desc.cast<Float>();
    view[0] = 0;
    view[1] = 0;
    view[2] = viewportWidth.toDouble();
    view[3] = viewportHeight.toDouble();
    view[4] = 0;
    view[5] = 1;
    _slot.value = _constantBuffer!.pointer;
    _context
      ..rsSetViewports(_context.pointer, 1, _desc.cast())
      ..iaSetInputLayout(_context.pointer, _inputLayout!.pointer)
      ..iaSetPrimitiveTopology(
          _context.pointer, d3d11PrimitiveTopologyTriangleList)
      ..vsSetShader(_context.pointer, _vertexShader!.pointer, nullptr, 0)
      ..psSetShader(_context.pointer, _pixelShader!.pointer, nullptr, 0)
      ..rsSetState(_context.pointer, _rasterizerState!.pointer)
      ..vsSetConstantBuffers(_context.pointer, 0, 1, _slot)
      ..psSetConstantBuffers(_context.pointer, 0, 1, _slot);
    // The whole register file, before any command of this pass can draw.
    //
    // This is where GL sets `uViewport`, and skipping it here is the bug that
    // cost the longest to find. Approach C only writes the constant buffer for
    // its **cover** command - the clear and the accumulation draw no colour, so
    // there is nothing per-draw for them to say - and on the *first* pass of a
    // process that leaves the buffer holding whatever `CreateBuffer` left
    // there. The viewport read by the vertex shader is then garbage, the
    // accumulation projects its triangles off-screen, the stencil plane stays
    // zero, and the cover quad is masked away: the route draws **nothing at
    // all**, once, on the first frame of every device, and is exact for ever
    // afterwards because by then the buffer holds the previous frame's values.
    // A frame-one-only failure is the worst shape a bug can have, so the fix is
    // to make the pass, not the draw, responsible for the registers that belong
    // to the pass.
    _writeConstants(Transform2D.identity, 0, 0, 0, 0);
  }

  /// Releases the state this pass held that a following dense range would
  /// inherit wrongly.
  ///
  /// Only the depth-stencil state, and only because it is the one piece the
  /// dense pipeline never sets: `D3d11RenderDevice._bindPipeline` rebinds the
  /// input layout, the buffers, both shaders, the rasteriser and the constant
  /// buffer, and `_drawBatches` rebinds the blend state on its first batch. A
  /// stencil state left enabled would make every following dense batch pass a
  /// stencil test against whatever this pass accumulated - a dense frame that
  /// draws holes where a promoted path was.
  void endPass() {
    _throwIfDisposed();
    disableDepthStencil();
    _forgetPassState();
  }

  /// Forgets what this pass believes is bound.
  ///
  /// [_boundStencilKey] goes to [_stencilStateUnknown] and **not** to
  /// [_stencilStateOff]: those are different claims, and confusing them is a
  /// missing shape. `-1` means "the depth-off state is bound", which is what
  /// [endPass] leaves behind and what lets a following [disableDepthStencil]
  /// skip a redundant call. At the start of a pass nothing is known - on the
  /// first pass of a device nothing has ever bound a depth-stencil state, so
  /// Direct3D's default is in force and the default has `DepthEnable = TRUE`.
  /// A cache that claimed "off" there would let [disableDepthStencil] return
  /// without binding anything, and approach B would be depth-tested against a
  /// plane nothing wrote.
  void _forgetPassState() {
    _scissorLeft = -1;
    _scissorTop = -1;
    _scissorRight = -1;
    _scissorBottom = -1;
    _boundBlendKey = -1;
    _boundStencilKey = _stencilStateUnknown;
    _boundStencilRef = -1;
  }

  /// Cache key of the depth-and-stencil-off state. Never produced by
  /// [_stencilKey], which is a non-negative bit packing.
  static const int _stencilStateOff = -1;

  /// "Nothing is known about the bound depth-stencil state."
  static const int _stencilStateUnknown = -2;

  /// Writes the constant register file: viewport, transform rows and colour.
  void setConstants(Transform2D localToTarget, D3d11VectorMaterial material) =>
      _writeConstants(localToTarget, material.red, material.green,
          material.blue, material.alpha);

  void _writeConstants(
    Transform2D localToTarget,
    double red,
    double green,
    double blue,
    double alpha,
  ) {
    final values = _constants.cast<Float>();
    values[0] = _viewportWidth.toDouble();
    values[1] = _viewportHeight.toDouble();
    values[2] = 0;
    values[3] = 0;
    values[4] = localToTarget.a;
    values[5] = localToTarget.c;
    values[6] = localToTarget.tx;
    values[7] = 0;
    values[8] = localToTarget.b;
    values[9] = localToTarget.d;
    values[10] = localToTarget.ty;
    values[11] = 0;
    values[12] = red;
    values[13] = green;
    values[14] = blue;
    values[15] = alpha;
    _context.updateSubresource(_context.pointer, _constantBuffer!.pointer, 0,
        nullptr, _constants.cast(), 0, 0);
  }

  /// Restricts everything after it to the outward-rounded [bounds].
  ///
  /// Outward, and clamped to the viewport, exactly as `StencilCoverGlScissor`
  /// rounds: a cover quad's rectangle is fractional, and rounding inward would
  /// clip the very fringe pixels these routes exist to produce. There is no
  /// `viewportHeight - bottom` here - D3D11's scissor origin is the top-left
  /// corner, which is where device space starts too.
  void setScissor(Rect bounds) {
    final int left = bounds.left.floor().clamp(0, _viewportWidth);
    final int right = bounds.right.ceil().clamp(0, _viewportWidth);
    final int top = bounds.top.floor().clamp(0, _viewportHeight);
    final int bottom = bounds.bottom.ceil().clamp(0, _viewportHeight);
    if (left == _scissorLeft &&
        top == _scissorTop &&
        right == _scissorRight &&
        bottom == _scissorBottom) {
      return;
    }
    _scissorLeft = left;
    _scissorTop = top;
    _scissorRight = right;
    _scissorBottom = bottom;
    final rect = _desc.cast<Int32>();
    rect[0] = left;
    rect[1] = top;
    rect[2] = math.max(left, right);
    rect[3] = math.max(top, bottom);
    _context.rsSetScissorRects(_context.pointer, 1, _desc.cast());
  }

  /// Binds blending for [blendMode], writing colour only when [colorWrites].
  void setBlend(int blendMode, {required bool colorWrites}) {
    final int key = blendMode * 2 + (colorWrites ? 1 : 0);
    if (key == _boundBlendKey) return;
    _boundBlendKey = key;
    final ComObject state = _blendStateFor(blendMode, colorWrites, key);
    for (var i = 0; i < 4; i++) {
      _float4[i] = 0;
    }
    _context.omSetBlendState(
        _context.pointer, state.pointer, _float4, 0xFFFFFFFF);
  }

  /// Turns the depth and stencil tests off entirely.
  ///
  /// Not the same as binding the null state, and the difference is a whole
  /// missing shape. `OMSetDepthStencilState(nullptr, 0)` restores Direct3D's
  /// *default* descriptor, which is `DepthEnable = TRUE`, `DepthWriteMask =
  /// ALL` and `DepthFunc = LESS` - so a pass with a depth-stencil view bound
  /// and depth never cleared rejects every fragment whose `z` is not strictly
  /// less than whatever the allocator left in the buffer. Approach B writes
  /// `z = 0`, so with the default state and an uncleared view it draws exactly
  /// nothing, silently, and the frame looks like a route that was never taken.
  void disableDepthStencil() {
    const int key = _stencilStateOff;
    if (key == _boundStencilKey && _boundStencilRef == 0) return;
    _boundStencilKey = key;
    _boundStencilRef = 0;
    ComObject? state = _stencilStates[key];
    if (state == null) {
      final desc = _desc.cast<Uint32>();
      for (var i = 0; i < sizeOfDepthStencilDesc ~/ 4; i++) {
        desc[i] = 0;
      }
      desc[2] = d3d11ComparisonAlways; // DepthFunc must name a legal enum.
      desc[8] = d3d11ComparisonAlways; // FrontFace.StencilFunc, likewise.
      desc[12] = d3d11ComparisonAlways; // BackFace.StencilFunc.
      desc[5] = d3d11StencilOpKeep;
      desc[6] = d3d11StencilOpKeep;
      desc[7] = d3d11StencilOpKeep;
      desc[9] = d3d11StencilOpKeep;
      desc[10] = d3d11StencilOpKeep;
      desc[11] = d3d11StencilOpKeep;
      checkHresult(
        _device.createDepthStencilState(_device.pointer, _desc.cast(), _out),
        'ID3D11Device::CreateDepthStencilState(off)',
      );
      state = ComObject(_out.value, interfaceName: 'ID3D11DepthStencilState');
      _objects.keep(state);
      _stencilStates[key] = state;
    }
    _context.omSetDepthStencilState(_context.pointer, state.pointer, 0);
  }

  /// Binds the stencil test and write rules [state] describes.
  ///
  /// [referenceOverride] is how the clear-by-quad gets its value in: a clear's
  /// [StencilCoverPassState] carries `clearValue` and `StencilOperation.keep`,
  /// because on GL the clear is a `glClear` and not a draw. Here it is a draw
  /// with `REPLACE`, so the value has to become the stencil reference.
  void setStencil(
    StencilCoverPassState state, {
    bool replaceWithClearValue = false,
  }) {
    final int reference = replaceWithClearValue
        ? (state.clearValue ?? 0)
        : switch (state.compare) {
            StencilCompare.always => 0,
            StencilCompare.notEqualZero => 0,
            StencilCompare.leastSignificantBitSet => 1,
          };
    final int key = _stencilKey(state, replaceWithClearValue);
    if (key == _boundStencilKey && reference == _boundStencilRef) return;
    _boundStencilKey = key;
    _boundStencilRef = reference;
    _context.omSetDepthStencilState(
      _context.pointer,
      _stencilStateFor(state, replaceWithClearValue, key).pointer,
      reference,
    );
  }

  /// Uploads [floats] into the streaming vertex buffer and binds it.
  ///
  /// One `Map`/`Unmap` per submission with `MAP_WRITE_DISCARD`, which is what
  /// makes the buffer dynamic: the driver hands back fresh memory and keeps
  /// reading the previous contents for any draw still in flight, so a
  /// per-submission upload never stalls the pipeline. Returns false when the
  /// map failed, which on this API means the device was removed.
  bool uploadStream(Float32List floats, int floatCount) {
    _throwIfDisposed();
    final int bytes = floatCount * 4;
    if (!_ensureStreamBuffer(bytes)) return false;
    final Pointer<Uint8> mapped = _mapWrite(_streamBuffer!);
    if (mapped == nullptr) return false;
    mapped
        .cast<Float>()
        .asTypedList(floatCount)
        .setRange(0, floatCount, floats);
    _context.unmap(_context.pointer, _streamBuffer!.pointer, 0);
    bindVertexBuffer(_streamBuffer!);
    return true;
  }

  void bindVertexBuffer(ComObject buffer) {
    _slot.value = buffer.pointer;
    _uint[0] = kD3d11VectorVertexStrideBytes;
    _uintB[0] = 0;
    _context.iaSetVertexBuffers(_context.pointer, 0, 1, _slot, _uint, _uintB);
  }

  void draw({required int firstVertex, required int vertexCount}) {
    if (vertexCount <= 0) return;
    _context.draw(_context.pointer, vertexCount, firstVertex);
  }

  void drawIndexed({
    required ComObject indexBuffer,
    required int indexCount,
  }) {
    _context
      ..iaSetIndexBuffer(
          _context.pointer, indexBuffer.pointer, dxgiFormatR32Uint, 0)
      ..drawIndexed(_context.pointer, indexCount, 0, 0);
  }

  /// An immutable vertex or index buffer holding [bytes] from [source].
  ///
  /// `D3D11_USAGE_IMMUTABLE`, which is the whole point of approach B on this
  /// API: a retained mesh is never written again, so the driver is free to put
  /// it wherever it reads fastest. A dynamic buffer would be re-uploaded and
  /// re-orphaned on the frame nothing changed.
  ComObject? createImmutableBuffer(
    TypedData source,
    int bytes,
    int bindFlags,
  ) {
    _throwIfDisposed();
    if (bytes <= 0) return null;
    final Pointer<Uint8> staging = _ensureStaging(bytes);
    staging.asTypedList(bytes).setAll(
          0,
          source.buffer.asUint8List(source.offsetInBytes, bytes),
        );
    final desc = _desc.cast<Uint32>();
    desc[0] = bytes;
    desc[1] = d3d11UsageImmutable;
    desc[2] = bindFlags;
    desc[3] = 0;
    desc[4] = 0;
    desc[5] = 0;
    final Pointer<Uint8> initial =
        Pointer<Uint8>.fromAddress(_desc.address + 64);
    initial.cast<IntPtr>()[0] = staging.address;
    Pointer<Uint32>.fromAddress(initial.address + 8)[0] = 0;
    Pointer<Uint32>.fromAddress(initial.address + 12)[0] = 0;
    final int hr = hresult(_device.createBuffer(
        _device.pointer, _desc.cast(), initial.cast(), _out));
    if (failed(hr) || _out.value == nullptr) return null;
    return ComObject(_out.value, interfaceName: 'ID3D11Buffer');
  }

  ComObject _blendStateFor(int blendMode, bool colorWrites, int key) {
    final ComObject? cached = _blendStates[key];
    if (cached != null) return cached;
    final GpuBlendState blend = gpuBlendForMode(blendMode);
    final desc = _desc.cast<Uint32>();
    for (var i = 0; i < sizeOfBlendDesc ~/ 4; i++) {
      desc[i] = 0;
    }
    const int rt0 = 8 ~/ 4;
    desc[rt0 + 0] = 1; // BlendEnable
    desc[rt0 + 1] = _blendFactor(blend.source);
    desc[rt0 + 2] = _blendFactor(blend.destination);
    desc[rt0 + 3] = d3d11BlendOpAdd;
    desc[rt0 + 4] = _blendFactor(blend.source);
    desc[rt0 + 5] = _blendFactor(blend.destination);
    desc[rt0 + 6] = d3d11BlendOpAdd;
    // The half GL spells `glColorMask`. Zero means the accumulation and the
    // clear rasterise, update stencil, and touch no colour at all.
    desc[rt0 + 7] = colorWrites ? d3d11ColorWriteEnableAll : 0;
    checkHresult(
      _device.createBlendState(_device.pointer, _desc.cast(), _out),
      'ID3D11Device::CreateBlendState(vector)',
    );
    final state = ComObject(_out.value, interfaceName: 'ID3D11BlendState');
    _objects.keep(state);
    _blendStates[key] = state;
    return state;
  }

  static int _stencilKey(StencilCoverPassState state, bool replace) =>
      (replace ? 1 : 0) |
      (state.compare.index << 1) |
      (state.frontPass.index << 4) |
      (state.backPass.index << 8) |
      ((state.compareMask & 0xFF) << 12) |
      ((state.writeMask & 0xFF) << 20);

  ComObject _stencilStateFor(
    StencilCoverPassState state,
    bool replace,
    int key,
  ) {
    final ComObject? cached = _stencilStates[key];
    if (cached != null) return cached;
    final desc = _desc.cast<Uint32>();
    for (var i = 0; i < sizeOfDepthStencilDesc ~/ 4; i++) {
      desc[i] = 0;
    }
    // Depth is allocated because `D24_UNORM_S8_UINT` carries it and is never
    // tested: a 2D renderer orders by submission, and a depth test here would
    // be a second, silent ordering nothing asked for. `DepthFunc` still has to
    // name a legal enum or the debug layer rejects the descriptor.
    desc[0] = 0; // DepthEnable
    desc[1] = d3d11DepthWriteMaskZero;
    desc[2] = d3d11ComparisonAlways;
    desc[3] = 1; // StencilEnable
    // StencilReadMask and StencilWriteMask are `UINT8`s sharing one word, and
    // writing either of them as a `UINT` would clobber the other.
    final masks = Pointer<Uint8>.fromAddress(_desc.address + 16);
    masks[0] = state.compareMask & 0xFF;
    masks[1] = state.writeMask & 0xFF;
    masks[2] = 0;
    masks[3] = 0;
    final int comparison = switch (state.compare) {
      StencilCompare.always => d3d11ComparisonAlways,
      StencilCompare.notEqualZero => d3d11ComparisonNotEqual,
      StencilCompare.leastSignificantBitSet => d3d11ComparisonEqual,
    };
    final int front =
        replace ? d3d11StencilOpReplace : _stencilOp(state.frontPass);
    final int back =
        replace ? d3d11StencilOpReplace : _stencilOp(state.backPass);
    // FrontFace at byte 20, BackFace at 36; each is fail, depth-fail, pass,
    // func. The depth test is disabled so it always passes, but the depth-fail
    // slot still has to hold a legal operation.
    desc[5] = front;
    desc[6] = front;
    desc[7] = front;
    desc[8] = comparison;
    desc[9] = back;
    desc[10] = back;
    desc[11] = back;
    desc[12] = comparison;
    checkHresult(
      _device.createDepthStencilState(_device.pointer, _desc.cast(), _out),
      'ID3D11Device::CreateDepthStencilState',
    );
    final object =
        ComObject(_out.value, interfaceName: 'ID3D11DepthStencilState');
    _objects.keep(object);
    _stencilStates[key] = object;
    return object;
  }

  bool _ensureStreamBuffer(int bytes) {
    if (_streamBuffer != null && bytes <= _streamBufferBytes) return true;
    _streamBuffer?.dispose();
    _streamBuffer = null;
    _streamBufferBytes = bytes < 4096 ? 4096 : bytes * 2;
    final desc = _desc.cast<Uint32>();
    desc[0] = _streamBufferBytes;
    desc[1] = d3d11UsageDynamic;
    desc[2] = d3d11BindVertexBuffer;
    desc[3] = d3d11CpuAccessWrite;
    desc[4] = 0;
    desc[5] = 0;
    final int hr = hresult(
        _device.createBuffer(_device.pointer, _desc.cast(), nullptr, _out));
    if (failed(hr) || _out.value == nullptr) {
      _streamBufferBytes = 0;
      return false;
    }
    _streamBuffer = ComObject(_out.value, interfaceName: 'ID3D11Buffer');
    return true;
  }

  Pointer<Uint8> _mapWrite(ComObject resource) {
    final int hr = hresult(_context.map(_context.pointer, resource.pointer, 0,
        d3d11MapWriteDiscard, 0, _mapped.cast()));
    if (failed(hr)) return nullptr;
    return Pointer<Uint8>.fromAddress(_mapped.cast<IntPtr>()[0]);
  }

  /// Host staging, doubled on demand.
  ///
  /// The previous block is abandoned rather than freed because a [NativeArena]
  /// releases in one go and its `free` is a no-op by design - see
  /// `native_memory.dart`. Doubling keeps that bounded: a pipeline that ever
  /// uploads N bytes has abandoned less than N in total over its whole life,
  /// and the arena hands all of it back when the device does.
  Pointer<Uint8> _ensureStaging(int bytes) {
    if (bytes <= _stagingBytes) return _staging;
    _stagingBytes = math.max(4096, bytes * 2);
    return _staging = _arena.allocate<Uint8>(_stagingBytes);
  }

  /// Releases every COM reference and forgets the caches.
  ///
  /// Released, not merely forgotten, and that is the same choice
  /// [D3d11RenderDevice.discardNativeResources] argues for at length: `Release`
  /// is the one call that still works on an object whose device was removed -
  /// it is how the refcount reaches zero and the memory is freed - so skipping
  /// it would leak the whole vector pipeline on every reset, and a device that
  /// resets four times before the CPU fallback would hold four of them for the
  /// life of the process.
  ///
  /// Clearing the caches is the other half: a rebuilt pipeline must not be able
  /// to hand out a state object that belonged to the dead device.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _streamBuffer?.dispose();
    _streamBuffer = null;
    _streamBufferBytes = 0;
    _blendStates.clear();
    _stencilStates.clear();
    _vertexShader = null;
    _pixelShader = null;
    _inputLayout = null;
    _rasterizerState = null;
    _constantBuffer = null;
    _objects.dispose();
    _arena.dispose();
    _staging = nullptr;
    _stagingBytes = 0;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the Direct3D 11 vector pipeline is disposed');
    }
  }

  static int _blendFactor(GpuBlendFactor factor) => switch (factor) {
        GpuBlendFactor.zero => d3d11BlendZero,
        GpuBlendFactor.one => d3d11BlendOne,
        GpuBlendFactor.oneMinusSrcAlpha => d3d11BlendInvSrcAlpha,
      };

  static int _stencilOp(StencilOperation operation) => switch (operation) {
        StencilOperation.keep => d3d11StencilOpKeep,
        StencilOperation.zero => d3d11StencilOpZero,
        StencilOperation.incrementWrap => d3d11StencilOpIncrementWrap,
        StencilOperation.decrementWrap => d3d11StencilOpDecrementWrap,
        StencilOperation.invertLeastSignificantBit => d3d11StencilOpInvert,
      };
}

/// Bytes one position-only vertex occupies. Two floats, tightly packed.
const int kD3d11VectorVertexStrideBytes = 8;

/// Shader profiles for the vector program. Feature level 10.0, like the dense
/// one, and for the same reason: nothing here is above Shader Model 4.
const String kD3d11VectorProfileVertex = 'vs_4_0';
const String kD3d11VectorProfilePixel = 'ps_4_0';

/// GPU buffers retained for one tessellated mesh.
final class D3d11MeshHandle {
  const D3d11MeshHandle({
    required this.vertexBuffer,
    required this.indexBuffer,
    required this.indexCount,
    required this.retainedBytes,
  });

  final ComObject vertexBuffer;
  final ComObject indexBuffer;
  final int indexCount;
  final int retainedBytes;

  void dispose() {
    vertexBuffer.dispose();
    indexBuffer.dispose();
  }
}

/// What one submission of either route actually issued.
final class D3d11VectorExecutionStats {
  const D3d11VectorExecutionStats({
    this.drawCalls = 0,
    this.triangles = 0,
    this.uploadedMeshes = 0,
    this.uploadedBytes = 0,
    this.evictedMeshes = 0,
    this.clearCommands = 0,
    this.coverDraws = 0,
  });

  final int drawCalls;
  final int triangles;
  final int uploadedMeshes;
  final int uploadedBytes;
  final int evictedMeshes;
  final int clearCommands;
  final int coverDraws;
}

/// Approach B: retained CPU-tessellated meshes in immutable vertex buffers.
///
/// The inventory bound and its least-recently-used eviction are
/// `TessellatedGlExecutor`'s, argument for argument - a mesh is keyed by path
/// content, so a subtree whose geometry is rebuilt every frame uploads and
/// abandons a pair every frame, and the budget is in bytes because an icon and
/// a map outline differ by three orders of magnitude.
final class D3d11TessellatedExecutor {
  D3d11TessellatedExecutor(
    this._pipeline, {
    this.maxRetainedBytes = kD3d11DefaultRetainedMeshBytes,
  }) : assert(maxRetainedBytes > 0);

  final D3d11VectorPipeline _pipeline;
  final int maxRetainedBytes;

  /// Key to buffers, in least-recently-used order: a `Map` iterates in
  /// insertion order in Dart, so a hit removes and re-inserts and the first key
  /// is always the coldest.
  final Map<TessellatedPathCacheKey, D3d11MeshHandle> _meshes =
      <TessellatedPathCacheKey, D3d11MeshHandle>{};
  int _retainedBytes = 0;
  int _evictionCount = 0;
  bool _disposed = false;

  int get retainedMeshCount => _meshes.length;
  int get retainedBytes => _retainedBytes;
  int get evictionCount => _evictionCount;

  /// Draws [mesh] with [material] into the currently bound target.
  ///
  /// The caller has bound the render target and called
  /// [D3d11VectorPipeline.beginPass]; this sets only what differs per draw.
  D3d11VectorExecutionStats submit(
    TessellatedPathMesh mesh, {
    required D3d11VectorMaterial material,
    required Transform2D localToTarget,
    required Rect clip,
  }) {
    _throwIfDisposed();
    if (mesh.vertices.length.isOdd || mesh.indices.length % 3 != 0) {
      throw ArgumentError('tessellated mesh storage is malformed');
    }
    if (mesh.indices.isEmpty) return const D3d11VectorExecutionStats();
    _validateTransform(localToTarget);

    D3d11MeshHandle? handle = _meshes.remove(mesh.cacheKey);
    var uploadedMeshes = 0;
    var uploadedBytes = 0;
    if (handle == null) {
      final int vertexCount = mesh.vertices.length ~/ 2;
      if (vertexCount == 0 ||
          mesh.vertices.any((double value) => !value.isFinite) ||
          mesh.indices.any((int index) => index >= vertexCount)) {
        throw ArgumentError('tessellated mesh contains invalid vertices');
      }
      uploadedBytes = mesh.vertices.lengthInBytes + mesh.indices.lengthInBytes;
      final ComObject? vertexBuffer = _pipeline.createImmutableBuffer(
        mesh.vertices,
        mesh.vertices.lengthInBytes,
        d3d11BindVertexBuffer,
      );
      if (vertexBuffer == null) return const D3d11VectorExecutionStats();
      final ComObject? indexBuffer = _pipeline.createImmutableBuffer(
        mesh.indices,
        mesh.indices.lengthInBytes,
        d3d11BindIndexBuffer,
      );
      if (indexBuffer == null) {
        vertexBuffer.dispose();
        return const D3d11VectorExecutionStats();
      }
      handle = D3d11MeshHandle(
        vertexBuffer: vertexBuffer,
        indexBuffer: indexBuffer,
        indexCount: mesh.indices.length,
        retainedBytes: uploadedBytes,
      );
      uploadedMeshes = 1;
      _retainedBytes += uploadedBytes;
    }
    // Re-inserted after the lookup so a hit counts as the most recent use.
    _meshes[mesh.cacheKey] = handle;
    final int evicted = _evictToBudget(keep: mesh.cacheKey);

    _pipeline
      ..setConstants(localToTarget, material)
      ..setScissor(clip)
      // A tessellated mesh writes colour and reads no stencil. Binding the
      // null depth-stencil state is not tidiness: this pass may follow one of
      // approach C's inside the same layer, and D3D11 keeps the last bound
      // state until something replaces it.
      ..setBlend(material.blendMode, colorWrites: true)
      // Explicitly off, not merely unset. This pass may follow one of approach
      // C's inside the same layer, and Direct3D keeps the last bound state
      // until something replaces it - and the state that "replaces it with
      // nothing" turns the depth test back *on*. See [disableDepthStencil].
      ..disableDepthStencil()
      ..bindVertexBuffer(handle.vertexBuffer)
      ..drawIndexed(
        indexBuffer: handle.indexBuffer,
        indexCount: handle.indexCount,
      );
    return D3d11VectorExecutionStats(
      drawCalls: 1,
      triangles: handle.indexCount ~/ 3,
      uploadedMeshes: uploadedMeshes,
      uploadedBytes: uploadedBytes,
      evictedMeshes: evicted,
    );
  }

  /// Deletes coldest-first until the budget holds, never [keep].
  ///
  /// Releasing the buffers a draw is one line away from binding would be a
  /// use-after-free; one frame over budget is not.
  int _evictToBudget({required TessellatedPathCacheKey keep}) {
    var evicted = 0;
    while (_retainedBytes > maxRetainedBytes && _meshes.length > 1) {
      final TessellatedPathCacheKey coldest = _meshes.keys.first;
      if (coldest == keep) break;
      final D3d11MeshHandle stale = _meshes.remove(coldest)!;
      _retainedBytes -= stale.retainedBytes;
      stale.dispose();
      _evictionCount++;
      evicted++;
    }
    return evicted;
  }

  /// Releases every retained buffer.
  ///
  /// These are the only GPU allocations in this backend that no `ComBag` owns -
  /// the executor holds the `ID3D11Buffer`s directly - so this is the only
  /// place they can be freed, on a device loss as much as on a dispose. See
  /// [D3d11VectorPipeline.dispose] for why a removal still releases.
  void clearRetainedMeshes() {
    for (final D3d11MeshHandle mesh in _meshes.values) {
      mesh.dispose();
    }
    _meshes.clear();
    _retainedBytes = 0;
  }

  void dispose() {
    if (_disposed) return;
    clearRetainedMeshes();
    _disposed = true;
  }

  static void _validateTransform(Transform2D transform) {
    if (<double>[
      transform.a,
      transform.b,
      transform.c,
      transform.d,
      transform.tx,
      transform.ty,
    ].any((double value) => !value.isFinite)) {
      throw ArgumentError.value(transform, 'localToTarget', 'must be finite');
    }
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the Direct3D 11 tessellated executor is disposed');
    }
  }
}

/// Default GPU budget for retained meshes: 8 MiB, as on OpenGL.
const int kD3d11DefaultRetainedMeshBytes = 8 * 1024 * 1024;

/// Approach C: winding accumulated into stencil, then a cover pass.
///
/// The command walk is `StencilCoverGlExecutor.submit`'s. What is different is
/// the upload: GL transfers the accumulation and the cover quads into two
/// buffers and clears with `glClear`, while this packs three geometries -
/// accumulation triangles, cover quads and **clear quads** - into one dynamic
/// buffer and draws all three, for the reason difference 2 above gives.
final class D3d11StencilCoverExecutor {
  D3d11StencilCoverExecutor(this._pipeline);

  final D3d11VectorPipeline _pipeline;
  bool _disposed = false;

  /// The packed upload arena, grown on demand. Reused between submissions so a
  /// frame of promoted paths allocates on the Dart heap once.
  Float32List _packed = Float32List(0);

  D3d11VectorExecutionStats submit(
    StencilCoverDrawPlan plan, {
    required List<D3d11VectorMaterial> materials,
    required StencilCoverCapabilities capabilities,
  }) {
    _throwIfDisposed();
    if (plan.commandCount == 0) return const D3d11VectorExecutionStats();
    _validatePlan(plan, materials, capabilities);

    // Three blocks, in this order, so a `firstVertex` is a plain addition.
    final int accumulationFloats = plan.vertexCount * kStencilCoverVertexStride;
    final int coverFloats = plan.coverVertexCount * kStencilCoverVertexStride;
    final int clearCommands = _countClears(plan);
    final int clearFloats = clearCommands *
        kStencilCoverQuadVertexCount *
        kStencilCoverVertexStride;
    final int totalFloats = accumulationFloats + coverFloats + clearFloats;
    if (_packed.length < totalFloats) {
      _packed = Float32List(totalFloats < 512 ? 512 : totalFloats * 2);
    }
    _packed.setRange(0, accumulationFloats, plan.vertexStorage);
    _packed.setRange(
      accumulationFloats,
      accumulationFloats + coverFloats,
      plan.coverVertexStorage,
    );
    final int coverBase = plan.vertexCount;
    final int clearBase = coverBase + plan.coverVertexCount;
    var clearSlot = 0;
    final Map<int, int> clearVertexOfCommand = <int, int>{};
    for (var command = 0; command < plan.commandCount; command++) {
      if (plan.commandKind(command) != StencilCoverCommandKind.clear) continue;
      final Rect bounds = plan.commandBounds(command);
      final int base = accumulationFloats +
          coverFloats +
          clearSlot * kStencilCoverQuadVertexCount * kStencilCoverVertexStride;
      _writeQuad(_packed, base, bounds);
      clearVertexOfCommand[command] =
          clearBase + clearSlot * kStencilCoverQuadVertexCount;
      clearSlot++;
    }

    if (!_pipeline.uploadStream(_packed, totalFloats)) {
      return const D3d11VectorExecutionStats();
    }

    var accumulationTriangles = 0;
    var coverDraws = 0;
    var clears = 0;
    var drawCalls = 0;
    for (var command = 0; command < plan.commandCount; command++) {
      final int draw = plan.commandDraw(command);
      // Every command, not only the ones that obviously need it. An
      // accumulation left to inherit the previous rectangle draws the wrong
      // shape the moment two draws share a clear - the failure
      // `stencil_cover_draw_plan.dart` records.
      _pipeline.setScissor(plan.commandBounds(command));
      final StencilCoverPassState state = plan.commandState(command);
      switch (plan.commandKind(command)) {
        case StencilCoverCommandKind.clear:
          _pipeline
            ..setBlend(blendModeSrcOver, colorWrites: false)
            ..setStencil(state, replaceWithClearValue: true)
            ..draw(
              firstVertex: clearVertexOfCommand[command]!,
              vertexCount: kStencilCoverQuadVertexCount,
            );
          clears++;
          drawCalls++;
        case StencilCoverCommandKind.accumulate:
          _pipeline
            ..setBlend(blendModeSrcOver, colorWrites: false)
            ..setStencil(state)
            ..draw(
              firstVertex: plan.drawFirstVertex(draw),
              vertexCount: plan.drawVertexCount(draw),
            );
          accumulationTriangles += plan.drawVertexCount(draw) ~/ 3;
          drawCalls++;
        case StencilCoverCommandKind.cover:
          final D3d11VectorMaterial material =
              materials[plan.drawMaterial(draw)];
          _pipeline
            ..setConstants(Transform2D.identity, material)
            ..setBlend(material.blendMode, colorWrites: true)
            ..setStencil(state)
            ..draw(
              firstVertex: coverBase + plan.drawCoverFirstVertex(draw),
              vertexCount: kStencilCoverQuadVertexCount,
            );
          coverDraws++;
          drawCalls++;
      }
    }
    return D3d11VectorExecutionStats(
      drawCalls: drawCalls,
      triangles: accumulationTriangles,
      clearCommands: clears,
      coverDraws: coverDraws,
    );
  }

  static int _countClears(StencilCoverDrawPlan plan) {
    var count = 0;
    for (var command = 0; command < plan.commandCount; command++) {
      if (plan.commandKind(command) == StencilCoverCommandKind.clear) count++;
    }
    return count;
  }

  /// Six vertices of a triangle-list quad over [bounds], top-left first.
  static void _writeQuad(Float32List into, int base, Rect bounds) {
    final double l = bounds.left;
    final double t = bounds.top;
    final double r = bounds.right;
    final double b = bounds.bottom;
    into[base] = l;
    into[base + 1] = t;
    into[base + 2] = r;
    into[base + 3] = t;
    into[base + 4] = r;
    into[base + 5] = b;
    into[base + 6] = l;
    into[base + 7] = t;
    into[base + 8] = r;
    into[base + 9] = b;
    into[base + 10] = l;
    into[base + 11] = b;
  }

  void _validatePlan(
    StencilCoverDrawPlan plan,
    List<D3d11VectorMaterial> materials,
    StencilCoverCapabilities capabilities,
  ) {
    for (var draw = 0; draw < plan.drawCount; draw++) {
      final int material = plan.drawMaterial(draw);
      if (material < 0 || material >= materials.length) {
        throw RangeError.range(
          material,
          0,
          materials.isEmpty ? 0 : materials.length - 1,
          'materialIndex',
        );
      }
      final StencilCoverRequirements requirements =
          StencilCoverRequirements.forDraw(
        fillRule: plan.drawFillRule(draw),
        antiAlias: plan.drawAntiAlias(draw),
        nonZeroStencilBits: plan.drawRequiredStencilBits(draw),
      );
      final String? unsupported = capabilities.unsupportedReason(requirements);
      if (unsupported != null) {
        throw UnsupportedError('stencil-then-cover unavailable: $unsupported');
      }
    }
  }

  void dispose() => _disposed = true;

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('the Direct3D 11 stencil-cover executor is disposed');
    }
  }
}
