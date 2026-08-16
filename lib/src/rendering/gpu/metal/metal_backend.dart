/// The Metal backend's entry point, and an honest account of how far it goes.
///
/// # WHAT HAS RUN ON A MAC, AND WHAT HAS NOT
///
/// The `macos-14` leg of `.github/workflows/framework.yml` is an Apple Silicon
/// runner whose GPU reports itself as an `Apple Paravirtual device`, and every
/// claim below is something a test asserted there on the last push. This file
/// used to open with "nothing in this file has been executed on a Mac". That
/// stopped being true, one measured step at a time.
///
/// **Runs on hardware, in CI, on every push:**
///
///   * the Objective-C message layer and the encoding comparison, now for all
///     79 rows of `kMetalSelectors` - `lib/src/ffi/objc_runtime.dart`;
///   * `MTLCreateSystemDefaultDevice` and one `MTLCommandQueue`;
///   * the MSL of `metal_shaders.dart`, **compiled** by
///     `newLibraryWithSource:options:error:`, with both entry points found;
///   * one `MTLRenderPipelineState` per blend mode, built from the vertex
///     descriptor `gpu_pipeline.dart` defines - and Metal refusing an
///     incomplete descriptor, which is what makes it accepting the real one
///     mean something;
///   * an offscreen `MTLTexture` cleared, drawn into through the real
///     `GpuRasterSink`, and read back with
///     `getBytes:bytesPerRow:fromRegion:mipmapLevel:`;
///   * **pixel parity against the CPU rasteriser**: 0 deviation on solid
///     rectangles and on a clipped scene, 1 level on blended and antialiased
///     pixels, with the arithmetic worked out in
///     `test/rendering/gpu/metal/metal_cpu_parity_test.dart`.
///
/// **Does not exist:** any presentation. There is no `CAMetalLayer` drawable,
/// no `IOSurface` handed to a host process, no window. There is also no mask
/// atlas, no glyph atlas and no layer stack on this path, so paths, rounded
/// rectangles, text and compositing layers are refused by name rather than
/// approximated.
///
/// ## What [probe] therefore says
///
/// `supported: true` on a Mac where the device opens - because
/// [createDevice] now returns a device that really draws - and
/// [supportsSurface] answers **true only for a [MemorySurfaceDescriptor]**.
/// That pair is the honest shape: the selection policy asks whether this
/// backend can present to the surface at hand, and for a window the answer is
/// still no. Section 6.6 - faked capability is worse than absent capability -
/// is satisfied by narrowing the claim rather than by refusing everything, and
/// the capability set says the same thing: [Capability.cpuPresentation] and
/// **not** [Capability.gpuPresentation], because the pixels reach the caller
/// through a readback and not through a swap.
///
/// ## What finishing it means
///
/// In the order the pieces depend on each other:
///
///   1. a texture type implementing `GpuTextureHandle` and an image cache, so
///      `drawImage` and the two atlases work - the sink refuses them today;
///   2. a `GpuLayerTargetAllocator`, as `GlFramebufferPool` and
///      `D3d11LayerPool` are for their backends, so `saveLayer` composites;
///   3. the two presenters ADR 0005 splits apart: the `IOSurface` one for
///      `appkitNativeHost` and the `CAMetalLayer` one for the in-process
///      backends;
///   4. device-loss recovery, which on Metal is not the same problem as on
///      Direct3D: there is no `DXGI_ERROR_DEVICE_REMOVED` to observe.
///
library;

import 'dart:io';

import '../../../ffi/objc_runtime.dart';
import '../../../foundation/diagnostics.dart';
import '../../../foundation/lifecycle.dart';
import '../../../geometry/rect.dart';
import '../../../graphics/display_list.dart';
import '../../framebuffer.dart';
import '../../renderer.dart';
import 'metal_bindings.dart';
import 'metal_device.dart';
import 'metal_offscreen.dart';

/// Metal, as a [RendererBackend].
///
/// Const-constructible and stateless, exactly as [GlRendererBackend] and
/// [D3d11RendererBackend] are: a backend object is a name and a probe, and the
/// state lives in the device.
final class MetalRendererBackend implements RendererBackend {
  const MetalRendererBackend();

  /// The stable lowercase id, in the same space as `opengl`, `direct3d11`,
  /// `direct3d12` and `cpu`. Selection policy may match on it; rendering code
  /// may not.
  static const String backendName = 'metal';

  @override
  RendererInfo get info => const RendererInfo(
        name: backendName,
        deviceDescription:
            'Metal via the Objective-C runtime, rendering into a shared '
            'IOSurface (ADR 0005)',
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      );

  /// Whether this backend can present to [surface].
  ///
  /// **A memory surface, and nothing else.** That is not a placeholder either
  /// way: a [MemorySurfaceDescriptor] is answered by rendering into an
  /// `MTLTexture` and reading it back, which is implemented, measured against
  /// the CPU rasteriser and running in CI. A window surface is answered no,
  /// because no drawable is ever acquired and no `IOSurface` ever handed over -
  /// ADR 0005's presenters do not exist yet.
  ///
  /// The narrowing is the point. Selection policy asks this per surface, so a
  /// backend that can do one of the two says so instead of claiming both or
  /// refusing everything.
  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) =>
      surface is MemorySurfaceDescriptor;

  /// What this machine has, and why the backend still refuses.
  ///
  /// Never throws - a probe that throws cannot report, which is the whole
  /// point of `BackendProbeResult` existing instead of a bool.
  @override
  BackendProbeResult probe() {
    try {
      return _probe();
    } on Object catch (error, stack) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'the Metal probe threw, which is a bug in the probe',
          detail: '$error\n$stack',
        ),
      );
    }
  }

  BackendProbeResult _probe() {
    if (!Platform.isMacOS) {
      return BackendProbeResult.unsupported(
        backendName,
        const BackendDiagnostic(
          kind: DiagnosticKind.unsupportedPlatform,
          message: 'Metal exists only on Apple platforms',
          detail: 'Metal.framework is not present off macOS, iOS and their '
              'relatives. This is the expected result on Windows and Linux '
              'and is not a defect.',
        ),
      );
    }

    final List<BackendDiagnostic> diagnostics = <BackendDiagnostic>[];

    if (!isObjCRuntimeAvailable) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic.missingLibrary(
          'libobjc.A.dylib',
          detail: 'the Objective-C runtime could not be opened on a machine '
              'reporting itself as macOS, which should not happen: '
              '${objcRuntimeLoadError ?? 'no reason reported'}',
        ),
      );
    }

    if (tryLoadMetal() == null) {
      return BackendProbeResult.unsupported(
        backendName,
        BackendDiagnostic.missingLibrary(
          'Metal.framework',
          detail: '${metalLoadError ?? 'no reason reported'}',
        ),
      );
    }

    // Everything past here is a report. The device is what decides.
    diagnostics.addAll(describeSystemDefaultDevice());
    diagnostics.add(const BackendDiagnostic.note(
      'binding provenance',
      detail: kMetalBindingProvenance,
    ));

    // Opened and thrown away. A probe that reported `supported: true` from the
    // presence of Metal.framework would be reporting the machine and not the
    // backend, and this is the one question whose answer cannot be inferred:
    // MTLCreateSystemDefaultDevice returns nil on a headless or virtualised Mac
    // that has the framework and no GPU.
    try {
      MetalGpu.open().dispose();
    } on Object catch (error) {
      return BackendProbeResult(
        backendName: backendName,
        supported: false,
        diagnostics: <BackendDiagnostic>[
          ...diagnostics,
          BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'Metal is present but no device could be opened',
            detail: '$error',
          ),
        ],
      );
    }

    return BackendProbeResult(
      backendName: backendName,
      supported: true,
      // cpuPresentation and deliberately NOT gpuPresentation: the pixels this
      // backend produces reach the caller through
      // getBytes:bytesPerRow:fromRegion:mipmapLevel:, which is a readback, not
      // a surface swap. Capability.gpuPresentation's own documentation calls
      // that "cpu presentation with a GPU rasteriser bolted on", and claiming
      // it here is exactly the overclaim section 6.6 forbids.
      capabilities: const <Capability>{Capability.cpuPresentation},
      diagnostics: <BackendDiagnostic>[
        ...diagnostics,
        const BackendDiagnostic(
          kind: DiagnosticKind.rejectedByPolicy,
          message: 'this backend renders offscreen only: a memory surface is '
              'supported and a window surface is not',
          detail: 'MetalRenderDevice creates a target for a '
              'MemorySurfaceDescriptor, renders a display list through the '
              'shared GpuRasterSink and reads the texture back. What is '
              'missing is presentation - the CAMetalLayer drawable and the '
              'IOSurface hand-off of ADR 0005 - and the mask atlas, glyph '
              'atlas and layer stack, so paths, rounded rectangles, text and '
              'compositing saveLayers are refused by name rather than '
              'approximated. supportsSurface() is where that shows up in '
              'selection policy.',
        ),
      ],
    );
  }

  /// Opens a real [MetalRenderDevice], or throws [BackendSelectionError]
  /// carrying the probe.
  ///
  /// The throw carries the probe so the caller's error names what was found on
  /// the machine rather than only what failed - the difference between "you
  /// have no GPU" and "this renderer is not finished", which call for opposite
  /// reactions.
  @override
  Future<RenderDevice> createDevice() async {
    final BackendProbeResult report = probe();
    if (!report.supported) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[report],
      );
    }
    try {
      return MetalRenderDevice.open();
    } on Object catch (error) {
      throw BackendSelectionError(
        requested: backendName,
        attempts: <BackendProbeResult>[
          BackendProbeResult(
            backendName: backendName,
            supported: false,
            diagnostics: <BackendDiagnostic>[
              ...report.diagnostics,
              BackendDiagnostic(
                kind: DiagnosticKind.incompatibleDevice,
                message: 'the probe found a device and createDevice could not '
                    'open one, which is a defect rather than a machine',
                detail: '$error',
              ),
            ],
          ),
        ],
      );
    }
  }

  /// What the system default `MTLDevice` says about itself, as notes.
  ///
  /// Separated from [_probe] because it is the one part of this file that will
  /// survive unchanged once the device exists: a device report belongs in the
  /// probe either way. Returns an empty list, never throws, when there is no
  /// Metal here.
  ///
  /// ## Ownership
  ///
  /// `MTLCreateSystemDefaultDevice` returns a **+1** reference, so this
  /// releases it. `-[MTLDevice name]` returns an **autoreleased** `NSString`,
  /// so it must not be released - and the whole call sits inside an
  /// autorelease pool, because there is no run loop here to drain the
  /// process-level one and a probe run in a loop would otherwise accumulate
  /// every string it ever read.
  static List<BackendDiagnostic> describeSystemDefaultDevice() {
    if (!isMetalAvailable) return const <BackendDiagnostic>[];
    return ObjCAutoreleasePool.run(() {
      final ObjCOwned device = ObjCOwned.adopt(mtlCreateSystemDefaultDevice());
      if (device.isNull) {
        return <BackendDiagnostic>[
          const BackendDiagnostic(
            kind: DiagnosticKind.incompatibleDevice,
            message: 'MTLCreateSystemDefaultDevice returned nil',
            detail: 'Metal.framework loaded but reported no default GPU. This '
                'is what a headless or virtualised Mac looks like.',
          ),
        ];
      }
      try {
        final String name = _deviceName(device);
        final bool unified = objcSendBool(
          device.pointer,
          objcSelector('hasUnifiedMemory'),
        );
        final int registryId = objcSendUnsigned(
          device.pointer,
          objcSelector('registryID'),
        );
        return <BackendDiagnostic>[
          BackendDiagnostic.note(
            'system default MTLDevice: $name',
            detail: 'registryID 0x${registryId.toRadixString(16)}; '
                '${unified ? 'unified' : 'discrete'} memory. '
                'ADR 0005 records the open question this number answers: the '
                'host process opens its own MTLDevice, and on a Mac with more '
                'than one GPU the two sides must agree or a shared IOSurface '
                'is read by a GPU that did not write it. The protocol does '
                'not carry the registryID today.',
          ),
        ];
      } finally {
        // Reverse order: the +1 from the C entry point, released last-acquired
        // -first exactly as DisposableBag would have done it.
        objcRelease(device.pointer);
      }
    });
  }

  /// `-[MTLDevice name]` as a Dart string, or a stated fallback.
  ///
  /// Two messages, and the second one is the one that is easy to get wrong:
  /// `name` gives an autoreleased `NSString`, and `UTF8String` gives a `char*`
  /// **owned by that string**, valid only until the pool drains. It is copied
  /// into a Dart string immediately and never stored.
  static String _deviceName(ObjCOwned device) {
    final ptr = objcSendPointer(device.pointer, objcSelector('name'));
    if (ptr.address == 0) return 'unnamed';
    final utf8 = objcSendPointer(ptr, objcSelector('UTF8String'));
    if (utf8.address == 0) return 'unnamed';
    return objcReadCString(utf8.cast());
  }
}

// ---------------------------------------------------------------------------
// The device, and the one kind of target it can make
// ---------------------------------------------------------------------------

/// An open `MTLDevice`, its queue and its pipeline states.
///
/// One shader compile and up to three pipeline states for the whole device,
/// shared by every target it creates - which is why the cache lives here and
/// not in the target, and why a test that renders several scenes pays for the
/// compile once.
final class MetalRenderDevice with DisposableMixin implements RenderDevice {
  MetalRenderDevice._(this._gpu, this._pipelines);

  /// Opens the system default device. Throws [MetalError] when there is none.
  static MetalRenderDevice open() {
    final MetalGpu gpu = MetalGpu.open();
    try {
      return MetalRenderDevice._(gpu, MetalPipelineCache.build(gpu));
    } on Object {
      // The shader failed to compile, which leaves the device open with
      // nothing holding it. Released here, because there is no finaliser.
      gpu.dispose();
      rethrow;
    }
  }

  final MetalGpu _gpu;
  final MetalPipelineCache _pipelines;

  /// What `-[MTLDevice name]` answered, read once at open time.
  late final String deviceName = _gpu.name;

  @override
  RendererInfo get info => RendererInfo(
        name: MetalRendererBackend.backendName,
        deviceDescription: 'Metal on $deviceName, offscreen only',
        rasterizationApproach: RasterizationApproach.analyticCoverageAtlas,
      );

  /// What this device can do **today**, which is less than Metal can.
  ///
  /// Every `false` here is a decision with a reason, not a default:
  ///
  ///   * no partial present, because there is no present at all - a memory
  ///     target reads the whole texture back;
  ///   * no MSAA: the renderer antialiases analytically in the fragment stage
  ///     and through the mask atlas, which is why `sampleCount` never leaves 1;
  ///   * no compute, matching every other backend in this repository;
  ///   * no external textures: `newTextureWithDescriptor:iosurface:plane:` is
  ///     bound but never called, and claiming the capability would promise the
  ///     `IOSurface` path of ADR 0005;
  ///   * no linear colour: the pipeline's attachment is `rgba8Unorm`, not
  ///     `rgba8Unorm_sRGB`, and the CPU rasteriser composites in the same
  ///     space.
  ///
  /// [RendererCapabilities.maxTextureSize] is 8192, which is a **floor and not
  /// a query**: every Metal GPU family guarantees at least that for a 2D
  /// texture, and Apple family 3 and later allow 16384. Reporting the floor
  /// cannot promise something a device refuses; reporting 16384 without asking
  /// would.
  @override
  RendererCapabilities get capabilities => const RendererCapabilities(
        supportsPartialPresent: false,
        supportsMsaa: false,
        supportsCompute: false,
        supportsExternalTextures: false,
        supportsLinearColor: false,
        maxTextureSize: 8192,
        formats: <PixelFormat>{PixelFormat.rgba8888Premultiplied},
      );

  /// Always false. Metal has no device-removed notification to observe - there
  /// is no `DXGI_ERROR_DEVICE_REMOVED` here - and a field that flipped on
  /// nothing would be a guess. When the recovery work of section 25 reaches
  /// this backend it will have a source: `-[MTLCommandBuffer error]` with an
  /// `MTLCommandBufferErrorDeviceRemoved` status.
  @override
  bool get isLost => false;

  @override
  RenderTarget createTarget(NativeSurfaceDescriptor surface) {
    throwIfDisposed();
    if (surface is! MemorySurfaceDescriptor) {
      throw UnsupportedCapabilityError(
        backendName: MetalRendererBackend.backendName,
        capability: Capability.gpuPresentation,
        detail: 'a ${surface.runtimeType} was asked for. This backend renders '
            'into an MTLTexture and reads it back; '
            'no CAMetalLayer drawable is acquired and no IOSurface is shared, '
            'so there is no window surface it can present to. '
            'MetalRendererBackend.supportsSurface answers the same question '
            'before a target is asked for.',
      );
    }
    if (surface.format != PixelFormat.rgba8888Premultiplied) {
      throw UnsupportedCapabilityError(
        backendName: MetalRendererBackend.backendName,
        capability: Capability.cpuPresentation,
        detail: 'a ${surface.format.name} memory surface was asked for, and '
            'the colour texture is MTLPixelFormatRGBA8Unorm; the '
            'readback is byte for byte that layout. A bgra8888 surface would '
            'need either a second pipeline state - a pixel format is part of a '
            'pipeline state identity in Metal - or a swizzle on the way out, '
            'and neither is written. capabilities.formats says the same.',
      );
    }
    return MetalMemoryTarget._(this, surface);
  }

  @override
  void onDispose() {
    _pipelines.dispose();
    _gpu.dispose();
  }
}

/// A [RenderTarget] that renders into an `MTLTexture` and reads it back.
///
/// The GPU work happens in [present], not in [beginFrame]: between the two the
/// caller plays a display list into the batcher and nothing has reached the
/// driver yet. That is the division `D3d11OffscreenTarget` makes, and it is
/// what lets a frame be abandoned - a resize between the two calls makes the
/// frame stale and the recorded batches are dropped.
final class MetalMemoryTarget with DisposableMixin implements RenderTarget {
  MetalMemoryTarget._(this._device, this._surface)
      : _offscreen = MetalOffscreenTarget.create(
          _device._gpu,
          _device._pipelines,
          width: _surface.pixelWidth,
          height: _surface.pixelHeight,
        );

  final MetalRenderDevice _device;
  MemorySurfaceDescriptor _surface;
  MetalOffscreenTarget _offscreen;

  int _generation = 0;
  int? _pendingClear;

  @override
  NativeSurfaceDescriptor get surface => _surface;

  @override
  int get generation => _generation;

  /// The pixels of the **last presented** frame.
  ///
  /// Handed to [Frame.cpuPixels] as well, where it is the buffer the readback
  /// will land in - so during a frame it still holds the previous one's
  /// pixels. That is the contract `D3d11OffscreenTarget` has, and it is stated
  /// because the other reading - "this frame's pixels, before it was drawn" -
  /// is the kind of thing a golden test passes silently.
  Framebuffer get framebuffer => _offscreen.framebuffer;

  @override
  Frame beginFrame(FrameRequest request) {
    throwIfDisposed();
    _offscreen.beginFrame();
    _pendingClear = request.clearColor;
    return Frame(
      target: this,
      framebuffer: _offscreen.framebuffer,
      damage: request.damage ??
          Rect.fromLTWH(
            0,
            0,
            _surface.pixelWidth.toDouble(),
            _surface.pixelHeight.toDouble(),
          ),
      generation: _generation,
    );
  }

  @override
  Future<PresentResult> present(Frame frame) async {
    throwIfDisposed();
    if (frame.generation != _generation) {
      return const PresentResult(
        status: PresentStatus.stale,
        diagnostic: BackendDiagnostic.note(
          'frame belonged to a previous generation of the target',
        ),
      );
    }
    try {
      _offscreen.submit(clearColor: _pendingClear);
      _offscreen.readPixels();
    } on MetalError catch (error) {
      // A command buffer that ends in MTLCommandBufferStatusError is the one
      // place this backend can learn that something went wrong on the GPU, and
      // it is reported rather than thrown: a present is fallible by contract
      // and the caller decides what to do about it.
      return PresentResult(
        status: PresentStatus.failed,
        diagnostic: BackendDiagnostic(
          kind: DiagnosticKind.incompatibleDevice,
          message: 'the Metal command buffer did not complete',
          detail: '$error',
        ),
      );
    }
    return const PresentResult(status: PresentStatus.presented);
  }

  /// Rasterises [list] into this target and presents it.
  ///
  /// Mirrors `MemoryRenderTarget.renderDisplayList` and
  /// `D3d11OffscreenTarget.renderDisplayList` argument for argument, so a
  /// parity test can swap one for another and compare the pixels.
  Future<PresentResult> renderDisplayList(
    DisplayList list, {
    int? clearColor,
  }) async {
    final Frame frame = beginFrame(FrameRequest(clearColor: clearColor));
    _offscreen.playDisplayList(list);
    return present(frame);
  }

  @override
  void resize(int pixelWidth, int pixelHeight, double scale) {
    throwIfDisposed();
    if (pixelWidth == _surface.pixelWidth &&
        pixelHeight == _surface.pixelHeight &&
        scale == _surface.scale) {
      return;
    }
    // The generation moves first, so a frame begun against the old size is
    // already stale by the time the texture is replaced.
    _generation++;
    _surface = MemorySurfaceDescriptor(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      scale: scale,
      format: _surface.format,
    );
    _offscreen.dispose();
    _offscreen = MetalOffscreenTarget.create(
      _device._gpu,
      _device._pipelines,
      width: pixelWidth,
      height: pixelHeight,
    );
  }

  @override
  void onDispose() => _offscreen.dispose();
}
