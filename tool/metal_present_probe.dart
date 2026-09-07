/// Ground truth for Metal **presentation** on a GitHub `macos-14` runner.
///
/// # Why this exists when `metal_mesh_abi_probe.dart` already passes
///
/// That probe proved a great deal, and none of it is presentation. Run
/// [`34148425779`](https://github.com/insinfo/dart_ui/actions/runs/34148425779)
/// reports `METAL_DEVICE=PASS name=Apple Paravirtual device`, 27 selector
/// encodings read back from the live Objective-C runtime, a real
/// `MTLRenderPipelineState` built from the MSL in `metal_shaders.dart`, and
/// meshes drawn and read back. What it never does is put a pixel anywhere a
/// window could show it.
///
/// Three sends stand between this repository and presentation. All three are
/// declared in `kMetalSelectors` and have had their type encodings verified
/// against the runtime on every push - and all three have **never been sent**,
/// anywhere in `lib/`, `test/` or `tool/`:
///
///   1. `newTextureWithDescriptor:iosurface:plane:` - the bridge ADR 0005
///      chose, and the one call most likely to fail on a device whose name is
///      literally `Apple Paravirtual device`;
///   2. `addCompletedHandler:` - which ADR 0005 makes load-bearing for
///      *correctness*, not speed: `commit` only enqueues, so a `PRESENT_SLOT`
///      sent before the GPU finished hands the host a half-written surface.
///      No `ObjCBlock` has ever been constructed in this repository; the tests
///      assert `sizeOf<ObjCBlockLiteral>() == 32` and stop there;
///   3. reading GPU-written pixels back out through `IOSurfaceLock`, which is
///      what "presented" actually means on the recommended macOS backend.
///
/// # Why the target is the `IOSurface` and not a `CAMetalLayer`
///
/// `macos_backend_selection.dart` hard-codes `canCreateWindow: false` for both
/// `skylight` and `appkitSignal`; each is still a POC. The only macOS backend
/// that creates a window in `lib/` is `appkitNativeHost`, and ADR 0001 put its
/// `NSWindow` - and therefore any `CAMetalLayer` - in **another process**. So
/// a layer presenter has no window in this repository to attach to, and
/// building one would be the unverifiable Metal presenter this project already
/// refused once. The layer group below is therefore reported and never gated:
/// it answers whether that presenter could ever be built, not whether it works.
///
/// # Why nothing here fails the build
///
/// A probe that goes red on an unknown teaches nothing twice. Every check
/// records `OK` or its own failure and the run continues, so **one run says
/// which ABI claims are true** instead of stopping at the first that is not.
/// The exit code is non-zero only when the probe itself could not run - no
/// macOS, no Metal, no device - because that is the one outcome that makes the
/// remaining answers meaningless. Once an answer is known it becomes a gate in
/// the workflow, which is the point at which a regression should be red.
///
/// # Why it does not touch `kMetalSelectors`
///
/// Several selectors below are not in that table. Adding them would mean the
/// shared `framework.yml` going red is how we learn an encoding is wrong, and
/// that workflow is not mine to spend. Instead every selector this probe sends
/// that the table does not already carry is **first read back out of the
/// runtime** with `metalRuntimeEncoding` and compared against what is declared
/// here; a mismatch is reported and the send is skipped. A wrong selector name
/// is a silent no-op or a crash and a wrong encoding corrupts the frame, so
/// "verify, then send" is the only safe order.
///
/// # Ordering is deliberate
///
/// `-[CAMetalLayer nextDrawable]` may block for about a second and return nil
/// when no drawable can be vended, and a detached layer on a paravirtual GPU
/// is exactly that case. It runs **last**, after every other answer has been
/// printed, so a hang costs the layer answer and not the whole run.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/macos/io_surface.dart';
import 'package:dart_ui/src/ffi/objc_runtime.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_device.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_offscreen.dart';

// ---------------------------------------------------------------------------
// The surface under test
// ---------------------------------------------------------------------------

/// Small enough that a failure prints in full, large enough that a stride
/// rounded up by IOSurface is visible: 100 * 4 is 400 bytes, which is not a
/// multiple of the 64-byte alignment IOSurface likes, so `bytesPerRow` is
/// expected to come back larger than `width * 4`. That difference is itself a
/// finding - a presenter that assumed `width * 4` would shear every frame.
const int _width = 100;
const int _height = 40;

/// Premultiplied ARGB with **three distinct, non-zero colour channels**.
///
/// This is the check that separates "something was drawn" from "the right
/// thing was drawn". A `BGRA`/`RGBA` mix-up - `MTLPixelFormatBGRA8Unorm` is 80
/// and `rgba8Unorm` is 70, one wrong constant apart - survives every
/// structural test in this repository and then ships as blue faces. With
/// R=0x20, G=0x40, B=0x80 the two orders are trivially distinguishable in the
/// bytes read back; with a grey or a primary they would not be.
const int _clearArgb = 0xFF204080;

const int _expectedRed = 0x20;
const int _expectedGreen = 0x40;
const int _expectedBlue = 0x80;
const int _expectedAlpha = 0xFF;

/// A GPU may round the last bit differently from the reference arithmetic.
/// One level is the same tolerance the CPU-parity suite already allows where
/// blending happens; a channel *order* error is off by more than 0x60 here, so
/// this cannot hide the failure the check exists for.
const int _channelTolerance = 1;

// ---------------------------------------------------------------------------
// Selectors this probe sends that kMetalSelectors does not already carry
// ---------------------------------------------------------------------------

/// Declared here rather than added to `kMetalSelectors`; see the library
/// comment for why. Each one is compared against the runtime before it is
/// sent.
///
/// The three `MTLDevice` properties are Objective-C `getter=` renames -
/// `@property(readonly, getter=isLowPower) BOOL lowPower` - so the selector is
/// `isLowPower` and not `lowPower`. Getting that wrong is a `nil` send that
/// reads as `false`, which would quietly report every device as
/// mains-powered and on-screen.
const List<MetalSelector> _extraSelectors = <MetalSelector>[
  MetalSelector('isLowPower', 'B@:', ObjCSendShape.boolReturn0,
      returnsOwned: false, receiver: 'MTLDevice'),
  MetalSelector('isHeadless', 'B@:', ObjCSendShape.boolReturn0,
      returnsOwned: false, receiver: 'MTLDevice'),
  MetalSelector('isRemovable', 'B@:', ObjCSendShape.boolReturn0,
      returnsOwned: false, receiver: 'MTLDevice'),
  // CGRect is four doubles and shares voidReturnDouble4 with MTLClearColor;
  // the layer needs a non-empty bounds before it will size anything.
  MetalSelector('setBounds:', 'v@:{CGRect={CGPoint=dd}{CGSize=dd}}',
      ObjCSendShape.voidReturnDouble4,
      returnsOwned: false, receiver: 'CAMetalLayer'),
];

/// Selectors already in `kMetalSelectors` whose **receiver** here is not the
/// one the table names.
///
/// `setPixelFormat:` is declared on `MTLTextureDescriptor` and is being sent
/// to a `CAMetalLayer`. The send helpers check the selector's *shape*, which
/// is identical, so the send is safe - but the encoding has only ever been
/// read back from the descriptor's class, so this re-reads it from the layer's
/// before trusting it.
const List<MetalSelector> _reReadOnLayer = <MetalSelector>[
  MetalSelector('setPixelFormat:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector('setDevice:', 'v@:@', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector(
      'setDrawableSize:', 'v@:{CGSize=dd}', ObjCSendShape.voidReturnDouble2,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector('setFramebufferOnly:', 'v@:B', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector('setMaximumDrawableCount:', 'v@:Q', ObjCSendShape.voidReturn1,
      returnsOwned: false, receiver: 'CAMetalLayer'),
  MetalSelector('nextDrawable', '@@:', ObjCSendShape.pointerReturn0,
      returnsOwned: false, receiver: 'CAMetalLayer'),
];

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

int _okCount = 0;
int _failCount = 0;
int _skipCount = 0;

void _pass(String check, [String detail = '']) {
  _okCount++;
  stdout.writeln('CHECK=$check RESULT=OK${detail.isEmpty ? '' : ' $detail'}');
}

void _fail(String check, String detail) {
  _failCount++;
  stdout.writeln('CHECK=$check RESULT=FAIL $detail');
}

void _skip(String check, String reason) {
  _skipCount++;
  stdout.writeln('CHECK=$check RESULT=SKIP $reason');
}

/// The probe could not run at all, which is the only fatal outcome.
Never _abort(String message) {
  stderr.writeln('METAL_PRESENT_PROBE=ABORT $message');
  exit(1);
}

/// Whether the runtime agrees with [declared], reporting either way.
///
/// Returns false rather than throwing, because the caller's job is to skip the
/// send and keep going: an encoding the runtime does not confirm is precisely
/// the send that corrupts a frame or crashes the process.
bool _encodingAgrees(
  MetalSelector declared,
  Map<String, Pointer<ObjCObject>> specimens,
) {
  final MetalRuntimeEncoding runtime =
      metalRuntimeEncoding(declared, specimens: specimens);
  final String id = '${declared.receiver}.${declared.name}';
  if (!runtime.isFound) {
    stdout.writeln('ENCODING=NOT_FOUND $id declared=${declared.encoding}');
    return false;
  }
  if (parseObjCTypeEncoding(runtime.encoding!) !=
      parseObjCTypeEncoding(declared.encoding)) {
    stdout.writeln('ENCODING=MISMATCH $id declared=${declared.encoding} '
        'runtime=${runtime.encoding}');
    return false;
  }
  stdout.writeln('ENCODING=OK $id source=${runtime.source.name} '
      'encoding=${runtime.encoding}');
  return true;
}

// ---------------------------------------------------------------------------

Future<void> main() async {
  stdout.writeln('METAL_PRESENT_PLATFORM=${Platform.operatingSystem}');
  stdout.writeln('METAL_PRESENT_ARCH=${Abi.current()}');

  if (!Platform.isMacOS) {
    _abort('requires macOS; got ${Platform.operatingSystem}');
  }
  if (!isMetalAvailable) {
    _abort('Metal.framework or libobjc could not be loaded: '
        '${metalLoadError ?? objcRuntimeLoadError}');
  }

  final Pointer<ObjCObject> raw = mtlCreateSystemDefaultDevice();
  stdout.writeln(
      'MTLCreateSystemDefaultDevice=${raw == nullptr ? 'NIL' : 'NON_NIL'}');
  if (raw == nullptr) {
    _abort('MTLCreateSystemDefaultDevice returned nil: this runner has no '
        'Metal device, and every answer below would be about nothing');
  }
  // MetalGpu.open takes its own +1 device; this one existed only to make the
  // nil question a separately logged step, as the mesh probe does.
  objcRelease(raw);

  MetalGpu? gpu;
  Map<String, Pointer<ObjCObject>> specimens =
      const <String, Pointer<ObjCObject>>{};
  String deviceName = 'unknown';

  // Verdicts, in the words Phase 2 will need. Set pessimistically so that a
  // group which throws leaves the verdict it could not earn.
  String ioSurfaceVerdict = 'BLOCKED reason=not_reached';
  String handlerVerdict = 'BLOCKED reason=not_reached';
  String layerVerdict = 'BLOCKED reason=not_reached';

  _IoSurfaceOutcome? ioOutcome;
  try {
    gpu = MetalGpu.open();
    deviceName = gpu.name;
    _pass('device', 'name=$deviceName');

    specimens = ObjCAutoreleasePool.run(metalDescriptorSpecimens);

    _reportDeviceProperties(gpu, specimens);

    ioOutcome = _probeIoSurfaceBridge(gpu, specimens);
    ioSurfaceVerdict = ioOutcome.verdict;
    handlerVerdict = await _probeCompletionHandler(gpu, ioOutcome);

    // Last on purpose: nextDrawable can block. See the library comment.
    layerVerdict = _probeMetalLayer(gpu, specimens);
  } on Object catch (error, stack) {
    stderr.writeln(error);
    stderr.writeln(stack);
    _fail('probe_body', 'the probe threw: $error');
  } finally {
    // Reverse acquisition order, and the texture before the surface: Metal
    // retains the IOSurface it wrapped, so releasing the surface first would
    // leave a texture pointing at pages this process no longer owns.
    ioOutcome?.dispose();
    if (specimens.isNotEmpty) metalReleaseSpecimens(specimens);
    gpu?.dispose();
  }

  // The three lines that decide Phase 2. Named after what they gate rather
  // than after the call they make, so a reader of the log does not have to
  // hold ADR 0005 in their head to know what a BLOCKED means.
  stdout.writeln('ADR0005_IOSURFACE_BRIDGE=$ioSurfaceVerdict');
  stdout.writeln('ADR0005_COMPLETION_HANDLER=$handlerVerdict');
  stdout.writeln('CAMETALLAYER_PRESENTER=$layerVerdict');
  stdout.writeln('METAL_PRESENT_PROBE=DONE ok=$_okCount fail=$_failCount '
      'skip=$_skipCount device=$deviceName');
}

// ---------------------------------------------------------------------------
// Group 1 - what kind of device this is
// ---------------------------------------------------------------------------

/// Logs the device properties ADR 0005 left as open questions.
///
/// `registryID` is the one that matters beyond curiosity. ADR 0005 records
/// that two `MTLDevice`s - one in the Dart worker, one in the AppKit host -
/// would silently copy rather than share an `IOSurface` on a Mac with a
/// discrete GPU, and that **the protocol carries no way to detect it**.
/// Logging the id now, while it costs one send, is what makes that detectable
/// later: the host can print its own and the two can be compared instead of
/// assumed equal.
void _reportDeviceProperties(
  MetalGpu gpu,
  Map<String, Pointer<ObjCObject>> specimens,
) {
  final int registryId = metalSendUnsigned(gpu.device, 'registryID');
  final int maxBuffer = metalSendUnsigned(gpu.device, 'maxBufferLength');
  stdout.writeln('DEVICE_REGISTRY_ID=$registryId');
  stdout.writeln('DEVICE_MAX_BUFFER_LENGTH=$maxBuffer');

  for (final MetalSelector selector in _extraSelectors) {
    if (selector.receiver != 'MTLDevice') continue;
    if (!_encodingAgrees(selector, specimens)) {
      _skip('device_${selector.name}',
          'the runtime did not confirm the declared encoding');
      continue;
    }
    final bool value = objcSendBool(gpu.device, objcSelector(selector.name));
    stdout.writeln('DEVICE_${selector.name.toUpperCase()}=$value');
    _pass('device_${selector.name}', 'value=$value');
  }

  // hasUnifiedMemory is already in kMetalSelectors, so it goes through the
  // checked helper rather than being re-verified here.
  final bool unified =
      objcSendBool(gpu.device, objcSelector('hasUnifiedMemory'));
  stdout.writeln('DEVICE_HASUNIFIEDMEMORY=$unified');
}

// ---------------------------------------------------------------------------
// Group 2 - the bridge ADR 0005 chose
// ---------------------------------------------------------------------------

/// What the IOSurface group produced, so the completion-handler group can
/// reuse the texture instead of allocating a second one.
final class _IoSurfaceOutcome {
  _IoSurfaceOutcome(this.verdict, this.surface, this.texture);

  final String verdict;

  /// Null when the surface could not be created; owned by this object.
  final MacosIOSurface? surface;

  /// The IOSurface-backed texture, **+1**, or `nullptr` when the wrap failed.
  final Pointer<ObjCObject> texture;

  bool get isUsable => surface != null && texture != nullptr;

  void dispose() {
    if (texture != nullptr) objcRelease(texture);
    surface?.dispose();
  }
}

_IoSurfaceOutcome _probeIoSurfaceBridge(
  MetalGpu gpu,
  Map<String, Pointer<ObjCObject>> specimens,
) {
  MacosIOSurface? surface;
  try {
    // Deliberately the production shape: `global: false` is what
    // surface_pool.dart uses, and a global surface is a different security
    // and lookup path. Proving the wrong one would prove nothing.
    surface = MacosIOSurface.create(
      width: _width,
      height: _height,
      global: false,
    );
  } on Object catch (error) {
    _fail('iosurface_create', '$error');
    return _IoSurfaceOutcome(
        'BLOCKED reason=iosurface_create_failed', null, nullptr);
  }

  // Reported rather than asserted: the point is to find out. A stride larger
  // than width*4 is normal and is exactly what a presenter must not assume
  // away - it is why MacosSurfaceDescriptor carries bytesPerRow at all.
  final bool padded = surface.bytesPerRow != _width * 4;
  _pass(
      'iosurface_create',
      'width=$_width height=$_height bytesPerRow=${surface.bytesPerRow} '
          'widthTimes4=${_width * 4} padded=$padded');

  // Both storage modes, because which one a paravirtual device accepts for an
  // IOSurface-backed texture is unknown and the answer decides the presenter's
  // synchronisation: `managed` needs an explicit blit to make GPU writes
  // visible to the CPU, `shared` does not.
  Pointer<ObjCObject> texture = nullptr;
  int acceptedMode = -1;
  const Map<String, int> storageModes = <String, int>{
    'shared': MtlStorageMode.shared,
    'managed': MtlStorageMode.managed,
  };
  for (final MapEntry<String, int> entry in storageModes.entries) {
    final String name = entry.key;
    final int mode = entry.value;
    final Pointer<ObjCObject> candidate =
        _wrapIoSurface(gpu, surface, storageMode: mode);
    if (candidate == nullptr) {
      _fail('iosurface_texture_$name',
          'newTextureWithDescriptor:iosurface:plane: returned nil');
      continue;
    }
    _pass('iosurface_texture_$name');
    if (texture == nullptr) {
      texture = candidate;
      acceptedMode = mode;
    } else {
      objcRelease(candidate);
    }
  }

  if (texture == nullptr) {
    surface.dispose();
    return _IoSurfaceOutcome(
      'BLOCKED reason=newTextureWithDescriptor_iosurface_plane_returned_nil',
      null,
      nullptr,
    );
  }
  stdout.writeln('IOSURFACE_TEXTURE_STORAGE_MODE=$acceptedMode');

  final _IoSurfaceOutcome outcome = _IoSurfaceOutcome(
    'OK storageMode=$acceptedMode',
    surface,
    texture,
  );

  // The pass that makes this a presentation probe and not a binding test: the
  // GPU writes, the CPU reads the same pages, and the bytes are checked in
  // order rather than merely counted.
  if (!_clearThroughGpu(gpu, texture, waitOnCpu: true)) {
    return _IoSurfaceOutcome(
      'BLOCKED reason=render_pass_into_iosurface_texture_failed',
      surface,
      texture,
    );
  }
  final bool readable = _verifyIoSurfacePixels(surface);
  if (!readable) {
    return _IoSurfaceOutcome(
      'BLOCKED reason=gpu_write_not_visible_or_wrong_channel_order',
      surface,
      texture,
    );
  }
  return outcome;
}

/// `-[MTLDevice newTextureWithDescriptor:iosurface:plane:]`, **+1** or nil.
Pointer<ObjCObject> _wrapIoSurface(
  MetalGpu gpu,
  MacosIOSurface surface, {
  required int storageMode,
}) =>
    ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> cls = objcClass('MTLTextureDescriptor');
      if (cls == nullptr) return nullptr;
      final Pointer<ObjCObject> descriptor = metalSendPointer4(
        cls,
        'texture2DDescriptorWithPixelFormat:width:height:mipmapped:',
        // bgra8Unorm and not rgba8Unorm: the surface's FourCC is 'BGRA'
        // (kMacosPixelFormatBgra) and Metal returns nil rather than
        // converting when the two disagree.
        MtlPixelFormat.bgra8Unorm,
        surface.width,
        surface.height,
        0,
      );
      if (descriptor == nullptr) return nullptr;
      metalSendVoid1(descriptor, 'setUsage:',
          MtlTextureUsage.renderTarget | MtlTextureUsage.shaderRead);
      metalSendVoid1(descriptor, 'setStorageMode:', storageMode);
      return metalSendPointer3(
        gpu.device,
        'newTextureWithDescriptor:iosurface:plane:',
        descriptor.address,
        surface.surfaceRef.address,
        0,
      );
    });

/// Encodes one clear-only pass into [texture].
///
/// [waitOnCpu] chooses between the two answers ADR 0005 weighs: blocking on
/// `waitUntilCompleted`, which is correct and serialises CPU and GPU, and the
/// completion handler, which is what the presenter wants. This function does
/// the first; [_probeCompletionHandler] does the second.
bool _clearThroughGpu(
  MetalGpu gpu,
  Pointer<ObjCObject> texture, {
  required bool waitOnCpu,
}) {
  try {
    ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> commandBuffer = _encodeClear(gpu, texture);
      metalSendVoid(commandBuffer, 'commit');
      if (waitOnCpu) metalSendVoid(commandBuffer, 'waitUntilCompleted');
      final int status = metalSendUnsigned(commandBuffer, 'status');
      if (status != MtlCommandBufferStatus.completed) {
        throw StateError('command buffer status $status, expected '
            '${MtlCommandBufferStatus.completed}: '
            '${metalErrorDescription(metalSendPointer(commandBuffer, 'error'))}'
            '');
      }
    });
  } on Object catch (error) {
    _fail('iosurface_render_pass', '$error');
    return false;
  }
  _pass('iosurface_render_pass', 'clear=0x${_clearArgb.toRadixString(16)}');
  return true;
}

/// Builds and encodes the clear pass, returning the **uncommitted** buffer.
///
/// Split out so the completion-handler group can install its block between
/// encoding and `commit`, which is the only order that works: a handler added
/// after commit may be added to a buffer that has already completed.
Pointer<ObjCObject> _encodeClear(
  MetalGpu gpu,
  Pointer<ObjCObject> texture,
) {
  final Pointer<ObjCObject> passClass = objcClass('MTLRenderPassDescriptor');
  final Pointer<ObjCObject> pass =
      metalSendPointer(passClass, 'renderPassDescriptor');
  final Pointer<ObjCObject> attachment = metalSendPointer1(
      metalSendPointer(pass, 'colorAttachments'),
      'objectAtIndexedSubscript:',
      0);
  metalSendVoid1(attachment, 'setTexture:', texture.address);
  // clear and store, both spelled out: the POC this file's neighbours document
  // asked for dontCare on both ends of a pass whose whole purpose was to keep
  // a colour, and reported success.
  metalSendVoid1(attachment, 'setLoadAction:', MtlLoadAction.clear);
  metalSendVoid1(attachment, 'setStoreAction:', MtlStoreAction.store);
  metalSendDouble4(attachment, 'setClearColor:', metalClearColor(_clearArgb));

  final Pointer<ObjCObject> commandBuffer =
      metalSendPointer(gpu.commandQueue, 'commandBuffer');
  if (commandBuffer == nullptr) {
    throw StateError('-[MTLCommandQueue commandBuffer] returned nil');
  }
  final Pointer<ObjCObject> encoder = metalSendPointer1(
      commandBuffer, 'renderCommandEncoderWithDescriptor:', pass.address);
  if (encoder == nullptr) {
    throw StateError('renderCommandEncoderWithDescriptor: returned nil - the '
        'usual cause is a texture created without MTLTextureUsageRenderTarget');
  }
  metalSendVoid(encoder, 'endEncoding');
  return commandBuffer;
}

/// Locks the surface and checks the bytes the GPU left, **in order**.
bool _verifyIoSurfacePixels(MacosIOSurface surface) {
  int nonZero = 0;
  int b = -1;
  int g = -1;
  int r = -1;
  int a = -1;
  try {
    surface.withPixels((Uint8List pixels) {
      for (int y = 0; y < surface.height; y++) {
        final int row = y * surface.bytesPerRow;
        for (int x = 0; x < surface.width; x++) {
          final int i = row + x * 4;
          if (pixels[i] != 0 ||
              pixels[i + 1] != 0 ||
              pixels[i + 2] != 0 ||
              pixels[i + 3] != 0) {
            nonZero++;
          }
        }
      }
      // The centre texel, away from any edge a viewport might clip.
      final int centre = (surface.height ~/ 2) * surface.bytesPerRow +
          (surface.width ~/ 2) * 4;
      b = pixels[centre];
      g = pixels[centre + 1];
      r = pixels[centre + 2];
      a = pixels[centre + 3];
    });
  } on Object catch (error) {
    _fail('iosurface_readback', 'IOSurfaceLock path threw: $error');
    return false;
  }

  final int total = surface.width * surface.height;
  if (nonZero == 0) {
    _fail(
        'iosurface_gpu_write',
        'every one of the $total pixels is still zero: the GPU wrote nothing '
            'the CPU can see through IOSurfaceLock');
    return false;
  }
  _pass('iosurface_gpu_write', 'nonZero=$nonZero of $total');

  stdout.writeln('IOSURFACE_CENTRE_BGRA=$b,$g,$r,$a');
  bool near(int got, int want) => (got - want).abs() <= _channelTolerance;
  if (near(b, _expectedBlue) &&
      near(g, _expectedGreen) &&
      near(r, _expectedRed) &&
      near(a, _expectedAlpha)) {
    _pass('channel_order', 'bgra as declared');
    return true;
  }
  // Naming the swap explicitly, because "channel order wrong" sends a reader
  // looking at the shader and the answer is a pixel-format constant.
  final String diagnosis = near(b, _expectedRed) && near(r, _expectedBlue)
      ? 'red and blue are swapped: the texture was created with the wrong '
          'MTLPixelFormat for a BGRA IOSurface'
      : 'unrecognised';
  _fail(
      'channel_order',
      'expected b=$_expectedBlue g=$_expectedGreen r=$_expectedRed '
          'a=$_expectedAlpha got b=$b g=$g r=$r a=$a - $diagnosis');
  return false;
}

// ---------------------------------------------------------------------------
// Group 3 - does a block ever fire
// ---------------------------------------------------------------------------

/// Sends `addCompletedHandler:` with a real Objective-C block.
///
/// The first block this repository has ever constructed. `ObjCBlock`'s layout
/// is asserted on Windows and its ABI reasoning is written down, but a struct
/// whose size is right can still have `invoke` at the wrong offset and the
/// only way to find out is to let a framework call it.
///
/// The callable **must** be `NativeCallable.listener`: Metal invokes a
/// completion handler on a thread it owns, and an `isolateLocal` callable
/// reached from a foreign thread is undefined behaviour. Listener delivery is
/// asynchronous, which is precisely the isolate round trip ADR 0005 accepts as
/// the cost of not blocking on every frame.
Future<String> _probeCompletionHandler(
  MetalGpu gpu,
  _IoSurfaceOutcome outcome,
) async {
  if (!outcome.isUsable) {
    _skip('completion_handler',
        'no IOSurface-backed texture to encode a pass into');
    return 'BLOCKED reason=no_texture';
  }
  if (!isObjCBlockRuntimeAvailable) {
    _skip(
        'completion_handler', '_NSConcreteGlobalBlock is not in this process');
    return 'BLOCKED reason=no_block_runtime';
  }

  final Completer<int> fired = Completer<int>();
  final Stopwatch clock = Stopwatch();
  NativeCallable<Void Function(Pointer<Void>, Pointer<ObjCObject>)>? callable;
  ObjCBlock? block;
  try {
    callable = NativeCallable<
            Void Function(Pointer<Void>, Pointer<ObjCObject>)>.listener(
        (Pointer<Void> _, Pointer<ObjCObject> __) {
      if (!fired.isCompleted) fired.complete(clock.elapsedMicroseconds);
    });
    block = ObjCBlock(callable.nativeFunction);

    ObjCAutoreleasePool.run(() {
      final Pointer<ObjCObject> commandBuffer =
          _encodeClear(gpu, outcome.texture);
      // Before commit, never after: a handler added to a buffer that already
      // completed is not guaranteed to run.
      metalSendVoid1(
          commandBuffer, 'addCompletedHandler:', block!.pointer.address);
      clock.start();
      metalSendVoid(commandBuffer, 'commit');
    });

    final int elapsed = await fired.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    if (elapsed < 0) {
      _fail(
          'completion_handler',
          'the block did not fire within 10 s; on this path a presenter would '
              'have to fall back to waitUntilCompleted');
      return 'BLOCKED reason=handler_never_fired';
    }
    _pass('completion_handler', 'elapsed_us=$elapsed');
    stdout.writeln('COMPLETION_HANDLER_LATENCY_US=$elapsed');
    return 'OK latency_us=$elapsed';
  } on Object catch (error) {
    _fail('completion_handler', '$error');
    return 'BLOCKED reason=threw';
  } finally {
    // Order matters and is the rule ObjCBlock documents: the block is marked
    // global so nothing copies it, which means this object owns the lifetime
    // outright and freeing it while Metal could still call it is a
    // use-after-free on Metal's own thread. By here the handler has fired or
    // ten seconds have passed with the buffer committed.
    block?.dispose();
    callable?.close();
  }
}

// ---------------------------------------------------------------------------
// Group 4 - could the other presenter ever exist
// ---------------------------------------------------------------------------

/// Whether a detached `CAMetalLayer` vends a drawable on this runner.
///
/// Informational, and it must stay that way: even a green answer here does not
/// give this repository a layer presenter, because no macOS backend in `lib/`
/// creates a window in this process for a layer to live in. What it does buy
/// is knowing whether the `skylight` and `appkitSignal` paths would have a
/// presenter *if* they were ever finished - which is a real question, since a
/// paravirtual GPU with no window server surface to back a drawable is exactly
/// where `nextDrawable` returns nil forever.
String _probeMetalLayer(
  MetalGpu gpu,
  Map<String, Pointer<ObjCObject>> specimens,
) {
  if (tryLoadQuartzCore() == null) {
    _skip('cametallayer_class', 'QuartzCore.framework did not load');
    return 'BLOCKED reason=no_quartzcore';
  }
  final Pointer<ObjCObject> cls = objcClass('CAMetalLayer');
  if (cls == nullptr) {
    _skip('cametallayer_class', 'objc_getClass("CAMetalLayer") returned nil');
    return 'BLOCKED reason=no_cametallayer_class';
  }
  _pass('cametallayer_class');

  // Verify every selector against the layer's own class before sending it;
  // the table's encodings were read from other receivers.
  final List<MetalSelector> toCheck = <MetalSelector>[
    ..._reReadOnLayer,
    ..._extraSelectors.where((MetalSelector s) => s.receiver == 'CAMetalLayer'),
  ];
  for (final MetalSelector selector in toCheck) {
    if (!_encodingAgrees(selector, specimens)) {
      _skip('cametallayer_setup',
          '${selector.name} was not confirmed on CAMetalLayer');
      return 'BLOCKED reason=encoding_unconfirmed_${selector.name}';
    }
  }

  Pointer<ObjCObject> layer = nullptr;
  try {
    return ObjCAutoreleasePool.run(() {
      layer = metalSendPointer(metalSendPointer(cls, 'alloc'), 'init');
      if (layer == nullptr) {
        _fail('cametallayer_init', '[[CAMetalLayer alloc] init] returned nil');
        return 'BLOCKED reason=init_returned_nil';
      }
      metalSendVoid1(layer, 'setDevice:', gpu.device.address);
      metalSendVoid1(layer, 'setPixelFormat:', MtlPixelFormat.bgra8Unorm);
      // NO, so the drawable's texture could be read back at all. A presenter
      // would set YES for the tiler's benefit; this probe would rather be
      // able to see what it drew.
      metalSendVoid1(layer, 'setFramebufferOnly:', 0);
      metalSendVoid1(
          layer, 'setMaximumDrawableCount:', kMetalMaximumDrawableCount);
      objcSendVoidDouble4(layer, objcSelector('setBounds:'),
          objcDouble4(0, 0, _width.toDouble(), _height.toDouble()));
      objcSendVoidDouble2(layer, objcSelector('setDrawableSize:'),
          objcDouble2(_width.toDouble(), _height.toDouble()));
      _pass('cametallayer_configure');

      final Pointer<ObjCObject> drawable =
          metalSendPointer(layer, 'nextDrawable');
      if (drawable == nullptr) {
        _fail(
            'cametallayer_next_drawable',
            'nextDrawable returned nil for a layer with a device, a pixel '
                'format and a non-zero drawable size - which is what a layer '
                'with nothing to present into does');
        return 'BLOCKED reason=next_drawable_nil';
      }
      _pass('cametallayer_next_drawable');

      final Pointer<ObjCObject> drawableTexture =
          metalSendPointer(drawable, 'texture');
      if (drawableTexture == nullptr) {
        _fail('cametallayer_drawable_texture', 'the drawable has no texture');
        return 'BLOCKED reason=drawable_texture_nil';
      }
      _pass('cametallayer_drawable_texture');

      final Pointer<ObjCObject> commandBuffer =
          _encodeClear(gpu, drawableTexture);
      metalSendVoid1(commandBuffer, 'presentDrawable:', drawable.address);
      metalSendVoid(commandBuffer, 'commit');
      metalSendVoid(commandBuffer, 'waitUntilCompleted');
      final int status = metalSendUnsigned(commandBuffer, 'status');
      if (status != MtlCommandBufferStatus.completed) {
        _fail('cametallayer_present', 'command buffer status $status');
        return 'BLOCKED reason=present_status_$status';
      }
      _pass('cametallayer_present');
      return 'VIABLE note=no_window_in_this_process_to_attach_it_to';
    });
  } on Object catch (error) {
    _fail('cametallayer_group', '$error');
    return 'BLOCKED reason=threw';
  } finally {
    if (layer != nullptr) objcRelease(layer);
  }
}
