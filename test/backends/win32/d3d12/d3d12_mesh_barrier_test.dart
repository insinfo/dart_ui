/// A mesh frame, with the Direct3D 12 debug layer on, must draw no complaint.
///
/// ## Why this file exists next to `d3d12_barrier_test.dart`
///
/// `d3d12_mesh_cpu_parity_test.dart` proves the picture is right and cannot
/// see a barrier at all: an offscreen colour texture never leaves
/// `RENDER_TARGET`, so the whole class of mistake this file is about is
/// unreachable there. A **window** target's back buffer is handed over by DXGI
/// in `PRESENT`, and `D3d12WindowTarget.present` records `PRESENT` ->
/// `RENDER_TARGET` -> `PRESENT` around its own draws. A mesh pass runs before
/// that pair, so `D3d12MeshRenderer` has to record a pair of its own and leave
/// the buffer exactly as it found it.
///
/// Getting that wrong does not throw and does not change the picture on this
/// adapter. A barrier whose `before` state does not match the resource's real
/// state is undefined behaviour: one driver tolerates it and the next corrupts
/// the buffer. **The debug layer is the only thing that reports it**, which is
/// the argument `d3d12_barrier_test.dart` already makes at length and the
/// reason this is a separate file rather than an assertion in the parity one -
/// the debug layer costs several times the driver call and applies only to
/// devices created after `EnableDebugLayer`, so it is opened per file.
///
/// The same run also covers the two other things only a window can show:
///
///   * the depth buffer is allocated against a swap chain's back buffer, which
///     carries no depth-stencil view of its own;
///   * a 2D display list drawn **after** a mesh frame, through the same
///     device. A mesh pass that left a depth-stencil view bound would make
///     every following batch depth-test against the plane the model wrote.
///     `tool/d3d12_mesh_window_probe.dart` checks that the pixels arrive; this
///     checks that the runtime had nothing to say about how.
///
/// It skips when the optional "Graphics Tools" Windows feature is absent, or
/// when another suite in this process created a device first - see
/// `d3d12_barrier_test.dart` for why the order matters.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_interfaces.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_mesh_pipeline.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_structs.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_window_target.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/display_list.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';
import 'package:dart_ui/src/rendering/renderer.dart';
import 'package:test/test.dart';

import 'd3d12_session.dart';

void main() {
  final D3d12Session session =
      D3d12Session.open(debugLayer: true, window: true);
  final String? skip = session.skipReason ??
      (session.device?.infoQueue == null
          ? 'no ID3D12InfoQueue: either the optional "Graphics Tools" Windows '
              'feature is absent, or another suite in this process created a '
              'device before EnableDebugLayer ran'
          : null);

  group('a mesh frame in a window draws no complaint from the debug layer', () {
    tearDownAll(session.close);

    test('four mesh frames, then a 2D list through the same device', () async {
      final D3d12RenderDevice device = session.device!;
      final Object built = D3d12MeshRenderer.create(device);
      expect(built, isA<D3d12MeshRenderer>(),
          reason: built is BackendDiagnostic
              ? '${built.message}: ${built.detail}'
              : '$built');
      final renderer = built as D3d12MeshRenderer;
      final D3d12WindowTarget target = device.createTarget(
        session.window!.describe(width: 96, height: 72),
      ) as D3d12WindowTarget;
      target.syncInterval = 0;
      expect(target.creationFailure, isNull);

      final Mesh3D mesh = _cube();
      final MeshCamera camera =
          MeshCamera.frame(mesh.computeBounds(), yaw: 0.7, pitch: 0.42);
      device.infoQueue!.clearStoredMessages();
      try {
        // Four, so the *second* pass over each back buffer is included: the
        // first time a buffer is used it comes straight from creation, and
        // only the second exercises the `PRESENT` state a previous frame's
        // mesh pass left it in.
        for (var frame = 0; frame < 4; frame++) {
          final Frame open = target.beginFrame(const FrameRequest());
          final MeshRenderStats stats =
              renderer.drawScene(target, MeshScene(mesh: mesh, camera: camera));
          expect(stats.triangles, mesh.triangleCount,
              reason: 'the mesh pass recognised the window target');
          final PresentResult result = await target.present(open);
          expect(result.status, PresentStatus.presented,
              reason: '${result.diagnostic}');
        }

        // The 2D pass, after the 3D one, through the same device and the same
        // command list cycle.
        final PresentResult after =
            await target.renderDisplayList(_overlay(), clearColor: 0xFF102030);
        expect(after.status, PresentStatus.presented,
            reason: '${after.diagnostic}');

        _expectNoErrors(device);
      } finally {
        renderer.dispose();
        target.dispose();
      }
    }, skip: skip);

    test('the device survives the whole file without being removed', () {
      expect(session.device?.isLost ?? false, isFalse);
    }, skip: skip);
  });
}

/// The unit cube, two triangles a face, wound counter-clockwise seen from
/// outside.
///
/// Generated rather than loaded, and closed rather than open: a closed model is
/// what makes the back-face cull do something, and the cull is one of the
/// states this pipeline bakes into a pipeline state object.
Mesh3D _cube() {
  final List<double> positions = <double>[];
  final List<double> normals = <double>[];
  final List<int> indices = <int>[];

  void face(Vector3 origin, Vector3 right, Vector3 up, Vector3 normal) {
    final int base = positions.length ~/ 3;
    final List<Vector3> corners = <Vector3>[
      origin,
      origin + right,
      origin + right + up,
      origin + up,
    ];
    for (final Vector3 corner in corners) {
      positions
        ..add(corner.x)
        ..add(corner.y)
        ..add(corner.z);
      normals
        ..add(normal.x)
        ..add(normal.y)
        ..add(normal.z);
    }
    indices
      ..addAll(<int>[base, base + 1, base + 2])
      ..addAll(<int>[base, base + 2, base + 3]);
  }

  const Vector3 x = Vector3(1, 0, 0);
  const Vector3 y = Vector3(0, 1, 0);
  const Vector3 z = Vector3(0, 0, 1);
  face(const Vector3(0, 0, 1), x, y, z);
  face(const Vector3(1, 0, 0), const Vector3(-1, 0, 0), y,
      const Vector3(0, 0, -1));
  face(const Vector3(1, 0, 1), const Vector3(0, 0, -1), y, x);
  face(const Vector3(0, 0, 0), z, y, const Vector3(-1, 0, 0));
  face(const Vector3(0, 1, 1), x, const Vector3(0, 0, -1), y);
  face(const Vector3(0, 0, 0), x, z, const Vector3(0, -1, 0));

  return Mesh3D(
    name: 'cube',
    format: 'generated',
    primitives: <MeshPrimitive>[
      MeshPrimitive(
        positions: Float32List.fromList(positions),
        indices: Uint32List.fromList(indices),
        normals: Float32List.fromList(normals),
        material: const MeshMaterial(colorArgb: 0xFFB0C4DE),
      ),
    ],
  );
}

/// Two rectangles, to prove the 2D path still records after a mesh pass.
DisplayList _overlay() {
  final DisplayList list = DisplayList();
  final int blue = list.addPaint(colorArgb: 0xFF2E7BD6, antiAlias: false);
  final int orange = list.addPaint(colorArgb: 0xFFD6642E, antiAlias: false);
  return list
    ..drawRect(4, 4, 92, 20, blue)
    ..drawRect(4, 52, 40, 68, orange);
}

/// Fails if the info queue holds anything the runtime called an error.
void _expectNoErrors(D3d12RenderDevice device) {
  final List<_Message> messages = _drain(device);
  final List<_Message> failures = messages
      .where((_Message m) =>
          m.severity == d3d12MessageSeverityCorruption ||
          m.severity == d3d12MessageSeverityError)
      .toList();
  // The tolerated ones are still printed: a new warning is worth reading even
  // when it is not worth failing on.
  printOnFailure(messages.isEmpty
      ? 'the debug layer said nothing at all'
      : messages.join('\n'));
  expect(
    failures,
    isEmpty,
    reason: 'the Direct3D 12 debug layer reported ${failures.length} '
        'error-level messages:\n${failures.join('\n')}',
  );
}

final class _Message {
  const _Message(this.severity, this.text);

  final int severity;
  final String text;

  @override
  String toString() => '[${_severityName(severity)}] $text';

  static String _severityName(int severity) => switch (severity) {
        d3d12MessageSeverityCorruption => 'CORRUPTION',
        d3d12MessageSeverityError => 'ERROR',
        d3d12MessageSeverityWarning => 'WARNING',
        _ => 'severity $severity',
      };
}

/// Reads and clears everything the info queue has stored.
///
/// `GetMessage` is called twice per message, as the API requires: once with a
/// null message to learn the byte length - the description is a variable-length
/// string stored after the structure - and once with a buffer of that size.
List<_Message> _drain(D3d12RenderDevice device) {
  final D3d12InfoQueue queue = device.infoQueue!;
  final Allocator allocator = device.library.allocator;
  final Pointer<IntPtr> length = allocator.allocate<IntPtr>(sizeOf<IntPtr>());
  final List<_Message> messages = <_Message>[];
  try {
    final int count = queue.storedMessageCount;
    for (var i = 0; i < count; i++) {
      length.value = 0;
      queue.getMessage(i, nullptr, length);
      if (length.value <= 0) continue;
      final Pointer<D3d12Message> message =
          allocator.allocate<D3d12Message>(length.value);
      try {
        if (_comFailed(queue.getMessage(i, message, length))) continue;
        messages.add(_Message(message.ref.severity, _text(message)));
      } finally {
        allocator.free(message);
      }
    }
  } finally {
    allocator.free(length);
    queue.clearStoredMessages();
  }
  return messages;
}

String _text(Pointer<D3d12Message> message) {
  final Pointer<Uint8> bytes = message.ref.description;
  final StringBuffer buffer = StringBuffer();
  for (var i = 0; i < message.ref.descriptionByteLength; i++) {
    final int byte = bytes[i];
    if (byte == 0) break;
    buffer.writeCharCode(byte);
  }
  return buffer.toString();
}

/// `comFailed`, re-declared locally so this file does not import the COM
/// helpers only for a sign test.
bool _comFailed(int hr) => hr < 0;
