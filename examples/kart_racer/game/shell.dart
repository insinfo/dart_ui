/// Um kart racer 3D: uma volta fechada, dois adversários e uma câmera de
/// perseguição, desenhados pela GPU através de `MeshSceneScope`.
///
/// A demonstração é de que este framework aguenta um jogo 3D: a simulação anda
/// em passo fixo de 120 Hz independente da taxa de quadros, a pista é uma
/// spline fechada com paredes e contagem de voltas, e a interface 2D é
/// composta por cima do back buffer que a malha desenhou.
///
/// ```
/// dart run examples/kart_racer/main.dart
/// dart run examples/kart_racer/main.dart --frames=600 --report
/// dart run examples/kart_racer/main.dart --replay=1800 --headless
/// ```
///
/// Compile antes de julgar a velocidade: `dart run` gasta uns seis segundos
/// compilando este pacote antes do `main`, e o número que importa é o do AOT.
/// Veja `tool/startup_cost.dart`.
///
/// ## O que não se pode fazer aqui, e custa uma tarde a descobrir
///
/// No caminho da GPU o modelo é desenhado no back buffer **antes** da display
/// list, então nada opaco pode ser pintado por cima do viewport. Um
/// `ColoredBox` de janela inteira atrás do HUD dá uma janela preta com a
/// interface funcionando, o que se lê como "o modelo não carregou" e não é.
/// Por isso o HUD abaixo é uma [Stack] cujos painéis cobrem só os cantos.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene_host.dart';
import 'package:dart_ui/src/widgets/mesh_scene_scope.dart';

import 'chase_camera.dart';
import 'geometry.dart';
import 'race.dart';
import 'track.dart';
import 'vehicle.dart';

void forceKartCpuRendering(bool value) {
  _KartRacerState.forceCpuFromArguments = value;
}

/// What `main`, the widget and the tests share.
///
/// The same shape `ViewerSession` has in `model_viewer_demo`, and for the same
/// reason: the interesting state of a demo lives inside a `State` that nothing
/// outside can reach, and a test that cannot ask where the kart ended up can
/// only assert that the window opened.
final class GameSession {
  Application? application;

  /// The race being driven. Null until the first build.
  Race? race;

  /// The camera following the player.
  ChaseCamera? camera;

  MeshRenderStats stats = MeshRenderStats.zero;
  double framesPerSecond = 0;
  double frameMilliseconds = 0;
  int staticTriangles = 0;
  String drawPath = 'nada';

  /// What is drawing the triangles: `direct3d11`, `opengl`, or `cpu`.
  String rendererName = 'selecionando';

  /// The input the last simulation step actually used, after the keyboard has
  /// been smoothed. The one thing a test of the controls has to be able to
  /// see.
  KartInput lastInput = KartInput.idle;
}

final class KartRacer extends StatefulWidget {
  const KartRacer({
    required this.session,
    this.laps = 3,
    this.opponents = 2,
    this.prop,
    super.key,
  });

  final GameSession session;
  final int laps;
  final int opponents;

  /// A model to stand beside the start line, or null.
  final Mesh3D? prop;

  @override
  State<KartRacer> createState() => _KartRacerState();
}

// Win32 virtual key codes, in the form `focus.dart` publishes the others.
const int _keyW = 0x57;
const int _keyA = 0x41;
const int _keyS = 0x53;
const int _keyD = 0x44;
const int _keyR = 0x52;
const int _keyShift = 0x10;
const int _keyControl = 0x11;

/// Seconds for the steering to travel from centre to full lock.
///
/// A keyboard has no axis: the key is down or it is not, and feeding ±1
/// straight into the physics gives a kart that snaps between three states and
/// is impossible to place. This is the ramp that turns two digital keys back
/// into an analogue stick, and it is the single change that made the handling
/// feel like a kart rather than like a cursor.
const double _steerRampSeconds = 0.16;

/// The same, coming back to centre. Faster than going out, because a player
/// letting go of the key means "straighten now".
const double _steerReturnSeconds = 0.09;

final class _KartRacerState extends State<KartRacer>
    implements KeyboardEventTarget {
  static bool forceCpuFromArguments = false;

  late Race _race;
  late ChaseCamera _camera;
  late CircuitMesh _circuit;
  late List<MeshPrimitive> _staticPrimitives;
  late List<KartMesh> _kartMeshes;

  final FixedStepAccumulator _accumulator =
      FixedStepAccumulator(step: kSimulationStep, maxStepsPerFrame: 8);

  final Set<int> _heldKeys = <int>{};
  double _steer = 0;

  bool _forceCpu = false;
  Duration? _previousTimestamp;

  final Stopwatch _rateWindow = Stopwatch()..start();
  int _framesThisWindow = 0;
  double _fps = 0;
  double _frameMs = 0;

  AnimationClock? _clock;
  bool _attached = false;
  _RenderCircuit? _render;

  late final FocusNode _focusNode =
      FocusNode(debugLabel: 'KartRacer', target: this);

  late final _GameTicker _ticker = _GameTicker(
    // Always, unlike the model viewer's: a race is running whether or not
    // anybody is pressing anything, and a ticker that went quiet would stop
    // the opponents mid-corner.
    ticking: () => mounted,
    onTick: _onTick,
  );

  @override
  void initState() {
    super.initState();
    _forceCpu = forceCpuFromArguments;
    _buildWorld();
  }

  void _buildWorld() {
    _race = Race.grid(opponents: widget.opponents, totalLaps: widget.laps);
    _camera = ChaseCamera()..snapTo(_race.player.body);
    _circuit = buildCircuitMesh(_race.track);
    _kartMeshes = <KartMesh>[
      for (final Racer racer in _race.racers) buildKartMesh(racer.colorArgb),
    ];
    _staticPrimitives = <MeshPrimitive>[..._circuit.primitives];
    final Mesh3D? prop = widget.prop;
    if (prop != null) {
      // Beside the start line and well outside the barrier, so it can never be
      // driven into and never has to be in the collision model.
      final TrackSample start = _race.track.frameAt(0);
      _staticPrimitives.addAll(placeProp(
        prop,
        targetHeight: 9,
        x: start.x + start.normalX * (_race.track.wallOffset + 9),
        z: start.z + start.normalZ * (_race.track.wallOffset + 9),
        yaw: math.atan2(-start.normalX, -start.normalZ),
      ));
    }
    widget.session
      ..race = _race
      ..camera = _camera
      ..staticTriangles = _circuit.triangleCount;
  }

  @override
  void dispose() {
    if (_attached) _clock?.removeTicker(_ticker);
    _focusNode.dispose();
    super.dispose();
  }

  /// The player's input for this step, with the keyboard's two digital keys
  /// turned back into an axis.
  KartInput _pollInput(double dt) {
    final double target = (_heldKeys.contains(logicalKeyArrowRight) ||
                _heldKeys.contains(_keyD)
            ? 1.0
            : 0.0) +
        (_heldKeys.contains(logicalKeyArrowLeft) || _heldKeys.contains(_keyA)
            ? -1.0
            : 0.0);
    final double tau = target == 0 ? _steerReturnSeconds : _steerRampSeconds;
    _steer += (target - _steer) * (1 - math.exp(-dt / tau));
    return KartInput(
      throttle:
          _heldKeys.contains(logicalKeyArrowUp) || _heldKeys.contains(_keyW)
              ? 1
              : 0,
      brake:
          _heldKeys.contains(logicalKeyArrowDown) || _heldKeys.contains(_keyS)
              ? 1
              : 0,
      steer: _steer,
      drift: _heldKeys.contains(logicalKeySpace) ||
          _heldKeys.contains(_keyShift) ||
          _heldKeys.contains(_keyControl),
    );
  }

  /// One frame of simulation, then a repaint.
  ///
  /// **No `setState` from here.** A ticker runs inside the frame, so a
  /// `setState` dirties the build the frame is settling and the window dies
  /// with "the frame did not settle in 8 passes". The picture needs a repaint,
  /// which reaches the render object by assignment; the HUD's *text* needs a
  /// rebuild, which is asked for through `Timer.run` at the bottom - outside
  /// the frame, and twenty times a second rather than sixty.
  void _onTick(Duration timestamp) {
    if (!mounted) return;
    final Duration previous = _previousTimestamp ?? timestamp;
    _previousTimestamp = timestamp;
    Duration delta = timestamp - previous;
    if (delta.isNegative) delta = Duration.zero;
    // A window dragged, alt-tabbed or paused by the debugger returns with a
    // delta of seconds. Without the cap the accumulator would run its eight
    // steps, report the rest as dropped, and the kart would still have jumped
    // half the straight; with it, the race simply pauses while the window is
    // not being drawn, which is what a player expects.
    const Duration cap = Duration(milliseconds: 100);
    if (delta > cap) delta = cap;

    final int steps = _accumulator.advance(delta);
    final double dt = kSimulationStep.inMicroseconds / 1e6;
    for (int i = 0; i < steps; i++) {
      final KartInput input = _pollInput(dt);
      widget.session.lastInput = input;
      _race.step(dt, input);
      _camera.follow(_race.player.body, dt,
          maxSpeed: _race.player.body.tuning.maxSpeed);
    }

    _render
      ?..camera = _camera.camera
      ..transforms = _transforms();

    _framesThisWindow++;
    final _RenderCircuit? render = _render;
    widget.session
      ..stats = render?.lastStats ?? MeshRenderStats.zero
      ..drawPath = render?.lastDrawPath ?? 'nada'
      ..rendererName = render?.lastRendererName ?? 'selecionando';
    if (_rateWindow.elapsedMilliseconds < 500) return;
    _fps = _framesThisWindow * 1000 / _rateWindow.elapsedMilliseconds;
    _frameMs = _fps > 0 ? 1000 / _fps : 0;
    _framesThisWindow = 0;
    _rateWindow.reset();
    widget.session
      ..framesPerSecond = _fps
      ..frameMilliseconds = _frameMs;
    Timer.run(() {
      if (mounted) setState(() {});
    });
  }

  /// Where each kart is drawn this frame.
  ///
  /// The lean is derived from the state the physics already has rather than
  /// being animated separately: roll from the lateral slip, pitch from the
  /// longitudinal acceleration this step. Two lines, and they are most of what
  /// makes the drift legible from behind.
  List<KartTransform> _transforms() {
    final List<KartTransform> out = <KartTransform>[];
    for (final Racer racer in _race.racers) {
      final KartBody body = racer.body;
      final double roll = (body.lateralSpeed / 22).clamp(-0.24, 0.24) *
          (body.drifting ? 1.4 : 1);
      final double pitch =
          (-body.yawRate * body.forwardSpeed / 260).clamp(-0.06, 0.06);
      out.add(KartTransform(
        x: body.x,
        y: 0,
        z: body.z,
        heading: body.heading,
        roll: roll,
        pitch: pitch,
        steer: body.steerAngle,
      ));
    }
    return out;
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    switch (event) {
      case KeyDownEvent():
        if (event.logicalKey == _keyR && !event.isRepeat) {
          // Rebuilt rather than reset field by field: a restart that forgot
          // one accumulator - the drift charge, the lap crossing times - is a
          // race that starts with a boost or on lap two, and finding which
          // field was missed costs more than rebuilding the world.
          setState(_buildWorld);
          _render?.rebuildWorld(_staticPrimitives, _kartMeshes);
          return true;
        }
        _heldKeys.add(event.logicalKey);
        return true;
      case KeyUpEvent():
        _heldKeys.remove(event.logicalKey);
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AnimationClock? clock = AnimationScope.maybeOf(context);
    if (clock != null && !_attached) {
      _clock = clock;
      clock.addTicker(_ticker);
      _attached = true;
    }

    // No opaque background anywhere over the viewport; see the library
    // comment. The 3D pass clears the whole surface to the sky colour and this
    // stack only paints its corners.
    return FocusAttachment(
      node: _focusNode,
      autofocus: true,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _CircuitView(
            surface: MeshSceneScope.maybeOf(context),
            forceCpu: _forceCpu,
            staticPrimitives: _staticPrimitives,
            kartMeshes: _kartMeshes,
            camera: _camera.camera,
            transforms: _transforms(),
            onCreated: (_RenderCircuit render) => _render = render,
          ),
          _Hud(
            race: _race,
            fps: _fps,
            frameMilliseconds: _frameMs,
            triangles: widget.session.stats.triangles,
            drawPath: widget.session.drawPath,
            rendererName: widget.session.rendererName,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The HUD
// ---------------------------------------------------------------------------

const Color _panel = Color(0xC00E1520);
const Color _ink = Color(0xFFF2F6FB);
const Color _muted = Color(0xFF9FB2C8);
const Color _accent = Color(0xFFFFC53D);

String _formatClock(double seconds) {
  if (seconds < 0) seconds = 0;
  final int minutes = seconds ~/ 60;
  final double rest = seconds - minutes * 60;
  return '$minutes:${rest.toStringAsFixed(2).padLeft(5, '0')}';
}

final class _Hud extends StatelessWidget {
  const _Hud({
    required this.race,
    required this.fps,
    required this.frameMilliseconds,
    required this.triangles,
    required this.drawPath,
    required this.rendererName,
  });

  final Race race;
  final double fps;
  final double frameMilliseconds;
  final int triangles;
  final String drawPath;
  final String rendererName;

  @override
  Widget build(BuildContext context) {
    final Racer player = race.player;
    final double? best = player.counter.bestLap;
    return Stack(
      children: <Widget>[
        Positioned(
          left: 16,
          top: 16,
          child: _Card(
            children: <Widget>[
              _Reading(
                label: 'VOLTA',
                value:
                    '${math.min(race.totalLaps, math.max(1, player.counter.lap))}'
                    '/${race.totalLaps}',
              ),
              const SizedBox(height: 8),
              _Reading(
                label: 'POSIÇÃO',
                value: '${player.position}/${race.racers.length}',
              ),
            ],
          ),
        ),
        Positioned(
          right: 16,
          top: 16,
          child: _Card(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              _Reading(label: 'TEMPO', value: _formatClock(race.time)),
              const SizedBox(height: 8),
              _Reading(
                label: 'MELHOR VOLTA',
                value: best == null ? '--:--.--' : _formatClock(best),
              ),
            ],
          ),
        ),
        Positioned(
          left: 16,
          bottom: 16,
          child: _Card(
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    (player.body.speed * 3.6).round().toString(),
                    color: _ink,
                    fontSize: 40,
                  ),
                  const SizedBox(width: 6),
                  const Text('km/h', color: _muted, fontSize: 13),
                ],
              ),
              Text(
                player.body.boostRemaining > 0
                    ? 'TURBO'
                    : player.body.drifting
                        ? 'DERRAPANDO '
                            '${(player.body.driftCharge * 100).round()}%'
                        : player.surface.onRoad
                            ? 'PISTA'
                            : 'GRAMA',
                color: player.body.boostRemaining > 0
                    ? _accent
                    : player.surface.onRoad
                        ? _muted
                        : const Color(0xFF8FD37A),
                fontSize: 12,
              ),
            ],
          ),
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: _Card(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '${fps.toStringAsFixed(1)} fps · '
                '${frameMilliseconds.toStringAsFixed(2)} ms',
                color: _ink,
                fontSize: 13,
              ),
              Text(
                '$drawPath · $rendererName · $triangles triângulos',
                color: _muted,
                fontSize: 11,
              ),
              const Text(
                'setas/WASD dirigem · espaço derrapa · R reinicia',
                color: _muted,
                fontSize: 11,
              ),
            ],
          ),
        ),
        if (!race.started)
          Align(
            child: _Card(
              children: <Widget>[
                Text(
                  race.countdownRemaining > 1
                      ? '${race.countdownRemaining.ceil() - 1}'
                      : 'VAI!',
                  color: _accent,
                  fontSize: 56,
                ),
              ],
            ),
          ),
        if (race.finished)
          Align(
            child: _Card(
              children: <Widget>[
                Text(
                  player.position == 1
                      ? 'VITÓRIA'
                      : '${player.position}º LUGAR',
                  color: _accent,
                  fontSize: 34,
                ),
                const SizedBox(height: 6),
                Text(
                  'tempo ${_formatClock(player.finishTime ?? race.time)} · '
                  'melhor volta ${best == null ? '--' : _formatClock(best)}',
                  color: _ink,
                  fontSize: 14,
                ),
                const SizedBox(height: 6),
                const Text('R para correr de novo',
                    color: _muted, fontSize: 12),
              ],
            ),
          ),
      ],
    );
  }
}

final class _Card extends StatelessWidget {
  const _Card({
    required this.children,
    this.crossAxisAlignment = CrossAxisAlignment.start,
  });

  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: _panel,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: crossAxisAlignment,
            children: children,
          ),
        ),
      );
}

final class _Reading extends StatelessWidget {
  const _Reading({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, color: _muted, fontSize: 10),
          Text(value, color: _ink, fontSize: 24),
        ],
      );
}

// ---------------------------------------------------------------------------
// The 3D view
// ---------------------------------------------------------------------------

final class _CircuitView extends RenderObjectWidget {
  const _CircuitView({
    required this.surface,
    required this.forceCpu,
    required this.staticPrimitives,
    required this.kartMeshes,
    required this.camera,
    required this.transforms,
    required this.onCreated,
  });

  final MeshSceneSurface? surface;
  final bool forceCpu;
  final List<MeshPrimitive> staticPrimitives;
  final List<KartMesh> kartMeshes;
  final MeshCamera camera;
  final List<KartTransform> transforms;
  final void Function(_RenderCircuit render) onCreated;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  _RenderCircuit createRenderObject(BuildContext context) {
    final _RenderCircuit render = _RenderCircuit(
      staticPrimitives: staticPrimitives,
      kartMeshes: kartMeshes,
      camera: camera,
      transforms: transforms,
    )
      ..surface = surface
      ..forceCpu = forceCpu;
    onCreated(render);
    return render;
  }

  @override
  void updateRenderObject(BuildContext context, _RenderCircuit renderObject) {
    renderObject
      ..surface = surface
      ..forceCpu = forceCpu
      ..camera = camera
      ..transforms = transforms;
    onCreated(renderObject);
  }
}

/// Draws the whole world as **one** scene.
///
/// One, and not one per object, because `MeshSceneRenderer.drawScene` clears
/// the depth buffer for every scene it is handed - so a second scene in the
/// same frame draws over the first whatever the depth says, and a kart would
/// be visible through the barrier it is behind. See `geometry.dart` for the
/// consequence that has for how the karts are built.
final class _RenderCircuit extends RenderBox {
  _RenderCircuit({
    required List<MeshPrimitive> staticPrimitives,
    required List<KartMesh> kartMeshes,
    required MeshCamera camera,
    required List<KartTransform> transforms,
  })  : _staticPrimitives = staticPrimitives,
        _kartMeshes = kartMeshes,
        _camera = camera,
        _transforms = transforms;

  List<MeshPrimitive> _staticPrimitives;
  List<KartMesh> _kartMeshes;
  MeshCamera _camera;
  List<KartTransform> _transforms;

  MeshSceneSurface? surface;
  bool forceCpu = false;

  MeshRenderStats lastStats = MeshRenderStats.zero;
  String lastDrawPath = 'nada';
  String lastRendererName = 'selecionando';

  final MeshRasterizer _rasterizer = MeshRasterizer();
  Framebuffer? _target;

  /// The karts of the *previous* frame, still resident on the device.
  ///
  /// Handed back with `discardMesh` after this frame's draw is recorded, not
  /// before: `MeshSceneSurface.draw` only queues, and the window flushes at
  /// the end of the frame, so discarding this frame's primitives here would
  /// free the buffers before they were drawn. Discarding *last* frame's is
  /// safe and is what stops the resident set growing by a frame of geometry
  /// sixty times a second until the renderer's budget starts evicting the
  /// circuit.
  Mesh3D? _previousKarts;

  void rebuildWorld(
    List<MeshPrimitive> staticPrimitives,
    List<KartMesh> kartMeshes,
  ) {
    _staticPrimitives = staticPrimitives;
    _kartMeshes = kartMeshes;
    markNeedsPaint();
  }

  set camera(MeshCamera value) {
    _camera = value;
    markNeedsPaint();
  }

  set transforms(List<KartTransform> value) {
    _transforms = value;
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

    final List<MeshPrimitive> karts = <MeshPrimitive>[];
    for (int i = 0; i < _transforms.length && i < _kartMeshes.length; i++) {
      karts.addAll(placeKart(_kartMeshes[i], _transforms[i]));
    }
    final Mesh3D world = Mesh3D(
      name: 'kart_racer',
      format: 'procedural',
      primitives: <MeshPrimitive>[..._staticPrimitives, ...karts],
    );
    final MeshScene scene = MeshScene(
      mesh: world,
      camera: _camera,
      // The sky. The 3D pass owns the frame's clear - see
      // `mesh_scene_host.dart` - so this is the colour of everything above the
      // horizon, and it must not be null or the back buffer shows whatever the
      // last frame left in it.
      backgroundArgb: 0xFF6FA8D8,
      lightDirection: const Vector3(-0.35, -0.86, -0.36),
      ambient: 0.34,
    );

    final MeshSceneSurface? gpu = forceCpu ? null : surface;
    if (gpu != null) {
      final MeshRenderStats? stats = gpu.draw(
        scene,
        viewport: Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      );
      if (stats != null) lastStats = stats;
      lastDrawPath = 'GPU';
      lastRendererName = gpu.rendererName;
      final Mesh3D? previous = _previousKarts;
      if (previous != null) gpu.discardMesh(previous);
      _previousKarts = Mesh3D(
        name: 'kart_racer.karts',
        format: 'procedural',
        primitives: karts,
      );
      return;
    }

    Framebuffer? target = _target;
    if (target == null || target.width != width || target.height != height) {
      target = _target = Framebuffer.allocate(width: width, height: height);
    }
    _rasterizer.render(
      target,
      world,
      _camera,
      backgroundArgb: 0xFF6FA8D8,
      lightDirection: scene.lightDirection,
      ambient: scene.ambient,
    );
    lastStats = _rasterizer.stats;
    lastDrawPath = 'CPU';
    lastRendererName = 'cpu';
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

final class _GameTicker implements AnimationTicker {
  _GameTicker({required this.ticking, required this.onTick});

  final bool Function() ticking;
  final void Function(Duration timestamp) onTick;

  @override
  bool get isTicking => ticking();

  @override
  void tick(Duration timestamp) => onTick(timestamp);
}
