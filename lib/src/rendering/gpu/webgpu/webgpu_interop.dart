/// Typed `dart:js_interop` bindings for the WebGPU API.
///
/// ## Why these are declared here and not imported
///
/// `package:web` is generated from the WebIDL of the DOM specifications, and
/// at the pinned version it ships only WebGPU's *flag namespaces* -
/// `GPUTextureUsage`, `GPUBufferUsage` and friends - not the interfaces. The
/// precedent for filling such a gap is `_WebGlLoseContext` in
/// `webgl_backend.dart`: an extension type over `JSObject` is the typed way to
/// name a browser object the package does not, the cast is unchecked either
/// way, and putting each method name in one place makes a typo a compile error
/// rather than a string that silently does nothing.
///
/// The same argument the WebGL descriptor makes about dictionaries applies to
/// every descriptor below: an extension type with an `external factory`
/// compiles to the same object literal an untyped `JSObject` build-up would,
/// and a misspelled member is a compile error instead of an attribute WebGPU
/// silently ignores. That failure mode is worse here than on WebGL, because
/// WebGPU validates *asynchronously* - a bad descriptor surfaces as an
/// `uncapturederror` event long after the call that caused it returned.
///
/// Only the members this backend calls are declared. WebGPU is a large API;
/// declaring it wholesale would be maintaining a second `package:web` with
/// none of its generator, and every undeclared member is a one-line addition
/// at the call site that needs it.
///
/// ## `dart:ffi` must never appear
///
/// Same rule, same reason, same enforcement as `webgl_backend.dart`: this
/// library is reachable from the web compilation fixture, and
/// `test/backends/web/web_compilation_test.dart` runs `dart2js` and
/// `dart2wasm` over it.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// `navigator.gpu`, or null where the browser has no WebGPU.
///
/// Declared as an extension member on `package:web`'s own `Navigator` rather
/// than as a top-level `@JS('navigator.gpu')` binding, so the lookup goes
/// through the same object every other navigator property in this codebase
/// goes through. The getter type is nullable because that is the honest
/// signature: on a browser without WebGPU the property is `undefined`, and
/// `dart:js_interop` hands a nullable static type null for it.
extension WebGpuNavigator on web.Navigator {
  @JS('gpu')
  external GPU? get gpuOrNull;
}

/// Asks the page for `navigator.gpu`, never throwing.
///
/// The probe's question, wrapped: a non-browser JavaScript host may have no
/// `navigator` at all, and reaching through it raises a `TypeError` that must
/// become "not supported here" rather than an exception out of a probe -
/// section 6.6's rule, in the same shape `WebWindowingBackend.probe` applies
/// to `document`.
GPU? navigatorGpu() {
  try {
    return web.window.navigator.gpuOrNull;
  } on Object {
    return null;
  }
}

/// The `getContext` id a canvas answers a [GPUCanvasContext] for.
const String kWebGpuContextId = 'webgpu';

/// Asks [canvas] for a WebGPU context, or null when the browser refuses.
///
/// Never throws, and checks the result with `instanceOfString` rather than
/// `is`, for exactly the reason `createWebGl2Context` documents: every
/// rendering context is a `JSObject` under the extension-type erasure, so an
/// `is` test would accept a 2D context and the first `configure` call on it
/// would throw a JavaScript `TypeError` out of the frame loop.
///
/// One property matters for the fallback story and is worth stating here:
/// `getContext('webgpu')` on a browser that does not recognise the id returns
/// null **without claiming the canvas**, so a canvas that was offered to this
/// backend and refused is still virgin for `getContext('webgl2')`. A canvas
/// that *received* a WebGPU context, on the other hand, is spent - which is
/// why the presenter asks the adapter and the device for everything they can
/// refuse *before* it touches the canvas.
GPUCanvasContext? createWebGpuContext(web.HTMLCanvasElement canvas) {
  try {
    final web.RenderingContext? context = canvas.getContext(kWebGpuContextId);
    if (context == null) return null;
    if (!context.instanceOfString('GPUCanvasContext')) {
      return null;
    }
    return context as GPUCanvasContext;
  } on Object {
    return null;
  }
}

/// The `GPU` interface: the entry point WebGPU hangs off `navigator.gpu`.
extension type GPU._(JSObject _) implements JSObject {
  external JSPromise<GPUAdapter?> requestAdapter(
      [GPURequestAdapterOptions options]);
  external String getPreferredCanvasFormat();
}

/// A physical adapter. Consumed by one `requestDevice` call.
extension type GPUAdapter._(JSObject _) implements JSObject {
  external JSPromise<GPUDevice> requestDevice([GPUDeviceDescriptor descriptor]);

  /// Nullable because `adapter.info` is newer than the rest of the API and a
  /// browser that predates it answers `undefined`. Its absence is normal and
  /// falls back to a generic description, exactly as the missing
  /// `WEBGL_debug_renderer_info` extension does on the WebGL path.
  external GPUAdapterInfo? get info;
}

extension type GPUAdapterInfo._(JSObject _) implements JSObject {
  external String get vendor;
  external String get architecture;
  external String get device;
  external String get description;
}

/// The logical device: every object this backend creates comes from here.
///
/// `addEventListener` is declared directly because a `GPUDevice` is an
/// `EventTarget` in the specification, and `uncapturederror` is the only
/// channel WebGPU's asynchronous validation reports through - a device that
/// did not listen would have every bad descriptor vanish silently, which is
/// the outcome section 6.6 exists to prevent.
extension type GPUDevice._(JSObject _) implements JSObject {
  external GPUQueue get queue;

  /// Resolves when the device is lost. Never rejects; a healthy device simply
  /// never resolves it. This is WebGPU's whole loss-notification story - there
  /// is no synchronous `isContextLost()` to poll, which is why the backend's
  /// liveness check reads its own [GpuDeviceState] instead.
  external JSPromise<GPUDeviceLostInfo> get lost;

  external GPUSupportedLimits get limits;
  external GPUShaderModule createShaderModule(
      GPUShaderModuleDescriptor descriptor);
  external GPUBuffer createBuffer(GPUBufferDescriptor descriptor);
  external GPUTexture createTexture(GPUTextureDescriptor descriptor);
  external GPUSampler createSampler([GPUSamplerDescriptor descriptor]);
  external GPUBindGroupLayout createBindGroupLayout(
      GPUBindGroupLayoutDescriptor descriptor);
  external GPUPipelineLayout createPipelineLayout(
      GPUPipelineLayoutDescriptor descriptor);
  external GPUBindGroup createBindGroup(GPUBindGroupDescriptor descriptor);
  external GPURenderPipeline createRenderPipeline(
      GPURenderPipelineDescriptor descriptor);
  external GPUCommandEncoder createCommandEncoder();
  external void destroy();
  external void addEventListener(String type, JSFunction? callback);
  external void removeEventListener(String type, JSFunction? callback);
}

extension type GPUDeviceLostInfo._(JSObject _) implements JSObject {
  /// `'unknown'` or `'destroyed'`. The second is this backend's own
  /// `destroy()` call and is not an error.
  external String get reason;
  external String get message;
}

extension type GPUSupportedLimits._(JSObject _) implements JSObject {
  external int get maxTextureDimension2D;
}

extension type GPUError._(JSObject _) implements JSObject {
  external String get message;
}

extension type GPUUncapturedErrorEvent._(JSObject _) implements JSObject {
  external GPUError get error;
}

extension type GPUQueue._(JSObject _) implements JSObject {
  external void submit(JSArray<GPUCommandBuffer> commandBuffers);

  /// [data] is a `BufferSource`; the callers hand over typed-array views of
  /// exactly the bytes to write, for the reason `webgl_backend.dart` gives at
  /// its `bufferData` call: the staging list is usually larger than the frame
  /// needs.
  external void writeBuffer(GPUBuffer buffer, int bufferOffset, JSObject data);
  external void writeTexture(
    GPUTexelCopyTextureInfo destination,
    JSObject data,
    GPUTexelCopyBufferLayout dataLayout,
    GPUExtent3DDict size,
  );
}

extension type GPUCanvasContext._(JSObject _) implements JSObject {
  external void configure(GPUCanvasConfiguration configuration);
  external void unconfigure();

  /// The texture the compositor will show at the end of this task. Stable
  /// within one task - a mid-frame flush and the final present of the same
  /// frame get the same texture - and replaced by the browser afterwards,
  /// which is the same "draw the whole frame inside one rAF callback"
  /// contract `webgl_canvas_target.dart` documents for the drawing buffer.
  external GPUTexture getCurrentTexture();
}

extension type GPUBuffer._(JSObject _) implements JSObject {
  external int get size;
  external void destroy();
}

extension type GPUTexture._(JSObject _) implements JSObject {
  external GPUTextureView createView();
  external void destroy();
}

extension type GPUTextureView._(JSObject _) implements JSObject {}

extension type GPUSampler._(JSObject _) implements JSObject {}

extension type GPUShaderModule._(JSObject _) implements JSObject {}

extension type GPUBindGroupLayout._(JSObject _) implements JSObject {}

extension type GPUPipelineLayout._(JSObject _) implements JSObject {}

extension type GPUBindGroup._(JSObject _) implements JSObject {}

extension type GPURenderPipeline._(JSObject _) implements JSObject {}

extension type GPUCommandBuffer._(JSObject _) implements JSObject {}

extension type GPUCommandEncoder._(JSObject _) implements JSObject {
  external GPURenderPassEncoder beginRenderPass(
      GPURenderPassDescriptor descriptor);
  external GPUCommandBuffer finish();
}

extension type GPURenderPassEncoder._(JSObject _) implements JSObject {
  external void setPipeline(GPURenderPipeline pipeline);
  external void setBindGroup(int index, GPUBindGroup bindGroup,
      [JSArray<JSNumber> dynamicOffsets]);
  external void setVertexBuffer(int slot, GPUBuffer buffer);
  external void setIndexBuffer(GPUBuffer buffer, String indexFormat);

  /// Framebuffer coordinates: origin at the top-left, like device space.
  /// Nothing is flipped here, and `wgsl_shaders.dart` says why GL's flip does
  /// not apply.
  external void setScissorRect(int x, int y, int width, int height);

  /// Framebuffer coordinates as well, and the sparse path sets it explicitly:
  /// a render pass's default viewport is the whole attachment, which is only
  /// the same rectangle as the caller's viewport when the target happens to be
  /// exactly that size.
  external void setViewport(
    num x,
    num y,
    num width,
    num height,
    num minDepth,
    num maxDepth,
  );
  external void drawIndexed(int indexCount,
      [int instanceCount, int firstIndex]);

  /// Non-indexed draw. The sparse-strip pipeline builds its unit quad from
  /// `@builtin(vertex_index)`, so there is no index buffer to bind, and
  /// [firstInstance] is what lets a command range be drawn without rebinding
  /// the vertex attributes the way GL 3.3 has to.
  external void draw(int vertexCount,
      [int instanceCount, int firstVertex, int firstInstance]);
  external void end();
}

// ---------------------------------------------------------------------------
// Descriptor dictionaries. Object literals with compile-checked member names;
// see the library comment for why each is an extension type with an external
// factory rather than an untyped JSObject.
// ---------------------------------------------------------------------------

extension type GPURequestAdapterOptions._(JSObject _) implements JSObject {
  /// `powerPreference` is deliberately not passed by this backend, for the
  /// reason `defaultWebGl2ContextAttributes` gives: the discrete-versus-
  /// integrated choice is a battery decision that belongs to the application.
  external factory GPURequestAdapterOptions({String powerPreference});
}

extension type GPUDeviceDescriptor._(JSObject _) implements JSObject {
  external factory GPUDeviceDescriptor({String label});
}

extension type GPUCanvasConfiguration._(JSObject _) implements JSObject {
  external factory GPUCanvasConfiguration({
    GPUDevice device,
    String format,
    String alphaMode,
  });
}

extension type GPUShaderModuleDescriptor._(JSObject _) implements JSObject {
  external factory GPUShaderModuleDescriptor({String code});
}

extension type GPUBufferDescriptor._(JSObject _) implements JSObject {
  external factory GPUBufferDescriptor({int size, int usage});
}

extension type GPUExtent3DDict._(JSObject _) implements JSObject {
  external factory GPUExtent3DDict({int width, int height});
}

extension type GPUTextureDescriptor._(JSObject _) implements JSObject {
  external factory GPUTextureDescriptor({
    GPUExtent3DDict size,
    String format,
    int usage,
  });
}

extension type GPUSamplerDescriptor._(JSObject _) implements JSObject {
  external factory GPUSamplerDescriptor({
    String magFilter,
    String minFilter,
    String addressModeU,
    String addressModeV,
  });
}

extension type GPUOrigin3DDict._(JSObject _) implements JSObject {
  external factory GPUOrigin3DDict({int x, int y});
}

extension type GPUTexelCopyTextureInfo._(JSObject _) implements JSObject {
  external factory GPUTexelCopyTextureInfo({
    GPUTexture texture,
    GPUOrigin3DDict origin,
  });
}

extension type GPUTexelCopyBufferLayout._(JSObject _) implements JSObject {
  external factory GPUTexelCopyBufferLayout({
    int offset,
    int bytesPerRow,
    int rowsPerImage,
  });
}

extension type GPUBufferBindingLayout._(JSObject _) implements JSObject {
  external factory GPUBufferBindingLayout({
    String type,
    bool hasDynamicOffset,
    int minBindingSize,
  });
}

extension type GPUSamplerBindingLayout._(JSObject _) implements JSObject {
  external factory GPUSamplerBindingLayout({String type});
}

extension type GPUTextureBindingLayout._(JSObject _) implements JSObject {
  external factory GPUTextureBindingLayout({String sampleType});
}

extension type GPUBindGroupLayoutEntry._(JSObject _) implements JSObject {
  external factory GPUBindGroupLayoutEntry({
    int binding,
    int visibility,
    GPUBufferBindingLayout buffer,
    GPUSamplerBindingLayout sampler,
    GPUTextureBindingLayout texture,
  });
}

extension type GPUBindGroupLayoutDescriptor._(JSObject _) implements JSObject {
  external factory GPUBindGroupLayoutDescriptor({
    JSArray<GPUBindGroupLayoutEntry> entries,
  });
}

extension type GPUPipelineLayoutDescriptor._(JSObject _) implements JSObject {
  external factory GPUPipelineLayoutDescriptor({
    JSArray<GPUBindGroupLayout> bindGroupLayouts,
  });
}

extension type GPUBufferBinding._(JSObject _) implements JSObject {
  external factory GPUBufferBinding({GPUBuffer buffer, int offset, int size});
}

extension type GPUBindGroupEntry._(JSObject _) implements JSObject {
  /// [resource] is a union in the specification - a sampler, a texture view
  /// or a buffer binding - which `JSAny` states honestly; the three call
  /// sites each pass one of the typed values above.
  external factory GPUBindGroupEntry({int binding, JSAny resource});
}

extension type GPUBindGroupDescriptor._(JSObject _) implements JSObject {
  external factory GPUBindGroupDescriptor({
    GPUBindGroupLayout layout,
    JSArray<GPUBindGroupEntry> entries,
  });
}

extension type GPUVertexAttribute._(JSObject _) implements JSObject {
  external factory GPUVertexAttribute({
    String format,
    int offset,
    int shaderLocation,
  });
}

extension type GPUVertexBufferLayout._(JSObject _) implements JSObject {
  /// [stepMode] is `'vertex'` by default and `'instance'` for the sparse-strip
  /// buffer, whose every record describes a whole quad rather than a corner.
  /// It is optional here rather than required because the dense path relies on
  /// the specification's own default and passing it would be noise.
  external factory GPUVertexBufferLayout({
    int arrayStride,
    String stepMode,
    JSArray<GPUVertexAttribute> attributes,
  });
}

extension type GPUVertexState._(JSObject _) implements JSObject {
  external factory GPUVertexState({
    GPUShaderModule module,
    String entryPoint,
    JSArray<GPUVertexBufferLayout> buffers,
  });
}

extension type GPUBlendComponent._(JSObject _) implements JSObject {
  external factory GPUBlendComponent({
    String srcFactor,
    String dstFactor,
    String operation,
  });
}

extension type GPUBlendStateDict._(JSObject _) implements JSObject {
  external factory GPUBlendStateDict({
    GPUBlendComponent color,
    GPUBlendComponent alpha,
  });
}

extension type GPUColorTargetState._(JSObject _) implements JSObject {
  external factory GPUColorTargetState({
    String format,
    GPUBlendStateDict blend,
  });
}

extension type GPUFragmentState._(JSObject _) implements JSObject {
  external factory GPUFragmentState({
    GPUShaderModule module,
    String entryPoint,
    JSArray<GPUColorTargetState> targets,
  });
}

extension type GPUPrimitiveState._(JSObject _) implements JSObject {
  external factory GPUPrimitiveState({String topology});
}

extension type GPURenderPipelineDescriptor._(JSObject _) implements JSObject {
  external factory GPURenderPipelineDescriptor({
    GPUPipelineLayout layout,
    GPUVertexState vertex,
    GPUFragmentState fragment,
    GPUPrimitiveState primitive,
  });
}

extension type GPUColorDict._(JSObject _) implements JSObject {
  external factory GPUColorDict({num r, num g, num b, num a});
}

extension type GPURenderPassColorAttachment._(JSObject _) implements JSObject {
  external factory GPURenderPassColorAttachment({
    GPUTextureView view,
    String loadOp,
    String storeOp,
    GPUColorDict clearValue,
  });
}

extension type GPURenderPassDescriptor._(JSObject _) implements JSObject {
  external factory GPURenderPassDescriptor({
    JSArray<GPURenderPassColorAttachment> colorAttachments,
  });
}
