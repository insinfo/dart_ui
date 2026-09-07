/// Renders a model through the **Direct3D 11 mesh pipeline** and prints what
/// came out, beside what the CPU rasteriser makes of the same scene.
///
/// `tool/mesh_render_probe.dart` is the model and the argument it makes applies
/// here twice over: a pipeline that compiles, does not throw and reports
/// plausible triangle counts can still be drawing nonsense, and on a GPU the
/// nonsense is quieter - a wrong winding is a hollow model, a missing depth
/// remap is a model with its near half gone, and neither raises an error.
///
/// So this prints the frame as text and, with `--diff`, subtracts the CPU
/// rasteriser's frame from it channel by channel and reports the deviation. The
/// numbers it prints are the ones `test/rendering/gpu/d3d11/`
/// `d3d11_mesh_cpu_parity_test.dart` asserts; this is where they are measured
/// and where a new model can be measured without writing a test.
///
/// ```
/// dart run tool/mesh_gpu_probe.dart D:/3d/sonic.glb --diff
/// dart run tool/mesh_gpu_probe.dart D:/3d/model.stl --size=1080x780 --frames=60
/// ```
///
/// Compile before judging the speed: `dart run` spends about six seconds
/// front-end compiling this package before `main` starts. See
/// `tool/startup_cost.dart`.
///
/// Exit codes: 0 when it drew, 2 when this machine has no Direct3D 11 device or
/// the model would not load, 1 when the pipeline refused to build.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_backend.dart';
import 'package:dart_ui/src/rendering/gpu/d3d11/d3d11_mesh_pipeline.dart';
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
    stderr.writeln('uso: dart run tool/mesh_gpu_probe.dart <modelo> '
        '[--size=1080x780] [--frames=1] [--shading=smooth] [--diff] '
        '[--ppm=saida.ppm]');
    exitCode = 2;
    return;
  }
  if (!Platform.isWindows) {
    stderr.writeln('MESH_GPU=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }

  final List<int> size = _size(_valueOf(arguments, '--size') ?? '1080x780');
  final int frames = int.tryParse(_valueOf(arguments, '--frames') ?? '') ?? 1;
  final MeshShading shading = switch (_valueOf(arguments, '--shading')) {
    'flat' => MeshShading.flat,
    'unlit' => MeshShading.unlit,
    'wireframe' => MeshShading.wireframe,
    _ => MeshShading.smooth,
  };

  final D3d11RenderDevice device;
  try {
    device = D3d11RendererBackend.openDevice();
  } on Object catch (error) {
    stderr.writeln('MESH_GPU=SKIP reason=no D3D11 device: $error');
    exitCode = 2;
    return;
  }

  final Object built = D3d11MeshRenderer.create(device);
  if (built is BackendDiagnostic) {
    stderr.writeln('MESH_GPU=FAIL ${built.message}\n  ${built.detail ?? ''}');
    device.dispose();
    exitCode = 1;
    return;
  }
  final renderer = built as D3d11MeshRenderer;

  final target = device.createTarget(MemorySurfaceDescriptor(
    pixelWidth: size[0],
    pixelHeight: size[1],
    // BGRA, because `MeshRasterizer` writes its words as BGRA into a
    // Framebuffer and the two pictures have to be compared byte for byte.
    format: PixelFormat.bgra8888Premultiplied,
  )) as D3d11OffscreenTarget;

  try {
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

      // Warm: the first draw uploads the geometry and compiles nothing else,
      // and reporting the upload as the frame time would overstate a
      // 451,838-triangle model by two orders of magnitude.
      await _drawOnce(target, renderer, scene);
      final int uploadsAfterWarmup = renderer.bufferUploadCount;

      // The GPU number. N draws issued back to back and then **one** readback,
      // which is the only thing here that waits for the device: timing a
      // single `drawInto` measures how long it took to write a command buffer,
      // not how long the hardware took to execute it.
      final Stopwatch wall = Stopwatch()..start();
      var submitUs = 0;
      final Frame frame = target.beginFrame(const FrameRequest());
      for (var i = 0; i < frames; i++) {
        submitUs += renderer
            .drawInto(
              target.colorRenderTargetView,
              targetWidth: size[0],
              targetHeight: size[1],
              scene: scene,
            )
            .microseconds;
      }
      await target.present(frame);
      wall.stop();

      stdout
        ..writeln(path)
        ..writeln('  ${mesh.format} · ${mesh.triangleCount} triângulos · '
            '${mesh.primitives.length} primitivas · extensão '
            '${bounds.extent.toStringAsFixed(2)}')
        ..writeln(
            '  GPU ${(wall.elapsedMicroseconds / frames / 1000).toStringAsFixed(2)} ms/quadro em ${size[0]}x${size[1]} '
            '($frames quadros, uma leitura de volta ao fim)')
        ..writeln(
            '  submissão ${(submitUs / frames / 1000).toStringAsFixed(3)} ms/quadro · '
            'uploads ${renderer.bufferUploadCount} '
            '(${renderer.bufferUploadCount - uploadsAfterWarmup} durante a '
            'medição) · ${(renderer.cachedBufferBytes / 1048576).toStringAsFixed(1)} MiB residentes')
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
        final _Difference difference = _compare(cpu, target.framebuffer);
        stdout
          ..writeln(
              '  CPU ${(cpuWatch.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms/quadro · ${rasterizer.stats}')
          ..writeln('  diferença: $difference');
      }

      final String? ppm = _valueOf(arguments, '--ppm');
      if (ppm != null) {
        _writePpm(File(ppm), target.framebuffer);
        stdout.writeln('  PPM em $ppm');
      }
      renderer.discardMesh(mesh);
    }
  } finally {
    renderer.dispose();
    target.dispose();
    device.dispose();
  }
}

Future<void> _drawOnce(
  D3d11OffscreenTarget target,
  D3d11MeshRenderer renderer,
  MeshScene scene,
) async {
  final Frame frame = target.beginFrame(const FrameRequest());
  renderer.drawScene(target, scene);
  await target.present(frame);
}

List<int> _size(String value) {
  final List<String> parts = value.split('x');
  final int width = int.tryParse(parts.first) ?? 1080;
  final int height = parts.length > 1 ? int.tryParse(parts[1]) ?? width : width;
  return <int>[width, height];
}

/// How far apart two renders of the same scene are.
final class _Difference {
  const _Difference({
    required this.pixels,
    required this.differing,
    required this.maxChannel,
    required this.overOne,
    required this.overFour,
    required this.overSixteen,
  });

  final int pixels;
  final int differing;
  final int maxChannel;

  /// Pixels whose worst channel is more than 1, 4 and 16 levels out.
  ///
  /// Three thresholds because the differences have three sources and they
  /// separate by size: rounding is one level, a normal interpolated a fraction
  /// differently is a few, and a pixel one rasteriser drew and the other did
  /// not - a silhouette pixel, a fill-rule pixel - is the whole distance
  /// between the model and the background.
  final int overOne;
  final int overFour;
  final int overSixteen;

  @override
  String toString() => '$differing/$pixels px diferentes '
      '(${(differing * 100 / pixels).toStringAsFixed(3)}%), '
      'máx $maxChannel níveis, '
      '>1: $overOne (${(overOne * 100 / pixels).toStringAsFixed(3)}%), '
      '>4: $overFour (${(overFour * 100 / pixels).toStringAsFixed(3)}%), '
      '>16: $overSixteen (${(overSixteen * 100 / pixels).toStringAsFixed(3)}%)';
}

_Difference _compare(Framebuffer a, Framebuffer b) {
  var differing = 0;
  var maxChannel = 0;
  var overOne = 0;
  var overFour = 0;
  var overSixteen = 0;
  for (var y = 0; y < a.height; y++) {
    final int rowA = y * a.bytesPerRow;
    final int rowB = y * b.bytesPerRow;
    for (var x = 0; x < a.width; x++) {
      var worst = 0;
      for (var c = 0; c < 3; c++) {
        final int delta =
            (a.pixels[rowA + x * 4 + c] - b.pixels[rowB + x * 4 + c]).abs();
        if (delta > worst) worst = delta;
      }
      if (worst == 0) continue;
      differing++;
      if (worst > maxChannel) maxChannel = worst;
      if (worst > 1) overOne++;
      if (worst > 4) overFour++;
      if (worst > 16) overSixteen++;
    }
  }
  return _Difference(
    pixels: a.width * a.height,
    differing: differing,
    maxChannel: maxChannel,
    overOne: overOne,
    overFour: overFour,
    overSixteen: overSixteen,
  );
}

String _ascii(Framebuffer target, {int columns = 78}) {
  final int rows = (columns * target.height / target.width / 2).round();
  final StringBuffer out = StringBuffer();
  for (var row = 0; row < rows; row++) {
    final int y = (row * target.height / rows).floor();
    out.write('  ');
    for (var column = 0; column < columns; column++) {
      final int x = (column * target.width / columns).floor();
      final int at = y * target.bytesPerRow + x * 4;
      final int b = target.pixels[at];
      final int g = target.pixels[at + 1];
      final int r = target.pixels[at + 2];
      final double luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
      final int index =
          (luma * (_ramp.length - 1)).round().clamp(0, _ramp.length - 1);
      out.write(_ramp[index]);
    }
    out.writeln();
  }
  return out.toString();
}

void _writePpm(File file, Framebuffer target) {
  file.parent.createSync(recursive: true);
  final BytesBuilder builder = BytesBuilder()
    ..add('P6\n${target.width} ${target.height}\n255\n'.codeUnits);
  final Uint8List rgb = Uint8List(target.width * target.height * 3);
  var out = 0;
  for (var y = 0; y < target.height; y++) {
    for (var x = 0; x < target.width; x++) {
      final int at = y * target.bytesPerRow + x * 4;
      rgb[out++] = target.pixels[at + 2];
      rgb[out++] = target.pixels[at + 1];
      rgb[out++] = target.pixels[at];
    }
  }
  builder.add(rgb);
  file.writeAsBytesSync(builder.takeBytes());
}
