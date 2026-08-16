/// The Metal backend's entry point, and an honest account of how far it goes.
///
/// # NOTHING IN THIS FILE HAS BEEN EXECUTED ON A MAC
///
/// ## What exists, and what does not
///
/// **Exists and is checked by tests that run on any platform:**
///
///   * the Objective-C message layer, with the closed shape table and the
///     encoding comparison - `lib/src/ffi/objc_runtime.dart`;
///   * the Metal constants, structs, vertex layout, ownership table and
///     translations from the shared GPU vocabulary - `metal_bindings.dart`;
///   * the MSL for the three modes, with the same analytic coverage term as
///     the GLSL and the HLSL - `metal_shaders.dart`;
///   * the probe below.
///
/// **Does not exist:** [MetalRenderDevice] and any [RenderTarget]. There is no
/// `MTLDevice` opened, no pipeline state built, no frame encoded, no drawable
/// presented.
///
/// ## Why [probe] therefore reports unsupported even on a Mac
///
/// Because [createDevice] cannot return a device, and a probe that said
/// `supported: true` would be a promise this backend cannot keep. Section 6.6
/// of the roadmap puts it directly - faked capability is worse than absent
/// capability - and a `RendererBackend` that probes green and then throws is
/// the exact failure mode that rule exists to prevent: the selection policy
/// would choose Metal over the CPU rasteriser and the application would not
/// start.
///
/// The probe still does real work on a Mac. It loads the frameworks, asks for
/// the system default device, reads its name and unified-memory flag, and
/// reports all of it as [DiagnosticKind.note]s. So the probe is a *diagnostic*
/// that is useful the day someone runs it on hardware - it will say what was
/// found - while the `supported` flag stays false because the renderer is not
/// finished.
///
/// ## What finishing it means
///
/// Concretely, and in the order they depend on each other:
///
///   1. `MetalRenderDevice implements RenderDevice, GpuTextureAllocator,
///      GpuRecoveryHost` - `MTLDevice`, one `MTLCommandQueue`, the library
///      compiled from [kMetalShaderSource], and one
///      `MTLRenderPipelineState` per blend mode.
///   2. A texture type implementing `GpuTextureHandle`, with an int id space
///      shared with the layer targets, because `GpuBatcher` breaks batches by
///      comparing texture ids as integers.
///   3. A `GpuLayerTargetAllocator`, as `GlFramebufferPool` and `D3d11LayerPool`
///      are for their backends.
///   4. The two presenters ADR 0005 splits apart: the `IOSurface` one for
///      `appkitNativeHost` and the `CAMetalLayer` one for the in-process
///      backends.
///
/// None of it is speculative work - every contract it must satisfy already
/// exists and is exercised by three other backends. What is missing is a
/// machine to run it on.
library;

import 'dart:io';

import '../../../ffi/objc_runtime.dart';
import '../../../foundation/diagnostics.dart';
import '../../renderer.dart';
import 'metal_bindings.dart';

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
      );

  /// Whether this backend can present to [surface].
  ///
  /// **False for everything**, and that is not a placeholder: this backend
  /// cannot create a device, so there is no surface it can present to. A
  /// method that answered `true` for a `MemorySurfaceDescriptor` would be
  /// describing the backend that is intended rather than the one that is here,
  /// and `RendererBackend` is consulted by selection policy that would act on
  /// the answer.
  ///
  /// When [MetalRenderDevice] lands, this grows the real answer: a memory
  /// surface, and the `IOSurface`-backed window surface ADR 0005 describes.
  @override
  bool supportsSurface(NativeSurfaceDescriptor surface) => false;

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

    // Everything past here is a report, not a gate. The refusal at the bottom
    // is unconditional.
    diagnostics.addAll(describeSystemDefaultDevice());
    diagnostics.add(const BackendDiagnostic.note(
      'binding provenance',
      detail: kMetalBindingProvenance,
    ));

    return BackendProbeResult(
      backendName: backendName,
      supported: false,
      diagnostics: <BackendDiagnostic>[
        ...diagnostics,
        const BackendDiagnostic(
          kind: DiagnosticKind.rejectedByPolicy,
          message: 'the Metal renderer has no device implementation yet, so '
              'this backend refuses rather than claiming a capability it has '
              'never exercised',
          detail: 'Metal.framework and the Objective-C runtime are both '
              'present on this machine and the bindings are in place; what is '
              'missing is MetalRenderDevice and its render targets. Section '
              '6.6 of the roadmap: faked capability is worse than absent '
              'capability. A probe reporting supported: true here would make '
              'the selection policy prefer Metal over the CPU rasteriser and '
              'the application would fail to start. See the library comment '
              'of metal_backend.dart for the four remaining pieces, and '
              'doc/adr/0005-metal-sobre-iosurface-compartilhada.md for the '
              'architecture they implement.',
        ),
      ],
    );
  }

  /// Always throws [BackendSelectionError].
  ///
  /// The throw carries the probe, so the caller's error names what was found
  /// on the machine rather than only what is missing in the code - which is
  /// the difference between "you have no GPU" and "this renderer is not
  /// finished", and they call for opposite reactions.
  @override
  Future<RenderDevice> createDevice() async {
    throw BackendSelectionError(
      requested: backendName,
      attempts: <BackendProbeResult>[probe()],
    );
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
