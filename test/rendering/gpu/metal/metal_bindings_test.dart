/// The Metal bindings, checked where there is no Metal.
///
/// This is section 11.4's checklist as executable assertions. Four of its items
/// - size test, offset test, ownership documentation, ignored-API report - are
/// pure data or pure arithmetic, and pure arithmetic is provable on a Windows
/// machine with no Apple software on it. The two that are not (symbol test,
/// minimal call test) skip here with the reason stated, which is the pattern
/// `test/rendering/gpu/gl_device_test.dart` established.
///
/// The offset tests are the reason this file is long. The Direct3D 12 work in
/// this repository already paid for their absence: `D3D12_SHADER_RESOURCE_VIEW_DESC`
/// has an 8-byte aligned union whose `Texture2D` arm starts at offset **16 and
/// not 12**, and because the struct is 40 bytes either way, `sizeOf` could
/// never have caught it. Every offset below is found by writing a sentinel into
/// one field and searching the raw bytes for it - which is a measurement of
/// what `dart:ffi` actually laid out, not a restatement of what the
/// declaration says.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/ffi/native_memory.dart';
import 'package:dart_ui/src/ffi/objc_runtime.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/gpu_texture.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/metal/metal_shaders.dart';
import 'package:test/test.dart';

/// Why the two checklist items that need hardware do not run here.
final String? _needsMac = Platform.isMacOS
    ? null
    : 'needs a Mac: this asserts that a symbol resolves in Metal.framework '
        'and that a message reaches a real MTLDevice. On Windows there is '
        'neither, and a test that reported "Metal is absent" would be '
        'asserting the platform rather than the binding.';

void main() {
  group('struct sizes', () {
    // The C sizes, from the metal-cpp headers named in kMetalBindingProvenance.
    test('MTLOrigin and MTLSize are three NSUIntegers each', () {
      expect(sizeOf<MtlOrigin>(), 3 * sizeOf<IntPtr>());
      expect(sizeOf<MtlSize>(), 3 * sizeOf<IntPtr>());
    });

    test('MTLRegion is an origin followed by a size', () {
      expect(sizeOf<MtlRegion>(), sizeOf<MtlOrigin>() + sizeOf<MtlSize>());
      expect(sizeOf<MtlRegion>(), 6 * sizeOf<IntPtr>());
    });

    test('MTLClearColor is four doubles', () {
      expect(sizeOf<MtlClearColor>(), 32);
    });

    test('MTLViewport is six doubles', () {
      expect(sizeOf<MtlViewport>(), 48);
    });

    test('MTLScissorRect is four NSUIntegers', () {
      expect(sizeOf<MtlScissorRect>(), 4 * sizeOf<IntPtr>());
    });

    test('CGSize is two doubles', () {
      expect(sizeOf<CgSize>(), 16);
    });

    test('the uniform block is 20 bytes with no padding', () {
      // The number the MSL and this struct must agree on. If a float2 were
      // used in the shader it would be 24 there and 20 here, and nothing on
      // this side would notice - see the library comment of metal_shaders.dart.
      expect(sizeOf<MetalUniforms>(), 20);
      expect(sizeOf<MetalUniforms>(), 2 * 4 + 3 * 4);
    });
  });

  group('struct offsets, measured', () {
    test('MTLOrigin fields are at 0, 8, 16', () {
      expect(
          _wordOffsets(
              sizeOf<MtlOrigin>(), <String, void Function(Pointer<Uint8>)>{
            'x': (Pointer<Uint8> p) =>
                p.cast<MtlOrigin>().ref.x = kWordSentinel,
            'y': (Pointer<Uint8> p) =>
                p.cast<MtlOrigin>().ref.y = kWordSentinel,
            'z': (Pointer<Uint8> p) =>
                p.cast<MtlOrigin>().ref.z = kWordSentinel,
          }),
          <String, int>{'x': 0, 'y': 8, 'z': 16});
    });

    test('MTLSize fields are at 0, 8, 16', () {
      expect(
          _wordOffsets(
              sizeOf<MtlSize>(), <String, void Function(Pointer<Uint8>)>{
            'width': (Pointer<Uint8> p) =>
                p.cast<MtlSize>().ref.width = kWordSentinel,
            'height': (Pointer<Uint8> p) =>
                p.cast<MtlSize>().ref.height = kWordSentinel,
            'depth': (Pointer<Uint8> p) =>
                p.cast<MtlSize>().ref.depth = kWordSentinel,
          }),
          <String, int>{'width': 0, 'height': 8, 'depth': 16});
    });

    test('MTLRegion nests without padding between origin and size', () {
      // The claim that matters: origin occupies 0..23 and size starts at 24
      // with nothing inserted. A nested aggregate that got padded would put
      // width at 32 and every texture upload would write the wrong rectangle.
      expect(
          _wordOffsets(
              sizeOf<MtlRegion>(), <String, void Function(Pointer<Uint8>)>{
            'origin.x': (Pointer<Uint8> p) =>
                p.cast<MtlRegion>().ref.origin.x = kWordSentinel,
            'origin.y': (Pointer<Uint8> p) =>
                p.cast<MtlRegion>().ref.origin.y = kWordSentinel,
            'origin.z': (Pointer<Uint8> p) =>
                p.cast<MtlRegion>().ref.origin.z = kWordSentinel,
            'size.width': (Pointer<Uint8> p) =>
                p.cast<MtlRegion>().ref.size.width = kWordSentinel,
            'size.height': (Pointer<Uint8> p) =>
                p.cast<MtlRegion>().ref.size.height = kWordSentinel,
            'size.depth': (Pointer<Uint8> p) =>
                p.cast<MtlRegion>().ref.size.depth = kWordSentinel,
          }),
          <String, int>{
            'origin.x': 0,
            'origin.y': 8,
            'origin.z': 16,
            'size.width': 24,
            'size.height': 32,
            'size.depth': 40,
          });
    });

    test('MTLScissorRect fields are at 0, 8, 16, 24', () {
      expect(
          _wordOffsets(
              sizeOf<MtlScissorRect>(), <String, void Function(Pointer<Uint8>)>{
            'x': (Pointer<Uint8> p) =>
                p.cast<MtlScissorRect>().ref.x = kWordSentinel,
            'y': (Pointer<Uint8> p) =>
                p.cast<MtlScissorRect>().ref.y = kWordSentinel,
            'width': (Pointer<Uint8> p) =>
                p.cast<MtlScissorRect>().ref.width = kWordSentinel,
            'height': (Pointer<Uint8> p) =>
                p.cast<MtlScissorRect>().ref.height = kWordSentinel,
          }),
          <String, int>{'x': 0, 'y': 8, 'width': 16, 'height': 24});
    });

    test('MTLClearColor is red, green, blue, alpha in that order', () {
      // Order, not just size. Four doubles in the wrong order is a picture in
      // the wrong colour, which is the kind of bug that gets blamed on the
      // colour conversion three layers up.
      expect(
          _doubleOffsets(
              sizeOf<MtlClearColor>(), <String, void Function(Pointer<Uint8>)>{
            'red': (Pointer<Uint8> p) =>
                p.cast<MtlClearColor>().ref.red = kDoubleSentinel,
            'green': (Pointer<Uint8> p) =>
                p.cast<MtlClearColor>().ref.green = kDoubleSentinel,
            'blue': (Pointer<Uint8> p) =>
                p.cast<MtlClearColor>().ref.blue = kDoubleSentinel,
            'alpha': (Pointer<Uint8> p) =>
                p.cast<MtlClearColor>().ref.alpha = kDoubleSentinel,
          }),
          <String, int>{'red': 0, 'green': 8, 'blue': 16, 'alpha': 24});
    });

    test('MTLViewport is origin, extent, then the depth range', () {
      expect(
          _doubleOffsets(
              sizeOf<MtlViewport>(), <String, void Function(Pointer<Uint8>)>{
            'originX': (Pointer<Uint8> p) =>
                p.cast<MtlViewport>().ref.originX = kDoubleSentinel,
            'originY': (Pointer<Uint8> p) =>
                p.cast<MtlViewport>().ref.originY = kDoubleSentinel,
            'width': (Pointer<Uint8> p) =>
                p.cast<MtlViewport>().ref.width = kDoubleSentinel,
            'height': (Pointer<Uint8> p) =>
                p.cast<MtlViewport>().ref.height = kDoubleSentinel,
            'znear': (Pointer<Uint8> p) =>
                p.cast<MtlViewport>().ref.znear = kDoubleSentinel,
            'zfar': (Pointer<Uint8> p) =>
                p.cast<MtlViewport>().ref.zfar = kDoubleSentinel,
          }),
          <String, int>{
            'originX': 0,
            'originY': 8,
            'width': 16,
            'height': 24,
            'znear': 32,
            'zfar': 40,
          });
    });

    test('the uniform block matches the MSL declaration order', () {
      // viewportWidth, viewportHeight, mode, yFlip, useLinear - two floats
      // then three uints, every one 4-byte aligned. A reorder here draws with
      // the sampler selector interpreted as the mode.
      expect(
          _floatOffsets(
              sizeOf<MetalUniforms>(), <String, void Function(Pointer<Uint8>)>{
            'viewportWidth': (Pointer<Uint8> p) =>
                p.cast<MetalUniforms>().ref.viewportWidth = kFloatSentinel,
            'viewportHeight': (Pointer<Uint8> p) =>
                p.cast<MetalUniforms>().ref.viewportHeight = kFloatSentinel,
          }),
          <String, int>{'viewportWidth': 0, 'viewportHeight': 4});

      expect(
          _uint32Offsets(
              sizeOf<MetalUniforms>(), <String, void Function(Pointer<Uint8>)>{
            'mode': (Pointer<Uint8> p) =>
                p.cast<MetalUniforms>().ref.mode = kUint32Sentinel,
            'yFlip': (Pointer<Uint8> p) =>
                p.cast<MetalUniforms>().ref.yFlip = kUint32Sentinel,
            'useLinear': (Pointer<Uint8> p) =>
                p.cast<MetalUniforms>().ref.useLinear = kUint32Sentinel,
          }),
          <String, int>{'mode': 8, 'yFlip': 12, 'useLinear': 16});
    });
  });

  group('the flat ABI types the messages actually carry', () {
    // metal_bindings.dart declares the named Metal structs, but the sends go
    // through objc_runtime.dart's shape-named ones. These tests are what makes
    // that substitution legitimate rather than assumed.
    test('ObjCWord6 is layout-identical to MTLRegion', () {
      expect(sizeOf<ObjCWord6>(), sizeOf<MtlRegion>());
      expect(
        _wordOffsets(
            sizeOf<ObjCWord6>(), <String, void Function(Pointer<Uint8>)>{
          'a0': (Pointer<Uint8> p) =>
              p.cast<ObjCWord6>().ref.a0 = kWordSentinel,
          'a3': (Pointer<Uint8> p) =>
              p.cast<ObjCWord6>().ref.a3 = kWordSentinel,
        }),
        <String, int>{'a0': 0, 'a3': 24},
      );
    });

    test('ObjCWord4 is layout-identical to MTLScissorRect', () {
      expect(sizeOf<ObjCWord4>(), sizeOf<MtlScissorRect>());
    });

    test('ObjCDouble4 is layout-identical to MTLClearColor', () {
      expect(sizeOf<ObjCDouble4>(), sizeOf<MtlClearColor>());
    });

    test('ObjCDouble6 is layout-identical to MTLViewport', () {
      expect(sizeOf<ObjCDouble6>(), sizeOf<MtlViewport>());
    });

    test('ObjCDouble2 is layout-identical to CGSize', () {
      expect(sizeOf<ObjCDouble2>(), sizeOf<CgSize>());
    });

    test('mtlRegion2D puts the extent where MTLSize begins, with depth 1', () {
      // The upload rectangle, packed. depth must be 1: a region of depth 0 is
      // empty and replaceRegion: would copy nothing, so every glyph would
      // render blank while every call reported success.
      final ObjCWord6 region = mtlRegion2D(x: 3, y: 5, width: 7, height: 11);
      expect(
        <int>[region.a0, region.a1, region.a2, region.a3, region.a4, region.a5],
        <int>[3, 5, 0, 7, 11, 1],
      );
    });

    test('mtlScissorRect takes an extent, not a right and bottom edge', () {
      // GpuBatch carries left/top/right/bottom; MTLScissorRect wants
      // x/y/width/height. The subtraction lives in the caller, and this pins
      // down which convention this function speaks.
      final ObjCWord4 scissor =
          mtlScissorRect(x: 10, y: 20, width: 30, height: 40);
      expect(<int>[scissor.a0, scissor.a1, scissor.a2, scissor.a3],
          <int>[10, 20, 30, 40]);
    });

    test('mtlViewport defaults the depth range to 0..1, not 0..0', () {
      final ObjCDouble6 viewport =
          mtlViewport(originX: 0, originY: 0, width: 640, height: 480);
      expect(viewport.a4, 0);
      expect(viewport.a5, 1);
    });
  });

  group('enum values', () {
    test('the two constants poc_07_metal got wrong', () {
      // poc/poc_07_metal/lib/metal_bindings.dart:
      //     const int mtlLoadActionClear = 0;   // really 2
      //     const int mtlStoreActionStore = 0;  // really 1
      // Both are MTLLoadActionDontCare / MTLStoreActionDontCare. The POC asked
      // for "discard" on both ends of a pass whose only purpose was to clear
      // and keep a colour, and reported success - because discarding is not an
      // error. This is the regression test for a bug that already shipped.
      expect(MtlLoadAction.clear, 2);
      expect(MtlStoreAction.store, 1);
      expect(MtlLoadAction.dontCare, 0);
      expect(MtlStoreAction.dontCare, 0);
      expect(MtlLoadAction.clear, isNot(MtlLoadAction.dontCare));
      expect(MtlStoreAction.store, isNot(MtlStoreAction.dontCare));
    });

    test('pixel formats', () {
      expect(MtlPixelFormat.invalid, 0);
      expect(MtlPixelFormat.a8Unorm, 1);
      expect(MtlPixelFormat.r8Unorm, 10);
      expect(MtlPixelFormat.rgba8Unorm, 70);
      expect(MtlPixelFormat.bgra8Unorm, 80);
    });

    test('storage mode and resource option are different number spaces', () {
      // MTLStorageModeManaged is 1; MTLResourceStorageModeManaged is 16. The
      // storage mode occupies bits 4..7 of a resource option, so passing one
      // where the other belongs is silent and wrong.
      expect(MtlStorageMode.managed, 1);
      expect(MtlResourceOptions.storageModeManaged, 16);
      expect(
          MtlResourceOptions.storageModeManaged, MtlStorageMode.managed << 4);
      expect(
          MtlResourceOptions.storageModePrivate, MtlStorageMode.private << 4);
      expect(MtlResourceOptions.storageModeMemoryless,
          MtlStorageMode.memoryless << 4);
    });

    test('blend factors', () {
      expect(MtlBlendFactor.zero, 0);
      expect(MtlBlendFactor.one, 1);
      expect(MtlBlendFactor.oneMinusSourceAlpha, 5);
    });

    test('primitive type and command buffer status', () {
      expect(MtlPrimitiveType.triangle, 3);
      expect(MtlCommandBufferStatus.completed, 4);
      expect(MtlCommandBufferStatus.error, 5);
    });

    test('vertex formats', () {
      expect(MtlVertexFormat.float2, 29);
      expect(MtlVertexFormat.float4, 31);
    });

    test('texture usage is a bit set', () {
      expect(MtlTextureUsage.shaderRead, 1);
      expect(MtlTextureUsage.renderTarget, 4);
      expect(
        MtlTextureUsage.shaderRead | MtlTextureUsage.renderTarget,
        5,
      );
    });
  });

  group('translations from the shared vocabulary', () {
    test('alpha8 maps to R8Unorm and never to A8Unorm', () {
      // The shaders read `.r`. An A8Unorm texture returns its value in `.a`
      // and zero in `.r`, so every mask and every glyph would sample as fully
      // transparent - a blank screen that looks like a broken rasteriser.
      expect(metalPixelFormat(GpuTextureFormat.alpha8), MtlPixelFormat.r8Unorm);
      expect(metalPixelFormat(GpuTextureFormat.alpha8),
          isNot(MtlPixelFormat.a8Unorm));
      expect(metalPixelFormat(GpuTextureFormat.rgba8888Premultiplied),
          MtlPixelFormat.rgba8Unorm);
    });

    test('every GpuBlendFactor has a Metal factor', () {
      for (final GpuBlendFactor factor in GpuBlendFactor.values) {
        expect(metalBlendFactor(factor), isA<int>(), reason: factor.name);
      }
      expect(metalBlendFactor(GpuBlendFactor.zero), MtlBlendFactor.zero);
      expect(metalBlendFactor(GpuBlendFactor.one), MtlBlendFactor.one);
      expect(metalBlendFactor(GpuBlendFactor.oneMinusSrcAlpha),
          MtlBlendFactor.oneMinusSourceAlpha);
    });

    test('every GpuPipelineKind maps to its declared mode constant', () {
      for (final GpuPipelineKind kind in GpuPipelineKind.values) {
        expect(metalPipelineMode(kind), kind.index,
            reason: 'the mode constants are declared equal to the enum order, '
                'and gl_shaders.dart and d3d12_shaders.dart say the same; a '
                'backend that disagreed would be compared pixel for pixel '
                'against the others and drawn with the wrong shader branch');
      }
      expect(metalPipelineMode(GpuPipelineKind.solid), kMetalModeSolid);
      expect(metalPipelineMode(GpuPipelineKind.coverageMask),
          kMetalModeCoverageMask);
      expect(metalPipelineMode(GpuPipelineKind.texturedImage),
          kMetalModeTexturedImage);
    });

    test('the filter picks a sampler, not a sampler state object', () {
      expect(
          metalSamplerSelector(GpuTextureFilter.nearest), kMetalSamplerPoint);
      expect(
          metalSamplerSelector(GpuTextureFilter.linear), kMetalSamplerLinear);
    });
  });

  group('the vertex layout follows gpu_pipeline.dart', () {
    test('offsets are the shared layout, in bytes', () {
      final Map<String, int> byName = <String, int>{
        for (final MetalVertexAttribute a in kMetalVertexAttributes)
          a.name: a.byteOffset,
      };
      expect(byName, <String, int>{
        'position': kGpuPositionOffset * 4,
        'texCoord': kGpuTexCoordOffset * 4,
        'color': kGpuColorOffset * 4,
        'shapeRect': kGpuShapeRectOffset * 4,
      });
      expect(byName, <String, int>{
        'position': 0,
        'texCoord': 8,
        'color': 16,
        'shapeRect': 32,
      });
    });

    test('the stride is the shared vertex size', () {
      expect(kMetalVertexStride, kGpuFloatsPerVertex * 4);
      expect(kMetalVertexStride, 48);
    });

    test('attribute indices match the MSL [[attribute(n)]] qualifiers', () {
      expect(
        kMetalVertexAttributes
            .map((MetalVertexAttribute a) => a.attributeIndex)
            .toList(),
        <int>[
          kMetalAttributePosition,
          kMetalAttributeTexCoord,
          kMetalAttributeColor,
          kMetalAttributeShapeRect,
        ],
      );
      expect(
        kMetalVertexAttributes
            .map((MetalVertexAttribute a) => a.attributeIndex)
            .toList(),
        <int>[0, 1, 2, 3],
      );
    });

    test('formats are float2 for the pairs and float4 for the quads', () {
      expect(
        kMetalVertexAttributes.map((MetalVertexAttribute a) => a.format),
        <int>[
          MtlVertexFormat.float2,
          MtlVertexFormat.float2,
          MtlVertexFormat.float4,
          MtlVertexFormat.float4,
        ],
      );
    });

    test('no attribute overruns the stride', () {
      // Arithmetic that would catch a layout change nobody propagated: the
      // last attribute is four floats at offset 32, which ends exactly at 48.
      for (final MetalVertexAttribute a in kMetalVertexAttributes) {
        final int width = a.format == MtlVertexFormat.float2 ? 8 : 16;
        expect(a.byteOffset + width, lessThanOrEqualTo(kMetalVertexStride),
            reason: '${a.name} ends past the vertex stride');
      }
    });
  });

  group('the selector table', () {
    test('every declared encoding matches its declared shape', () {
      // Mechanism 2 of objc_runtime.dart, applied to the whole Metal surface.
      // This is the check that would catch a selector given the wrong
      // trampoline cast, which on arm64 reads a register nobody wrote.
      for (final MetalSelector selector in kMetalSelectors) {
        expect(
          selector.shape.signature,
          parseObjCTypeEncoding(selector.encoding),
          reason: '${selector.receiver}.${selector.name} is declared '
              '"${selector.encoding}" but ${selector.shape.name} implements '
              '${selector.shape.signature}. Provenance: '
              '$kMetalBindingProvenance',
        );
      }
    });

    test('the colon count equals the declared argument count', () {
      // An Objective-C selector spells one colon per argument. This catches
      // both halves of a mismatch: a selector transcribed with a colon missing,
      // and a shape with the wrong arity attached to a correct selector.
      for (final MetalSelector selector in kMetalSelectors) {
        final int colons = selector.name.split(':').length - 1;
        expect(
          colons,
          selector.shape.signature.explicitArgumentCount,
          reason: '${selector.receiver}.${selector.name} has $colons colon(s) '
              'but ${selector.shape.name} declares '
              '${selector.shape.signature.explicitArgumentCount} argument(s)',
        );
      }
    });

    test('declared ownership agrees with the naming convention', () {
      // Two independent statements of the same fact: the hand-written
      // returnsOwned flag, and the alloc/new/copy/mutableCopy/init rule the
      // runtime itself follows. Disagreement is a leak in one direction and an
      // over-release - a crash inside the driver, several frames later - in the
      // other.
      for (final MetalSelector selector in kMetalSelectors) {
        expect(
          selector.returnsOwned,
          objcSelectorReturnsOwned(selector.name),
          reason: '${selector.receiver}.${selector.name} is declared '
              '${selector.returnsOwned ? '+1' : 'borrowed'} but the naming '
              'convention says otherwise',
        );
      }
    });

    test('the +1 selectors are the ones a reader would expect', () {
      final List<String> owned = <String>[
        for (final MetalSelector s in kMetalSelectors)
          if (s.returnsOwned) s.name,
      ];
      expect(owned, contains('newCommandQueue'));
      expect(owned, contains('newTextureWithDescriptor:iosurface:plane:'));
      expect(owned, contains('newRenderPipelineStateWithDescriptor:error:'));
      expect(owned, contains('alloc'));
      // The autoreleased ones, which are the dangerous half: releasing any of
      // these over-releases an object Metal still owns.
      expect(owned, isNot(contains('commandBuffer')));
      expect(owned, isNot(contains('nextDrawable')));
      expect(owned, isNot(contains('texture')));
      expect(owned, isNot(contains('renderCommandEncoderWithDescriptor:')));
      expect(owned, isNot(contains('renderPassDescriptor')));
      expect(owned, isNot(contains('name')));
    });

    test('no selector returns an aggregate', () {
      // objc_msgSend is the wrong trampoline for a struct return on x86_64 and
      // the right one does not exist on arm64. -[CAMetalLayer drawableSize]
      // would be one, which is why this backend tracks the size itself and
      // only ever calls the setter.
      for (final MetalSelector selector in kMetalSelectors) {
        expect(selector.shape.signature.hasAggregateReturn, isFalse,
            reason: selector.name);
      }
    });

    test('every name appears once, or identically', () {
      // Selectors are uniqued by the runtime, so the same name on two classes
      // must carry the same shape. objectAtIndexedSubscript: and setTexture:
      // really are used on more than one class, which is why this checks
      // consistency rather than uniqueness.
      final Map<String, MetalSelector> seen = <String, MetalSelector>{};
      for (final MetalSelector selector in kMetalSelectors) {
        final MetalSelector? previous = seen[selector.name];
        if (previous == null) {
          seen[selector.name] = selector;
          continue;
        }
        expect(selector.shape, previous.shape,
            reason: '${selector.name} is sent with two different shapes '
                '(${previous.receiver} vs ${selector.receiver}); the runtime '
                'uniques selectors, so one of the two call sites is wrong');
        expect(selector.encoding, previous.encoding, reason: selector.name);
      }
    });

    test('the lookup map covers the table', () {
      expect(kMetalSelectorsByName.length,
          kMetalSelectors.map((MetalSelector s) => s.name).toSet().length);
      expect(kMetalSelectorsByName['setClearColor:']?.shape,
          ObjCSendShape.voidReturnDouble4);
    });
  });

  group('the checklist items that are documents', () {
    test('provenance names a source and admits its weakness', () {
      expect(kMetalBindingProvenance, contains('metal-cpp'));
      expect(kMetalBindingProvenance, contains('16 August 2026'));
      // The honest half: the encodings are derived, not transcribed.
      expect(kMetalBindingProvenance, contains('hand-derived'));
      expect(kMetalUnverifiedEncodings, isNotEmpty);
    });

    test('the ignored-API report is a list of decisions, not an oversight', () {
      expect(kMetalDeliberatelyUnbound, isNotEmpty);
      kMetalDeliberatelyUnbound.forEach((String api, String why) {
        expect(why.length, greaterThan(20),
            reason: '$api is listed as unbound with no reason, which makes it '
                'indistinguishable from an omission');
      });
      expect(kMetalDeliberatelyUnbound.keys, contains('MTLSamplerState'));
      expect(kMetalDeliberatelyUnbound.keys, contains('MTLSharedEvent'));
    });

    test('the required-symbol list is what a device needs to start', () {
      expect(kMetalRequiredSymbols, contains('MTLCreateSystemDefaultDevice'));
    });
  });

  group('availability off macOS', () {
    test('nothing is loaded by importing this library', () {
      // Every framework handle is a lazy top-level final, exactly as
      // io_surface.dart does it, so a Windows test suite that imports this
      // transitively pays nothing and throws nothing.
      expect(isMetalAvailable, isA<bool>());
      if (!Platform.isMacOS) {
        expect(isMetalAvailable, isFalse);
        expect(tryLoadMetal(), isNull);
        expect(metalLoadError, isNotNull);
        expect(tryLoadQuartzCore(), isNull);
      }
    });
  });

  group('checklist items that need hardware', () {
    test('every required symbol resolves in Metal.framework', () {
      final DynamicLibrary metal = tryLoadMetal()!;
      for (final String symbol in kMetalRequiredSymbols) {
        expect(() => metal.lookup<Void>(symbol), returnsNormally,
            reason: symbol);
      }
    }, skip: _needsMac);

    test('the minimal call: a system default device answers its own name', () {
      // The "minimal call test" of section 11.4. Everything above proves the
      // transcription is self-consistent; only this proves a message was
      // delivered.
      expect(isMetalAvailable, isTrue);
      final List<String> names = <String>[];
      ObjCAutoreleasePool.run(() {
        final Pointer<ObjCObject> device = mtlCreateSystemDefaultDevice();
        if (device.address == 0) return;
        try {
          final Pointer<ObjCObject> name =
              objcSendPointer(device, objcSelector('name'));
          final Pointer<ObjCObject> utf8 =
              objcSendPointer(name, objcSelector('UTF8String'));
          names.add(objcReadCString(utf8.cast<Uint8>()));
        } finally {
          objcRelease(device);
        }
      });
      // A headless or virtualised Mac legitimately has no default device, so
      // the assertion is conditional on having got one rather than on the
      // machine having a GPU.
      if (names.isNotEmpty) {
        expect(names.single, isNotEmpty);
        printOnFailure('MTLDevice.name = ${names.single}');
      }
    }, skip: _needsMac);

    test('the runtime agrees with the encodings this file declares', () {
      // Mechanism 3 of objc_runtime.dart, and the only one that can fail in a
      // way the other two cannot see: it reads the encoding the class really
      // declares instead of the one transcribed here. Selectors whose class is
      // not loaded are skipped rather than failed, because a protocol has no
      // class to ask.
      var checked = 0;
      for (final MetalSelector selector in kMetalSelectors) {
        final Pointer<ObjCObject> cls = objcClass(selector.receiver);
        if (cls.address == 0) continue;
        final String? real = objcMethodTypeEncoding(cls, selector.name);
        if (real == null) continue;
        checked++;
        expect(
          parseObjCTypeEncoding(real),
          parseObjCTypeEncoding(selector.encoding),
          reason: '${selector.receiver}.${selector.name}: the runtime says '
              '"$real", this file says "${selector.encoding}"',
        );
      }
      printOnFailure('$checked selector(s) checked against the runtime');
    }, skip: _needsMac);
  });
}

// ---------------------------------------------------------------------------
// Offset measurement
// ---------------------------------------------------------------------------

// `sizeOf<T>()` and `Pointer<T>.ref` both need a type that is concrete at
// compile time, so these helpers cannot be generic over the struct. The size
// and the cast are supplied by the caller instead; the measurement itself -
// zero the memory, write one sentinel, find the bytes - is shared.

/// A 64-bit pattern with no repeating byte, so that finding it twice means
/// something went wrong rather than that the value was `1`.
const int kWordSentinel = 0x1122334455667788;
const double kDoubleSentinel = 1234.5678;
const double kFloatSentinel = 1234.5;
const int kUint32Sentinel = 0x1A2B3C4D;

/// Where each named `UintPtr` field really lives.
///
/// Zeroes the struct, writes a sentinel through one writer, and finds the byte
/// sequence. Measuring rather than restating is the whole point: a declaration
/// says where a field is *meant* to be, and the D3D12 union that starts at 16
/// instead of 12 is what happens when only the declaration is consulted.
Map<String, int> _wordOffsets(
  int size,
  Map<String, void Function(Pointer<Uint8>)> writers,
) =>
    _offsets(
        size,
        writers,
        (ByteData(8)..setUint64(0, kWordSentinel, Endian.host))
            .buffer
            .asUint8List());

/// Where each named `Double` field really lives.
Map<String, int> _doubleOffsets(
  int size,
  Map<String, void Function(Pointer<Uint8>)> writers,
) =>
    _offsets(
        size,
        writers,
        (ByteData(8)..setFloat64(0, kDoubleSentinel, Endian.host))
            .buffer
            .asUint8List());

/// Where each named `Float` field really lives.
Map<String, int> _floatOffsets(
  int size,
  Map<String, void Function(Pointer<Uint8>)> writers,
) =>
    _offsets(
        size,
        writers,
        (ByteData(4)..setFloat32(0, kFloatSentinel, Endian.host))
            .buffer
            .asUint8List());

/// Where each named `Uint32` field really lives.
Map<String, int> _uint32Offsets(
  int size,
  Map<String, void Function(Pointer<Uint8>)> writers,
) =>
    _offsets(
        size,
        writers,
        (ByteData(4)..setUint32(0, kUint32Sentinel, Endian.host))
            .buffer
            .asUint8List());

Map<String, int> _offsets(
  int size,
  Map<String, void Function(Pointer<Uint8>)> writers,
  Uint8List needle,
) {
  final Map<String, int> found = <String, int>{};
  writers.forEach((String name, void Function(Pointer<Uint8>) write) {
    // NativeAllocator zeroes, which is what makes a single sentinel findable.
    final Pointer<Uint8> pointer =
        NativeAllocator.instance.allocate<Uint8>(size);
    try {
      write(pointer);
      found[name] = _findUnique(pointer.asTypedList(size), needle, what: name);
    } finally {
      NativeAllocator.instance.free(pointer);
    }
  });
  return found;
}

/// The single index at which [needle] occurs in [haystack].
///
/// Fails when it occurs zero times - the setter did not write what was
/// expected - or more than once, which would make the answer ambiguous and is
/// why the sentinels are eight and four bytes of unrepeated pattern rather
/// than a convenient `1`.
int _findUnique(Uint8List haystack, Uint8List needle, {required String what}) {
  final List<int> hits = <int>[];
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) hits.add(i);
  }
  if (hits.length != 1) {
    fail('$what: expected the sentinel exactly once, found ${hits.length} '
        'occurrence(s) at $hits in ${haystack.length} bytes');
  }
  return hits.single;
}
