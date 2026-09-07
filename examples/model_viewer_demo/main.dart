/// A 3D model viewer: open a file, orbit it, pan it, zoom it, and see what
/// each frame cost.
///
/// Reads OBJ, STL, glTF and GLB. FBX is refused by name with what to export
/// instead — see `lib/src/graphics/mesh/mesh_loaders.dart` for why half-reading
/// it would be worse than not reading it.
///
/// ## The controls
///
/// The scheme is three.js' `OrbitControls`, because that is the one a user
/// already knows from every other 3D tool they have opened:
///
///   * **left drag** orbits, pitch clamped short of the poles;
///   * **right drag or middle drag** pans — the *target* slides in the camera's
///     own screen plane, so the model follows the cursor at any zoom;
///   * **the wheel** zooms, about the pointer rather than about the centre;
///   * **F** frames the model again, and so does the ENQUADRAR button. It is
///     the way back from a camera panned somewhere with nothing in shot, which
///     is a state every 3D viewer eventually gets into;
///   * **the arrow keys** nudge the orbit, **+/-** zoom, **G** starts and stops
///     the turntable.
///
/// None of that arithmetic lives here. It is [OrbitCameraController], beside
/// [MeshCamera] in `lib/src/rendering/mesh/mesh_rasterizer.dart`, because a
/// scene view, a level editor and a 3D game's inspector all want exactly the
/// same control scheme and differ only in what draws the pixels. What lives
/// here is the wiring from this framework's pointer and key events to it.
///
/// ## What is doing the drawing
///
/// The status bar names the path that actually drew the frame, and it asks the
/// render object rather than asserting it: see [MeshDrawPath]. Today there is
/// one answer — this framework's display list has no triangle and no depth
/// buffer, so the mesh is rasterised on the CPU into a framebuffer that the
/// window's backend then presents as one image. The backend named beside it
/// *presents* that image; reading "direct3d11" there and concluding the GPU
/// drew the model would be exactly the wrong conclusion, which is why the two
/// halves are labelled separately.
///
/// ```
/// dart run examples/model_viewer_demo/main.dart D:/3d/sonic.glb
/// dart run examples/model_viewer_demo/main.dart --frames=200 --report model.stl
/// ```
///
/// `--frames=N` runs N frames with no human and exits, which is how this demo
/// is checked in a script: interactive controls cannot be proven by a unit test
/// and a window that does not close itself is worse than no test at all.
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

/// The value of `--name=value`, or of `--name value`.
///
/// Both forms, because the second is what a person types from memory and
/// silently treating its value as a model path — which is what a `startsWith`
/// filter does with `--frames 200` — produces "não encontrei 200" and no
/// explanation.
String? _valueOf(List<String> arguments, String name) {
  for (int i = 0; i < arguments.length; i++) {
    final String argument = arguments[i];
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
    if (argument == name && i + 1 < arguments.length) return arguments[i + 1];
  }
  return null;
}

/// The positional arguments: everything that is not a flag and not a flag's
/// value.
List<String> _positional(List<String> arguments) {
  final List<String> paths = <String>[];
  for (int i = 0; i < arguments.length; i++) {
    final String argument = arguments[i];
    if (argument.startsWith('--')) {
      if (!argument.contains('=') && argument == '--frames') i++;
      continue;
    }
    paths.add(argument);
  }
  return paths;
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
  final List<String> paths = _positional(arguments);
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
        'REPORT draw_path=${session.drawPath.name} '
        'backend=${session.backendName} '
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

/// Which path drew the triangles of the last frame.
///
/// Reported by the render object that did the drawing rather than written into
/// the status bar as a sentence, because a sentence goes stale silently: this
/// viewer used to state "os triângulos são rasterizados pela CPU" as a fact
/// about the framework, and the moment a GPU mesh pipeline lands that fact
/// becomes a lie with nothing to catch it.
///
/// ## The seam this needs from the framework, and does not have
///
/// The honest answer today is that the *demo's own* render object knows, since
/// it is the thing that calls [MeshRasterizer]. That is enough to keep the text
/// true, and it does not survive the mesh being drawn by anything else. What
/// would be needed for the viewer to report a path it did not choose itself:
///
///   * a field on [MeshRenderStats] — the natural home, since the stats already
///     travel from whatever drew the frame back to whoever asks — naming the
///     path that produced them; or
///   * a capability query on `RendererBackend`, answering whether this backend
///     has a mesh pipeline at all, so the viewer can say *why* it got the CPU
///     path (no pipeline, versus a pipeline that failed and fell back).
///
/// Neither exists yet. What landed while this was being written is the half
/// below them: `lib/src/rendering/mesh/mesh_scene.dart` now declares a
/// `MeshSceneRenderer` contract that a backend fills to draw a mesh itself, and
/// the Direct3D 11 implementation of it. What is still missing is the way an
/// application *gets* one — nothing hands a widget the running backend's mesh
/// renderer — and a way for the answer to travel back with the frame. When both
/// exist, the only line that changes is the assignment in `_RenderModel.paint`.
///
/// `MeshRenderStats` is owned by whoever is adding those pipelines, so adding a
/// field to it from here would collide with them; this enum stays local until
/// there is a second path to report.
enum MeshDrawPath {
  /// Nothing drawn yet: no model, or no frame produced.
  none('nada desenhado', ''),

  /// [MeshRasterizer], on the CPU, into a [Framebuffer] the backend presents.
  cpu(
    'CPU rasteriza',
    'Os triângulos são rasterizados pela CPU nesta sessão. O backend acima '
        'apresenta o resultado como uma imagem; ele não desenha a malha.',
  ),

  /// A GPU mesh pipeline. No such pipeline exists yet; this member is here so
  /// that the day one lands, the status bar reports it instead of being
  /// rewritten.
  gpu(
    'GPU desenha',
    'Os triângulos são desenhados pelo pipeline 3D do backend.',
  );

  const MeshDrawPath(this.label, this.explanation);

  /// What the status line calls this path.
  final String label;

  /// The sentence below the status line, in as many words.
  final String explanation;
}

/// What `main` and the widget share.
final class ViewerSession {
  Application? application;
  MeshRenderStats stats = MeshRenderStats.zero;
  double framesPerSecond = 0;
  MeshDrawPath drawPath = MeshDrawPath.none;

  /// The size of the surface the model is drawn into, which is not the
  /// window's: the panels above and below it take a hundred and fifty pixels.
  /// Every camera move is scaled by this height, so it is the number anything
  /// checking a pan against the picture has to use.
  Size viewportSize = Size.zero;

  /// The controls the viewer is driving.
  ///
  /// Published because the wiring from a pointer to the camera is exactly the
  /// part a unit test of the arithmetic cannot reach, and it is where this
  /// viewer was broken: the camera maths was fine and the wheel simply never
  /// arrived. A test drives the real widget tree and asks this where the camera
  /// ended up. See test/examples/model_viewer_interaction_test.dart.
  OrbitCameraController? controls;

  /// The presentation path actually chosen.
  ///
  /// It presents whatever produced the picture; on the CPU path it does not
  /// draw the triangles. The status bar says which is which, because a viewer
  /// reporting "direct3d11" beside a 3D model invites exactly the wrong
  /// conclusion.
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

/// Virtual key codes, in the same form `focus.dart` publishes the others.
const int _logicalKeyF = 0x46;
const int _logicalKeyG = 0x47;
const int _logicalKeyPlus = 0xBB;
const int _logicalKeyMinus = 0xBD;
const int _logicalKeyNumpadAdd = 0x6B;
const int _logicalKeyNumpadSubtract = 0x6D;

final class _ModelViewerDemoState extends State<ModelViewerDemo>
    implements KeyboardEventTarget {
  Mesh3D? _mesh;
  String? _error;
  String _source = '';
  Duration _loadTime = Duration.zero;

  late OrbitCameraController _controls;
  MeshShading _shading = MeshShading.smooth;
  bool _spinning = true;

  late final FocusNode _focusNode =
      FocusNode(debugLabel: 'ModelViewer', target: this);

  final Stopwatch _rateWindow = Stopwatch()..start();
  int _framesThisWindow = 0;
  double _fps = 0;

  AnimationClock? _clock;
  late final _ViewerTicker _ticker = _ViewerTicker(
    // The loop only stays awake while something is actually moving. A ticker
    // that always answers true rasterises 450,000 triangles sixty times a
    // second to produce the same picture, which is a laptop fan for nothing;
    // a pointer or key event asks for a frame on its own, so nothing is lost
    // by going quiet. A budgeted run (`--frames`) drives its own frames and
    // does not depend on this answer.
    ticking: () => mounted && (_spinning || _controls.isSettling),
    onTick: (_) => _onTick(),
  );
  bool _attached = false;
  _RenderModel? _render;
  bool _opening = false;

  /// The pointer holding the view, and which button it went down with.
  int? _activePointer;
  PointerButton? _activeButton;
  Offset _lastPointerPosition = Offset.zero;

  @override
  void initState() {
    super.initState();
    _mesh = widget.mesh;
    _error = widget.error;
    _source = widget.sourcePath;
    _loadTime = widget.loadTime;
    _controls = OrbitCameraController.framing(
      _mesh?.computeBounds() ?? Bounds3.empty,
    );
    widget.session.controls = _controls;
  }

  @override
  void dispose() {
    if (_attached) _clock?.removeTicker(_ticker);
    _focusNode.dispose();
    super.dispose();
  }

  /// The height the camera arithmetic is scaled by: the viewport's, in pixels.
  ///
  /// Only the height, on both axes — see [MeshCamera.worldUnitsPerPixel]. Zero
  /// before the first layout, which every caller treats as "no movement" rather
  /// than dividing by it.
  double get _viewportHeight {
    final _RenderModel? render = _render;
    return render != null && render.hasSize ? render.size.height : 0;
  }

  /// Repaints, and rebuilds only the status line, twice a second.
  ///
  /// A ticker runs inside the frame, so a `setState` from here dirties the
  /// build the frame is settling and the loop never converges - the window dies
  /// with "the frame did not settle in 8 passes". The picture needs a repaint,
  /// not a rebuild, and the camera reaches the render object by assignment for
  /// exactly that reason.
  void _onTick() {
    if (!mounted) return;
    if (_spinning) _controls.spin(yawDelta: 0.012);
    if (_controls.update()) _render?.camera = _controls.camera;
    _framesThisWindow++;
    final _RenderModel? render = _render;
    widget.session
      ..stats = render?.lastStats ?? MeshRenderStats.zero
      ..drawPath = render?.lastDrawPath ?? MeshDrawPath.none
      ..viewportSize =
          render != null && render.hasSize ? render.size : Size.zero
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
      if (mesh != null) _controls.frame(mesh.computeBounds());
    });
    _render?.markNeedsPaint();
  }

  // ---------------------------------------------------------------------
  // Input
  //
  // Raw pointer events rather than a GestureDetector, for the reasons
  // `PointerListener` documents: the wheel is not a gesture and no recognizer
  // is offered one, and there is no middle-button or right-button drag
  // callback to ask for. Pan on the right button is the convention this viewer
  // would otherwise have to do without.
  // ---------------------------------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    _focusNode.requestFocus(FocusChangeReason.pointer);
    _activePointer = event.pointerId;
    _activeButton = event.button;
    _lastPointerPosition = event.logicalPosition;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointerId != _activePointer) return;
    final Offset delta = event.logicalPosition - _lastPointerPosition;
    _lastPointerPosition = event.logicalPosition;
    final double height = _viewportHeight;
    if (height <= 0) return;
    switch (_activeButton) {
      case PointerButton.primary:
        _controls.rotateByPixels(delta.dx, delta.dy, viewportHeight: height);
      case PointerButton.secondary:
      case PointerButton.middle:
        _controls.panByPixels(delta.dx, delta.dy, viewportHeight: height);
      case PointerButton.forward:
      case PointerButton.back:
      case null:
        return;
    }
    // The move is only accumulated; [OrbitCameraController.update] applies it
    // on the next tick, damped. Asking for the frame here is what makes that
    // tick happen at all when the viewer was idle.
    _render?.markNeedsPaint();
  }

  void _endPointer(PointerEvent event) {
    if (event.pointerId != _activePointer) return;
    _activePointer = null;
    _activeButton = null;
  }

  void _onPointerScroll(PointerScrollEvent event) {
    final _RenderModel? render = _render;
    final double height = _viewportHeight;
    if (render == null || height <= 0) return;
    // A "line" is one detent. Pixel-unit devices - trackpads, and some mice
    // through some drivers - report far larger numbers, so they are divided
    // down to detents before anything else looks at them.
    final double unit =
        event.scrollDeltaUnit == ScrollDeltaUnit.lines ? 1.0 : 1 / 40.0;
    final double notches = event.scrollDelta.dy * unit;
    if (notches == 0) return;
    final Offset local = render.globalToLocal(event.logicalPosition);
    _controls.zoomByWheel(
      notches,
      focusX: local.dx - render.size.width / 2,
      focusY: local.dy - render.size.height / 2,
      viewportHeight: height,
    );
    render.camera = _controls.camera;
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final double height = _viewportHeight;
    switch (event.logicalKey) {
      case _logicalKeyF:
        _controls.frame();
      case _logicalKeyG:
        setState(() => _spinning = !_spinning);
        return true;
      case logicalKeyArrowLeft:
        _controls.rotateByPixels(-24, 0, viewportHeight: height);
      case logicalKeyArrowRight:
        _controls.rotateByPixels(24, 0, viewportHeight: height);
      case logicalKeyArrowUp:
        _controls.rotateByPixels(0, -24, viewportHeight: height);
      case logicalKeyArrowDown:
        _controls.rotateByPixels(0, 24, viewportHeight: height);
      case _logicalKeyPlus:
      case _logicalKeyNumpadAdd:
        _controls.zoomBy(0.8);
      case _logicalKeyMinus:
      case _logicalKeyNumpadSubtract:
        _controls.zoomBy(1.25);
      default:
        return false;
    }
    _render?.camera = _controls.camera;
    _render?.markNeedsPaint();
    return true;
  }

  void _zoom(double factor) {
    _controls.zoomBy(factor);
    _render?.camera = _controls.camera;
  }

  void _frame() {
    _controls.frame();
    _render?.camera = _controls.camera;
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
                      : FocusAttachment(
                          node: _focusNode,
                          autofocus: true,
                          child: PointerListener(
                            onPointerDown: _onPointerDown,
                            onPointerMove: _onPointerMove,
                            onPointerUp: _endPointer,
                            onPointerCancel: _endPointer,
                            onPointerScroll: _onPointerScroll,
                            child: _ModelView(
                              mesh: _mesh!,
                              camera: _controls.camera,
                              shading: _shading,
                              onCreated: (_RenderModel render) =>
                                  _render = render,
                            ),
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
                  Text(
                    (_render?.lastDrawPath ?? MeshDrawPath.none).explanation,
                    color: muted,
                    fontSize: 11,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Botão esquerdo orbita · botão direito ou do meio desloca · '
                    'roda aproxima no ponteiro · F enquadra · G gira · '
                    'setas e +/- também.',
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
                      Button(label: 'ENQUADRAR', onPressed: _frame),
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
    return '${(_render?.lastDrawPath ?? MeshDrawPath.none).label} · '
        '${widget.session.backendName} apresenta · '
        '${_fps.toStringAsFixed(1)} fps · '
        'rasterizador ${(stats.microseconds / 1000).toStringAsFixed(2)} ms · '
        '${stats.drawn} de ${stats.triangles} desenhados · '
        '${stats.culled} descartados por face · '
        '${stats.clipped} cortados no near · ${stats.pixels} pixels · '
        'distância ${_controls.camera.distance.toStringAsFixed(2)}';
  }
}

/// Draws the model.
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

  /// What drew the last frame. Set by [paint], never asserted from outside.
  MeshDrawPath lastDrawPath = MeshDrawPath.none;

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
    // Reported from the branch that actually ran. When a GPU mesh path exists,
    // it is this assignment that changes, not the status bar.
    lastDrawPath = MeshDrawPath.cpu;

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
