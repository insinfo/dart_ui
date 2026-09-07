/// Proves the GL mesh pipeline draws in a **real window**, and measures it.
///
/// A headless run gives a false green for presentation: the off-screen
/// framebuffer this repository tests GL with is one this file creates with a
/// depth renderbuffer attached, so it says nothing about whether the *window's*
/// pixel format actually carries depth bits. Only a real `HWND` with a real
/// WGL context answers that, and answering it is half of why this file exists.
///
/// The other half is the comparison. `MeshRasterizer` is the reference picture
/// and a GPU path that merely "looks 3D" is not evidence of anything, so the
/// same model, camera and size go down both paths and the two images are
/// subtracted. The result is printed as two numbers with an argument attached:
///
///   * **interior deviation** - the largest per-channel difference over pixels
///     that are *not* next to a colour discontinuity in the CPU image. Away
///     from an edge both rasterisers evaluate the same shading arithmetic at
///     the same barycentric point, so anything above a level or two here is a
///     real disagreement about *shading*.
///   * **edge pixels** - how many pixels differ at all, as a fraction. These
///     are the boundary ones, and they cannot be zero: GL snaps vertices to a
///     fixed-point sub-pixel grid and applies a top-left fill rule, while
///     `_drawProjected` evaluates float edge functions at pixel centres with
///     an inclusive test on both sides. The two disagree on which side of a
///     boundary a pixel falls, by at most one pixel, along every silhouette.
///     So this number scales with the *perimeter* of what is drawn and never
///     with its area, which is the property that makes it a bound rather than
///     an excuse.
///
/// ```
/// dart run tool/gl_mesh_probe.dart                       # built-in scene
/// dart run tool/gl_mesh_probe.dart D:/3d/sonic.glb
/// dart run tool/gl_mesh_probe.dart D:/3d/x.stl --size=1080x780 --frames=240
/// dart run tool/gl_mesh_probe.dart --sabotage=depth      # prove it can fail
/// ```
///
/// `dart run` front-end compiles this package for about six seconds before
/// `main` starts (see `tool/startup_cost.dart`), and the JIT needs a few
/// hundred frames to settle. **Compile it before believing a number**:
///
/// ```
/// dart compile exe tool/gl_mesh_probe.dart -o build/gl_mesh_probe.exe
/// ```
///
/// The window is closed after [_defaultFrames] frames whatever happens - there
/// is no event loop here that could keep it up - and `--hidden` never shows it.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/src/backends/win32/win32_api.dart';
import 'package:dart_ui/src/backends/win32/win32_constants.dart';
import 'package:dart_ui/src/backends/win32/win32_gl_surface.dart';
import 'package:dart_ui/src/backends/win32/win32_structs.dart';
import 'package:dart_ui/src/foundation/diagnostics.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:dart_ui/src/rendering/framebuffer.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_bindings.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_context.dart';
import 'package:dart_ui/src/rendering/gpu/gl/gl_mesh_pipeline.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';

import 'mesh_scenes.dart';

const int _defaultFrames = 120;
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
  if (!Platform.isWindows) {
    stderr.writeln('GL_MESH=SKIP platform=${Platform.operatingSystem}; this '
        'probe opens a Win32 window, and the EGL path has no equivalent here');
    exitCode = 2;
    return;
  }

  final String size = _valueOf(arguments, '--size') ?? '1080x780';
  final List<String> parts = size.split('x');
  final int width = int.tryParse(parts.first) ?? 1080;
  final int height = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 780;
  final int frames =
      int.tryParse(_valueOf(arguments, '--frames') ?? '') ?? _defaultFrames;
  final MeshShading shading = switch (_valueOf(arguments, '--shading')) {
    'flat' => MeshShading.flat,
    'unlit' => MeshShading.unlit,
    'wireframe' => MeshShading.wireframe,
    _ => MeshShading.smooth,
  };
  final String? sabotage = _valueOf(arguments, '--sabotage');
  final bool hidden = arguments.contains('--hidden');
  final String? ppmDir = _valueOf(arguments, '--ppm-dir');
  final List<String> paths =
      arguments.where((String a) => !a.startsWith('--')).toList();

  final Mesh3D mesh;
  if (paths.isEmpty) {
    mesh = buildProbeScene();
  } else {
    final File file = File(paths.first);
    if (!file.existsSync()) {
      stderr.writeln('GL_MESH=FAIL não encontrei ${paths.first}');
      exitCode = 2;
      return;
    }
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
  }

  final MeshCamera camera =
      paths.isEmpty ? probeSceneCamera : MeshCamera.frame(mesh.computeBounds());

  stdout.writeln('${mesh.name} · ${mesh.format} · ${mesh.triangleCount} '
      'triângulos · ${mesh.vertexCount} vértices');
  if (mesh.unsupported.isNotEmpty) {
    stdout
        .writeln('  não suportado pelo loader: ${mesh.unsupported.join(', ')}');
  }

  final Win32GlSurfaceAttempt attempt = Win32GlSurface.hidden(
    width: width,
    height: height,
    className: 'DartUiGlMeshProbe',
  );
  final Win32GlSurface? surface = attempt.surface;
  if (surface == null) {
    stderr.writeln('GL_MESH=FAIL no GL surface: '
        '${attempt.diagnostics.join('; ')}');
    exitCode = 1;
    return;
  }

  final GlContextAttempt contextAttempt = surface.createContext();
  final GlContext? context = contextAttempt.context;
  if (context == null) {
    surface.dispose();
    stderr.writeln('GL_MESH=FAIL no GL context: '
        '${contextAttempt.diagnostics.join('; ')}');
    exitCode = 1;
    return;
  }
  if (!context.makeCurrent()) {
    context.dispose();
    surface.dispose();
    stderr.writeln('GL_MESH=FAIL the context refused to become current');
    exitCode = 1;
    return;
  }

  final Win32Api? api = Win32Api.load().api;
  final GlApi gl = GlApi(context.procAddress);
  stdout
    ..writeln('  GL: ${gl.stringOf(glVendor)} · ${gl.stringOf(glRenderer)}')
    ..writeln('  versão: ${gl.stringOf(glVersion)} · GLSL '
        '${gl.stringOf(glShadingLanguageVersion)}');

  final GlMeshPipelineAttempt built = GlMeshPipeline.create(gl: gl);
  final GlMeshPipeline? pipeline = built.pipeline;
  if (pipeline == null) {
    for (final BackendDiagnostic diagnostic in built.diagnostics) {
      stderr.writeln('  $diagnostic');
    }
    context.dispose();
    surface.dispose();
    stderr.writeln('GL_MESH=FAIL the mesh program could not be built');
    exitCode = 1;
    return;
  }

  if (sabotage == 'depth') {
    // GL_ALWAYS and not GL_GREATER: greater draws a plausible-looking model
    // seen from the wrong side, where always draws in submission order, which
    // is the failure a depth buffer exists to prevent.
    pipeline.debugDepthFunc = glAlways;
    stdout.writeln('  SABOTAGEM: glDepthFunc(GL_ALWAYS)');
  } else if (sabotage == 'winding') {
    pipeline.debugFrontFace = glCw;
    stdout.writeln('  SABOTAGEM: glFrontFace(GL_CW)');
  }

  final int errors = _run(
    api: api,
    surface: surface,
    gl: gl,
    pipeline: pipeline,
    mesh: mesh,
    camera: camera,
    width: width,
    height: height,
    frames: frames,
    shading: shading,
    hidden: hidden,
    ppmDir: ppmDir,
  );

  pipeline.dispose();
  context.dispose();
  surface.dispose();
  stdout.writeln('GL_MESH=${errors == 0 ? 'PASS' : 'FAIL'}');
  exitCode = errors == 0 ? 0 : 1;
}

int _run({
  required Win32Api? api,
  required Win32GlSurface surface,
  required GlApi gl,
  required GlMeshPipeline pipeline,
  required Mesh3D mesh,
  required MeshCamera camera,
  required int width,
  required int height,
  required int frames,
  required MeshShading shading,
  required bool hidden,
  required String? ppmDir,
}) {
  var failures = 0;

  if (!hidden && api != null) {
    api.showWindow(surface.windowHandle, swShowNormal);
  }

  // The requested size is the *outer* window, because CreateWindowExW takes
  // one; the back buffer is the client area, which is smaller by the border
  // and the caption. Rendering at the requested size instead would put a
  // strip of the frame outside the buffer, and glReadPixels would hand back
  // undefined pixels for it - which looks exactly like a broken projection.
  var renderWidth = width;
  var renderHeight = height;
  if (api != null) {
    final Pointer<Win32Rect> rect = api.allocator<Win32Rect>();
    if (api.getClientRect(surface.windowHandle, rect) != 0) {
      renderWidth = rect.ref.right - rect.ref.left;
      renderHeight = rect.ref.bottom - rect.ref.top;
    }
    api.allocator.free(rect);
  }
  // The window's own back buffer. glReadPixels below reads GL_BACK, which is
  // the default read buffer for framebuffer zero, so the pixels compared are
  // the ones that would have been swapped to the screen.
  gl.bindFramebuffer(glFramebuffer, 0);
  final int windowDepthBits = pipeline.depthBitsOfCurrentTarget();
  stdout.writeln('  janela: ${renderWidth}x$renderHeight · depth bits '
      '${windowDepthBits < 0 ? 'desconhecido' : windowDepthBits}');
  if (windowDepthBits == 0) {
    stdout.writeln('  ERRO: a superfície da janela não tem depth buffer; '
        'PIXELFORMATDESCRIPTOR.cDepthBits precisa ser diferente de zero');
    failures++;
  }

  // Warm, so the first frame's shader specialisation and buffer upload are not
  // reported as the frame time. The upload is the point: after this the cache
  // holds every buffer and glBufferData must not be called again.
  pipeline.render(
    mesh: mesh,
    camera: camera,
    width: renderWidth,
    height: renderHeight,
    shading: shading,
    measure: true,
  );
  final int uploadsAfterWarmUp = pipeline.bufferUploadCount;
  stdout.writeln('  buffers enviados: $uploadsAfterWarmUp · '
      '${(pipeline.uploadedByteCount / (1024 * 1024)).toStringAsFixed(1)} MB');

  final List<int> micros = <int>[];
  MeshCamera orbit = camera;
  final Pointer<Msg>? message = api?.allocator<Msg>();
  for (var frame = 0; frame < frames; frame++) {
    orbit = orbit.withYaw(orbit.yaw + 0.01);
    final MeshRenderStats stats = pipeline.render(
      mesh: mesh,
      camera: orbit,
      width: renderWidth,
      height: renderHeight,
      shading: shading,
      measure: true,
    );
    micros.add(stats.microseconds);
    surface.swapBuffers();
    // Drained so the window is not marked unresponsive while the probe runs.
    // There is no window procedure of our own - the class uses DefWindowProcW -
    // so nothing here can dispatch into Dart.
    if (api != null && message != null) {
      while (api.peekMessageW(message, surface.windowHandle, 0, 0, pmRemove) !=
          0) {
        api
          ..translateMessage(message)
          ..dispatchMessageW(message);
      }
    }
  }
  if (message != null) api?.allocator.free(message);

  if (pipeline.bufferUploadCount != uploadsAfterWarmUp) {
    stdout.writeln('  ERRO: $frames quadros custaram '
        '${pipeline.bufferUploadCount - uploadsAfterWarmUp} uploads de buffer; '
        'a geometria está sendo reenviada por quadro');
    failures++;
  }
  if (pipeline.lastError != null) {
    stdout.writeln('  ERRO: ${pipeline.lastError}');
    failures++;
  }
  if (pipeline.depthDiagnostic != null) {
    stdout.writeln('  ERRO: ${pipeline.depthDiagnostic}');
    failures++;
  }

  micros.sort();
  stdout.writeln('  GPU: ${_ms(micros)} ms/quadro (mediana de $frames, com '
      'glFinish) · ${(micros.first / 1000).toStringAsFixed(2)} melhor · '
      '${(micros.last / 1000).toStringAsFixed(2)} pior');

  // The frame that is compared is drawn from the original camera, so the two
  // paths are looking at the same thing. Read before the swap, from GL_BACK.
  pipeline.render(
    mesh: mesh,
    camera: camera,
    width: renderWidth,
    height: renderHeight,
    shading: shading,
    measure: true,
  );
  final Framebuffer gpuImage = Framebuffer.allocate(
    width: renderWidth,
    height: renderHeight,
  );
  if (!_readBackBuffer(gl, gpuImage)) {
    stdout.writeln('  ERRO: glReadPixels da janela falhou');
    failures++;
  }

  final Framebuffer cpuImage =
      Framebuffer.allocate(width: renderWidth, height: renderHeight);
  final MeshRasterizer rasterizer = MeshRasterizer()
    ..render(cpuImage, mesh, camera, shading: shading);
  final List<int> cpuMicros = <int>[];
  for (var i = 0; i < 5; i++) {
    rasterizer.render(cpuImage, mesh, camera, shading: shading);
    cpuMicros.add(rasterizer.stats.microseconds);
  }
  cpuMicros.sort();
  stdout.writeln('  CPU: ${_ms(cpuMicros)} ms/quadro (mediana de 5) · '
      '${rasterizer.stats}');

  final MeshImageDiff diff = compareMeshImages(cpuImage, gpuImage);
  stdout.writeln('  paridade: desvio interior ${diff.interiorDeviation} · '
      'desvio máximo ${diff.maxDeviation} · '
      '${diff.differingPixels} px diferentes '
      '(${(diff.differingFraction * 100).toStringAsFixed(2)}%) de '
      '${renderWidth * renderHeight}');

  stdout
    ..writeln('  CPU:')
    ..write(asciiOf(cpuImage, columns: 78))
    ..writeln('  GPU:')
    ..write(asciiOf(gpuImage, columns: 78));

  if (ppmDir != null) {
    writePpm(File('$ppmDir/mesh_cpu.ppm'), cpuImage);
    writePpm(File('$ppmDir/mesh_gpu.ppm'), gpuImage);
    stdout.writeln('  PPM em $ppmDir/mesh_cpu.ppm e $ppmDir/mesh_gpu.ppm');
  }

  // And the same comparison through an off-screen target, which is the
  // configuration the test suite can reach. Reported separately because a
  // window and an FBO are different surfaces with different depth precision
  // histories, and a difference between the two is worth seeing.
  final Object offscreen = GlMeshOffscreenSurface.create(
    api: gl,
    heap: NativeHeap.tryBind(null)!,
    width: width,
    height: height,
  );
  if (offscreen is GlMeshOffscreenSurface) {
    offscreen.bind();
    final Framebuffer fboReference =
        Framebuffer.allocate(width: width, height: height);
    MeshRasterizer().render(fboReference, mesh, camera, shading: shading);
    stdout.writeln('  FBO: depth bits ${pipeline.depthBitsOfCurrentTarget()}');
    pipeline.render(
      mesh: mesh,
      camera: camera,
      width: width,
      height: height,
      shading: shading,
      measure: true,
    );
    final Framebuffer fboImage =
        Framebuffer.allocate(width: width, height: height);
    offscreen.readInto(fboImage);
    final MeshImageDiff fboDiff = compareMeshImages(fboReference, fboImage);
    stdout.writeln('  paridade FBO: desvio interior '
        '${fboDiff.interiorDeviation} · ${fboDiff.differingPixels} px '
        'diferentes (${(fboDiff.differingFraction * 100).toStringAsFixed(2)}%) '
        '· razão de borda ${fboDiff.edgeRatio.toStringAsFixed(2)} · '
        '${fboDiff.interiorPixels} px interiores');
    offscreen.dispose();
    gl.bindFramebuffer(glFramebuffer, 0);
  } else {
    stdout.writeln('  ERRO: $offscreen');
    failures++;
  }

  return failures;
}

String _ms(List<int> sorted) =>
    (sorted[sorted.length ~/ 2] / 1000).toStringAsFixed(2);

/// Reads the window's back buffer into [destination], flipping rows.
bool _readBackBuffer(GlApi gl, Framebuffer destination) {
  final int bytes = destination.width * destination.height * 4;
  final NativeHeap? heap = NativeHeap.tryBind(null);
  if (heap == null) return false;
  final Pointer<Uint8> staging = heap.allocate<Uint8>(bytes);
  try {
    gl.drainErrors();
    gl.pixelStorei(glPackAlignment, 1);
    gl.readPixels(0, 0, destination.width, destination.height, glRgba,
        glUnsignedByte, staging.cast<Void>());
    if (gl.drainErrors() != glNoError) return false;
    final Uint8List source = staging.asTypedList(bytes);
    for (var y = 0; y < destination.height; y++) {
      final int sourceRow =
          (destination.height - 1 - y) * destination.width * 4;
      final int destinationRow = y * destination.bytesPerRow;
      for (var x = 0; x < destination.width; x++) {
        final int s = sourceRow + x * 4;
        final int d = destinationRow + x * 4;
        // RGBA out of GL into the BGRA a Framebuffer holds by default.
        destination.pixels[d] = source[s + 2];
        destination.pixels[d + 1] = source[s + 1];
        destination.pixels[d + 2] = source[s];
        destination.pixels[d + 3] = 0xFF;
      }
    }
    return true;
  } finally {
    heap.release(staging);
  }
}

/// The framebuffer as text, [columns] wide. Lifted from
/// `tool/mesh_render_probe.dart`, which explains the halved vertical rate.
String asciiOf(Framebuffer target, {int columns = 78}) {
  final int rows = (columns * target.height / target.width / 2).round();
  final StringBuffer out = StringBuffer();
  for (var row = 0; row < rows; row++) {
    final int y = (row * target.height / rows).floor();
    out.write('  ');
    for (var column = 0; column < columns; column++) {
      final int x = (column * target.width / columns).floor();
      final int at = y * target.bytesPerRow + x * 4;
      final double luma = (0.299 * target.pixels[at + 2] +
              0.587 * target.pixels[at + 1] +
              0.114 * target.pixels[at]) /
          255;
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

void writePpm(File file, Framebuffer target) {
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
