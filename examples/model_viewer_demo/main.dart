/// A 3D model viewer: open a file, orbit it, and see what each frame cost.
///
/// Reads OBJ, STL, glTF and GLB. FBX is refused by name with what to export
/// instead — see `lib/src/graphics/mesh/mesh_loaders.dart` for why half-reading
/// it would be worse than not reading it.
///
/// ## What is doing the drawing, and what is not
///
/// The triangles are rasterised **on the CPU**, into a framebuffer that the
/// window's backend then presents as one image. That is not a fallback and it
/// is not temporary: this framework's display list has no triangle and no depth
/// buffer, so there is no GPU pipeline here to hand a mesh to. The status bar
/// names both halves — the rasteriser's time and the backend presenting its
/// output — because reading "direct3d11" there and concluding the GPU is
/// drawing the model would be exactly the wrong conclusion.
///
/// ```
/// dart run examples/model_viewer_demo/main.dart D:/3d/sonic.glb
/// dart run examples/model_viewer_demo/main.dart --frames=200 --report model.stl
/// ```
///
/// Compile before judging the speed: `dart run` spends about six seconds
/// front-end compiling this package before `main` starts, and the rasteriser is
/// two to three times faster in AOT. See `tool/startup_cost.dart`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/graphics/mesh/mesh_loaders.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';

String? _valueOf(List<String> arguments, String name) {
  for (final String argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

/// Reads a model from disk, resolving a glTF's external buffers beside it.
///
/// The resolver is the seam the loader leaves open on purpose: a decoder that
/// opens files cannot run in a browser or over bytes from a network, so the
/// path stays with the application. Here the application knows exactly where
/// the document came from, which is what makes a relative `.bin` resolvable.
Mesh3D readModel(File file) => loadMesh(
      Uint8List.fromList(file.readAsBytesSync()),
      name: file.uri.pathSegments.last,
      resolveBuffer: (String uri) {
        if (uri.startsWith('http:') || uri.startsWith('https:')) return null;
        final File sibling = File(
          '${file.parent.path}${Platform.pathSeparator}'
          '${Uri.decodeComponent(uri)}',
        );
        return sibling.existsSync()
            ? Uint8List.fromList(sibling.readAsBytesSync())
            : null;
      },
    );

Future<void> main(List<String> arguments) async {
  final List<String> paths =
      arguments.where((String a) => !a.startsWith('--')).toList();
  final int frameBudget =
      int.tryParse(_valueOf(arguments, '--frames') ?? '') ?? 0;

  Mesh3D? mesh;
  String? error;
  Duration loadTime = Duration.zero;
  String source = '';
  if (paths.isNotEmpty) {
    final File file = File(paths.first);
    if (!file.existsSync()) {
      stderr.writeln('não encontrei ${paths.first}');
      exitCode = 2;
      return;
    }
    source = file.path;
    final Stopwatch watch = Stopwatch()..start();
    try {
      mesh = readModel(file);
    } on MeshParseException catch (failure) {
      error = '${failure.message}${failure.detail == null ? '' : '\n'
          '${failure.detail}'}';
    }
    loadTime = watch.elapsed;
    if (mesh != null) {
      stdout.writeln(
        'modelo: ${mesh.name} · ${mesh.format} · '
        '${mesh.triangleCount} triângulos · ${mesh.primitives.length} '
        'primitivas · lido em ${loadTime.inMilliseconds} ms'
        '${mesh.unsupported.isEmpty ? '' : ' · não lido: '
            '${mesh.unsupported.join(', ')}'}',
      );
    } else {
      stdout.writeln('modelo recusado: $error');
    }
  }

  FrameworkFonts.install();
  final ViewerSession session = ViewerSession();
  final ApplicationOptions options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'dart_ui Model Viewer',
    size: const Size(1080, 780),
    minimumSize: const Size(680, 500),
    theme: ThemeData.neutralDark,
    clearColor: const Color(0xFF070A11),
    frameBudget: frameBudget,
    // Continuous only while something is moving: an idle viewer of a static
    // model has nothing to redraw, and rasterising 450,000 triangles sixty
    // times a second to produce the same picture is a laptop fan for nothing.
    onError: (FrameworkError failure) => stderr.writeln('$failure'),
  );

  final Application application = await Application.start(
    rootWidget: ModelViewerDemo(
      mesh: mesh,
      error: error,
      sourcePath: source,
      loadTime: loadTime,
      session: session,
    ),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  session.application = application;

  try {
    await application.run();
  } finally {
    if (arguments.contains('--report')) {
      final MeshRenderStats stats = session.stats;
      stdout.writeln(
        'REPORT backend=${session.backendName} '
        'triangles=${stats.triangles} '
        'drawn=${stats.drawn} culled=${stats.culled} clipped=${stats.clipped} '
        'pixels=${stats.pixels} '
        'raster_us=${stats.microseconds} '
        'fps=${session.framesPerSecond.toStringAsFixed(1)} '
        'presented=${application.framesPresented}',
      );
    }
    application.dispose();
    await application.closed;
  }
}

/// What `main` and the widget share.
final class ViewerSession {
  Application? application;
  MeshRenderStats stats = MeshRenderStats.zero;
  double framesPerSecond = 0;

  /// The presentation path actually chosen.
  ///
  /// It presents the rasteriser's output; it does not draw the triangles. The
  /// status bar says so in as many words, because a viewer reporting
  /// "direct3d11" beside a 3D model invites exactly the wrong conclusion.
  String get backendName =>
      application?.presentationSelection.chosen?.name ?? 'selecionando';
}

final class ModelViewerDemo extends StatefulWidget {
  const ModelViewerDemo({
    required this.mesh,
    required this.error,
    required this.sourcePath,
    required this.loadTime,
    required this.session,
    super.key,
  });

  final Mesh3D? mesh;
  final String? error;
  final String sourcePath;
  final Duration loadTime;
  final ViewerSession session;

  @override
  State<ModelViewerDemo> createState() => _ModelViewerDemoState();
}

final class _ModelViewerDemoState extends State<ModelViewerDemo> {
  Mesh3D? _mesh;
  String? _error;
  String _source = '';
  Duration _loadTime = Duration.zero;

  late MeshCamera _camera;
  MeshShading _shading = MeshShading.smooth;
  bool _spinning = true;

  final Stopwatch _rateWindow = Stopwatch()..start();
  int _framesThisWindow = 0;
  double _fps = 0;

  AnimationClock? _clock;
  late final _ViewerTicker _ticker = _ViewerTicker(
    ticking: () => mounted,
    onTick: (_) => _onTick(),
  );
  bool _attached = false;
  _RenderModel? _render;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _mesh = widget.mesh;
    _error = widget.error;
    _source = widget.sourcePath;
    _loadTime = widget.loadTime;
    _camera = MeshCamera.frame(
      _mesh?.computeBounds() ?? Bounds3.empty,
    );
  }

  @override
  void dispose() {
    if (_attached) _clock?.removeTicker(_ticker);
    super.dispose();
  }

  /// Repaints, and rebuilds only the status line, twice a second.
  ///
  /// A ticker runs inside the frame, so a `setState` from here dirties the
  /// build the frame is settling and the loop never converges - the window dies
  /// with "the frame did not settle in 8 passes". The picture needs a repaint,
  /// not a rebuild.
  void _onTick() {
    if (!mounted) return;
    if (_spinning) {
      _camera = _camera.withYaw(_camera.yaw + 0.012);
      _render?.markNeedsPaint();
    }
    _framesThisWindow++;
    widget.session
      ..stats = _render?.lastStats ?? MeshRenderStats.zero
      ..framesPerSecond = _fps;
    if (_rateWindow.elapsedMilliseconds < 500) return;
    _fps = _framesThisWindow * 1000 / _rateWindow.elapsedMilliseconds;
    _framesThisWindow = 0;
    _rateWindow.reset();
    widget.session.framesPerSecond = _fps;
    Timer.run(() {
      if (mounted) setState(() {});
    });
  }

  Future<void> _open() async {
    if (_opening) return;
    _opening = true;
    try {
      final PickedFile? picked = await FilePicker.openFile(
        title: 'Abrir modelo 3D',
        filters: const <FilePickerFilter>[
          FilePickerFilter(
            label: 'Modelos 3D',
            extensions: <String>['obj', 'stl', 'gltf', 'glb'],
          ),
          FilePickerFilter(
              label: 'Todos os arquivos', extensions: <String>['*']),
        ],
      );
      final String? path = picked?.path;
      if (path == null || !mounted) return;
      _load(File(path));
    } finally {
      _opening = false;
    }
  }

  void _load(File file) {
    final Stopwatch watch = Stopwatch()..start();
    Mesh3D? mesh;
    String? failure;
    try {
      mesh = readModel(file);
    } on MeshParseException catch (error) {
      failure = '${error.message}'
          '${error.detail == null ? '' : '\n${error.detail}'}';
    }
    watch.stop();
    setState(() {
      _mesh = mesh;
      _error = failure;
      _source = file.path;
      _loadTime = watch.elapsed;
      if (mesh != null) {
        _camera = MeshCamera.frame(mesh.computeBounds());
      }
    });
    _render?.markNeedsPaint();
  }

  void _orbit(Offset delta) {
    setState(() {
      _camera = _camera
          .withYaw(_camera.yaw - delta.dx * 0.008)
          .withPitch(_camera.pitch + delta.dy * 0.008);
    });
    _render?.markNeedsPaint();
  }

  void _zoom(double factor) {
    setState(() => _camera = _camera.withDistance(_camera.distance * factor));
    _render?.markNeedsPaint();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationClock? clock = AnimationScope.maybeOf(context);
    if (clock != null && !_attached) {
      _clock = clock;
      clock.addTicker(_ticker);
      _attached = true;
    }

    const Color page = Color(0xFF070A11);
    const Color panel = Color(0xFF111927);
    const Color text = Color(0xFFE7EEF9);
    const Color muted = Color(0xFF8EA0B8);

    return ColoredBox(
      color: page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ColoredBox(
            color: panel,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _mesh?.name ?? 'Nenhum modelo aberto',
                          color: text,
                          fontSize: 15,
                        ),
                        Text(
                          _mesh == null
                              ? 'OBJ, STL, glTF ou GLB'
                              : '${_mesh!.format} · '
                                  '${_mesh!.triangleCount} triângulos · '
                                  '${_mesh!.primitives.length} primitivas · '
                                  'lido em ${_loadTime.inMilliseconds} ms',
                          color: muted,
                          fontSize: 11,
                        ),
                      ],
                    ),
                  ),
                  Button(label: 'ABRIR MODELO', onPressed: _open),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          color: const Color(0xFFE0754A),
                          fontSize: 13,
                        ),
                      ),
                    )
                  : _mesh == null
                      ? const Center(
                          child: Text(
                            'Abra um arquivo OBJ, STL, glTF ou GLB.\n'
                            'FBX é recusado pelo nome: exporte como glTF.',
                            color: muted,
                            fontSize: 13,
                          ),
                        )
                      : GestureDetector(
                          onPanUpdate: (DragUpdateDetails details) =>
                              _orbit(details.delta),
                          child: _ModelView(
                            mesh: _mesh!,
                            camera: _camera,
                            shading: _shading,
                            onCreated: (_RenderModel render) =>
                                _render = render,
                          ),
                        ),
            ),
          ),
          ColoredBox(
            color: panel,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_statusLine(), color: text, fontSize: 12),
                  const SizedBox(height: 4),
                  const Text(
                    'Os triângulos são rasterizados pela CPU. O backend acima '
                    'apresenta o resultado como uma imagem; ele não desenha a '
                    'malha. Este framework não tem pipeline 3D.',
                    color: muted,
                    fontSize: 11,
                  ),
                  if (_mesh != null && _mesh!.unsupported.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Não lido neste arquivo: '
                      '${_mesh!.unsupported.join(', ')}',
                      color: const Color(0xFFE0B341),
                      fontSize: 11,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      for (final MeshShading shading in MeshShading.values) ...[
                        Button(
                          label: _shadingLabel(shading),
                          onPressed: shading == _shading
                              ? null
                              : () {
                                  setState(() => _shading = shading);
                                  _render?.markNeedsPaint();
                                },
                        ),
                        const SizedBox(width: 8),
                      ],
                      Button(
                        label: _spinning ? 'PARAR' : 'GIRAR',
                        onPressed: () => setState(() => _spinning = !_spinning),
                      ),
                      const SizedBox(width: 8),
                      Button(label: '+', onPressed: () => _zoom(0.8)),
                      const SizedBox(width: 8),
                      Button(label: '-', onPressed: () => _zoom(1.25)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _shadingLabel(MeshShading shading) => switch (shading) {
        MeshShading.smooth => 'SUAVE',
        MeshShading.flat => 'FACETADO',
        MeshShading.unlit => 'SEM LUZ',
        MeshShading.wireframe => 'ARAME',
      };

  String _statusLine() {
    final MeshRenderStats stats = _render?.lastStats ?? MeshRenderStats.zero;
    if (stats.triangles == 0) return 'nenhum modelo carregado · $_source';
    return '${widget.session.backendName} apresenta · '
        '${_fps.toStringAsFixed(1)} fps · '
        'rasterizador ${(stats.microseconds / 1000).toStringAsFixed(2)} ms · '
        '${stats.drawn} de ${stats.triangles} desenhados · '
        '${stats.culled} descartados por face · '
        '${stats.clipped} cortados no near · ${stats.pixels} pixels';
  }
}

/// Draws the model and turns drags into camera moves.
final class _ModelView extends RenderObjectWidget {
  const _ModelView({
    required this.mesh,
    required this.camera,
    required this.shading,
    required this.onCreated,
  });

  final Mesh3D mesh;
  final MeshCamera camera;
  final MeshShading shading;
  final void Function(_RenderModel render) onCreated;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  _RenderModel createRenderObject(BuildContext context) {
    final _RenderModel render = _RenderModel(
      mesh: mesh,
      camera: camera,
      shading: shading,
    );
    onCreated(render);
    return render;
  }

  @override
  void updateRenderObject(BuildContext context, _RenderModel renderObject) {
    renderObject
      ..mesh = mesh
      ..camera = camera
      ..shading = shading;
    onCreated(renderObject);
  }
}

final class _RenderModel extends RenderBox {
  _RenderModel({
    required Mesh3D mesh,
    required MeshCamera camera,
    required MeshShading shading,
  })  : _mesh = mesh,
        _camera = camera,
        _shading = shading;

  Mesh3D _mesh;
  MeshCamera _camera;
  MeshShading _shading;

  final MeshRasterizer _rasterizer = MeshRasterizer();
  Framebuffer? _target;
  MeshRenderStats lastStats = MeshRenderStats.zero;

  set mesh(Mesh3D value) {
    if (identical(value, _mesh)) return;
    _mesh = value;
    markNeedsPaint();
  }

  set camera(MeshCamera value) {
    _camera = value;
    markNeedsPaint();
  }

  set shading(MeshShading value) {
    if (value == _shading) return;
    _shading = value;
    markNeedsPaint();
  }

  @override
  void performLayout() => size = constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty) return;
    final int width = size.width.round();
    final int height = size.height.round();
    if (width <= 0 || height <= 0) return;

    // Reallocated only when the window changes size. A framebuffer per frame
    // for a 1000x700 view is 2.8 MB of garbage sixty times a second, which the
    // collector notices even when nothing else in the program does.
    Framebuffer? target = _target;
    if (target == null || target.width != width || target.height != height) {
      target = _target = Framebuffer.allocate(width: width, height: height);
    }

    _rasterizer.render(
      target,
      _mesh,
      _camera,
      shading: _shading,
      backgroundArgb: 0xFF0C111B,
    );
    lastStats = _rasterizer.stats;

    list.drawImage(
      list.addImage(target),
      0,
      0,
      width.toDouble(),
      height.toDouble(),
      offset.dx,
      offset.dy,
      offset.dx + width,
      offset.dy + height,
      list.addPaint(colorArgb: 0xFFFFFFFF),
    );
  }
}

final class _ViewerTicker implements AnimationTicker {
  _ViewerTicker({required this.ticking, required this.onTick});

  final bool Function() ticking;
  final void Function(Duration timestamp) onTick;

  @override
  bool get isTicking => ticking();

  @override
  void tick(Duration timestamp) => onTick(timestamp);
}
