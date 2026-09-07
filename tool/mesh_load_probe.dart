/// Loads every model in a directory and reports what came out.
///
/// Written because a mesh loader tested only on files it was written against is
/// a loader tested on nothing: the formats here are old, widely written and
/// inconsistently written, and the failures that matter are a model that loads
/// with a third of its triangles or with its normals pointing inwards. So this
/// prints the counts and the bounding box for each file and leaves the reading
/// to a person.
///
/// ```
/// dart run tool/mesh_load_probe.dart D:/3d
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';

const Set<String> _extensions = <String>{
  '.obj',
  '.stl',
  '.gltf',
  '.glb',
  '.fbx',
};

Future<void> main(List<String> arguments) async {
  final String root = arguments.isEmpty ? 'test/data' : arguments.first;
  final Directory directory = Directory(root);
  if (!directory.existsSync()) {
    stderr.writeln('não encontrei $root');
    exitCode = 2;
    return;
  }

  var loaded = 0;
  var refused = 0;
  for (final FileSystemEntity entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    final String lower = entity.path.toLowerCase();
    if (!_extensions.any(lower.endsWith)) continue;

    final String label = entity.path.substring(root.length + 1);
    final Stopwatch watch = Stopwatch()..start();
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(entity.readAsBytesSync());
    } on FileSystemException catch (error) {
      stdout.writeln('  $label: não deu para ler ($error)');
      continue;
    }
    try {
      final Mesh3D mesh = loadMesh(
        bytes,
        name: label,
        // The seam the library leaves open: a `.gltf` points at a `.bin`
        // beside it by relative URI, and only something that knows where the
        // document came from can turn that into a path.
        resolveBuffer: (String uri) => _readSibling(entity, uri),
      );
      watch.stop();
      final Bounds3 bounds = mesh.computeBounds();
      loaded++;
      stdout.writeln(
        '  $label\n'
        '      ${mesh.format} · ${mesh.primitives.length} primitivas · '
        '${mesh.triangleCount} triângulos · ${mesh.vertexCount} vértices · '
        '${(bytes.length / 1024).round()} KiB em '
        '${watch.elapsedMilliseconds} ms\n'
        '      extensão ${bounds.extent.toStringAsFixed(2)} · '
        'centro ${bounds.center}'
        '${mesh.unsupported.isEmpty ? '' : '\n      não lido: '
            '${mesh.unsupported.join(', ')}'}',
      );
    } on MeshParseException catch (error) {
      refused++;
      stdout.writeln('  $label\n      RECUSADO: ${error.message}');
    }
  }

  stdout.writeln('\n$loaded carregados, $refused recusados por nome');
  // A refusal is a result, not a failure: FBX is meant to be refused. Only an
  // empty run is worth a non-zero exit.
  if (loaded == 0) exitCode = 1;
}

/// Reads [uri] relative to [document], or null.
///
/// Percent-decoded, because an exporter writes `my%20model.bin` for a file
/// whose name has a space in it and the filesystem wants the space back.
Uint8List? _readSibling(File document, String uri) {
  if (uri.startsWith('http:') || uri.startsWith('https:')) return null;
  final String decoded = Uri.decodeComponent(uri);
  final String directory = document.parent.path;
  final File file = File('$directory${Platform.pathSeparator}$decoded');
  if (!file.existsSync()) return null;
  return Uint8List.fromList(file.readAsBytesSync());
}
