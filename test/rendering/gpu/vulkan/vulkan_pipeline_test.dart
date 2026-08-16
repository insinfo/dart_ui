/// The second of the three checks `vulkan_spirv.dart` names: the driver's.
///
/// `vulkan_spirv_test.dart` proves the modules are well-formed binary. This
/// file proves a real Vulkan implementation **accepts** them: it parses every
/// module, matches the vertex shader's declared inputs against the pipeline's
/// vertex attribute descriptions, matches the fragment shader's descriptor
/// against the pipeline layout, and compiles both to machine code. A pipeline
/// that is created at all has been through all of that.
///
/// It is a stronger check than it looks. `vkCreateGraphicsPipelines` is where
/// a wrong `Location` decoration, a push-constant block with no `Block`
/// decoration, a missing `OriginUpperLeft`, a `Sampled` operand of 0 on the
/// image type, or an entry point whose name does not match `pName` all come
/// out - each of which is a module that assembles perfectly.
library;

import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_ffi.g.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_pipeline.dart';
import 'package:test/test.dart';

import 'vulkan_session.dart';

void main() {
  final VulkanSession session = VulkanSession.open(validation: true);
  VulkanPipelines? pipelines;

  group('the pipelines this driver builds from the generated SPIR-V', () {
    setUpAll(() {
      if (session.skipReason != null) return;
      pipelines = VulkanPipelines.create(session.device!,
          colorFormat: VkFormat.VK_FORMAT_B8G8R8A8_UNORM);
    });
    tearDownAll(() {
      pipelines?.dispose(session.device!);
      session.close();
    });

    test('the driver compiled all nine', () {
      // Null here means vkCreateShaderModule or vkCreateGraphicsPipelines
      // refused, which for a module this backend generated itself is a defect
      // in `vulkan_spirv.dart` and not a driver difference to be tolerated.
      expect(pipelines, isNotNull,
          reason: 'the driver refused the generated SPIR-V or the pipeline '
              'state built around it');
      expect(pipelines!.pipelineCount,
          GpuPipelineKind.values.length * kVulkanBlendModes.length);
      expect(pipelines!.shaderWords, greaterThan(0));
      printOnFailure('${pipelines!.shaderWords} SPIR-V words compiled on '
          '${session.device!.physicalDevice.name}');
    }, skip: session.skipReason);

    test('every (kind, blend mode) pair maps to a distinct pipeline', () {
      // The index arithmetic in `pipelineFor`. Getting it wrong would draw a
      // coverage mask with the image shader, or source-over with the plus
      // equation - both of which produce a picture rather than an error.
      final Set<int> seen = <int>{};
      for (final GpuPipelineKind kind in GpuPipelineKind.values) {
        for (final int blendMode in kVulkanBlendModes) {
          final int address = pipelines!.pipelineFor(kind, blendMode).address;
          expect(address, isNot(0));
          expect(seen.add(address), isTrue,
              reason: '${kind.name} with blend mode $blendMode returned a '
                  'pipeline another pair already returned');
        }
      }
    }, skip: session.skipReason);

    test('a blend mode with no pipeline is refused by name', () {
      expect(() => pipelines!.pipelineFor(GpuPipelineKind.solid, 999),
          throwsArgumentError);
    }, skip: session.skipReason);

    test('the two render passes are distinct objects', () {
      expect(pipelines!.clearRenderPass.address, isNot(0));
      expect(pipelines!.loadRenderPass.address, isNot(0));
      expect(pipelines!.clearRenderPass.address,
          isNot(pipelines!.loadRenderPass.address));
    }, skip: session.skipReason);

    test('the validation layer reported nothing, or said it was absent', () {
      // Conditional on purpose, and the condition is reported rather than
      // hidden. `VK_LAYER_KHRONOS_validation` ships with the LunarG SDK and is
      // not present on a machine that only has a driver - including the one
      // this backend was written on. Asserting silence from a layer that is
      // not loaded would be an assertion about nothing.
      final instance = session.instance!;
      if (!instance.validationEnabled) {
        printOnFailure('validation layer not installed; '
            'vkCreateGraphicsPipelines still accepted every module');
        return;
      }
      expect(instance.problems, isEmpty,
          reason: 'the validation layer objected while the pipelines were '
              'being built:\n${instance.problems.join('\n')}');
    }, skip: session.skipReason);
  });
}
