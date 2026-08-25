/// A video player whose picture follows an audio master clock.
///
/// ## Why the loop is a ticker and not `Future.delayed`
///
/// `Application.run` waits for native messages synchronously. A Dart timer
/// cannot interrupt that wait, so a playback loop built out of
/// `Future.delayed` only gets a turn when the operating system happens to
/// deliver a message - which is why the previous version of this example ran
/// at four frames a second until the mouse moved. The application loop *does*
/// cap the wait to one frame interval while a window has an animation frame
/// armed, and the only thing that arms one is a ticker registered on the
/// [AnimationClock]. So playback is driven from [AnimationTicker.tick]: while
/// the ticker answers `isTicking`, the clock keeps asking for frames, the loop
/// keeps waking at the frame interval, and an idle mouse changes nothing.
///
/// ## Why the clock is the audio device
///
/// A `Stopwatch` counts the host's idea of a second and the sound card counts
/// its own; scheduling picture against the first drifts audibly out of lip
/// sync within minutes. [PcmAudioPlayers.openFile] hands back a player whose
/// `position` is what the endpoint has actually consumed, and that is the
/// reference every presentation decision is made against. A file with no audio
/// track - or any platform without an output device - gets [_WallMasterClock]
/// instead, so the rest of the state machine has exactly one shape.
///
/// ## Why decoding never happens inside a tick
///
/// A tick runs inside the frame; awaiting a decode there would stall the frame
/// it is part of. Decoding therefore runs ahead of presentation: one frame is
/// kept decoded and waiting, the tick only chooses between showing it,
/// throwing it away and leaving it where it is, and a new decode is kicked off
/// without being awaited. One frame of lookahead is the ceiling rather than an
/// arbitrary choice: the decoders hand out leases into a ring of three or four
/// slots, so at most `slotCount - 1` frames - the one on screen plus the one
/// waiting - may be retained before the ring wraps over storage still in use.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_ui/audio.dart';
import 'package:dart_ui/dart_ui.dart';

/// Whether the playback loop prints one statistics line per second.
///
/// Enabled with `--stats`. A windowed run has nowhere to show a number to
/// someone measuring it from outside the process, and the whole point of this
/// example is a frame rate that can be checked without touching the machine.
bool _logStatistics = false;

/// Whether a file opened on the command line starts playing by itself.
///
/// Enabled with `--autoplay`. This exists for the measurement above: proving
/// that playback no longer depends on mouse traffic means starting it without
/// a click.
bool _autoPlay = false;

/// Where framework errors go, so that a broken frame is a line of text rather
/// than a window that silently disappears.
final _FrameworkErrorLog _frameworkErrors = _FrameworkErrorLog();

Future<void> main(List<String> arguments) async {
  final String? initialPath = arguments
      .where((String value) => !value.startsWith('--'))
      .where((String value) => File(value).existsSync())
      .firstOrNull;
  if (arguments.contains('--smoke-test')) {
    if (initialPath == null) {
      throw ArgumentError('pass a video path with --smoke-test');
    }
    final VideoDecoder decoder = await VideoDecoders.openFile(
      initialPath,
      options: VideoDecoderOptions(
        enableFfmpegFallback: !arguments.contains('--native-only'),
      ),
    );
    try {
      var decoded = 0;
      while (decoded < 3 && await decoder.readFrame() != null) {
        decoded++;
      }
      await decoder.seek(Duration.zero);
      final VideoSample? replay = await decoder.readFrame();
      stdout.writeln(
        'video smoke: $decoded frame(s), ${decoder.info.width}x'
        '${decoder.info.height}, ${decoder.info.codec}, '
        '${decoder.info.backend}',
      );
      if (decoded == 0) throw StateError('the video has no decodable frames');
      if (replay == null || replay.frame.sequence != 0) {
        throw StateError('seek did not restart the native video stream');
      }
    } finally {
      await decoder.close();
    }
    return;
  }
  _logStatistics = arguments.contains('--stats');
  _autoPlay = arguments.contains('--autoplay');
  FrameworkFonts.install();
  FontRegistry.warmSystemFonts();
  await runApp(
    VideoPlayerDemo(initialPath: initialPath),
    options: ApplicationOptions.fromArguments(
      arguments,
      environment: Platform.environment,
      title: 'dart_ui Video Player',
      size: const Size(1100, 760),
      minimumSize: const Size(720, 520),
      theme: ThemeData.neutralDark,
      clearColor: const Color(0xFF050910),
      // Without this an error escaping build, layout or paint closes the
      // window with nothing written anywhere. The framework already contains
      // the failure; the only thing missing was somebody listening.
      onError: _frameworkErrors.report,
    ),
  );
}

/// Collects framework errors for the status bar and for stderr.
final class _FrameworkErrorLog {
  String? message;
  int count = 0;

  /// Called after every report so the UI can show the newest one.
  void Function()? onReport;

  void report(FrameworkError error) {
    count++;
    message = 'FrameworkError (${error.phase.name}): ${error.cause} '
        '· ${error.location}';
    stderr.writeln(error.describe());
    onReport?.call();
  }
}

/// The transport the player drives, whichever time source is behind it.
///
/// [MediaClock] alone would be enough to *read* the position, but the player
/// also has to start, stop and reposition whatever is producing it. Both
/// implementations answer the same six members, so the state machine below
/// never asks which one it is holding.
abstract interface class _MasterClock implements MediaClock {
  /// How this clock is described in the status bar: `áudio` or `parede`.
  String get label;

  void play();
  void pause();
  void seek(Duration to);
  Future<void> dispose();
}

/// The audio endpoint as the master clock. Position is what has been heard.
final class _AudioMasterClock implements _MasterClock {
  _AudioMasterClock(this._player);

  final PcmAudioPlayer _player;

  @override
  String get label => 'áudio';

  @override
  Duration get position => _player.position;

  @override
  bool get isRunning => _player.isRunning;

  @override
  void play() => _player.play();

  @override
  void pause() => _player.pause();

  @override
  void seek(Duration to) => _player.seek(to);

  @override
  Future<void> dispose() => _player.dispose();

  @override
  String toString() => 'áudio ${_player.sampleRate} Hz · '
      '${_player.channels} canais';
}

/// The fallback for a silent film: a stopwatch wearing the same interface.
///
/// This drifts against a sound card, which is the entire argument for
/// preferring [_AudioMasterClock] - but with no audio there is nothing to
/// drift against, and the picture only has to be paced.
final class _WallMasterClock implements _MasterClock {
  final Stopwatch _watch = Stopwatch();
  Duration _origin = Duration.zero;

  @override
  String get label => 'parede';

  @override
  Duration get position => _origin + _watch.elapsed;

  @override
  bool get isRunning => _watch.isRunning;

  @override
  void play() => _watch.start();

  @override
  void pause() => _watch.stop();

  @override
  void seek(Duration to) {
    _origin = to;
    // `reset` keeps a running stopwatch running, so a seek during playback
    // needs no restart and a seek while paused stays paused.
    _watch.reset();
  }

  @override
  Future<void> dispose() async => _watch.stop();

  @override
  String toString() => 'relógio de parede';
}

/// Adapts the state's tick to the [AnimationTicker] the clock registers.
final class _PlaybackTicker implements AnimationTicker {
  _PlaybackTicker({required this.onTick, required this.ticking});

  final void Function(Duration timestamp) onTick;
  final bool Function() ticking;

  @override
  void tick(Duration timestamp) => onTick(timestamp);

  @override
  bool get isTicking => ticking();
}

final class VideoPlayerDemo extends StatefulWidget {
  const VideoPlayerDemo({super.key, this.initialPath});

  final String? initialPath;

  @override
  State<VideoPlayerDemo> createState() => _VideoPlayerDemoState();
}

final class _VideoPlayerDemoState extends State<VideoPlayerDemo> {
  /// How much of a lead the decoder keeps over the screen.
  ///
  /// One, and not a number chosen for comfort: a decoder lease is a slot in a
  /// ring of three (GStreamer, AVFoundation) or four (Media Foundation), and
  /// the slot behind the cursor is overwritten without warning. The frame on
  /// screen is one retained lease; this is the other one.
  static const int _lookahead = 1;

  final AvSynchronizer _sync = AvSynchronizer();
  final Stopwatch _rateWindow = Stopwatch();

  late final _PlaybackTicker _ticker = _PlaybackTicker(
    onTick: _handleTick,
    ticking: () => _playing,
  );

  VideoDecoder? _decoder;
  _MasterClock? _clock;
  AnimationClock? _animationClock;

  /// The frame on screen, and the one decoded but not yet judged.
  VideoSample? _sample;
  VideoSample? _pending;

  String? _path;
  String? _error;
  bool _loading = false;
  bool _playing = false;
  bool _seeking = false;
  bool _decoding = false;
  bool _endOfStream = false;
  bool _tickerAttached = false;
  double? _pendingSeek;
  int _generation = 0;

  int _framesThisWindow = 0;
  double _presentedPerSecond = 0;

  @override
  void initState() {
    super.initState();
    _frameworkErrors.onReport = _onFrameworkError;
    final String? path = widget.initialPath;
    if (path != null) scheduleMicrotask(() => _load(path));
  }

  /// Surfaces a framework error in the UI, out of band.
  ///
  /// Deferred through a timer on purpose: the error is reported from inside
  /// build, layout or paint, and marking the tree dirty from there would be a
  /// second failure stacked on the first.
  void _onFrameworkError() {
    Timer.run(() {
      if (!mounted) return;
      setState(() => _error = _frameworkErrors.message);
    });
  }

  /// Cronometro dos tres marcos de abertura, para separar o tempo que e do
  /// usuario escolhendo o arquivo do tempo que e nosso carregando.
  ///
  /// A pergunta que ele existe para responder: uma corrida automatizada, sem
  /// dialogo, chega ao primeiro quadro em ~3 s, e o relato de uso e de ~8 s.
  /// Sem separar os marcos nao da para saber se a diferenca e o explorador de
  /// arquivos ou latencia real escondida no caminho interativo.
  Stopwatch? _openWatch;
  Duration? _dialogElapsed;
  Duration? _decodedElapsed;
  String _timingLabel = 'direto';

  Future<void> _open() async {
    final Stopwatch watch = Stopwatch()..start();
    _openWatch = watch;
    _dialogElapsed = null;

    final PickedFile? file = await FilePicker.openFile(
      title: 'Abrir vídeo',
      filters: const <FilePickerFilter>[
        FilePickerFilter(
          label: 'Vídeos',
          extensions: <String>['mp4', 'mkv', 'mov', 'avi', 'webm', 'm4v'],
        ),
      ],
    );

    final Duration dialog = watch.elapsed;
    _dialogElapsed = dialog;
    final String? path = file?.path;
    if (path == null) {
      _openWatch = null;
      _reportTiming('cancelado', dialog, null, null);
      return;
    }
    await _load(path);
  }

  /// Fecha a medicao quando o quadro ja esta na tela, nao quando foi apenas
  /// agendado.
  ///
  /// Conta dois pulsos de propósito. Um [AnimationTicker] roda no topo do
  /// frame: no primeiro pulso o frame que desenha a imagem esta comecando, e
  /// so no segundo ele ja foi apresentado. Parar no primeiro reportaria o
  /// agendamento e nao a imagem visivel, que e justamente a diferenca que esta
  /// sob suspeita aqui.
  void _measureFirstPaint() {
    final AnimationClock? clock = _animationClock;
    final Stopwatch? watch = _openWatch;
    final Duration? dialog = _dialogElapsed;
    if (clock == null || watch == null || dialog == null) return;

    int pulses = 0;
    bool alive = true;
    late final _PlaybackTicker probe;
    probe = _PlaybackTicker(
      ticking: () => alive,
      onTick: (_) {
        pulses++;
        if (pulses < 2) return;
        alive = false;
        clock.removeTicker(probe);
        _openWatch = null;
        _reportTiming(_timingLabel, dialog, _decodedElapsed, watch.elapsed);
      },
    );
    clock.addTicker(probe);
  }

  /// Imprime a decomposicao assim que o primeiro quadro chega a tela.
  void _reportTiming(
    String rotulo,
    Duration dialog,
    Duration? decoded,
    Duration? painted,
  ) {
    final StringBuffer line = StringBuffer('abertura[$rotulo] ')
      ..write('dialogo(usuario) ${_ms(dialog)}');
    if (decoded != null) {
      line.write(' · decode ate 1o quadro ${_ms(decoded - dialog)}');
    }
    if (painted != null) {
      line
        ..write(' · ate pintar ${_ms(painted - dialog)}')
        ..write(' · NOSSO TOTAL ${_ms(painted - dialog)}')
        ..write(' · parede ${_ms(painted)}');
    }
    stdout.writeln(line.toString());
  }

  static String _ms(Duration d) => '${d.inMilliseconds} ms';

  Future<void> _load(String path) async {
    if (_loading || _seeking) return;
    // Caminho direto (argumento de linha de comando ou recarga): nao houve
    // dialogo, entao o tempo do usuario e zero e tudo o que sobra e nosso.
    // Serve de linha de base contra a qual comparar a abertura interativa.
    if (_openWatch == null) {
      _openWatch = Stopwatch()..start();
      _dialogElapsed = Duration.zero;
      _decodedElapsed = null;
      _timingLabel = 'direto';
    } else {
      _timingLabel = 'dialogo';
    }
    _stopTicking();
    _generation++;
    _playing = false;
    _pending = null;
    _endOfStream = false;
    final _MasterClock? oldClock = _clock;
    final VideoDecoder? old = _decoder;
    _clock = null;
    _decoder = null;
    if (!mounted) return;
    setState(() {
      _loading = true;
      // Before the old decoder is closed, not after: closing frees the ring
      // its frames point into, and a frame painted from freed storage is a
      // crash rather than a stale picture.
      _sample = null;
      _path = path;
      _error = null;
    });
    await oldClock?.dispose();
    await old?.close();
    if (!mounted) return;
    try {
      final VideoDecoder decoder = await VideoDecoders.openFile(path);
      final VideoSample? first = await decoder.readFrame();
      _decodedElapsed = _openWatch?.elapsed;
      if (!mounted) {
        await decoder.close();
        return;
      }
      final _MasterClock clock = _openMasterClock(path);
      // A container whose first frame is not at zero would otherwise read as
      // "the video is seconds early" on the very first decision.
      final Duration origin = first?.timestamp ?? Duration.zero;
      if (origin > const Duration(milliseconds: 100)) clock.seek(origin);
      _sync.reset();
      setState(() {
        _decoder = decoder;
        _clock = clock;
        _sample = first;
        _endOfStream = first == null;
      });
      if (first != null) _measureFirstPaint();
      if (_autoPlay && first != null) _startPlayback();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Opens the audio track as the master clock, or falls back to the wall.
  ///
  /// A null player is the documented answer for "no audio track, no output
  /// device, or not Windows"; none of those is an error the user can act on,
  /// so none of them throws here either.
  _MasterClock _openMasterClock(String path) {
    try {
      final PcmAudioPlayer? player = PcmAudioPlayers.openFile(path);
      if (player != null) return _AudioMasterClock(player);
    } on Object catch (error) {
      stderr.writeln('audio unavailable, using the wall clock: $error');
    }
    return _WallMasterClock();
  }

  void _togglePlayback() {
    if (_decoder == null || _loading || _seeking) return;
    if (_playing) {
      _pausePlayback();
      return;
    }
    _startPlayback();
  }

  void _startPlayback() {
    final _MasterClock? clock = _clock;
    if (clock == null || _playing) return;
    if (_endOfStream && _pending == null) {
      // Play at the end means play again.
      unawaited(_seekTo(0));
      return;
    }
    setState(() {
      _playing = true;
      _error = null;
    });
    clock.play();
    _rateWindow
      ..reset()
      ..start();
    _framesThisWindow = 0;
    _startTicking();
    _pumpDecode();
  }

  void _pausePlayback() {
    _clock?.pause();
    _stopTicking();
    _rateWindow.stop();
    if (mounted) {
      setState(() => _playing = false);
    } else {
      _playing = false;
    }
  }

  void _startTicking() {
    final AnimationClock? clock = _animationClock;
    if (clock == null || _tickerAttached) return;
    clock.addTicker(_ticker);
    _tickerAttached = true;
  }

  void _stopTicking() {
    final AnimationClock? clock = _animationClock;
    if (clock == null || !_tickerAttached) return;
    clock.removeTicker(_ticker);
    _tickerAttached = false;
  }

  /// One frame's worth of playback decisions. Returns immediately, always.
  ///
  /// The clock may tick this twice for one drawn frame - the window settles a
  /// frame by building and pumping again after the callbacks have run - which
  /// is harmless: the second pass finds no waiting frame, because a decode
  /// cannot complete without the event loop running in between.
  void _handleTick(Duration timestamp) {
    if (!_playing || !mounted) return;
    final _MasterClock? clock = _clock;
    if (clock == null || _decoder == null) return;
    final VideoSample? next = _pending;
    if (next == null) {
      if (_endOfStream && !_decoding) {
        _finishPlayback();
        return;
      }
      _pumpDecode();
      _sampleFrameRate();
      return;
    }
    final AvSyncDecision decision = _sync.evaluate(
      framePts: next.timestamp,
      clock: clock.position,
      frameDuration: next.duration,
    );
    switch (decision.action) {
      case AvSyncAction.present:
        _pending = null;
        _framesThisWindow++;
        setState(() => _sample = next);
      case AvSyncAction.drop:
        // Late enough that showing it would only make the next one later.
        _pending = null;
      case AvSyncAction.wait:
        // Early. Nothing to do until the clock catches up with it; the
        // decision's delay is not a timer here, it is simply "not this tick".
        break;
    }
    _sampleFrameRate();
    _pumpDecode();
  }

  /// Keeps [_lookahead] frames decoded ahead of the screen.
  ///
  /// Never awaited by its caller: a tick that waited on a decode would hold up
  /// the frame it runs inside, which is the stall this rewrite exists to
  /// remove.
  void _pumpDecode() {
    final VideoDecoder? decoder = _decoder;
    if (decoder == null || _decoding || _endOfStream) return;
    if (_pending != null || _lookahead < 1) return;
    final int generation = _generation;
    _decoding = true;
    unawaited(decoder.readFrame().then((VideoSample? sample) {
      _decoding = false;
      if (!mounted || generation != _generation) return;
      if (sample == null) {
        _endOfStream = true;
        return;
      }
      _pending = sample;
    }, onError: (Object error, StackTrace stackTrace) {
      _decoding = false;
      if (!mounted || generation != _generation) return;
      setState(() => _error = '$error');
      _pausePlayback();
    }));
  }

  void _finishPlayback() {
    _pausePlayback();
    if (mounted) setState(() => _endOfStream = true);
  }

  /// Measures presented frames per second over a one-second window.
  ///
  /// The tick timestamp cannot be used for this: it is virtual time, advanced
  /// by exactly one frame interval per drawn frame, so measuring against it
  /// would report the rate the scheduler intended rather than the rate the
  /// screen got. Nothing in an example forbids a stopwatch.
  void _sampleFrameRate() {
    if (!_rateWindow.isRunning) _rateWindow.start();
    final int elapsed = _rateWindow.elapsedMilliseconds;
    if (elapsed < 1000) return;
    _presentedPerSecond = _framesThisWindow * 1000 / elapsed;
    _framesThisWindow = 0;
    _rateWindow.reset();
    if (!_logStatistics) return;
    final AvSyncStats stats = _sync.stats;
    stdout.writeln(
      'playback ${_presentedPerSecond.toStringAsFixed(1)} fps · '
      'clock ${_clock?.label} at ${_format(_clock?.position ?? Duration.zero)} '
      '· presented ${stats.presented} · dropped ${stats.dropped} · '
      'waited ${stats.waited} · drift ${stats.averageDrift.inMilliseconds}ms '
      'avg / ${stats.maxAbsoluteDrift.inMilliseconds}ms max · '
      'framework errors ${_frameworkErrors.count}',
    );
  }

  Future<void> _seek(double fraction) => _seekTo(fraction);

  Future<void> _seekTo(double fraction) async {
    final VideoDecoder? decoder = _decoder;
    if (decoder == null || _loading) return;
    _pendingSeek = fraction;
    if (_seeking) return;
    _seeking = true;
    final bool resume = _playing || _endOfStream;
    _pausePlayback();
    final int generation = ++_generation;
    try {
      while (_pendingSeek != null && mounted) {
        final double requested = _pendingSeek!;
        _pendingSeek = null;
        final Duration target = decoder.info.duration * requested;
        // Seeking invalidates every lease the decoder handed out, this frame
        // included, so the picture goes before the seek runs rather than
        // after it returns.
        _pending = null;
        setState(() => _sample = null);
        _clock?.seek(target);
        await decoder.seek(target);
        final VideoSample? sample = await decoder.readFrame();
        if (!mounted || generation != _generation) return;
        // Without this the jump in both the timestamps and the clock reads as
        // one enormous drift, and the first decisions after a seek are made
        // against it.
        _sync.reset();
        setState(() {
          _sample = sample;
          _endOfStream = sample == null;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      _seeking = false;
      if (mounted && resume && _sample != null && !_endOfStream) {
        _startPlayback();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _playing = false;
    _pending = null;
    _sample = null;
    _stopTicking();
    _frameworkErrors.onReport = null;
    final _MasterClock? clock = _clock;
    _clock = null;
    clock?.pause();
    unawaited(clock?.dispose());
    unawaited(_decoder?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The clock lives above this widget and is read here because this State
    // has no didChangeDependencies; it never changes for the life of a window.
    _animationClock ??= AnimationScope.maybeOf(context);
    if (_playing && !_tickerAttached) _startTicking();

    const Color page = Color(0xFF050910);
    const Color panel = Color(0xFF0D1726);
    const Color text = Color(0xFFE7EEF9);
    const Color muted = Color(0xFF8EA0B8);
    final VideoStreamInfo? info = _decoder?.info;
    final Duration position = _clock?.position ?? Duration.zero;
    final double progress =
        info == null || info.duration <= Duration.zero || _sample == null
            ? 0
            : (position.inMicroseconds / info.duration.inMicroseconds)
                .clamp(0.0, 1.0);
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
                  const Icon(
                    PhosphorIcons.video,
                    color: Color(0xFF5C9DFF),
                    size: 26,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text('dart_ui Video', color: text, fontSize: 16),
                        Text(
                          info == null
                              ? 'Windows · Linux · macOS'
                              : '${info.codec.toUpperCase()} · '
                                  '${info.width}×${info.height} · '
                                  '${info.frameRate.toStringAsFixed(2)} fps',
                          color: muted,
                          fontSize: 11,
                        ),
                      ],
                    ),
                  ),
                  Button(
                    label: 'ABRIR VÍDEO',
                    onPressed: _loading || _seeking ? null : _open,
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: ColoredBox(
                color: const Color(0xFF000000),
                child: _sample == null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Icon(
                              _loading
                                  ? PhosphorIcons.spinner
                                  : PhosphorIcons.filmStrip,
                              size: 72,
                              color: const Color(0xFF334865),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              _loading
                                  ? 'Preparando o decodificador…'
                                  : 'Abra um MP4, MKV, MOV, AVI ou WebM',
                              color: muted,
                              fontSize: 14,
                            ),
                          ],
                        ),
                      )
                    : VideoFrameView(_sample!.frame, fit: BoxFit.contain),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Text(
                _error!,
                color: const Color(0xFFFF7B7B),
                maxLines: 3,
                softWrap: true,
              ),
            ),
          ColoredBox(
            color: panel,
            child: Padding(
              padding: const EdgeInsets(20, 10, 20, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Slider(
                    value: progress,
                    step: 0.001,
                    onChanged: info == null
                        ? null
                        : (double value) => unawaited(_seek(value)),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      SizedBox(
                        width: 150,
                        child: Text(
                          '${_format(position)} / '
                          '${_format(info?.duration ?? Duration.zero)}',
                          color: muted,
                          fontSize: 11,
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: IconButton(
                            icon: Icon(
                              _playing
                                  ? PhosphorIcons.pause
                                  : PhosphorIcons.play,
                            ),
                            tooltip: _playing ? 'Pausar' : 'Reproduzir',
                            iconSize: 24,
                            backgroundColor: const Color(0xFF2869C8),
                            onPressed: _sample == null ? null : _togglePlayback,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 300,
                        child: Text(
                          info?.backend ?? _fileName(_path),
                          color: muted,
                          fontSize: 10,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _statusLine(),
                    color: const Color(0xFF5C6E86),
                    fontSize: 9,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The discreet line: which clock is master, and what sync is doing.
  String _statusLine() {
    final _MasterClock? clock = _clock;
    if (clock == null) return 'nenhum arquivo aberto';
    final AvSyncStats stats = _sync.stats;
    return 'relógio: ${clock.label} · '
        '${_presentedPerSecond.toStringAsFixed(1)} fps · '
        'apresentados ${stats.presented} · descartados ${stats.dropped} · '
        'esperas ${stats.waited} · drift ${stats.averageDrift.inMilliseconds} '
        'ms (máx ${stats.maxAbsoluteDrift.inMilliseconds} ms)';
  }
}

String _format(Duration value) {
  final int total = value.inSeconds.clamp(0, 359999);
  final int hours = total ~/ 3600;
  final int minutes = total ~/ 60 % 60;
  final int seconds = total % 60;
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}'
      : '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _fileName(String? path) {
  if (path == null) return 'FFmpeg é descoberto automaticamente';
  return path.replaceAll('\\', '/').split('/').last;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
