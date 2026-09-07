/// Renders a model without a window and prints what came out.
///
/// A 3D rasteriser that compiles, does not throw, and reports plausible
/// triangle counts can still be drawing nonsense — a mirrored model, an inside
/// out one, a depth buffer fighting itself. None of that shows in a number.
///
/// So this prints the frame as text: one character per cell, chosen by
/// brightness. It is coarse and it is enough to answer the questions that
/// matter at this stage — is the silhouette the right shape, is it lit from the
/// side the light is on, does the far side occlude the near side or the other
/// way round. A PPM of the real pixels is written beside it with `--ppm` for
/// anything the ASCII cannot settle.
///
/// ```
/// dart run tool/mesh_render_probe.dart D:/3d/sonic.glb
/// dart run tool/mesh_render_probe.dart D:/3d/sonic.glb --ppm=build/sonic.ppm
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:dart_ui/src/platform/model_asset_resolver.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';

/// Dark to light. The order is what makes the picture readable rather than a
/// negative of itself.
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
    stderr.writeln('uso: dart run tool/mesh_render_probe.dart <modelo> '
        '[--ppm=saida.ppm] [--size=512] [--frames=1] [--shading=smooth]');
    exitCode = 2;
    return;
  }

  final int size = int.tryParse(_valueOf(arguments, '--size') ?? '') ?? 480;
  final int frames = int.tryParse(_valueOf(arguments, '--frames') ?? '') ?? 1;
  final MeshShading shading = switch (_valueOf(arguments, '--shading')) {
    'flat' => MeshShading.flat,
    'unlit' => MeshShading.unlit,
    'wireframe' => MeshShading.wireframe,
    _ => MeshShading.smooth,
  };

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
        resolveBuffer: ModelAssetResolver(file).call,
      );
    } on MeshParseException catch (error) {
      stdout.writeln('$path\n  RECUSADO: ${error.message}');
      continue;
    }

    final Bounds3 bounds = mesh.computeBounds();
    final Framebuffer target = Framebuffer.allocate(width: size, height: size);
    final MeshRasterizer rasterizer = MeshRasterizer();
    MeshCamera camera = MeshCamera.frame(bounds);

    // Warm, then measure: the first render pays for the smooth-normal pass and
    // for the JIT, and reporting that as the frame time would overstate every
    // model by an order of magnitude.
    rasterizer.render(target, mesh, camera, shading: shading);
    var total = 0;
    for (var i = 0; i < frames; i++) {
      camera = camera.withYaw(camera.yaw + 0.02);
      rasterizer.render(target, mesh, camera, shading: shading);
      total += rasterizer.stats.microseconds;
    }

    final MeshRenderStats stats = rasterizer.stats;
    stdout
      ..writeln(path)
      ..writeln('  ${mesh.format} · ${mesh.triangleCount} triângulos · '
          'extensão ${bounds.extent.toStringAsFixed(2)}')
      ..writeln('  ${stats.drawn} desenhados · ${stats.culled} descartados '
          'por face · ${stats.clipped} cortados no near · '
          '${stats.pixels} pixels')
      // Mean and not median, and labelled as such: the frames here are a
      // camera orbiting by a fixed step, so they differ in real work rather
      // than in noise, and averaging is the honest summary of that.
      ..writeln('  ${(total / frames / 1000).toStringAsFixed(2)} ms/quadro '
          'em ${size}x$size, média de $frames')
      ..writeln(_ascii(target, columns: 78));

    final String? ppm = _valueOf(arguments, '--ppm');
    if (ppm != null) {
      _writePpm(File(ppm), target);
      stdout.writeln('  PPM em $ppm');
    }
  }
}

/// The framebuffer as text, [columns] wide.
///
/// Cells are twice as tall as they are wide in a terminal, so the vertical
/// sample rate is halved to keep the model from looking stretched - which would
/// be indistinguishable from a broken aspect ratio in the projection, and this
/// tool exists to tell those apart.
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
      // Rec. 601 luma: green dominates what an eye calls brightness, and a
      // plain average makes a blue background read as bright as lit geometry.
      final double luma = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
      final int index = (luma * (_ramp.length - 1)).round().clamp(
            0,
            _ramp.length - 1,
          );
      out.write(_ramp[index]);
    }
    out.writeln();
  }
  return out.toString();
}

/// Writes a binary PPM, which every image viewer and every scripting language
/// reads without a library.
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
