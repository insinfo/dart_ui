/// Renders a model through the **Vulkan mesh pipeline** off-screen and prints
/// what a frame costs, beside what the CPU rasteriser makes of the same scene.
///
/// `tool/mesh_gpu_probe.dart` (Direct3D 11) and `tool/d3d12_mesh_probe.dart`
/// are the model, and the argument they make applies here: a pipeline that
/// compiles, does not throw and reports plausible triangle counts can still be
/// drawing nonsense, and on a GPU the nonsense is quiet - a wrong winding is a
/// hollow model, a missing depth remap is a model with its near half gone, a
/// missing Y negation is a model upside down, and none of the three raises an
/// error.
///
/// ## What the number here measures, and why it is not the other probes'
///
/// The two Direct3D probes issue N draws into one command buffer and read back
/// once, so their "ms/frame" is N draws divided by one GPU round trip. **This
/// one cannot.** A Vulkan target opens its command buffer inside `present` and
/// `VulkanOffscreenTarget.present` ends with `vkDeviceWaitIdle` before it maps
/// the readback, so every frame here is a complete submit-and-wait cycle and N
/// of them are N round trips.
///
/// Reporting that as a frame time would blame the pipeline for a fence. So
/// this measures **twice**: N frames with the model and N frames of an empty
/// scene through the same target, and prints the median of both together with
/// the difference. The empty run is the round trip and everything else the
/// target does per frame; the difference is what drawing the model costs, and
/// it is the number comparable with the Direct3D probes'.
///
/// ### The baseline can come out *larger* than the frame with the model
///
/// Measured on an Intel UHD Graphics at 1080x780: 19.7 ms with a
/// 451 838-triangle model and 26 to 31 ms with nothing at all, run after run.
/// That is not noise - the median over 120 frames is stable and the sign does
/// not change - and it is not a bug in the pipeline. An empty submission gives
/// an integrated GPU no reason to leave its lowest power state, so the fixed
/// cost of `vkDeviceWaitIdle` plus a 3 MB readback is paid at idle clocks,
/// while the same cost beside real work is paid at boosted ones.
///
/// So **the subtraction is only meaningful where the round trip is small
/// relative to the draw.** At 512x384 the same model reports 9.15 ms against a
/// 7.10 ms baseline - 2.05 ms of model - and the sign behaves. At 1080x780 use
/// `tool/vulkan_mesh_window_probe.dart` instead: a swap chain gives the driver
/// a steady stream of real frames, which is the condition this probe cannot
/// create.
///
/// ```
/// dart run tool/vulkan_mesh_probe.dart D:/3d/model.stl --size=1080x780 --frames=60
/// ```
///
/// Compile before judging the speed: `dart run` spends about six seconds
/// front-end compiling this package before `main` starts. See
/// `tool/startup_cost.dart`.
///
/// Exit codes: 0 when it drew, 2 when this machine has no Vulkan device or the
/// model would not load, 1 when the pipeline refused to build.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_backend.dart';
import 'package:dart_ui/src/rendering/gpu/vulkan/vulkan_mesh_pipeline.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';
import 'package:dart_ui/src/rendering/renderer.dart';

const String _ramp = ' .:-=+*#%@';

String? _valueOf(List<String> arguments, String name) {
  for (final String argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

Future<void> main(List<String> arguments) async {
  final List<String> paths =
      arguments.where((String a) => !a.startsWith('--')).toList();
  if (paths.isEmpty) {
    stderr.writeln('uso: dart run tool/vulkan_mesh_probe.dart <modelo> '
        '[--size=1080x780] [--frames=30] [--shading=smooth] [--diff]');
    exitCode = 2;
    return;
  }

  final List<int> size = _size(_valueOf(arguments, '--size') ?? '1080x780');
  final int frames = int.tryParse(_valueOf(arguments, '--frames') ?? '') ?? 30;
  final MeshShading shading = switch (_valueOf(arguments, '--shading')) {
    'flat' => MeshShading.flat,
    'unlit' => MeshShading.unlit,
    'wireframe' => MeshShading.wireframe,
    _ => MeshShading.smooth,
  };

  final VulkanRenderDevice device;
  try {
    device = VulkanRenderDevice.open();
  } on Object catch (error) {
    stderr.writeln('VULKAN_MESH_GPU=SKIP reason=no Vulkan device: $error');
    exitCode = 2;
    return;
  }

  final Object built = VulkanMeshRenderer.create(device);
  if (built is BackendDiagnostic) {
    stderr.writeln('VULKAN_MESH_GPU=FAIL ${built.message}\n'
        '  ${built.detail ?? ''}');
    device.dispose();
    exitCode = 1;
    return;
  }
  final renderer = built as VulkanMeshRenderer;

  final target = device.createTarget(MemorySurfaceDescriptor(
    pixelWidth: size[0],
    pixelHeight: size[1],
    // BGRA, because `MeshRasterizer` writes its words as BGRA into a
    // Framebuffer and the two pictures have to be compared byte for byte.
    format: PixelFormat.bgra8888Premultiplied,
  )) as VulkanOffscreenTarget;

  try {
    stdout.writeln('DEVICE ${device.info.deviceDescription}, depth format '
        '${renderer.depthFormat}');
    for (final String path in paths) {
      final File file = File(path);
      if (!file.existsSync()) {
        stderr.writeln('não encontrei $path');
        exitCode = 2;
        continue;
      }
      final Mesh3D mesh;
      try {
        mesh = loadMesh(
          Uint8List.fromList(file.readAsBytesSync()),
          name: file.uri.pathSegments.last,
          resolveBuffer: (String uri) {
            final File sibling = File('${file.parent.path}'
                '${Platform.pathSeparator}${Uri.decodeComponent(uri)}');
            return sibling.existsSync()
                ? Uint8List.fromList(sibling.readAsBytesSync())
                : null;
          },
        );
      } on MeshParseException catch (error) {
        stdout.writeln('$path\n  RECUSADO: ${error.message}');
        exitCode = 2;
        continue;
      }

      final Bounds3 bounds = mesh.computeBounds();
      final MeshScene scene = MeshScene(
        mesh: mesh,
        camera: MeshCamera.frame(bounds),
        shading: shading,
      );

      // Warm: the first frame uploads the geometry and builds the pipeline for
      // this colour format, and reporting either as a frame time would
      // overstate a 451 838-triangle model by two orders of magnitude.
      await _drawOnce(target, renderer, scene);
      final int uploadsAfterWarmup = renderer.bufferUploadCount;

      // Per-frame samples and a median, not a total and a mean. An offscreen
      // Vulkan frame ends in `vkDeviceWaitIdle` and a 3 MB readback memcpy, so
      // one descheduled frame moves a sixty-frame mean by several
      // milliseconds - measured, and it is why an earlier version of this probe
      // reported the model as *negative* cost twice in three runs.
      final List<int> drawn = <int>[];
      final Stopwatch clock = Stopwatch()..start();
      for (var i = 0; i < frames; i++) {
        final int at = clock.elapsedMicroseconds;
        await _drawOnce(target, renderer, scene);
        drawn.add(clock.elapsedMicroseconds - at);
      }

      // The same target, the same submit, the same wait, no model. See the
      // library comment: this is the round trip that has to come out of the
      // number above before it can be compared with the Direct3D probes'.
      final List<int> blank = <int>[];
      for (var i = 0; i < frames; i++) {
        final int at = clock.elapsedMicroseconds;
        final Frame frame = target.beginFrame(const FrameRequest());
        await target.present(frame);
        blank.add(clock.elapsedMicroseconds - at);
      }
      clock.stop();

      final double withModel = _median(drawn) / 1000;
      final double roundTrip = _median(blank) / 1000;
      stdout
        ..writeln(path)
        ..writeln('  ${mesh.format} · ${mesh.triangleCount} triângulos · '
            '${mesh.primitives.length} primitivas · extensão '
            '${bounds.extent.toStringAsFixed(2)}')
        ..writeln('  quadro completo ${withModel.toStringAsFixed(2)} ms '
            '(mediana) em ${size[0]}x${size[1]} ($frames quadros, um submit e '
            'uma espera cada)')
        ..writeln('  quadro vazio ${roundTrip.toStringAsFixed(2)} ms · '
            'MODELO ${(withModel - roundTrip).toStringAsFixed(2)} ms/quadro')
        ..writeln('  uploads ${renderer.bufferUploadCount} '
            '(${renderer.bufferUploadCount - uploadsAfterWarmup} durante a '
            'medição) · '
            '${(renderer.cachedBufferBytes / 1048576).toStringAsFixed(1)} MiB '
            'residentes')
        ..writeln(_ascii(target.framebuffer, columns: 78));

      if (arguments.contains('--diff')) {
        final Framebuffer cpu = Framebuffer.allocate(
          width: size[0],
          height: size[1],
          format: PixelFormat.bgra8888Premultiplied,
        );
        final rasterizer = MeshRasterizer();
        final Stopwatch cpuWatch = Stopwatch()..start();
        rasterizer.render(
          cpu,
          mesh,
          scene.camera,
          shading: shading,
          backgroundArgb: scene.backgroundArgb ?? 0xFF10151F,
          lightDirection: scene.lightDirection,
          ambient: scene.ambient,
        );
        cpuWatch.stop();
        stdout
          ..writeln(
              '  CPU ${(cpuWatch.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms/quadro · ${rasterizer.stats}')
          ..writeln('  diferença: ${_compare(cpu, target.framebuffer)}');
      }
      renderer.discardMesh(mesh);
    }
  } finally {
    target.dispose();
    renderer.dispose();
    device.dispose();
  }
}

double _median(List<int> values) {
  if (values.isEmpty) return 0;
  final List<int> sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2].toDouble();
}

Future<void> _drawOnce(
  VulkanOffscreenTarget target,
  VulkanMeshRenderer renderer,
  MeshScene scene,
) async {
  final Frame frame = target.beginFrame(const FrameRequest());
  renderer.drawScene(target, scene);
  await target.present(frame);
}

List<int> _size(String value) {
  final List<String> parts = value.split('x');
  if (parts.length != 2) return <int>[1080, 780];
  return <int>[
    int.tryParse(parts[0]) ?? 1080,
    int.tryParse(parts[1]) ?? 780,
  ];
}

/// The frame as text, so a headless run can see the model.
String _ascii(Framebuffer image, {required int columns}) {
  final int step = (image.width / columns).ceil().clamp(1, image.width);
  final StringBuffer out = StringBuffer();
  for (var y = 0; y < image.height; y += step * 2) {
    out.write('  ');
    for (var x = 0; x < image.width; x += step) {
      final int at = y * image.bytesPerRow + x * 4;
      final int luma = (image.pixels[at] * 29 +
              image.pixels[at + 1] * 150 +
              image.pixels[at + 2] * 77) >>
          8;
      out.write(_ramp[(luma * (_ramp.length - 1) ~/ 255).clamp(0, 9)]);
    }
    out.writeln();
  }
  return out.toString();
}

/// The two fractions the parity tests use, over a whole model.
String _compare(Framebuffer a, Framebuffer b) {
  var differing = 0;
  var worst = 0;
  var overOne = 0;
  var overSixteen = 0;
  final int pixels = a.width * a.height;
  for (var y = 0; y < a.height; y++) {
    final int rowA = y * a.bytesPerRow;
    final int rowB = y * b.bytesPerRow;
    for (var x = 0; x < a.width; x++) {
      var channel = 0;
      for (var c = 0; c < 3; c++) {
        final int delta =
            (a.pixels[rowA + x * 4 + c] - b.pixels[rowB + x * 4 + c]).abs();
        if (delta > channel) channel = delta;
      }
      if (channel == 0) continue;
      differing++;
      if (channel > worst) worst = channel;
      if (channel > 1) overOne++;
      if (channel > 16) overSixteen++;
    }
  }
  return '$differing/$pixels px diferentes, máx $worst níveis, '
      '>1: $overOne (${(overOne * 100 / pixels).toStringAsFixed(3)}%), '
      '>16: $overSixteen '
      '(${(overSixteen * 100 / pixels).toStringAsFixed(3)}%)';
}
