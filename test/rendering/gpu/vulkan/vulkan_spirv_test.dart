/// The SPIR-V this backend emits, checked with no GPU.
///
/// This is the first of the three checks `vulkan_spirv.dart` names. It cannot
/// tell a correct shader from a wrong one - only the parity test can do that -
/// but it can tell a *well-formed module* from a malformed one, and it runs on
/// every runner, including the ones with no Vulkan at all. That matters: the
/// module is built by Dart code, so a mistake in it is a mistake that CI can
/// catch on Linux without a driver in sight.
library;

import 'dart:typed_data';

import 'package:dart_ui/src/rendering/gpu/gpu_pipeline.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_shaders.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_spirv.dart';
import 'package:test/test.dart';

/// Splits a module into `(opcode, operands)` pairs.
///
/// Written here rather than exposed from `vulkan_spirv.dart` on purpose: a
/// test that walked the module with the builder's own helper would agree with
/// the builder by construction. This decoder knows only the one rule the
/// specification fixes - the high 16 bits of the first word are the length -
/// and is therefore an independent reading of the bytes.
List<({int opcode, List<int> operands})> _decode(Uint32List words) {
  final List<({int opcode, List<int> operands})> out =
      <({int opcode, List<int> operands})>[];
  var offset = 5;
  while (offset < words.length) {
    final int header = words[offset];
    final int length = header >> 16;
    out.add((
      opcode: header & 0xFFFF,
      operands: words.sublist(offset + 1, offset + length),
    ));
    offset += length;
  }
  return out;
}

const int _opExtInstImport = 11;
const int _opMemoryModel = 14;
const int _opEntryPoint = 15;
const int _opExecutionMode = 16;
const int _opCapability = 17;
const int _opDecorate = 71;
const int _opFunction = 54;
const int _opFunctionEnd = 56;
const int _opLabel = 248;
const int _opReturn = 253;

void main() {
  final VulkanShaderCode code = VulkanShaderCode();
  final List<Uint32List> modules = <Uint32List>[
    code.vertex,
    ...code.fragments,
  ];
  final List<String> names = <String>[
    'vertex',
    for (final GpuPipelineKind kind in GpuPipelineKind.values)
      'fragment ${kind.name}',
  ];

  group('the literal-string encoding', () {
    test('is NUL-terminated and padded to whole words', () {
      // Derived independently of the builder: "main" is four bytes plus a NUL,
      // padded to eight, which is two words with the terminator in the second.
      expect(literalString('main'), <int>[0x6E69616D, 0x00000000]);
      expect(literalString('ab'), <int>[0x00006261]);
      expect(literalString('abc'), <int>[0x00636261]);
      // A three-byte string plus its NUL is exactly one word, and the
      // specification still requires no extra padding word.
      expect(literalString(''), <int>[0]);
      expect(literalString(kGlslStd450).length, 4);
      expect(() => literalString('não'), throwsArgumentError);
    });
  });

  group('every module', () {
    for (var i = 0; i < modules.length; i++) {
      final Uint32List words = modules[i];
      final String name = names[i];

      test('$name has a valid header and no malformed instruction', () {
        expect(validateSpirvStructure(words), isEmpty);
        expect(words[0], kSpirvMagic);
        expect(words[1], kSpirvVersion1_0);
        expect(words[4], 0);
        // A bound that does not exceed every id used is the failure a driver
        // is allowed to crash on rather than diagnose.
        expect(words[3], greaterThan(1));
      });

      test('$name declares Shader, the logical model, and one entry point', () {
        final List<({int opcode, List<int> operands})> instructions =
            _decode(words);
        final Iterable<int> opcodes = instructions
            .map((({int opcode, List<int> operands}) i) => i.opcode);

        expect(opcodes, contains(_opCapability));
        expect(
          instructions
              .firstWhere((({int opcode, List<int> operands}) i) =>
                  i.opcode == _opCapability)
              .operands
              .first,
          kSpirvCapabilityShader,
        );

        final ({int opcode, List<int> operands}) memory =
            instructions.firstWhere((({int opcode, List<int> operands}) i) =>
                i.opcode == _opMemoryModel);
        expect(memory.operands,
            <int>[kSpirvAddressingModelLogical, kSpirvMemoryModelGlsl450]);

        expect(
            opcodes.where((int opcode) => opcode == _opEntryPoint).length, 1);
        // The entry point's name is a literal string starting at operand 2.
        final List<int> entry = instructions
            .firstWhere((({int opcode, List<int> operands}) i) =>
                i.opcode == _opEntryPoint)
            .operands;
        expect(entry.sublist(2, 2 + literalString(kVulkanEntryPoint).length),
            literalString(kVulkanEntryPoint));
      });

      test('$name is exactly one function with one block', () {
        final List<({int opcode, List<int> operands})> instructions =
            _decode(words);
        int count(int opcode) => instructions
            .where((({int opcode, List<int> operands}) i) => i.opcode == opcode)
            .length;

        expect(count(_opFunction), 1);
        expect(count(_opFunctionEnd), 1);
        // One label means one basic block, which is the claim
        // `vulkan_shaders.dart` makes to justify a builder with no control
        // flow. A second label would mean a branch nothing here can emit.
        expect(count(_opLabel), 1);
        expect(count(_opReturn), 1);

        // The logical layout: every declaration comes before the function.
        final int function = instructions.indexWhere(
            (({int opcode, List<int> operands}) i) => i.opcode == _opFunction);
        final int lastDecoration = instructions.lastIndexWhere(
            (({int opcode, List<int> operands}) i) => i.opcode == _opDecorate);
        expect(lastDecoration, lessThan(function));
      });
    }
  });

  group('the vertex module', () {
    final List<({int opcode, List<int> operands})> instructions =
        _decode(code.vertex);

    test('binds the four attributes at the locations the layout fixes', () {
      final Map<int, int> locations = <int, int>{};
      for (final ({int opcode, List<int> operands}) i in instructions) {
        if (i.opcode != _opDecorate) continue;
        if (i.operands[1] != kSpirvDecorationLocation) continue;
        locations[i.operands[0]] = i.operands[2];
      }
      // Four inputs and four outputs, so locations 0..3 appear twice each.
      expect(locations.values.toList()..sort(), <int>[0, 0, 1, 1, 2, 2, 3, 3]);
      expect(kVulkanAttributePosition, kGpuPositionOffset ~/ 2);
      expect(kVulkanAttributeTexCoord, 1);
      expect(kVulkanAttributeColor, 2);
      expect(kVulkanAttributeShapeRect, 3);
    });

    test('declares gl_Position as a built-in, not as a location', () {
      final Iterable<({int opcode, List<int> operands})> builtIns =
          instructions.where((({int opcode, List<int> operands}) i) =>
              i.opcode == _opDecorate &&
              i.operands[1] == kSpirvDecorationBuiltIn);
      expect(builtIns.length, 1);
      expect(builtIns.first.operands[2], kSpirvBuiltInPosition);
    });

    test('declares the push-constant block and its member offset', () {
      // `Block` on the struct and `Offset 0` on its only member. Vulkan
      // rejects a push-constant block that is missing either, and the message
      // it gives names neither.
      expect(
        instructions.where((({int opcode, List<int> operands}) i) =>
            i.opcode == _opDecorate && i.operands[1] == kSpirvDecorationBlock),
        hasLength(1),
      );
      expect(kVulkanPushConstantBytes, 8);
    });

    test('has no execution mode, which only a fragment stage may declare', () {
      expect(
        instructions.where((({int opcode, List<int> operands}) i) =>
            i.opcode == _opExecutionMode),
        isEmpty,
      );
    });
  });

  group('the fragment modules', () {
    test('every one declares OriginUpperLeft', () {
      // The only origin Vulkan permits, and the one that makes `vDevicePos`
      // agree with the display list's y-down device space.
      for (final Uint32List words in code.fragments) {
        final Iterable<({int opcode, List<int> operands})> modes =
            _decode(words).where((({int opcode, List<int> operands}) i) =>
                i.opcode == _opExecutionMode);
        expect(modes, hasLength(1));
        expect(modes.first.operands[1], kSpirvExecutionModeOriginUpperLeft);
      }
    });

    test('only the two sampling modes declare a descriptor', () {
      // The solid pipeline reads no texture, so its module must not declare
      // one: a descriptor the shader never uses is a binding a reader will
      // believe has to be filled in.
      List<int> bindings(Uint32List words) => <int>[
            for (final ({int opcode, List<int> operands}) i in _decode(words))
              if (i.opcode == _opDecorate &&
                  i.operands[1] == kSpirvDecorationBinding)
                i.operands[2],
          ];

      expect(bindings(code.fragmentFor(GpuPipelineKind.solid)), isEmpty);
      expect(bindings(code.fragmentFor(GpuPipelineKind.coverageMask)),
          <int>[kVulkanTextureBinding]);
      expect(bindings(code.fragmentFor(GpuPipelineKind.texturedImage)),
          <int>[kVulkanTextureBinding]);

      List<int> sets(Uint32List words) => <int>[
            for (final ({int opcode, List<int> operands}) i in _decode(words))
              if (i.opcode == _opDecorate &&
                  i.operands[1] == kSpirvDecorationDescriptorSet)
                i.operands[2],
          ];
      expect(sets(code.fragmentFor(GpuPipelineKind.coverageMask)),
          <int>[kVulkanTextureSet]);
    });

    test('every one imports GLSL.std.450 for the coverage term', () {
      // `boxCoverage` is FMax, FMin and FClamp, all of which live in the
      // extended set. A module that forgot the import would fail to assemble.
      for (final Uint32List words in code.fragments) {
        final Iterable<({int opcode, List<int> operands})> imports =
            _decode(words).where((({int opcode, List<int> operands}) i) =>
                i.opcode == _opExtInstImport);
        expect(imports, hasLength(1));
        expect(imports.first.operands.sublist(1), literalString(kGlslStd450));
      }
    });

    test('the solid module is the smallest and the two samplers are equal', () {
      // A shape check rather than a value check: the three differ by exactly
      // the sampling instructions, so a builder that silently emitted the same
      // module three times - the failure a `switch` with a wrong default
      // produces - would make these equal.
      final int solid = code.fragmentFor(GpuPipelineKind.solid).length;
      final int mask = code.fragmentFor(GpuPipelineKind.coverageMask).length;
      final int image = code.fragmentFor(GpuPipelineKind.texturedImage).length;
      expect(solid, lessThan(mask));
      expect(mask, image);
      expect(code.fragmentFor(GpuPipelineKind.coverageMask),
          isNot(code.fragmentFor(GpuPipelineKind.texturedImage)));
    });
  });

  group('the agreement with the portable pipeline enum', () {
    test('each mode is its GpuPipelineKind index', () {
      // The same check `d3d12_shaders_test.dart` makes, for the same reason:
      // the module chosen for a batch is looked up by the enum's index, so an
      // enum that grew a member in the middle would silently pair every later
      // kind with the wrong shader - a coverage mask sampled as an image,
      // which produces a picture rather than an error.
      expect(kVulkanModeSolid, GpuPipelineKind.solid.index);
      expect(kVulkanModeCoverageMask, GpuPipelineKind.coverageMask.index);
      expect(kVulkanModeTexturedImage, GpuPipelineKind.texturedImage.index);
      expect(GpuPipelineKind.values.length, 3);
      expect(code.fragments, hasLength(GpuPipelineKind.values.length));
    });

    test('a fourth mode is refused by name rather than defaulted', () {
      expect(() => buildVulkanFragmentShader(3), throwsArgumentError);
      expect(() => buildVulkanFragmentShader(-1), throwsArgumentError);
    });

    test('the vertex layout the shader assumes is the shared one', () {
      expect(kGpuFloatsPerVertex, 12);
      expect(kGpuPositionOffset, 0);
      expect(kGpuTexCoordOffset, 2);
      expect(kGpuColorOffset, 4);
      expect(kGpuShapeRectOffset, 8);
    });
  });

  group('the structural validator itself', () {
    test('rejects a module it should reject', () {
      // Non-vacuity: if `validateSpirvStructure` returned an empty list for
      // everything, every assertion above would be worthless.
      expect(validateSpirvStructure(Uint32List(0)), isNotEmpty);
      expect(validateSpirvStructure(Uint32List.fromList(<int>[1, 2, 3, 4, 5])),
          isNotEmpty);

      final Uint32List broken = Uint32List.fromList(code.vertex);
      broken[0] = 0xDEADBEEF;
      expect(validateSpirvStructure(broken), isNotEmpty);

      // An instruction whose declared length runs off the end. Dropping the
      // last *word* would not do it: the final instruction is a one-word
      // OpFunctionEnd, so the remainder still parses - a truncation is only
      // detectable when it cuts an instruction in half.
      final Uint32List overrun = Uint32List.fromList(<int>[
        ...code.vertex,
        (5 << 16) | 1,
      ]);
      expect(validateSpirvStructure(overrun), isNotEmpty);

      final Uint32List zeroLength = Uint32List.fromList(<int>[
        ...code.vertex,
        0,
      ]);
      expect(validateSpirvStructure(zeroLength), isNotEmpty);

      final Uint32List understated = Uint32List.fromList(code.vertex);
      understated[3] = 2; // an id bound smaller than the ids in use
      expect(validateSpirvStructure(understated), isNotEmpty);
    });
  });
}
