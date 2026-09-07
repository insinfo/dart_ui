/// Um jogo de plataforma lateral, em Dart puro, desenhado em 3D pela GPU.
///
/// Corra, pule, role, esmague os inimigos, pegue os anéis e chegue à bandeira.
///
/// ```powershell
/// dart run .\examples\side_scroller_game\main.dart
/// dart run .\examples\side_scroller_game\main.dart --frames=600 --demo --report
/// dart run .\examples\side_scroller_game\main.dart --script
/// ```
///
/// Setas ou A/D correm, espaço, W ou seta para cima pulam — segure para pular
/// mais alto. ESC pausa, R recomeça.
///
/// ## The three seams this file is, and nothing else
///
/// The simulation is in `game/world.dart` and knows nothing about a window.
/// The triangles are in `game/scene.dart` and know nothing about a keyboard.
/// What is left here is the wiring, and it is only three things:
///
///   1. **A clock becomes fixed steps.** `FrameLoopOptions.continuous` makes
///      the loop produce frames because time passed; the animation clock hands
///      a monotonic timestamp to [_GameTicker]; the difference between two of
///      those goes into [GameWorld.advanceWith], which runs whole 10 ms steps
///      and leaves a remainder the renderer interpolates by. The simulation
///      therefore runs at the same rate on a 60 Hz laptop and a 144 Hz desktop,
///      which is the bug `FixedStepAccumulator` exists to prevent.
///
///      **That timestamp is the dispatcher's virtual time and not the wall
///      clock**, and `frame_scheduler.dart` says so in as many words. It is
///      worth knowing what that means for a game, because it is not obvious and
///      it is measurable: virtual time advances by at most one frame interval
///      per frame, so a frame that took four times its budget advances the
///      world by *one* interval rather than four. Forced onto the CPU
///      rasteriser with `--cpu`, this game ran 400 frames in 25.4 s of wall
///      time and simulated 6.65 s of game time — a quarter speed, with the
///      accumulator dropping nothing at all. That is a good trade and not a
///      bug: a game that slows down under load is playable and deterministic,
///      and one that skips a tenth of a second of simulation to keep up is
///      neither. It does mean the accumulator's own catch-up path is exercised
///      by the tests and not by the window.
///   2. **Keys become a [GameInput].** Held state, tracked here, because
///      nothing in this framework keeps a set of pressed keys — see
///      [_SideScrollerGameState._held] and the stuck-key guard beside it.
///   3. **A frame becomes a repaint, almost never a rebuild.** A ticker runs
///      *inside* the frame, so a `setState` from one dirties the build the
///      frame is settling and the window dies with "the frame did not settle in
///      8 passes". The picture is repainted with [RenderBox.markNeedsPaint] and
///      the HUD is rebuilt only when a number on it actually changed, from a
///      [Timer.run] outside the frame. That trap has been paid for three times
///      in this repository; see [_SideScrollerGameState._onTick].
///
/// ## Nothing opaque over the viewport
///
/// On the GPU path the scene is drawn into the back buffer *before* the display
/// list, so a full-window `ColoredBox` behind the HUD produces a black window
/// with a working interface — which reads as "the model failed to load" and is
/// not. The HUD here is a [Stack] of small panels over the game view and never
/// covers it.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/graphics/mesh/mesh3d.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_rasterizer.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene.dart';
import 'package:dart_ui/src/rendering/mesh/mesh_scene_host.dart';
import 'package:dart_ui/src/widgets/mesh_scene_scope.dart';

import 'game/actors.dart';
import 'game/autopilot.dart';
import 'game/follow_camera.dart';
import 'game/level.dart';
import 'game/motion_state.dart';
import 'game/scene.dart';
import 'game/world.dart';

/// Virtual key codes, in the form `focus.dart` publishes the ones it names.
const int _keyA = 0x41;
const int _keyD = 0x44;
const int _keyW = 0x57;
const int _keyR = 0x52;
const int _keyP = 0x50;

/// The value of `--name=value`, or of `--name value`.
String? _valueOf(List<String> arguments, String name) {
  for (var i = 0; i < arguments.length; i++) {
    final String argument = arguments[i];
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
    if (argument == name && i + 1 < arguments.length) return arguments[i + 1];
  }
  return null;
}

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--script')) {
    _runScript(int.tryParse(_valueOf(arguments, '--steps') ?? '') ?? 6000);
    return;
  }

  final int frameBudget =
      int.tryParse(_valueOf(arguments, '--frames') ?? '') ?? 0;

  FrameworkFonts.install();
  final GameSession session = GameSession(demo: arguments.contains('--demo'));
  final ApplicationOptions options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'dart_ui · Corrida do Lobo',
    size: const Size(1120, 700),
    minimumSize: const Size(760, 480),
    theme: ThemeData.neutralDark,
    clearColor: const Color(Palette.sky),
    frameBudget: frameBudget,
    // A game is the other shape of loop this framework supports: a frame is
    // produced because time passed, not because something asked. Without this
    // the window draws once and then sleeps in the message pump, and the
    // character stands still while the keyboard does nothing — which looks
    // exactly like the input being broken.
    frameLoop: const FrameLoopOptions.continuous(),
    onError: (FrameworkError failure) => stderr.writeln('$failure'),
  );

  final Application application = await Application.start(
    rootWidget: SideScrollerGame(session: session),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  session.application = application;

  try {
    await application.run();
  } finally {
    if (arguments.contains('--report')) {
      final SceneStats scene = session.sceneStats;
      stdout.writeln(
        'REPORT path=${session.drawPath} '
        'renderer=${session.rendererName} '
        'presenter=${session.presenterName} '
        'triangles=${session.triangles} '
        'dyn_vertices=${scene.dynamicVertices} '
        'dyn_triangles=${scene.dynamicTriangles} '
        'primitives=${scene.primitives} '
        'scene_build_us=${scene.buildMicroseconds} '
        'raster_us=${session.meshStats.microseconds} '
        'frame_ms=${session.frameMilliseconds.toStringAsFixed(2)} '
        'fps=${session.framesPerSecond.toStringAsFixed(1)} '
        'presented=${application.framesPresented} '
        'steps=${session.steps} dropped_ms=${session.droppedMilliseconds} '
        '| ${session.finalState}',
      );
    }
    application.dispose();
    await application.closed;
  }
}

/// Plays the whole level with no window at all and prints where it ended.
///
/// The regression this exists for is not "does it crash": it is "is the level
/// still completable". A change to gravity, to the jump's cut speed, to the
/// collision's epsilon or to the width of one gap can all leave a game that
/// runs perfectly and cannot be finished, and none of them is visible in a
/// screenshot. See `game/autopilot.dart`.
void _runScript(int maxSteps) {
  final Level level = buildDemoLevel();
  final GameWorld world = GameWorld(level: level);
  final Stopwatch watch = Stopwatch()..start();
  final int steps = runAutopilot(world, maxSteps: maxSteps);
  watch.stop();
  stdout
    ..writeln('level: ${level.name}')
    ..writeln('steps: $steps de $maxSteps '
        '(${(steps * world.stepSeconds).toStringAsFixed(2)} s simulados '
        'em ${watch.elapsedMilliseconds} ms)')
    ..writeln(world.describe());
  if (world.outcome != GameOutcome.finished) {
    stderr.writeln('o piloto automático não chegou ao fim');
    exitCode = 1;
  }
}

/// What `main` and the widget share, so the report can be written after the
/// window has gone.
final class GameSession {
  GameSession({this.demo = false});

  /// Whether the autopilot is driving instead of the keyboard.
  final bool demo;

  Application? application;

  /// Set by the render object, never asserted from outside: reading
  /// "direct3d11" beside a 3D picture and concluding the GPU drew the triangles
  /// is exactly the wrong conclusion on the CPU path.
  String drawPath = 'nada';
  String rendererName = '-';

  MeshRenderStats meshStats = MeshRenderStats.zero;
  SceneStats sceneStats = SceneStats.zero;
  int triangles = 0;

  double framesPerSecond = 0;
  double frameMilliseconds = 0;
  int steps = 0;
  int droppedMilliseconds = 0;
  String finalState = '';

  /// The camera the game is driving, for a test that asks where it ended up
  /// after real key events rather than asking the controller directly.
  FollowCamera? camera;

  /// The world being played, for the same reason.
  GameWorld? world;

  String get presenterName =>
      application?.presentationSelection.chosen?.name ?? 'selecionando';
}

final class SideScrollerGame extends StatefulWidget {
  const SideScrollerGame({required this.session, super.key});

  final GameSession session;

  @override
  State<SideScrollerGame> createState() => _SideScrollerGameState();
}

final class _SideScrollerGameState extends State<SideScrollerGame>
    implements KeyboardEventTarget {
  late Level _level = buildDemoLevel();
  late GameWorld _world = GameWorld(level: _level);
  late GameSceneBuilder _scene = GameSceneBuilder(_level);
  late FollowCamera _camera = _newCamera();
  Autopilot? _autopilot;

  /// The keys currently down.
  ///
  /// Tracked here because nothing in this framework keeps a set of pressed
  /// keys — only the modifiers — and a platformer is *entirely* about held
  /// input: the difference between a tap and a hold on the jump button is the
  /// difference between a hop and clearing the gap.
  final Set<int> _held = <int>{};

  bool _paused = false;
  MeshShading _shading = MeshShading.smooth;

  late final FocusNode _focusNode =
      FocusNode(debugLabel: 'SideScrollerGame', target: this)
        ..addListener(_focusChanged);

  AnimationClock? _clock;
  bool _attachedToClock = false;
  late final _GameTicker _ticker = _GameTicker(
    ticking: () => mounted,
    onTick: _onTick,
  );

  _RenderGame? _render;
  Duration? _lastTimestamp;

  final Stopwatch _rateWindow = Stopwatch()..start();
  int _framesThisWindow = 0;

  /// The HUD's last built values, so a rebuild happens when one of them changed
  /// and not once per frame. See [_onTick].
  _Hud _hud = const _Hud.empty();

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void dispose() {
    if (_attachedToClock) _clock?.removeTicker(_ticker);
    _focusNode.dispose();
    super.dispose();
  }

  FollowCamera _newCamera() => FollowCamera(
        // Wider across than up, and the vertical zone is the larger of the
        // two: a jump is a big, brief vertical excursion the camera should
        // ignore entirely, and a vertical dead zone the size of the horizontal
        // one turns every hop into a camera move.
        horizontalDeadZone: 2.1,
        verticalDeadZone: 2.9,
        lead: 3.2,
      );

  void _restart() {
    _level = buildDemoLevel();
    _world = GameWorld(level: _level);
    _scene = GameSceneBuilder(_level);
    _camera = _newCamera();
    _autopilot = widget.session.demo ? Autopilot(_level) : null;
    _scene.snap(_camera, _world, aspect: _aspect);
    _held.clear();
    _paused = false;
    widget.session
      ..world = _world
      ..camera = _camera;
    _render
      ?..scene = _scene
      ..markNeedsPaint();
  }

  /// The viewport's aspect ratio, or a sane guess before the first layout.
  ///
  /// A guess and not zero, because the camera's clamp divides by it: at zero
  /// the level's ends would clamp to infinity and the first frame would show
  /// nothing at all.
  double get _aspect {
    final _RenderGame? render = _render;
    if (render == null || !render.hasSize || render.size.height <= 0) {
      return 1120 / 700;
    }
    return render.size.width / render.size.height;
  }

  GameInput get _input {
    final Autopilot? autopilot = _autopilot;
    if (autopilot != null) return autopilot.decide(_world);
    return GameInput(
      left: _held.contains(logicalKeyArrowLeft) || _held.contains(_keyA),
      right: _held.contains(logicalKeyArrowRight) || _held.contains(_keyD),
      jump: _held.contains(logicalKeySpace) ||
          _held.contains(logicalKeyArrowUp) ||
          _held.contains(_keyW),
    );
  }

  /// One frame: advance the world, move the camera, repaint.
  ///
  /// **No `setState` on the ordinary path.** A ticker runs inside the frame the
  /// loop is settling, so dirtying the build here means the frame never
  /// converges and the window dies with "the frame did not settle in 8 passes".
  /// The picture is a repaint; the HUD is rebuilt only when one of its numbers
  /// changed, and then from a [Timer.run] that lands *after* this frame.
  void _onTick(Duration timestamp) {
    if (!mounted) return;
    final Duration last = _lastTimestamp ?? timestamp;
    _lastTimestamp = timestamp;
    // Clamped, because the first tick after a load, a resize or a debugger
    // breakpoint carries a delta of seconds. The accumulator would drop most of
    // it and report the drop, but the steps it did run would teleport the
    // character through a floor first.
    Duration delta = timestamp - last;
    if (delta.isNegative) delta = Duration.zero;
    if (delta > const Duration(milliseconds: 100)) {
      delta = const Duration(milliseconds: 100);
    }

    if (!_paused) {
      // Per step and not per frame. The autopilot decides from the world it is
      // handed, so handing it one decision for a frame that runs two steps
      // makes the second step act on a plan for a position the character has
      // already left; `GameWorld.advanceWith` names the run that failed.
      _world.advanceWith(delta, () => _input);
      _scene.follow(
        _camera,
        _world,
        dt: delta.inMicroseconds / 1e6,
        aspect: _aspect,
      );
    }
    _render?.markNeedsPaint();

    _framesThisWindow++;
    final GameSession session = widget.session;
    session
      ..sceneStats = _scene.stats
      ..steps = _world.accumulator.stepsTaken
      ..droppedMilliseconds = _world.accumulator.dropped.inMilliseconds
      ..finalState = _world.describe();
    final _RenderGame? render = _render;
    if (render != null) {
      session
        ..drawPath = render.lastDrawPath
        ..rendererName = render.lastRendererName
        ..meshStats = render.lastStats
        ..triangles = render.lastTriangles;
    }

    if (_rateWindow.elapsedMilliseconds >= 500) {
      session
        ..framesPerSecond =
            _framesThisWindow * 1000 / _rateWindow.elapsedMilliseconds
        ..frameMilliseconds =
            _rateWindow.elapsedMilliseconds / _framesThisWindow;
      _framesThisWindow = 0;
      _rateWindow.reset();
    }

    final _Hud wanted = _Hud.of(_world, _paused, session);
    if (wanted != _hud) {
      // Outside the frame. `Timer.run` is the seam: this callback is inside the
      // pipeline's flush, and the rebuild it asks for happens on the next turn
      // of the loop, where dirtying the tree is legal.
      Timer.run(() {
        if (!mounted) return;
        setState(() => _hud = wanted);
      });
    }
  }

  void _focusChanged(FocusNode node) {
    // A key held when the window loses focus never sends its up event, so the
    // character runs away by itself the moment focus comes back. Every game
    // that has ever been alt-tabbed away from has this line.
    if (!node.hasPrimaryFocus) _held.clear();
  }

  @override
  bool handleKeyEvent(KeyEvent event) {
    if (event is KeyUpEvent) return _held.remove(event.logicalKey);
    if (event is! KeyDownEvent) return false;

    switch (event.logicalKey) {
      case _keyR:
        setState(_restart);
        return true;
      case logicalKeyEscape:
      case _keyP:
        setState(() => _paused = !_paused);
        return true;
      case logicalKeyEnter:
        // Enter restarts once the run is over, which is what a player presses
        // when a screen says "acabou".
        if (_world.outcome != GameOutcome.playing) {
          setState(_restart);
          return true;
        }
      case _keyD:
      case _keyA:
      case _keyW:
      case logicalKeyArrowLeft:
      case logicalKeyArrowRight:
      case logicalKeyArrowUp:
      case logicalKeySpace:
        _held.add(event.logicalKey);
        return true;
    }
    return false;
  }

  void _cycleShading() {
    const List<MeshShading> order = <MeshShading>[
      MeshShading.smooth,
      MeshShading.flat,
      MeshShading.wireframe,
    ];
    setState(() {
      _shading = order[(order.indexOf(_shading) + 1) % order.length];
      _render?.shading = _shading;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AnimationClock? clock = AnimationScope.maybeOf(context);
    if (clock != null && !_attachedToClock) {
      _clock = clock;
      clock.addTicker(_ticker);
      _attachedToClock = true;
    }

    // No background over the whole window, and that is the rule rather than a
    // detail of this game: on the GPU path the scene is drawn into the back
    // buffer *before* the display list, so anything opaque painted over the
    // viewport erases it. Every panel below is small and pinned to a corner.
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: FocusAttachment(
            node: _focusNode,
            autofocus: true,
            child: PointerListener(
              // Clicking the picture takes the keyboard back. Without it a
              // player who clicked a button once can never steer again, and the
              // symptom is "the arrow keys stopped working".
              onPointerDown: (_) =>
                  _focusNode.requestFocus(FocusChangeReason.pointer),
              child: _GameView(
                scene: _scene,
                world: _world,
                camera: _camera,
                shading: _shading,
                // Resolved here and not in the render object: an inherited
                // widget is looked up from a `BuildContext`, and a render
                // object has none.
                surface: MeshSceneScope.maybeOf(context),
                onCreated: (_RenderGame render) => _render = render,
              ),
            ),
          ),
        ),
        Positioned(left: 16, top: 14, child: _ScorePanel(hud: _hud)),
        Positioned(
          right: 16,
          top: 14,
          child: _StatusPanel(hud: _hud, shading: _shading),
        ),
        Positioned(
          left: 16,
          bottom: 14,
          child:
              _HintPanel(onShading: _cycleShading, demo: widget.session.demo),
        ),
        if (_hud.outcome != GameOutcome.playing || _hud.paused)
          Positioned.fill(child: Align(child: _Banner(hud: _hud))),
      ],
    );
  }
}

/// Everything the HUD shows, as a value, so a rebuild can be skipped when
/// nothing on it moved.
///
/// A record of the *displayed* numbers and not of the world: the player's
/// position changes every frame and is not on the HUD, so comparing worlds
/// would rebuild the interface a hundred times a second to draw the same
/// pixels. See `_SideScrollerGameState._onTick`.
final class _Hud {
  const _Hud({
    required this.score,
    required this.rings,
    required this.ringTotal,
    required this.lives,
    required this.stomps,
    required this.outcome,
    required this.state,
    required this.paused,
    required this.fps,
    required this.frameMs,
    required this.drawPath,
    required this.progress,
  });

  const _Hud.empty()
      : score = -1,
        rings = 0,
        ringTotal = 0,
        lives = 0,
        stomps = 0,
        outcome = GameOutcome.playing,
        state = MotionState.idle,
        paused = false,
        fps = 0,
        frameMs = 0,
        drawPath = '',
        progress = 0;

  factory _Hud.of(GameWorld world, bool paused, GameSession session) => _Hud(
        score: world.score,
        rings: world.ringsCollected,
        ringTotal: world.rings.length,
        lives: world.lives,
        stomps: world.enemiesDefeated,
        outcome: world.outcome,
        state: world.player.motion.state,
        paused: paused,
        // Rounded before it is compared, so a frame rate wandering by a
        // hundredth does not rebuild the tree.
        fps: session.framesPerSecond.round(),
        frameMs: (session.frameMilliseconds * 10).round() / 10,
        drawPath: session.drawPath,
        progress: (((world.player.x - world.level.spawnX) /
                    (world.level.finishX - world.level.spawnX)) *
                100)
            .clamp(0, 100)
            .round(),
      );

  final int score;
  final int rings;
  final int ringTotal;
  final int lives;
  final int stomps;
  final GameOutcome outcome;
  final MotionState state;
  final bool paused;
  final int fps;
  final double frameMs;
  final String drawPath;
  final int progress;

  @override
  bool operator ==(Object other) =>
      other is _Hud &&
      other.score == score &&
      other.rings == rings &&
      other.ringTotal == ringTotal &&
      other.lives == lives &&
      other.stomps == stomps &&
      other.outcome == outcome &&
      other.state == state &&
      other.paused == paused &&
      other.fps == fps &&
      other.frameMs == frameMs &&
      other.drawPath == drawPath &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(score, rings, lives, stomps, outcome, state,
      paused, fps, frameMs, drawPath, progress);
}

Widget _panel({required Widget child}) => ColoredBox(
      color: const Color(Palette.hudPanel),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: child,
      ),
    );

final class _ScorePanel extends StatelessWidget {
  const _ScorePanel({required this.hud});

  final _Hud hud;

  @override
  Widget build(BuildContext context) => _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'ANÉIS ${hud.rings}/${hud.ringTotal}',
              color: const Color(Palette.ring),
              fontSize: 17,
            ),
            Text(
              'PONTOS ${hud.score}',
              color: const Color(Palette.hudText),
              fontSize: 13,
            ),
            Text(
              'VIDAS ${hud.lives}   INIMIGOS ${hud.stomps}',
              color: hud.lives <= 1
                  ? const Color(Palette.hudWarning)
                  : const Color(Palette.hudMuted),
              fontSize: 12,
            ),
          ],
        ),
      );
}

final class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.hud, required this.shading});

  final _Hud hud;
  final MeshShading shading;

  @override
  Widget build(BuildContext context) => _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              'PERCURSO ${hud.progress}%',
              color: const Color(Palette.hudText),
              fontSize: 13,
            ),
            Text(
              '${hud.fps} fps · ${hud.frameMs.toStringAsFixed(1)} ms',
              color: const Color(Palette.hudMuted),
              fontSize: 12,
            ),
            Text(
              '${hud.drawPath} · ${shading.name} · ${hud.state.name}',
              color: const Color(Palette.hudMuted),
              fontSize: 11,
            ),
          ],
        ),
      );
}

final class _HintPanel extends StatelessWidget {
  const _HintPanel({required this.onShading, required this.demo});

  final void Function() onShading;
  final bool demo;

  @override
  Widget build(BuildContext context) => _panel(
        child: Row(
          children: <Widget>[
            Text(
              demo
                  ? 'demonstração automática · ESC pausa · R recomeça'
                  : 'A/D ou setas correm · espaço pula (segure para pular '
                      'mais alto) · ESC pausa · R recomeça',
              color: const Color(Palette.hudMuted),
              fontSize: 12,
            ),
            const SizedBox(width: 14),
            Button(label: 'SOMBREADO', onPressed: onShading),
          ],
        ),
      );
}

final class _Banner extends StatelessWidget {
  const _Banner({required this.hud});

  final _Hud hud;

  @override
  Widget build(BuildContext context) {
    final (String title, String detail, int colour) = switch (hud) {
      _Hud(outcome: GameOutcome.finished) => (
          'VOCÊ CONSEGUIU',
          '${hud.score} pontos · ${hud.rings} de ${hud.ringTotal} anéis · '
              '${hud.stomps} inimigos\nENTER ou R para correr de novo',
          Palette.goalFlag,
        ),
      _Hud(outcome: GameOutcome.gameOver) => (
          'ACABOU',
          '${hud.score} pontos · ${hud.rings} de ${hud.ringTotal} anéis\n'
              'ENTER ou R para tentar de novo',
          Palette.hudWarning,
        ),
      _ => (
          'PAUSADO',
          'ESC para continuar · R para recomeçar',
          Palette.hudText
        ),
    };
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Text(title, color: Color(colour), fontSize: 30),
          const SizedBox(height: 8),
          Text(
            detail,
            color: const Color(Palette.hudText),
            fontSize: 14,
            softWrap: true,
          ),
        ],
      ),
    );
  }
}

/// Draws the game.
final class _GameView extends RenderObjectWidget {
  const _GameView({
    required this.scene,
    required this.world,
    required this.camera,
    required this.shading,
    required this.surface,
    required this.onCreated,
  });

  final GameSceneBuilder scene;
  final GameWorld world;
  final FollowCamera camera;
  final MeshShading shading;
  final MeshSceneSurface? surface;
  final void Function(_RenderGame render) onCreated;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  _RenderGame createRenderObject(BuildContext context) {
    final _RenderGame render = _RenderGame(
      scene: scene,
      world: world,
      camera: camera,
      shading: shading,
    )..surface = surface;
    onCreated(render);
    return render;
  }

  @override
  void updateRenderObject(BuildContext context, _RenderGame renderObject) {
    renderObject
      ..scene = scene
      ..world = world
      ..camera = camera
      ..shading = shading
      ..surface = surface;
    onCreated(renderObject);
  }
}

final class _RenderGame extends RenderBox {
  _RenderGame({
    required this.scene,
    required this.world,
    required this.camera,
    required MeshShading shading,
  }) : _shading = shading;

  GameSceneBuilder scene;
  GameWorld world;
  FollowCamera camera;
  MeshShading _shading;

  /// The window's 3D surface, or null when nothing here draws 3D.
  ///
  /// Resolved per build through the inherited scope and assigned rather than
  /// captured: a resize and a device-loss recovery both replace the render
  /// target under it.
  MeshSceneSurface? surface;

  final MeshRasterizer _rasterizer = MeshRasterizer();
  Framebuffer? _target;

  MeshRenderStats lastStats = MeshRenderStats.zero;
  String lastDrawPath = 'nada';
  String lastRendererName = '-';
  int lastTriangles = 0;

  /// Last frame's moving primitives, handed back to the GPU so their buffers
  /// are released. See [GameSceneBuilder.retiredDynamics] for the leak this
  /// closes.
  Mesh3D? _retired;

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

    final MeshScene built = scene.build(
      world,
      camera,
      aspect: size.width / size.height,
      shading: _shading,
    );
    lastTriangles = built.mesh.triangleCount;

    final MeshSceneSurface? gpu = surface;
    if (gpu != null) {
      final MeshRenderStats? stats = gpu.draw(
        built,
        viewport: Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      );
      // The buffers for the frame *before* last, released now rather than at
      // build time: the renderer is still reading last frame's until this draw
      // has been recorded, and a discard between the build and the draw would
      // free geometry that is about to be used.
      final Mesh3D? retired = _retired;
      if (retired != null) gpu.discardMesh(retired);
      _retired = scene.retiredDynamics;

      // Null before the first flush completes, which is one frame. Keeping the
      // previous statistics rather than zeroing them stops the status panel
      // flickering to zero on the frame the game restarts.
      if (stats != null) lastStats = stats;
      lastDrawPath = 'GPU desenha';
      lastRendererName = gpu.rendererName;
      return;
    }

    // Reallocated only when the window changes size. A framebuffer per frame
    // for a 1120x700 view is 3.1 MB of garbage sixty times a second, which the
    // collector notices even when nothing else in the program does.
    Framebuffer? target = _target;
    if (target == null || target.width != width || target.height != height) {
      target = _target = Framebuffer.allocate(width: width, height: height);
    }
    _rasterizer.render(
      target,
      built.mesh,
      built.camera,
      shading: _shading,
      backgroundArgb: built.backgroundArgb ?? Palette.sky,
      lightDirection: built.lightDirection,
      ambient: built.ambient,
    );
    lastStats = _rasterizer.stats;
    lastDrawPath = 'CPU rasteriza';
    lastRendererName = 'mesh_rasterizer';

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
