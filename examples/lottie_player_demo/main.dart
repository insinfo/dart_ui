/// A Lottie player that exists to be measured.
///
/// It plays `test/data/Cute Mascot Jumping Character` — as loose JSON or out of
/// its dotLottie ZIP — and reports, live, what each frame cost: frames per
/// second, the time spent building the display list, and how many paths, fills
/// and strokes went into it. The animation is a real one from LottieFiles
/// rather than a synthetic scene, which matters: a benchmark made of a thousand
/// identical rounded rectangles measures one code path, and real vector
/// animation is mostly cubic contours with per-frame morphs.
///
/// ## Why switching the renderer restarts the process
///
/// The honest answer, and it is a design decision of the framework rather than
/// a limitation of this demo: **`RenderPolicy` is read once, when the device
/// opens.** `GpuPathPlanner` says so in its own comment — a policy that could
/// change under a running frame would let two draws of the same shape in one
/// frame answer differently. `RenderingPolicy` is stronger still: CPU and GPU
/// are different devices and different swap chains.
///
/// So the buttons do not pretend. Each one relaunches this program with the
/// flags for the mode it names, which is what actually changes the answer, and
/// the interface says so. A button that silently did nothing would be worse
/// than no button.
///
/// ## Running it
///
/// ```
/// dart run examples/lottie_player_demo/main.dart              # interactive
/// dart run examples/lottie_player_demo/main.dart --frames 300 # measure, exit
/// dart run examples/lottie_player_demo/main.dart --bench      # every mode
/// ```
///
/// `--bench` runs each reachable mode as a **child process**, because that is
/// the only way to open a device under a different policy, and prints a table
/// in the shape of `doc/RELATORIO_POC_23_GPU_2D_STRATEGIES_INTEL_UHD.md` so the
/// two can be read side by side.
///
/// And measure the compiled program, not `dart run`: the front end spends about
/// six seconds compiling this package's import graph before `main` starts. See
/// `tool/startup_cost.dart`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ui/dart_ui.dart';
import 'package:dart_ui/src/graphics/lottie/lottie_model.dart';
import 'package:dart_ui/src/graphics/lottie/lottie_painter.dart';
import 'package:dart_ui/src/graphics/lottie/lottie_parser.dart';

const String _defaultJson = 'test/data/Cute Mascot Jumping Character.json';
const String _defaultDotLottie =
    'test/data/Cute Mascot Jumping Character.lottie';

/// One selectable rendering mode.
///
/// A mode is a *process configuration*, not a runtime switch — see the note at
/// the top of this file — so it is expressed as the arguments that produce it.
final class _Mode {
  const _Mode(this.id, this.label, this.arguments, this.detail);

  final String id;
  final String label;
  final List<String> arguments;
  final String detail;

  static const List<_Mode> all = <_Mode>[
    _Mode(
      'gpu',
      'GPU (padrão)',
      <String>['--gpu'],
      'a política medida: rota analítica para arredondados, atlas de cobertura '
          'para o resto',
    ),
    _Mode(
      'gpu-dense',
      'GPU só atlas',
      <String>['--gpu', '--strategy=coverageAtlas'],
      'faixas esparsas, tesselação, stencil e compute desligados: o piso '
          'contra o qual as outras rotas se comparam',
    ),
    _Mode(
      'gpu-large-paths',
      'GPU caminhos grandes',
      <String>['--gpu', '--strategy=largeAnimatedPaths'],
      'tesselação e stencil-then-cover habilitados, que é a rota B/C do '
          'relatório POC-23',
    ),
    _Mode(
      'cpu',
      'CPU',
      <String>['--cpu'],
      'o rasterizador de CPU, que é a resposta certa em três casos: sem GPU, '
          'fora da tela, ou o usuário da biblioteca pediu',
    ),
  ];
}

/// The `--strategy=` values, mapped to what they mean to the framework.
///
/// Only the combinations the policy can actually express are offered. There is
/// no per-strategy "use only this one" switch, and inventing one here would
/// mean building a policy the framework does not have: `GpuStrategySwitches` is
/// **subtractive** by construction, so a policy can turn a route off and has no
/// expression for turning one on. That is deliberate — it stops an application
/// asking a backend to execute something the backend never reported.
RenderPolicy _policyFor(String? strategy) {
  switch (strategy) {
    case 'coverageAtlas':
      return const RenderPolicy(strategies: GpuStrategySwitches.denseOnly);
    case 'largeAnimatedPaths':
      return const RenderPolicy(
          routes: GpuRouteAvailability.largeAnimatedPaths);
    case null:
    case '':
      return RenderPolicy.defaults;
    default:
      stderr.writeln('estratégia desconhecida "$strategy"; usando o padrão');
      return RenderPolicy.defaults;
  }
}

String? _valueOf(List<String> arguments, String name) {
  for (final String argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

int _intOf(List<String> arguments, String name, int fallback) {
  final String? raw = _valueOf(arguments, name);
  return raw == null ? fallback : int.tryParse(raw) ?? fallback;
}

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--bench')) {
    await _runBench(arguments);
    return;
  }

  final String path = _valueOf(arguments, '--file') ??
      (arguments.contains('--dotlottie') ? _defaultDotLottie : _defaultJson);
  final File file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('não encontrei $path');
    exitCode = 2;
    return;
  }

  final LottieAnimation animation;
  final Stopwatch parseWatch = Stopwatch()..start();
  try {
    animation = parseLottieBytes(Uint8List.fromList(file.readAsBytesSync()));
  } on LottieParseException catch (error) {
    stderr.writeln('$error');
    exitCode = 3;
    return;
  }
  parseWatch.stop();

  final int frameBudget = _intOf(arguments, '--frames', 0);
  final bool cpu = arguments.contains('--cpu');
  final RenderPolicy renderPolicy =
      _policyFor(_valueOf(arguments, '--strategy'));

  stdout.writeln(
    'lottie: ${animation.name.isEmpty ? path : animation.name} · '
    '${animation.width.toInt()}x${animation.height.toInt()} · '
    '${animation.frameRate.toStringAsFixed(0)} fps · '
    '${animation.durationInFrames.toStringAsFixed(0)} quadros · '
    'parse ${parseWatch.elapsedMilliseconds} ms'
    '${animation.unsupported.isEmpty ? '' : ' · não desenhado: '
        '${animation.unsupported.join(', ')}'}',
  );

  FrameworkFonts.install();

  // `Application.start` rather than `runApp`, for one reason: the handle. The
  // status bar names the presentation path that was actually chosen, and the
  // mode buttons have to be able to close the window. `runApp` hands the
  // application back only after teardown, which is too late for both.
  final LottieSession session = LottieSession();
  final ApplicationOptions options = ApplicationOptions.fromArguments(
    arguments,
    environment: Platform.environment,
    title: 'dart_ui Lottie Player',
    size: const Size(980, 720),
    minimumSize: const Size(640, 480),
    theme: ThemeData.neutralDark,
    clearColor: const Color(0xFF0A0E17),
    renderingPolicy: cpu ? RenderingPolicy.cpuOnly : RenderingPolicy.auto,
    // Through the options and not `RenderPolicyScope.install`: `start` installs
    // this one before any backend probes, and an install done here would be
    // overwritten by it a moment later.
    renderPolicy: renderPolicy,
    frameBudget: frameBudget,
    // A continuous animation is exactly the case the frame loop's continuous
    // mode was written for: nothing invalidates, the world simply moved.
    frameLoop: const FrameLoopOptions.continuous(),
    onError: (FrameworkError error) => stderr.writeln('$error'),
  );

  final Application application = await Application.start(
    rootWidget: LottiePlayerDemo(
      animation: animation,
      sourcePath: path,
      parseTime: parseWatch.elapsed,
      session: session,
    ),
    backends: PlatformBackendResolver.defaultBackends(options: options),
    presentations: PlatformBackendResolver.defaultPresentations(),
    options: options,
  );
  session.application = application;
  if (arguments.contains('--startup')) {
    stdout.write(application.describeStartup());
  }

  try {
    await application.run();
  } finally {
    if (arguments.contains('--report')) {
      stdout.writeln(
        'REPORT backend=${session.backendName} '
        'fps=${session.framesPerSecond.toStringAsFixed(1)} '
        'build_us=${session.buildMicroseconds.toStringAsFixed(0)} '
        'paths=${session.stats.pathsDrawn} '
        'fills=${session.stats.fills} '
        'strokes=${session.stats.strokes} '
        'layers=${session.stats.layersDrawn} '
        'presented=${application.framesPresented} '
        'routes=${renderPolicy.routes.name}',
      );
    }
    application.dispose();
    await application.closed;
  }
}

/// What the widget and `main` share.
///
/// A small mutable holder rather than a global, so that the two halves of this
/// program - the one that owns the window and the one that draws into it - can
/// exchange four numbers without either reaching into the other.
final class LottieSession {
  Application? application;
  LottiePaintStats stats = LottiePaintStats.zero;
  double buildMicroseconds = 0;
  double framesPerSecond = 0;

  /// The presentation path that was actually chosen, not the one requested.
  ///
  /// Worth the distinction in a demo about renderers: asking for the GPU and
  /// getting the CPU fallback is exactly the situation where a status bar
  /// showing the request would mislead.
  String get backendName =>
      application?.presentationSelection.chosen?.name ?? 'selecionando';
}

/// Runs every mode as a child process and prints the comparison.
///
/// Child processes and not a loop in this one, because a render policy is read
/// when a device opens and this process has already opened one. Measuring four
/// modes in four processes is slower to run and is the only way the numbers
/// mean what they say.
Future<void> _runBench(List<String> arguments) async {
  final int frames = _intOf(arguments, '--frames', 300);
  final String? only = _valueOf(arguments, '--mode');
  final String script = Platform.script.toFilePath();
  final bool compiled = !script.endsWith('.dart');

  stdout.writeln(
    'lottie bench · $frames quadros por modo · '
    '${compiled ? 'AOT' : 'JIT a partir do fonte, some ~6 s de partida por '
        'processo — veja tool/startup_cost.dart'}',
  );

  final List<List<String>> rows = <List<String>>[];
  for (final _Mode mode in _Mode.all) {
    if (only != null && only != mode.id) continue;
    final List<String> childArguments = <String>[
      if (!compiled) script,
      ...mode.arguments,
      '--frames=$frames',
      '--report',
    ];
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      compiled ? childArguments : <String>['run', ...childArguments],
      environment: Platform.environment,
    );
    final String output = '${result.stdout}';
    final String? line = output
        .split('\n')
        .map((String l) => l.trim())
        .where((String l) => l.startsWith('REPORT '))
        .lastOrNull;
    if (line == null) {
      stdout.writeln('  ${mode.label}: sem relatório');
      if ('${result.stderr}'.trim().isNotEmpty) {
        stdout.writeln('    ${'${result.stderr}'.trim().split('\n').first}');
      }
      continue;
    }
    final Map<String, String> fields = <String, String>{
      for (final String pair in line.substring('REPORT '.length).split(' '))
        if (pair.contains('=')) pair.split('=').first: pair.split('=').last,
    };
    rows.add(<String>[
      mode.label,
      fields['backend'] ?? '?',
      fields['fps'] ?? '?',
      fields['build_us'] ?? '?',
      fields['paths'] ?? '?',
    ]);
  }

  if (rows.isEmpty) {
    stdout.writeln('nenhum modo produziu números');
    exitCode = 1;
    return;
  }
  stdout
    ..writeln()
    ..writeln('| modo | backend | fps | display list (µs/quadro) | caminhos |')
    ..writeln('|---|---|---|---|---|');
  for (final List<String> row in rows) {
    stdout.writeln('| ${row.join(' | ')} |');
  }
}

/// The player.
final class LottiePlayerDemo extends StatefulWidget {
  const LottiePlayerDemo({
    required this.animation,
    required this.sourcePath,
    required this.parseTime,
    required this.session,
    super.key,
  });

  final LottieAnimation animation;
  final String sourcePath;
  final Duration parseTime;

  /// Where this widget publishes what it measured, so `main` can report it
  /// after the window closes.
  final LottieSession session;

  @override
  State<LottiePlayerDemo> createState() => _LottiePlayerDemoState();
}

final class _LottiePlayerDemoState extends State<LottiePlayerDemo> {
  late final LottiePainter _painter = LottiePainter(widget.animation);
  final Stopwatch _elapsed = Stopwatch()..start();
  final Stopwatch _rateWindow = Stopwatch()..start();

  AnimationClock? _clock;
  late final _PlaybackTicker _ticker = _PlaybackTicker(
    ticking: () => mounted,
    onTick: (_) => _onTick(),
  );
  bool _attached = false;
  bool _playing = true;

  /// The render object currently drawing the animation.
  ///
  /// Held so a tick can repaint it without rebuilding anything. Cleared by
  /// [_LottieView] when the element goes, so a ticker that outlives one frame
  /// of the tree cannot mark a detached object.
  _RenderLottie? _render;

  int _framesThisWindow = 0;
  double _fps = 0;

  /// Rolling mean of what building one display list costs, in microseconds.
  ///
  /// The number the demo exists for. Kept separately from the frame rate
  /// because a window at 60 Hz says nothing about headroom: a build of 400 µs
  /// and a build of 8000 µs both present sixty times a second, and only one of
  /// them has room for a second animation beside it.
  double _buildMicroseconds = 0;
  int _buildSamples = 0;

  @override
  void dispose() {
    if (_attached) _clock?.removeTicker(_ticker);
    super.dispose();
  }

  /// One tick of playback.
  ///
  /// It repaints and it does **not** rebuild, which is the difference between
  /// an animation and an exception. A ticker runs inside the frame, and a
  /// `setState` from in there dirties the build the frame is in the middle of
  /// settling; doing it on every tick means the settle loop never converges and
  /// the window dies with "the frame did not settle in 8 passes". Only the
  /// status line needs a rebuild, and only twice a second.
  void _onTick() {
    if (!mounted) return;
    _framesThisWindow++;
    _render?.markNeedsPaint();

    // Published every tick rather than only at the end: the frame budget stops
    // `Application.run` from the outside, so this widget never learns that the
    // last frame was the last one.
    widget.session
      ..stats = _painter.stats
      ..buildMicroseconds = _buildMicroseconds
      ..framesPerSecond = _fps;

    if (_rateWindow.elapsedMilliseconds < 500) return;
    _fps = _framesThisWindow * 1000 / _rateWindow.elapsedMilliseconds;
    _framesThisWindow = 0;
    _rateWindow.reset();
    widget.session.framesPerSecond = _fps;
    // Outside the frame, for the same reason the repaint above is not a
    // rebuild: `Timer.run` puts it on the next turn of the event loop, where
    // dirtying the tree is ordinary rather than re-entrant.
    Timer.run(() {
      if (mounted) setState(() {});
    });
  }

  String _backendName() => widget.session.backendName;

  void _restartIn(_Mode mode) {
    // See the file comment: this is the only thing that actually changes the
    // answer, so it is what the button does.
    final String script = Platform.script.toFilePath();
    final bool compiled = !script.endsWith('.dart');
    final List<String> arguments = <String>[
      if (!compiled) ...<String>['run', script],
      ...mode.arguments,
      '--file=${widget.sourcePath}',
    ];
    unawaited(
      Process.start(
        Platform.resolvedExecutable,
        arguments,
        mode: ProcessStartMode.detached,
      ).then((_) => widget.session.application?.requestClose()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AnimationClock? clock = AnimationScope.maybeOf(context);
    if (clock != null && !_attached) {
      _clock = clock;
      clock.addTicker(_ticker);
      _attached = true;
    }

    const Color page = Color(0xFF0A0E17);
    const Color panel = Color(0xFF121A28);
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
                          widget.animation.name.isEmpty
                              ? 'Lottie'
                              : widget.animation.name,
                          color: text,
                          fontSize: 15,
                        ),
                        Text(
                          '${widget.animation.width.toInt()}'
                          '×${widget.animation.height.toInt()} · '
                          '${widget.animation.frameRate.toStringAsFixed(0)} fps '
                          'autorais · parse '
                          '${widget.parseTime.inMilliseconds} ms',
                          color: muted,
                          fontSize: 11,
                        ),
                      ],
                    ),
                  ),
                  Button(
                    label: _playing ? 'PAUSAR' : 'TOCAR',
                    onPressed: () => setState(() {
                      _playing = !_playing;
                      if (_playing) {
                        _elapsed.start();
                      } else {
                        _elapsed.stop();
                      }
                    }),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: _LottieView(
                painter: _painter,
                frameOf: _frameNow,
                onBuilt: _noteBuild,
                onCreated: (_RenderLottie render) => _render = render,
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
                    'Trocar o modo reinicia o programa, e isso é de propósito: '
                    'a política de renderização é lida uma vez, quando o '
                    'dispositivo abre.',
                    color: muted,
                    fontSize: 11,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      for (final _Mode mode in _Mode.all) ...<Widget>[
                        Button(
                          label: mode.label,
                          onPressed: () => _restartIn(mode),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                  if (widget.animation.unsupported.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      'Não desenhado neste arquivo: '
                      '${widget.animation.unsupported.join(', ')}',
                      color: const Color(0xFFE0B341),
                      fontSize: 11,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The composition frame to draw right now.
  ///
  /// A callback and not a value passed down the tree: the frame changes sixty
  /// times a second and the tree does not, so passing it as a field would mean
  /// a rebuild per frame to deliver one double.
  double _frameNow() => widget.animation.frameAt(_elapsed.elapsed);

  void _noteBuild(int microseconds) {
    // A running mean rather than the last sample: one frame's build time on a
    // machine with a browser open swings by a factor of three, and a status bar
    // that flickers between 300 and 900 µs tells the reader nothing.
    _buildSamples++;
    _buildMicroseconds +=
        (microseconds - _buildMicroseconds) / _buildSamples.clamp(1, 120);
  }

  String _statusLine() {
    final LottiePaintStats stats = _painter.stats;
    return '${_backendName()} · ${_fps.toStringAsFixed(1)} fps · '
        'display list ${_buildMicroseconds.toStringAsFixed(0)} µs/quadro · '
        '${stats.layersDrawn} camadas · ${stats.pathsDrawn} caminhos · '
        '${stats.fills} preenchimentos · ${stats.strokes} contornos';
  }
}

/// Draws the animation and reports what building the commands cost.
final class _LottieView extends RenderObjectWidget {
  const _LottieView({
    required this.painter,
    required this.frameOf,
    required this.onBuilt,
    required this.onCreated,
  });

  final LottiePainter painter;
  final double Function() frameOf;
  final void Function(int microseconds) onBuilt;
  final void Function(_RenderLottie render) onCreated;

  @override
  RenderObjectElement createElement() => RenderObjectElement(this);

  @override
  _RenderLottie createRenderObject(BuildContext context) {
    final _RenderLottie render = _RenderLottie(
      painter: painter,
      frameOf: frameOf,
      onBuilt: onBuilt,
    );
    onCreated(render);
    return render;
  }

  @override
  void updateRenderObject(BuildContext context, _RenderLottie renderObject) {
    renderObject
      ..painter = painter
      ..frameOf = frameOf
      ..onBuilt = onBuilt;
    onCreated(renderObject);
  }
}

final class _RenderLottie extends RenderBox {
  _RenderLottie({
    required LottiePainter painter,
    required this.frameOf,
    required this.onBuilt,
  }) : _painter = painter;

  LottiePainter _painter;

  /// Asked at paint time rather than pushed in: see [_LottiePlayerDemoState].
  double Function() frameOf;
  void Function(int microseconds) onBuilt;

  final Stopwatch _watch = Stopwatch();

  set painter(LottiePainter value) {
    if (identical(value, _painter)) return;
    _painter = value;
    markNeedsPaint();
  }

  @override
  void performLayout() => size = constraints.biggest;

  @override
  void paint(DisplayList list, Offset offset) {
    if (size.isEmpty) return;
    _watch
      ..reset()
      ..start();
    _painter.paint(
      list,
      Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
      frameOf(),
    );
    _watch.stop();
    onBuilt(_watch.elapsedMicroseconds);
  }
}

/// A ticker that runs while [ticking] answers true.
final class _PlaybackTicker implements AnimationTicker {
  _PlaybackTicker({required this.ticking, required this.onTick});

  final bool Function() ticking;
  final void Function(Duration timestamp) onTick;

  @override
  bool get isTicking => ticking();

  @override
  void tick(Duration timestamp) => onTick(timestamp);
}
