/// The Metal objects that only exist on a Mac, built one layer at a time.
///
/// # What has actually run, and where
///
/// Everything in this file is executed by `test/rendering/gpu/metal/` on the
/// `macos-14` leg of `.github/workflows/framework.yml`, which is an Apple
/// Silicon machine with a usable GPU. That is the only claim of execution this
/// framework makes about Metal, and it is checkable: the tests are gated on
/// `Platform.isMacOS`, they run on every push, and `MTLCreateSystemDefaultDevice`
/// answers there.
///
/// The order below is the order the pieces depend on each other, and each one
/// is proved before the next is written:
///
///   1. [MetalGpu.open] - a device and a command queue.
///   2. [MetalGpu.compileShaderLibrary] - the MSL of `metal_shaders.dart`
///      through `newLibraryWithSource:options:error:`, with Apple's own
///      diagnostic on failure.
///
/// ## Every send goes through the declared table
///
/// A call site here does not spell a shape. It names a selector, and
/// [_declaredShape] asserts that the shape it is about to use is the one
/// `kMetalSelectors` declares for that name - which is the same string the
/// on-Mac encoding test compares against `method_getTypeEncoding`. So a wrong
/// trampoline cast has to survive three independent statements to reach the
/// hardware, and the assertion runs in CI because `dart test` runs in JIT with
/// assertions on.
///
/// ## The autorelease pool
///
/// `objc_runtime.dart` states the rule: a pool is per thread, and a thread
/// without one leaks every autoreleased object. Tests run in `package:test`
/// isolates, which have no run loop and therefore no pool anybody drains, so
/// every entry point here that creates an autoreleased object pushes one and
/// pops it before returning.
///
/// What survives the pool is exactly what Objective-C's naming convention says
/// survives it: `MTLCreateSystemDefaultDevice`, `newCommandQueue`,
/// `newLibraryWithSource:options:error:` and `newFunctionWithName:` all return
/// **+1** references, and those are the only things this class holds across a
/// call. The autoreleased objects - the `NSString` of the source, an `NSError`
/// - are read inside the pool and never stored.
library;

import 'dart:ffi';

import '../../../ffi/native_memory.dart';
import '../../../ffi/objc_runtime.dart';
import '../gpu_pipeline.dart';
import 'metal_bindings.dart';
import 'metal_shaders.dart';

/// A Metal operation that failed, with whatever the framework said about it.
///
/// Carries [detail] separately from [message] because the interesting half is
/// always Apple's: a shader that does not compile comes back as an `NSError`
/// whose `localizedDescription` names the line and the column, and a report
/// that dropped it would leave a CI log saying only "compilation failed".
final class MetalError extends Error {
  MetalError(this.message, {this.detail});

  final String message;

  /// `-[NSError localizedDescription]`, or null when the framework returned
  /// nil without an error - which happens and is worth distinguishing.
  final String? detail;

  @override
  String toString() =>
      detail == null ? 'MetalError: $message' : 'MetalError: $message\n$detail';
}

/// An `MTLDevice` and its command queue, opened once and reused.
///
/// Not a `RenderDevice`: this is the layer underneath one. Keeping it separate
/// is what lets a test open a device and compile a library without any of the
/// frame plumbing existing yet, which is the difference between finding out
/// that the MSL has a syntax error and finding out that "the Metal backend
/// does not work".
final class MetalGpu {
  MetalGpu._(this.device, this.commandQueue);

  /// The `id<MTLDevice>`, **+1**, released by [dispose].
  final Pointer<ObjCObject> device;

  /// The `id<MTLCommandQueue>`, **+1**.
  final Pointer<ObjCObject> commandQueue;

  bool _disposed = false;

  /// Opens the system default device and one command queue.
  ///
  /// Throws [MetalError] rather than returning null, and says which of the two
  /// steps failed: "no Metal on this machine" and "this Mac has no default
  /// GPU" are different facts, and a headless or virtualised Mac produces the
  /// second while looking like the first.
  ///
  /// One queue for the whole device, as `d3d11_backend.dart` keeps one
  /// immediate context: Apple's own guidance is that a queue is expensive and
  /// long-lived, and this renderer submits from one isolate.
  static MetalGpu open() {
    if (!isMetalAvailable) {
      throw MetalError(
        'Metal is not available in this process',
        detail: 'Metal.framework: ${metalLoadError ?? 'loaded'}; '
            'libobjc: ${objcRuntimeLoadError ?? 'loaded'}',
      );
    }
    final Pointer<ObjCObject> device = mtlCreateSystemDefaultDevice();
    if (device == nullptr) {
      throw MetalError(
        'MTLCreateSystemDefaultDevice returned nil',
        detail: 'Metal.framework loaded but reported no default GPU, which is '
            'what a headless or virtualised Mac looks like.',
      );
    }
    final Pointer<ObjCObject> queue =
        metalSendPointer(device, 'newCommandQueue');
    if (queue == nullptr) {
      objcRelease(device);
      throw MetalError('-[MTLDevice newCommandQueue] returned nil');
    }
    return MetalGpu._(device, queue);
  }

  /// `-[MTLDevice name]`, copied out of the autoreleased `NSString`.
  String get name => ObjCAutoreleasePool.run(() {
        final Pointer<ObjCObject> string = metalSendPointer(device, 'name');
        return metalReadNsString(string) ?? 'unnamed';
      });

  /// Compiles [source] and returns the `id<MTLLibrary>`, **+1**.
  ///
  /// Defaults to [kMetalShaderSource], which is the point: until this ran,
  /// nothing in this repository knew whether that string was valid MSL. A
  /// syntax error now fails the macOS leg of CI with Apple's own message,
  /// which names the line.
  ///
  /// `options:` is nil - the documented "use the defaults" value, which is
  /// Metal 2.x language version, fast math on, no preprocessor macros. Passing
  /// an `MTLCompileOptions` would mean binding four more setters to restate
  /// defaults.
  ///
  /// The `error:` argument is an **out** parameter: a pointer to a variable the
  /// framework writes an autoreleased `NSError` into. It is zeroed first,
  /// because a framework that succeeds does not write it and a caller reading
  /// uninitialised stack memory would report a garbage pointer as an error.
  Pointer<ObjCObject> compileShaderLibrary([String? source]) {
    _checkAlive();
    final String text = source ?? kMetalShaderSource;
    return _withErrorOut((Pointer<Pointer<ObjCObject>> errorOut) {
      return ObjCAutoreleasePool.run(() {
        final Pointer<ObjCObject> nsSource = metalNsString(text);
        final Pointer<ObjCObject> library = metalSendPointer3(
          device,
          'newLibraryWithSource:options:error:',
          nsSource.address,
          0,
          errorOut.address,
        );
        if (library == nullptr) {
          throw MetalError(
            'newLibraryWithSource:options:error: returned nil: the Metal '
            'Shading Language in metal_shaders.dart did not compile',
            detail: metalErrorDescription(errorOut.value) ??
                'the framework returned nil and wrote no NSError, which means '
                    'the shader compiler itself could not be reached',
          );
        }
        return library;
      });
    });
  }

  /// `-[MTLLibrary newFunctionWithName:]` - an `id<MTLFunction>`, **+1**.
  ///
  /// Returns nil, not an error, when the library has no such entry point, so
  /// this throws with the name rather than handing a nil object onwards. A nil
  /// function set on a pipeline descriptor is not an error either: the
  /// descriptor accepts it and `newRenderPipelineStateWithDescriptor:` fails
  /// later with a message about a missing vertex function, which is two steps
  /// away from the typo that caused it.
  Pointer<ObjCObject> newFunction(
    Pointer<ObjCObject> library,
    String entryPoint,
  ) {
    _checkAlive();
    return ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> function = metalSendPointer1(
        library,
        'newFunctionWithName:',
        metalNsString(entryPoint).address,
      );
      if (function == nullptr) {
        throw MetalError(
          'the compiled library has no function named "$entryPoint"',
          detail: 'entry points are declared in metal_shaders.dart as '
              'kMetalVertexEntryPoint and kMetalFragmentEntryPoint, and an MSL '
              'function is only an entry point if it is qualified `vertex` or '
              '`fragment`',
        );
      }
      return function;
    });
  }

  void _checkAlive() {
    if (_disposed) {
      throw MetalError('this MetalGpu was disposed; its MTLDevice is gone');
    }
  }

  /// Releases the queue and then the device, in that order.
  ///
  /// Reverse of acquisition, which is what `DisposableBag` would have done and
  /// what Metal wants: the queue holds a reference to the device, and releasing
  /// the device first would leave the queue pointing at an object whose last
  /// external reference is gone.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    objcRelease(commandQueue);
    objcRelease(device);
  }
}

// ---------------------------------------------------------------------------
// The pipeline - where the vertex layout stops being a comment
// ---------------------------------------------------------------------------

/// The `MTLVertexDescriptor` for the one interleaved layout, autoreleased.
///
/// Built from [kMetalVertexAttributes] and [kMetalVertexStride], which are
/// themselves computed from `gpu_pipeline.dart` rather than restated - so the
/// descriptor Metal validates is the shared layout and not a second opinion
/// about it. A mismatch between this and the `[[attribute(n)]]` qualifiers in
/// the MSL is one of the two things `newRenderPipelineStateWithDescriptor:`
/// refuses outright, which is why building it is worth doing even before there
/// is anything to draw.
///
/// **The caller must be inside an autorelease pool.**
/// `+[MTLVertexDescriptor vertexDescriptor]` is a convenience constructor.
/// [attributes] defaults to the shared layout and is a parameter for exactly
/// one reason: a test hands in a deliberately incomplete one to check that
/// Metal *refuses* it. A validator that accepts everything proves nothing
/// about the descriptor it accepted.
Pointer<ObjCObject> metalBuildVertexDescriptor({
  List<MetalVertexAttribute> attributes = kMetalVertexAttributes,
}) {
  final Pointer<ObjCObject> cls = objcClass('MTLVertexDescriptor');
  if (cls == nullptr) {
    throw MetalError('the MTLVertexDescriptor class is not loaded');
  }
  final Pointer<ObjCObject> descriptor =
      metalSendPointer(cls, 'vertexDescriptor');
  if (descriptor == nullptr) {
    throw MetalError('+[MTLVertexDescriptor vertexDescriptor] returned nil');
  }

  final Pointer<ObjCObject> slots = metalSendPointer(descriptor, 'attributes');
  for (final MetalVertexAttribute attribute in attributes) {
    final Pointer<ObjCObject> slot = metalSendPointer1(
        slots, 'objectAtIndexedSubscript:', attribute.attributeIndex);
    if (slot == nullptr) {
      throw MetalError('vertex attribute ${attribute.attributeIndex} '
          '(${attribute.name}) has no descriptor slot');
    }
    metalSendVoid1(slot, 'setFormat:', attribute.format);
    metalSendVoid1(slot, 'setOffset:', attribute.byteOffset);
    metalSendVoid1(slot, 'setBufferIndex:', kMetalVertexBufferIndex);
  }

  final Pointer<ObjCObject> layouts = metalSendPointer(descriptor, 'layouts');
  final Pointer<ObjCObject> layout = metalSendPointer1(
      layouts, 'objectAtIndexedSubscript:', kMetalVertexBufferIndex);
  if (layout == nullptr) {
    throw MetalError('buffer layout $kMetalVertexBufferIndex has no slot');
  }
  metalSendVoid1(layout, 'setStride:', kMetalVertexStride);
  metalSendVoid1(layout, 'setStepFunction:', MtlVertexStepFunction.perVertex);
  return descriptor;
}

/// One `MTLRenderPipelineState` per blend mode, built once and reused.
///
/// The state object is where Metal *validates*: the vertex descriptor against
/// the `[[stage_in]]` struct, the attachment's pixel format against the
/// fragment return type, the entry points against the library. An inconsistent
/// description fails here, with Apple's message, rather than drawing something
/// wrong - which is why this is a step of its own and not part of drawing.
final class MetalPipelineCache {
  MetalPipelineCache._(this._gpu, this._library, this._pixelFormat);

  /// Compiles the shader library and holds it for the pipelines built from it.
  ///
  /// [pixelFormat] is an [MtlPixelFormat] member and is part of the pipeline's
  /// identity in Metal: a state built for `rgba8Unorm` cannot be used in a pass
  /// whose attachment is `bgra8Unorm`, and Metal raises rather than converting.
  static MetalPipelineCache build(
    MetalGpu gpu, {
    int pixelFormat = MtlPixelFormat.rgba8Unorm,
  }) {
    final Pointer<ObjCObject> library = gpu.compileShaderLibrary();
    return MetalPipelineCache._(gpu, library, pixelFormat);
  }

  final MetalGpu _gpu;
  final Pointer<ObjCObject> _library;
  final int _pixelFormat;

  /// Keyed by the display list's blend-mode constant, which is what a
  /// [GpuBatch] carries; the factors come from [gpuBlendForMode].
  final Map<int, Pointer<ObjCObject>> _states = <int, Pointer<ObjCObject>>{};

  bool _disposed = false;

  /// The pipeline state for [blendMode], built on first use.
  Pointer<ObjCObject> forBlendMode(int blendMode) {
    if (_disposed) throw MetalError('this MetalPipelineCache was disposed');
    final Pointer<ObjCObject>? cached = _states[blendMode];
    if (cached != null) return cached;
    final Pointer<ObjCObject> state = buildState(gpuBlendForMode(blendMode));
    _states[blendMode] = state;
    return state;
  }

  /// Builds one `MTLRenderPipelineState`, **+1**, uncached.
  ///
  /// [vertexDescriptor] is a factory rather than an object because the
  /// descriptor is autoreleased and has to be born inside this method's pool.
  /// It is a parameter so that a test can supply a wrong one and assert that
  /// Metal refuses it; nothing in the renderer passes anything but the
  /// default.
  Pointer<ObjCObject> buildState(
    GpuBlendState blend, {
    Pointer<ObjCObject> Function() vertexDescriptor =
        metalBuildVertexDescriptor,
  }) {
    final Pointer<ObjCObject> cls = objcClass('MTLRenderPipelineDescriptor');
    if (cls == nullptr) {
      throw MetalError('the MTLRenderPipelineDescriptor class is not loaded');
    }
    final Pointer<ObjCObject> vertexFunction =
        _gpu.newFunction(_library, kMetalVertexEntryPoint);
    final Pointer<ObjCObject> fragmentFunction =
        _gpu.newFunction(_library, kMetalFragmentEntryPoint);
    // The descriptor is +1 (alloc), the two functions are +1 (new...), and all
    // three are dead the moment the state exists: a pipeline state retains
    // everything it needs. Releasing them here rather than at teardown is what
    // keeps the cache from holding two compiled functions per blend mode.
    try {
      return _withErrorOut((Pointer<Pointer<ObjCObject>> errorOut) {
        return ObjCAutoreleasePool.run(() {
          final Pointer<ObjCObject> descriptor =
              metalSendPointer(metalSendPointer(cls, 'alloc'), 'init');
          if (descriptor == nullptr) {
            throw MetalError('[[MTLRenderPipelineDescriptor alloc] init] '
                'returned nil');
          }
          try {
            metalSendVoid1(
                descriptor, 'setVertexFunction:', vertexFunction.address);
            metalSendVoid1(
                descriptor, 'setFragmentFunction:', fragmentFunction.address);
            metalSendVoid1(
                descriptor, 'setVertexDescriptor:', vertexDescriptor().address);

            final Pointer<ObjCObject> attachment = metalSendPointer1(
              metalSendPointer(descriptor, 'colorAttachments'),
              'objectAtIndexedSubscript:',
              0,
            );
            if (attachment == nullptr) {
              throw MetalError('colorAttachments[0] is nil on a fresh '
                  'MTLRenderPipelineDescriptor');
            }
            metalSendVoid1(attachment, 'setPixelFormat:', _pixelFormat);
            // Always enabled, with the factors the shared vocabulary asks for.
            // `src` is (one, zero), which is what a disabled blend does anyway,
            // so there is one code path instead of two and no branch that can
            // disagree with gpuBlendForMode.
            metalSendVoid1(attachment, 'setBlendingEnabled:', 1);
            final int source = metalBlendFactor(blend.source);
            final int destination = metalBlendFactor(blend.destination);
            metalSendVoid1(attachment, 'setSourceRGBBlendFactor:', source);
            metalSendVoid1(
                attachment, 'setDestinationRGBBlendFactor:', destination);
            // The alpha factors are the same as the colour ones, which is what
            // `glBlendFunc` means and what d3d11_backend.dart writes into its
            // blend descriptor. Leaving them at their defaults is the classic
            // way to get a surface whose colours are right and whose alpha is
            // not - invisible until something composites the result.
            metalSendVoid1(attachment, 'setSourceAlphaBlendFactor:', source);
            metalSendVoid1(
                attachment, 'setDestinationAlphaBlendFactor:', destination);
            metalSendVoid1(
                attachment, 'setRgbBlendOperation:', MtlBlendOperation.add);
            metalSendVoid1(
                attachment, 'setAlphaBlendOperation:', MtlBlendOperation.add);

            final Pointer<ObjCObject> state = metalSendPointer2(
              _gpu.device,
              'newRenderPipelineStateWithDescriptor:error:',
              descriptor.address,
              errorOut.address,
            );
            if (state == nullptr) {
              throw MetalError(
                'newRenderPipelineStateWithDescriptor:error: returned nil for '
                'blend (${blend.source.name}, ${blend.destination.name})',
                detail: metalErrorDescription(errorOut.value) ??
                    'no NSError was written, which should not happen',
              );
            }
            return state;
          } finally {
            objcRelease(descriptor);
          }
        });
      });
    } finally {
      objcRelease(fragmentFunction);
      objcRelease(vertexFunction);
    }
  }

  /// Releases every state and the library, states first.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final Pointer<ObjCObject> state in _states.values) {
      objcRelease(state);
    }
    _states.clear();
    objcRelease(_library);
  }
}

/// Live instances of the Metal classes whose methods only exist on a private
/// subclass, keyed by the name [MetalSelector.receiver] uses.
///
/// The 27 selectors [kMetalUnverifiedEncodings] used to name are all property
/// accessors on descriptor classes, and Metal's descriptor classes are
/// façades: `MTLTextureDescriptor` declares `width` in the header and some
/// private subclass implements it, so `class_getInstanceMethod` on the class
/// named in the header finds nothing. `object_getClass` on an *instance* finds
/// the class that really implements them, which is a stronger answer than the
/// header's anyway - it is the code that will actually run.
///
/// **The caller must be inside an autorelease pool**, and must call
/// [metalReleaseSpecimens] afterwards for the two that are +1.
Map<String, Pointer<ObjCObject>> metalDescriptorSpecimens() {
  final Map<String, Pointer<ObjCObject>> specimens =
      <String, Pointer<ObjCObject>>{};

  void put(String receiver, Pointer<ObjCObject> object) {
    if (object != nullptr) specimens[receiver] = object;
  }

  final Pointer<ObjCObject> textureDescriptorClass =
      objcClass('MTLTextureDescriptor');
  if (textureDescriptorClass != nullptr) {
    put(
      'MTLTextureDescriptor',
      metalSendPointer4(
        textureDescriptorClass,
        'texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
        MtlPixelFormat.rgba8Unorm,
        4,
        4,
        0,
      ),
    );
  }

  final Pointer<ObjCObject> passClass = objcClass('MTLRenderPassDescriptor');
  if (passClass != nullptr) {
    final Pointer<ObjCObject> pass =
        metalSendPointer(passClass, 'renderPassDescriptor');
    put('MTLRenderPassDescriptor', pass);
    if (pass != nullptr) {
      put(
        'MTLRenderPassColorAttachmentDescriptor',
        metalSendPointer1(metalSendPointer(pass, 'colorAttachments'),
            'objectAtIndexedSubscript:', 0),
      );
    }
  }

  final Pointer<ObjCObject> pipelineClass =
      objcClass('MTLRenderPipelineDescriptor');
  if (pipelineClass != nullptr) {
    // +1: alloc/init. Released by metalReleaseSpecimens.
    final Pointer<ObjCObject> pipeline =
        metalSendPointer(metalSendPointer(pipelineClass, 'alloc'), 'init');
    put('MTLRenderPipelineDescriptor', pipeline);
    if (pipeline != nullptr) {
      put(
        'MTLRenderPipelineColorAttachmentDescriptor',
        metalSendPointer1(metalSendPointer(pipeline, 'colorAttachments'),
            'objectAtIndexedSubscript:', 0),
      );
    }
  }

  final Pointer<ObjCObject> vertexClass = objcClass('MTLVertexDescriptor');
  if (vertexClass != nullptr) {
    final Pointer<ObjCObject> vertex =
        metalSendPointer(vertexClass, 'vertexDescriptor');
    put('MTLVertexDescriptor', vertex);
    if (vertex != nullptr) {
      put(
        'MTLVertexAttributeDescriptor',
        metalSendPointer1(metalSendPointer(vertex, 'attributes'),
            'objectAtIndexedSubscript:', 0),
      );
      put(
        'MTLVertexBufferLayoutDescriptor',
        metalSendPointer1(metalSendPointer(vertex, 'layouts'),
            'objectAtIndexedSubscript:', 0),
      );
    }
  }

  return specimens;
}

/// Releases the specimens that arrived with a +1 reference.
///
/// Only `MTLRenderPipelineDescriptor` does: everything else in
/// [metalDescriptorSpecimens] comes from a convenience constructor or is a
/// property of something that does, and releasing one of those would
/// over-release an object Metal still owns.
void metalReleaseSpecimens(Map<String, Pointer<ObjCObject>> specimens) {
  final Pointer<ObjCObject>? pipeline =
      specimens['MTLRenderPipelineDescriptor'];
  if (pipeline != null) objcRelease(pipeline);
}

// ---------------------------------------------------------------------------
// Sending, with the declared shape asserted at every call site
// ---------------------------------------------------------------------------

/// Asserts that [selector] is declared in [kMetalSelectors] with [shape].
///
/// The point is that a call site cannot invent a shape *or* a selector. A
/// selector missing from the table is a selector the on-Mac encoding test never
/// compared against `method_getTypeEncoding`, so an unchecked send would be
/// exactly the thing this backend's whole verification story is built to
/// prevent.
bool _declaredShape(String selector, ObjCSendShape shape) {
  final MetalSelector? declared = kMetalSelectorsByName[selector];
  if (declared == null) {
    throw MetalError(
      'the selector "$selector" is not in kMetalSelectors, so its type '
      'encoding has never been compared against the runtime',
    );
  }
  if (declared.shape != shape) {
    throw MetalError(
      'the selector "$selector" is declared ${declared.shape.name} in '
      'kMetalSelectors and is being sent as ${shape.name}',
    );
  }
  return true;
}

/// `id result = [target selector]`.
Pointer<ObjCObject> metalSendPointer(
  Pointer<ObjCObject> target,
  String selector,
) {
  assert(_declaredShape(selector, ObjCSendShape.pointerReturn0));
  return objcSendPointer(target, objcSelector(selector));
}

/// `id result = [target selector:a0]`.
Pointer<ObjCObject> metalSendPointer1(
  Pointer<ObjCObject> target,
  String selector,
  int a0,
) {
  assert(_declaredShape(selector, ObjCSendShape.pointerReturn1));
  return objcSendPointer1(target, objcSelector(selector), a0);
}

/// `id result = [target selector:a0 x:a1]`.
Pointer<ObjCObject> metalSendPointer2(
  Pointer<ObjCObject> target,
  String selector,
  int a0,
  int a1,
) {
  assert(_declaredShape(selector, ObjCSendShape.pointerReturn2));
  return objcSendPointer2(target, objcSelector(selector), a0, a1);
}

/// `id result = [target selector:a0 x:a1 y:a2]`.
Pointer<ObjCObject> metalSendPointer3(
  Pointer<ObjCObject> target,
  String selector,
  int a0,
  int a1,
  int a2,
) {
  assert(_declaredShape(selector, ObjCSendShape.pointerReturn3));
  return objcSendPointer3(target, objcSelector(selector), a0, a1, a2);
}

/// `id result = [target selector:a0 x:a1 y:a2 z:a3]`.
Pointer<ObjCObject> metalSendPointer4(
  Pointer<ObjCObject> target,
  String selector,
  int a0,
  int a1,
  int a2,
  int a3,
) {
  assert(_declaredShape(selector, ObjCSendShape.pointerReturn4));
  return objcSendPointer4(target, objcSelector(selector), a0, a1, a2, a3);
}

/// `[target selector]`, returning nothing.
void metalSendVoid(Pointer<ObjCObject> target, String selector) {
  assert(_declaredShape(selector, ObjCSendShape.voidReturn0));
  objcSendVoid(target, objcSelector(selector));
}

/// `[target selector:a0]`, returning nothing.
void metalSendVoid1(Pointer<ObjCObject> target, String selector, int a0) {
  assert(_declaredShape(selector, ObjCSendShape.voidReturn1));
  objcSendVoid1(target, objcSelector(selector), a0);
}

/// `[target selector:a0 x:a1]`, returning nothing.
void metalSendVoid2(
    Pointer<ObjCObject> target, String selector, int a0, int a1) {
  assert(_declaredShape(selector, ObjCSendShape.voidReturn2));
  objcSendVoid2(target, objcSelector(selector), a0, a1);
}

/// `[target selector:a0 x:a1 y:a2]`, returning nothing.
void metalSendVoid3(
    Pointer<ObjCObject> target, String selector, int a0, int a1, int a2) {
  assert(_declaredShape(selector, ObjCSendShape.voidReturn3));
  objcSendVoid3(target, objcSelector(selector), a0, a1, a2);
}

/// `[target selector:a0 x:a1 y:a2 z:a3 w:a4]`, returning nothing.
void metalSendVoid5(Pointer<ObjCObject> target, String selector, int a0, int a1,
    int a2, int a3, int a4) {
  assert(_declaredShape(selector, ObjCSendShape.voidReturn5));
  objcSendVoid5(target, objcSelector(selector), a0, a1, a2, a3, a4);
}

/// `NSUInteger result = [target selector]`.
int metalSendUnsigned(Pointer<ObjCObject> target, String selector) {
  assert(_declaredShape(selector, ObjCSendShape.unsignedReturn0));
  return objcSendUnsigned(target, objcSelector(selector));
}

/// `[target selector:aggregate]` for a four-`double` argument.
void metalSendDouble4(
    Pointer<ObjCObject> target, String selector, ObjCDouble4 value) {
  assert(_declaredShape(selector, ObjCSendShape.voidReturnDouble4));
  objcSendVoidDouble4(target, objcSelector(selector), value);
}

/// `[target selector:aggregate]` for a six-`double` argument.
void metalSendDouble6(
    Pointer<ObjCObject> target, String selector, ObjCDouble6 value) {
  assert(_declaredShape(selector, ObjCSendShape.voidReturnDouble6));
  objcSendVoidDouble6(target, objcSelector(selector), value);
}

/// `[target selector:aggregate]` for a four-`NSUInteger` argument.
void metalSendWord4(
    Pointer<ObjCObject> target, String selector, ObjCWord4 value) {
  assert(_declaredShape(selector, ObjCSendShape.voidReturnWord4));
  objcSendVoidWord4(target, objcSelector(selector), value);
}

/// `-[MTLTexture replaceRegion:mipmapLevel:withBytes:bytesPerRow:]`.
void metalSendReplaceRegion(
  Pointer<ObjCObject> target,
  String selector,
  ObjCWord6 region,
  int mipmapLevel,
  Pointer<Void> bytes,
  int bytesPerRow,
) {
  assert(
      _declaredShape(selector, ObjCSendShape.voidReturnRegionLevelBytesStride));
  objcSendVoidRegion(
      target, objcSelector(selector), region, mipmapLevel, bytes, bytesPerRow);
}

/// `-[MTLTexture getBytes:bytesPerRow:fromRegion:mipmapLevel:]`.
void metalSendGetBytes(
  Pointer<ObjCObject> target,
  String selector,
  Pointer<Void> bytes,
  int bytesPerRow,
  ObjCWord6 region,
  int mipmapLevel,
) {
  assert(
      _declaredShape(selector, ObjCSendShape.voidReturnBytesStrideRegionLevel));
  objcSendVoidGetBytes(
      target, objcSelector(selector), bytes, bytesPerRow, region, mipmapLevel);
}

// ---------------------------------------------------------------------------
// Strings and errors
// ---------------------------------------------------------------------------

/// An autoreleased `NSString` holding [value].
///
/// **The caller must already be inside an autorelease pool.** `+[NSString
/// stringWithUTF8String:]` is a convenience constructor, so the string it
/// returns is autoreleased; on a thread with no pool it leaks, and this is
/// called with the whole shader source.
Pointer<ObjCObject> metalNsString(String value) {
  final Pointer<ObjCObject> cls = objcClass('NSString');
  if (cls == nullptr) {
    throw MetalError(
      'the NSString class is not loaded in this process',
      detail: 'Foundation is linked by Metal.framework, so this means Metal '
          'itself was never opened',
    );
  }
  final Pointer<Uint8> utf8 = objcAllocateCString(value);
  try {
    final Pointer<ObjCObject> string =
        metalSendPointer1(cls, 'stringWithUTF8String:', utf8.address);
    if (string == nullptr) {
      throw MetalError('+[NSString stringWithUTF8String:] returned nil');
    }
    return string;
  } finally {
    // The string copies the bytes, so the buffer is dead the moment the call
    // returns - which is why this is freed here and not tracked.
    objcFreeCString(utf8);
  }
}

/// A Dart string from an `NSString`, or null when [string] is nil.
///
/// `-[NSString UTF8String]` returns a `char*` **owned by the string** and valid
/// only until the enclosing pool drains, so it is copied immediately.
String? metalReadNsString(Pointer<ObjCObject> string) {
  if (string == nullptr) return null;
  final Pointer<ObjCObject> utf8 = metalSendPointer(string, 'UTF8String');
  if (utf8 == nullptr) return null;
  return objcReadCString(utf8.cast<Uint8>());
}

/// `-[NSError localizedDescription]` as a Dart string, or null.
String? metalErrorDescription(Pointer<ObjCObject> error) {
  if (error == nullptr) return null;
  final Pointer<ObjCObject> description =
      metalSendPointer(error, 'localizedDescription');
  return metalReadNsString(description);
}

/// Runs [body] with a zeroed `NSError*` out-parameter.
///
/// Allocated per call rather than kept as a scratch field: these calls are once
/// per device, and a shared slot would have to be zeroed anyway for exactly the
/// reason stated on [MetalGpu.compileShaderLibrary].
T _withErrorOut<T>(T Function(Pointer<Pointer<ObjCObject>>) body) {
  final Pointer<Pointer<ObjCObject>> slot =
      NativeAllocator.instance.allocate<Pointer<ObjCObject>>(sizeOf<Pointer>());
  try {
    slot.value = nullptr;
    return body(slot);
  } finally {
    NativeAllocator.instance.free(slot);
  }
}
