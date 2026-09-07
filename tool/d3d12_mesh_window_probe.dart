/// Draws a model with the Direct3D 12 mesh pipeline **into a real window**, and
/// measures what a frame costs there.
///
/// ## Why this cannot be a test, and why the offscreen probe is not enough
///
/// This repository has a standing rule about it and `tool/present_mode_smoke.dart`
/// states it: a headless run here gives a **false green** for presentation. The
/// offscreen target's colour buffer is a texture this backend created and reads
/// back; a window's is a buffer DXGI handed the driver for a swap chain, and the
/// two differ in exactly the ways a mesh pass can go wrong on one and not the
/// other:
///
///   * the back buffer carries **no depth-stencil view**, so a pipeline that
///     quietly relied on the one a pooled layer target has would draw nothing
///     here and everything offscreen;
///   * the swap chain's view is **refetched every present** and replaced by
///     every resize, so a renderer that cached the pointer draws into a freed
///     buffer the first time the window changes size - which no offscreen run
///     can reach;
///   * a frame that leaves the output-merger holding a depth-stencil state or a
///     depth view goes on to break **the 2D pass that draws the interface over
///     the model**, and offscreen there is no such pass.
///
/// So this opens a window, drives the framework's own loop through it, then
/// drives mesh frames through the same `D3d12WindowTarget` and times them.
/// `ApplicationOptions.onError` is attached throughout: without it a paint or
/// present failure closes the window with exit 0 and nothing on stderr.
///
/// **It closes itself.** `--frames` bounds the run and the window is disposed
/// afterwards, because a probe that leaves a window on somebody's screen is a
/// probe nobody runs.
///
/// ```
/// dart run tool/d3d12_mesh_window_probe.dart D:/3d/model.stl --frames=240
/// ```
///
/// Prints one `D3D12_MESH_WINDOW=` verdict. Exit 0 when it drew and presented every
/// frame with no framework error, 1 when something it measured contradicts the
/// implementation, 2 when this machine cannot host the run - no Windows, no
/// Direct3D 12 presentation, no window, no model.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_device.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_mesh_pipeline.dart';
import 'package:dart_ui/src/backends/win32/d3d12/d3d12_window_target.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';

/// Frames dropped from the front of the measurement.
///
/// The first frames after a swap chain is created pay for the geometry upload
/// and for a queue that is still empty, and averaging them in would report a
/// 451 838-triangle model as slower than it is by an order of magnitude.
const int _warmup = 15;

const double _defaultWidth = 1080;
const double _defaultHeight = 780;

int? _intOption(List<String> arguments, String name) {
  for (final String argument in arguments) {
    if (argument.startsWith(name)) {
      return int.tryParse(argument.substring(name.length));
    }
  }
  return null;
}

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr
        .writeln('D3D12_MESH_WINDOW=SKIP platform=${Platform.operatingSystem}');
    exitCode = 2;
    return;
  }
  final List<String> paths =
      arguments.where((String a) => !a.startsWith('--')).toList();
  if (paths.isEmpty) {
    stderr.writeln('uso: dart run tool/d3d12_mesh_window_probe.dart <modelo> '
        '[--frames=240] [--width=1080] [--height=780]');
    exitCode = 2;
    return;
  }
  final File file = File(paths.first);
  if (!file.existsSync()) {
    stderr
        .writeln('D3D12_MESH_WINDOW=SKIP reason=não encontrei ${paths.first}');
    exitCode = 2;
    return;
  }

  final int frames = _intOption(arguments, '--frames=') ?? 240;
  final double width =
      (_intOption(arguments, '--width=') ?? _defaultWidth.toInt()).toDouble();
  final double height =
      (_intOption(arguments, '--height=') ?? _defaultHeight.toInt()).toDouble();

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
    stderr.writeln('D3D12_MESH_WINDOW=SKIP reason=${error.message}');
    exitCode = 2;
    return;
  }

  final errors = <FrameworkError>[];
  final diagnostics = <BackendDiagnostic>[];
  final Application app;
  try {
    app = await Application.start(
      rootWidget: const ColoredBox(color: Color(0xFF10151F)),
      backends: PlatformBackendResolver.defaultBackends(),
      presentations: PlatformBackendResolver.defaultPresentations(),
      options: ApplicationOptions(
        title: 'dart_ui Direct3D 12 mesh probe',
        size: Size(width, height),
        // Shown. DXGI answers a present for an invisible window with
        // DXGI_STATUS_OCCLUDED and is entitled to discard the frame, so a
        // hidden run would measure a compositor refusing frames rather than a
        // GPU drawing them.
        visible: true,
        // gpuOnly, so a machine whose Direct3D 12 probe fails is a loud failure
        // instead of a CPU frame that would prove nothing.
        renderingPolicy: RenderingPolicy.gpuOnly,
        requestedPresentation: 'direct3d12',
        onError: errors.add,
        onDiagnostic: diagnostics.add,
      ),
    );
  } on Object catch (error) {
    stderr
        .writeln('D3D12_MESH_WINDOW=SKIP reason=a aplicação não abriu: $error');
    exitCode = 2;
    return;
  }

  var ok = true;
  try {
    // The framework's own loop first, through every layer an application uses.
    // If this does not present, nothing measured below means anything - and it
    // is also what leaves a 2D frame in the back buffer, so the mesh pass that
    // follows is drawing over an interface rather than into a blank device.
    await app.run(frameBudget: 12);
    final String? chosen = app.presentationSelection.chosen?.name;
    stdout.writeln('APP presentation=$chosen frames=${app.framesPresented} '
        'errors=${errors.length}');
    if (chosen != 'direct3d12') {
      stderr
          .writeln('D3D12_MESH_WINDOW=SKIP reason=a seleção escolheu $chosen');
      exitCode = 2;
      return;
    }
    final SurfacePresenter presenter = app.host.presenter;
    if (presenter is! RenderTargetPresenter) {
      stderr
          .writeln('D3D12_MESH_WINDOW=SKIP reason=${presenter.runtimeType} não '
              'tem RenderTarget');
      exitCode = 2;
      return;
    }
    final RenderTarget raw = presenter.target;
    if (raw is! D3d12WindowTarget) {
      stderr.writeln('D3D12_MESH_WINDOW=SKIP reason=${raw.runtimeType} não é '
          'D3d12WindowTarget');
      exitCode = 2;
      return;
    }
    final D3d12RenderDevice device = _deviceOf(raw);
    final Object built = D3d12MeshRenderer.create(device);
    if (built is BackendDiagnostic) {
      stderr
          .writeln('D3D12_MESH_WINDOW=FAIL ${built.message}: ${built.detail}');
      exitCode = 1;
      return;
    }
    final renderer = built as D3d12MeshRenderer;

    try {
      final Bounds3 bounds = mesh.computeBounds();
      MeshCamera camera = MeshCamera.frame(bounds);
      final int pixelWidth = raw.surface.pixelWidth;
      final int pixelHeight = raw.surface.pixelHeight;
      stdout.writeln('MODEL ${mesh.name} ${mesh.format} '
          '${mesh.triangleCount} triangles, target '
          '${pixelWidth}x$pixelHeight');

      final frameUs = <int>[];
      final submitUs = <int>[];
      var notPresented = 0;
      final Stopwatch clock = Stopwatch()..start();
      for (var i = 0; i < frames + _warmup; i++) {
        // A moving camera, so the run is a viewer being used rather than the
        // same command buffer replayed - which is what a driver is entitled to
        // make free.
        camera = camera.withYaw(camera.yaw + 0.01);
        final int start = clock.elapsedMicroseconds;
        final Frame frame = raw.beginFrame(const FrameRequest());
        final MeshRenderStats stats = renderer.drawScene(
          raw,
          MeshScene(mesh: mesh, camera: camera),
        );
        final PresentResult result = await raw.present(frame);
        final int elapsed = clock.elapsedMicroseconds - start;
        if (i < _warmup) continue;
        if (result.status != PresentStatus.presented) {
          notPresented++;
          if (notPresented == 1) {
            stderr.writeln('  present: $result');
          }
        }
        frameUs.add(elapsed);
        submitUs.add(stats.microseconds);
      }

      final int median = _median(frameUs);
      stdout
        ..writeln('MESH ${_ms(median)} ms/frame median, '
            'p95 ${_ms(_p95(frameUs))} ms, '
            'submit ${_ms(_median(submitUs))} ms, '
            '${(1000000 / median).toStringAsFixed(1)} fps')
        // The swap chain presents with a sync interval and this target
        // exposes no `PresentPacer`, so whenever the GPU is faster than the
        // panel the number above **is** the panel. That is still the
        // measurement that matters here - a frame that misses the refresh is
        // the failure a viewer sees - and `tool/mesh_gpu_probe.dart` is where
        // throughput with no display in the loop is measured.
        ..writeln('NOTE the frame time is vsync-bounded; p95 above the median '
            'is where a frame was missed')
        ..writeln('BUFFERS uploads=${renderer.bufferUploadCount} '
            'resident=${(renderer.cachedBufferBytes / 1048576).toStringAsFixed(1)} MiB '
            'primitives=${renderer.cachedPrimitiveCount}');

      // The geometry must have been uploaded once. A window run is where a
      // per-frame upload would be least visible and most expensive.
      if (renderer.bufferUploadCount > mesh.primitives.length * 2) {
        stderr.writeln(
            'D3D12_MESH_WINDOW=FAIL ${renderer.bufferUploadCount} buffer '
            'uploads for ${mesh.primitives.length} primitives: the cache is '
            'not holding across frames');
        ok = false;
      }
      // A dropped frame, without needing to know the panel's rate: under a
      // sync interval every frame takes the same time, so a p95 half again as
      // long as the median is a frame that missed a refresh and waited for the
      // next.
      if (_p95(frameUs) > median * 3 ~/ 2) {
        stderr.writeln(
            'D3D12_MESH_WINDOW=FAIL p95 ${_ms(_p95(frameUs))} ms against '
            'a median of ${_ms(median)} ms: frames are missing the refresh');
        ok = false;
      }
      if (notPresented > 0) {
        stderr.writeln(
            'D3D12_MESH_WINDOW=FAIL $notPresented of ${frameUs.length} '
            'frames were not presented');
        ok = false;
      }
      // A resize, still drawing the model. This is the half that catches a
      // renderer that cached the swap chain's back-buffer view or kept a depth
      // buffer of the old size: `ResizeBuffers` releases both, and Direct3D
      // refuses an output-merger whose views disagree about their dimensions.
      // Neither failure can be reached offscreen.
      final int resizedWidth = pixelWidth - 60;
      final int resizedHeight = pixelHeight - 40;
      raw.resize(resizedWidth, resizedHeight, raw.surface.scale);
      var resizedOk = true;
      for (var i = 0; i < 30; i++) {
        camera = camera.withYaw(camera.yaw + 0.01);
        final Frame frame = raw.beginFrame(const FrameRequest());
        renderer.drawScene(raw, MeshScene(mesh: mesh, camera: camera));
        final PresentResult result = await raw.present(frame);
        if (result.status != PresentStatus.presented) {
          stderr.writeln('  after resize: $result');
          resizedOk = false;
          break;
        }
      }
      stdout.writeln('RESIZE ${resizedWidth}x$resizedHeight '
          'presented=$resizedOk uploads=${renderer.bufferUploadCount}');
      if (!resizedOk) {
        stderr
            .writeln('D3D12_MESH_WINDOW=FAIL the mesh pass stopped presenting '
                'after a resize');
        ok = false;
      }

      // The 2D path, after the 3D one, through the same device. This is the
      // check the offscreen probe cannot make: a mesh frame that left a
      // depth-stencil view or a depth-testing state bound makes every dense
      // batch after it fail the depth test against a plane the model wrote, and
      // the interface disappears where the model was.
      final PresentResult after = await raw.renderDisplayList(
        _overlay(resizedWidth.toDouble(), resizedHeight.toDouble()),
        clearColor: 0xFF10151F,
      );
      stdout.writeln('AFTER 2d=${after.status.name}');
      if (after.status != PresentStatus.presented) {
        stderr.writeln(
            'D3D12_MESH_WINDOW=FAIL the 2D pass after the mesh pass did '
            'not present: $after');
        ok = false;
      }
    } finally {
      renderer.dispose();
    }

    if (errors.isNotEmpty) {
      stderr
          .writeln('D3D12_MESH_WINDOW=FAIL ${errors.length} framework errors');
      ok = false;
    }
  } finally {
    for (final FrameworkError error in errors) {
      stderr.writeln('  error: $error');
    }
    for (final BackendDiagnostic diagnostic in diagnostics) {
      stdout.writeln('  diagnostic: ${diagnostic.message}');
    }
    app.dispose();
    await app.closed;
  }
  stdout.writeln('D3D12_MESH_WINDOW=${ok ? 'PASS' : 'FAIL'}');
  exitCode = ok ? 0 : 1;
}

/// The device behind [target], which is the one the mesh pipeline has to be
/// built on.
///
/// Not a second device opened here: a resource created by another
/// `ID3D12Device` cannot be bound alongside a render-target view belonging to
/// this one, and Direct3D answers that by drawing nothing rather than by
/// failing.
D3d12RenderDevice _deviceOf(D3d12WindowTarget target) => target.device;

/// A few rectangles, to prove the 2D path still draws after a mesh frame.
DisplayList _overlay(double width, double height) {
  final DisplayList list = DisplayList();
  final int blue = list.addPaint(colorArgb: 0xFF2E7BD6, antiAlias: false);
  final int orange = list.addPaint(colorArgb: 0xFFD6642E, antiAlias: false);
  list
    ..drawRect(24, 24, width - 24, 72, blue)
    ..drawRect(24, height - 72, 264, height - 24, orange);
  return list;
}

String _ms(int microseconds) => (microseconds / 1000).toStringAsFixed(2);

int _median(List<int> values) {
  if (values.isEmpty) return 0;
  final List<int> sorted = List<int>.of(values)..sort();
  return sorted[sorted.length ~/ 2];
}

int _p95(List<int> values) {
  if (values.isEmpty) return 0;
  final List<int> sorted = List<int>.of(values)..sort();
  return sorted[((sorted.length - 1) * 95) ~/ 100];
}
