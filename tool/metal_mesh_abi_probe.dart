import 'dart:ffi';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/ffi/objc_runtime.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_device.dart';

// The minimum Objective-C surface a Metal mesh pipeline would add or reuse.
// Keep this deliberately explicit: CI output must say which ABI was proved,
// instead of reducing twenty independent claims to one "Metal works" line.
const List<String> _meshSelectors = <String>[
  'newCommandQueue',
  'newLibraryWithSource:options:error:',
  'newRenderPipelineStateWithDescriptor:error:',
  'newDepthStencilStateWithDescriptor:',
  'newBufferWithBytes:length:options:',
  'newFunctionWithName:',
  'vertexDescriptor',
  'attributes',
  'layouts',
  'objectAtIndexedSubscript:',
  'setFormat:',
  'setOffset:',
  'setBufferIndex:',
  'setStride:',
  'setStepFunction:',
  'setVertexFunction:',
  'setFragmentFunction:',
  'setVertexDescriptor:',
  'colorAttachments',
  'setPixelFormat:',
  'setBlendingEnabled:',
  'setDepthAttachmentPixelFormat:',
  'setDepthCompareFunction:',
  'setDepthWriteEnabled:',
  'depthAttachment',
  'setDepthStencilState:',
  'setTriangleFillMode:',
];

Never _fail(String message) {
  stderr.writeln('METAL_MESH_ABI_PROBE=FAIL $message');
  exit(1);
}

void main() {
  stdout.writeln('METAL_MESH_ABI_PLATFORM=${Platform.operatingSystem}');
  stdout.writeln('METAL_MESH_ABI_ARCH=${Abi.current()}');
  if (!Platform.isMacOS) {
    _fail('requires macOS');
  }
  if (!isMetalAvailable) {
    _fail('Metal.framework or libobjc could not be loaded: '
        '${metalLoadError ?? objcRuntimeLoadError}');
  }

  final Pointer<ObjCObject> rawDevice = mtlCreateSystemDefaultDevice();
  stdout.writeln(
    'MTLCreateSystemDefaultDevice=${rawDevice == nullptr ? 'NIL' : 'NON_NIL'}',
  );
  if (rawDevice == nullptr) {
    _fail('MTLCreateSystemDefaultDevice returned nil');
  }
  // MetalGpu.open obtains its own owned device. This first object exists only
  // to make the nil/non-nil question an explicit, independently logged step.
  objcRelease(rawDevice);

  MetalGpu? gpu;
  MetalPipelineCache? pipelines;
  Map<String, Pointer<ObjCObject>> specimens =
      const <String, Pointer<ObjCObject>>{};
  try {
    gpu = MetalGpu.open();
    stdout.writeln('METAL_DEVICE=PASS name=${gpu.name}');

    ObjCAutoreleasePool.run(() {
      specimens = metalDescriptorSpecimens();
      for (final String name in _meshSelectors) {
        final MetalSelector? declaration = kMetalSelectorsByName[name];
        if (declaration == null) {
          _fail('selector $name is absent from kMetalSelectors');
        }
        final MetalRuntimeEncoding runtime = metalRuntimeEncoding(
          declaration,
          specimens: specimens,
        );
        if (!runtime.isFound) {
          _fail('${declaration.receiver}.$name was not found in ObjC runtime');
        }
        if (parseObjCTypeEncoding(runtime.encoding!) !=
            parseObjCTypeEncoding(declaration.encoding)) {
          _fail('${declaration.receiver}.$name encoding mismatch: '
              'declared=${declaration.encoding} runtime=${runtime.encoding}');
        }
        stdout.writeln('SELECTOR=PASS receiver=${declaration.receiver} '
            'name=$name shape=${declaration.shape.name} '
            'source=${runtime.source.name} encoding=${runtime.encoding}');
      }
    });
    metalReleaseSpecimens(specimens);
    specimens = const <String, Pointer<ObjCObject>>{};

    // This is an invocation witness, not merely runtime metadata inspection:
    // it compiles the checked MSL, sends the descriptor setters above, and
    // asks Metal to validate and create a real render pipeline state.
    pipelines = MetalPipelineCache.build(gpu);
    final Pointer<ObjCObject> state = pipelines.forBlendMode(blendModeSrcOver);
    if (state == nullptr) {
      _fail('pipeline creation returned nil');
    }
    stdout.writeln('METAL_MESH_PIPELINE_STATE=PASS');
    stdout.writeln(
        'METAL_MESH_ABI_PROBE=PASS selectors=${_meshSelectors.length}');
  } on Object catch (error, stack) {
    stderr.writeln(error);
    stderr.writeln(stack);
    _fail('exception while exercising Metal');
  } finally {
    if (specimens.isNotEmpty) metalReleaseSpecimens(specimens);
    pipelines?.dispose();
    gpu?.dispose();
  }
}
