import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_ui/dart_ui.dart';

import 'music_player_engine.dart';

enum _VisualizationMode { cover, bars, waveform }

final class MusicPlayerApp extends StatefulWidget {
  const MusicPlayerApp({
    super.key,
    required this.engine,
    this.initialPaths = const <String>[],
  });

  final MusicPlayerEngine engine;
  final List<String> initialPaths;

  @override
  State<MusicPlayerApp> createState() => _MusicPlayerAppState();
}

final class _MusicPlayerAppState extends State<MusicPlayerApp> {
  final List<_PlaylistTrack> _playlist = <_PlaylistTrack>[];
  final List<double> _equalizerGains = List<double>.filled(
    musicEqualizerFrequencies.length,
    0,
  );
  final math.Random _random = math.Random();
  final Stopwatch _uiPollClock = Stopwatch()..start();
  AnimationController? _uiAnimation;
  int _lastUiPollMicros = 0;
  int? _currentIndex;
  bool _loading = false;
  bool _playing = false;
  bool _advancing = false;
  bool _repeat = false;
  bool _shuffle = false;
  bool _showEqualizer = false;
  _VisualizationMode _visualizationMode = _VisualizationMode.bars;
  double _position = 0;
  double _volume = 0.72;
  double _peak = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialPaths.isNotEmpty) {
      scheduleMicrotask(() => _addPaths(widget.initialPaths));
    }
  }

  void _ensureUiAnimation(BuildContext context) {
    if (_uiAnimation != null) return;
    final AnimationClock? clock = AnimationScope.maybeOf(context);
    if (clock == null) return;
    _uiAnimation = AnimationController(
      clock: clock,
      duration: const Duration(seconds: 1),
    )
      ..addListener(_pollUiOnFrame)
      ..repeat();
  }

  void _pollUiOnFrame() {
    if (!mounted || !widget.engine.isLoaded) return;
    final int now = _uiPollClock.elapsedMicroseconds;
    if (now - _lastUiPollMicros < 80000) return;
    _lastUiPollMicros = now;
    final bool ended = widget.engine.hasEnded;
    setState(() {
      _position = widget.engine.positionFraction;
      _peak = widget.engine.peak;
      if (ended) _playing = false;
    });
    if (ended && !_advancing) unawaited(_advanceAfterEnd());
  }

  Future<void> _open() async {
    final PickedFile? selected = await FilePicker.openFile(
      title: 'Adicionar música à lista',
      filters: const <FilePickerFilter>[
        FilePickerFilter(
          label: 'Áudio compatível (*.wav;*.mp3)',
          extensions: <String>['wav', 'mp3'],
        ),
      ],
    );
    if (selected == null) return;
    if (selected.path == null) {
      setState(() => _error = 'O player desktop precisa de um caminho local.');
      return;
    }
    await _addPaths(<String>[selected.path!]);
  }

  Future<bool> _addPaths(List<String> paths) async {
    final Set<String> known = <String>{
      for (final _PlaylistTrack track in _playlist) track.path.toLowerCase(),
    };
    final List<_PlaylistTrack> added = <_PlaylistTrack>[];
    for (final String rawPath in paths) {
      final File file = File(rawPath);
      final String extension = _extension(file.path);
      final String canonical = file.absolute.path;
      if (!file.existsSync() ||
          (extension != 'wav' && extension != 'mp3') ||
          !known.add(canonical.toLowerCase())) {
        continue;
      }
      added
          .add(_PlaylistTrack(path: canonical, name: _nameFromPath(canonical)));
    }
    if (added.isEmpty) return false;
    final bool shouldStart = _playlist.isEmpty && _currentIndex == null;
    setState(() {
      _playlist.addAll(added);
      _error = null;
    });
    if (shouldStart) await _playIndex(0);
    return true;
  }

  Future<DragAction> _dropFiles(DropDetails details) async {
    final List<String> paths = await details.data.readFilePaths();
    return await _addPaths(paths) ? DragAction.copy : DragAction.none;
  }

  Future<void> _playIndex(int index) async {
    if (_loading || index < 0 || index >= _playlist.length) return;
    setState(() {
      _loading = true;
      _currentIndex = index;
      _position = 0;
      _peak = 0;
      _error = null;
    });
    try {
      await widget.engine.load(_playlist[index].path);
      widget.engine.volume = _volume;
      for (int band = 0; band < _equalizerGains.length; band++) {
        widget.engine.setEqualizerGainDb(band, _equalizerGains[band]);
      }
      if (!mounted) return;
      setState(() {
        _playlist[index].duration = widget.engine.duration;
        _playing = true;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _playing = false;
          _error = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _togglePlayback() {
    if (!widget.engine.isLoaded) return;
    if (_playing) {
      widget.engine.pause();
    } else {
      widget.engine.play();
    }
    setState(() => _playing = !_playing);
  }

  Future<void> _previous() async {
    if (_playlist.isEmpty || _loading) return;
    if (_position > 0.04 && widget.engine.isLoaded) {
      widget.engine.seek(0);
      setState(() => _position = 0);
      return;
    }
    final int current = _currentIndex ?? 0;
    await _playIndex(current <= 0 ? _playlist.length - 1 : current - 1);
  }

  Future<void> _next() async {
    if (_playlist.isEmpty || _loading) return;
    final int current = _currentIndex ?? -1;
    final int next = _shuffle && _playlist.length > 1
        ? _differentRandomIndex(current)
        : (current + 1) % _playlist.length;
    await _playIndex(next);
  }

  int _differentRandomIndex(int current) {
    int next = _random.nextInt(_playlist.length);
    while (next == current) {
      next = _random.nextInt(_playlist.length);
    }
    return next;
  }

  Future<void> _advanceAfterEnd() async {
    if (_advancing || _playlist.isEmpty) return;
    _advancing = true;
    try {
      if (_repeat) {
        await _playIndex(_currentIndex ?? 0);
      } else {
        await _next();
      }
    } finally {
      _advancing = false;
    }
  }

  Future<void> _removeCurrent() async {
    final int? index = _currentIndex;
    if (index == null || index >= _playlist.length || _loading) return;
    await widget.engine.stop();
    setState(() {
      _playlist.removeAt(index);
      _playing = false;
      _position = 0;
      _peak = 0;
      _currentIndex =
          _playlist.isEmpty ? null : index.clamp(0, _playlist.length - 1);
    });
    if (_currentIndex != null) await _playIndex(_currentIndex!);
  }

  Future<void> _clearPlaylist() async {
    if (_loading) return;
    await widget.engine.stop();
    setState(() {
      _playlist.clear();
      _currentIndex = null;
      _playing = false;
      _position = 0;
      _peak = 0;
      _error = null;
    });
  }

  void _resetEqualizer() {
    widget.engine.resetEqualizer();
    setState(() {
      for (int band = 0; band < _equalizerGains.length; band++) {
        _equalizerGains[band] = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // The framework animation clock wakes the native window pump. A raw Dart
    // Timer cannot interrupt a synchronous Win32 wait, which made mouse input
    // accidentally determine how often transport telemetry was presented.
    _ensureUiAnimation(context);
    const Color page = Color(0xFF050B14);
    const Color chrome = Color(0xFF0B1625);
    const Color panel = Color(0xFF101E31);
    const Color muted = Color(0xFF8DA2BD);
    const Color bright = Color(0xFFF4F8FF);
    final _PlaylistTrack? current = _currentIndex == null
        ? null
        : _playlist[_currentIndex!.clamp(0, _playlist.length - 1)];
    return DartUiApp(
      theme: ThemeData.neutralDark,
      home: DropTarget(
        formats: const <String>[DragFormats.uriList],
        onDrop: _dropFiles,
        highlightColor: const Color(0x443A8DFF),
        semanticLabel: 'Solte arquivos WAV ou MP3 para adicionar à playlist',
        child: ColoredBox(
          color: page,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildHeader(chrome, bright, muted),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: Stack(
                        children: <Widget>[
                          _buildStage(current, bright, muted),
                          if (_showEqualizer)
                            Align(
                              alignment: Alignment.topCenter,
                              child: Padding(
                                padding: const EdgeInsets.all(18),
                                child: _buildEqualizer(panel, bright, muted),
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 320,
                      child: _buildPlaylist(panel, bright, muted),
                    ),
                  ],
                ),
              ),
              _buildTransport(chrome, bright, muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Color chrome, Color bright, Color muted) => ColoredBox(
        color: chrome,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            children: <Widget>[
              const Icon(
                PhosphorIcons.playCircle,
                size: 27,
                color: Color(0xFF5C9DFF),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('DART MEDIA PLAYER', color: bright, fontSize: 16),
                    Text(
                      'WAV · MP3 · WASAPI · DSP realtime',
                      color: muted,
                      fontSize: 10,
                    ),
                  ],
                ),
              ),
              if (widget.engine.isLoaded)
                Badge(
                    label: widget.engine.decoder,
                    color: const Color(0xFF1B755F)),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(PhosphorIcons.chartBar),
                tooltip: _visualizationMode == _VisualizationMode.bars
                    ? 'Mostrar capa'
                    : 'Mostrar visualização de barras',
                isSelected: _visualizationMode == _VisualizationMode.bars,
                onPressed: () => _toggleVisualization(_VisualizationMode.bars),
              ),
              IconButton(
                icon: const Icon(PhosphorIcons.waveform),
                tooltip: _visualizationMode == _VisualizationMode.waveform
                    ? 'Mostrar capa'
                    : 'Mostrar forma de onda em tempo real',
                isSelected: _visualizationMode == _VisualizationMode.waveform,
                onPressed: () =>
                    _toggleVisualization(_VisualizationMode.waveform),
              ),
              IconButton(
                icon: const Icon(PhosphorIcons.equalizer),
                tooltip: 'Equalizador gráfico',
                isSelected: _showEqualizer,
                onPressed: () =>
                    setState(() => _showEqualizer = !_showEqualizer),
              ),
              IconButton(
                icon: const Icon(PhosphorIcons.folderOpen),
                tooltip: 'Adicionar música',
                onPressed: _loading ? null : _open,
              ),
            ],
          ),
        ),
      );

  Widget _buildStage(_PlaylistTrack? current, Color bright, Color muted) =>
      Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (_visualizationMode != _VisualizationMode.cover &&
                widget.engine.isLoaded)
              _RealtimeVisualization(
                engine: widget.engine,
                mode: _visualizationMode,
              )
            else
              const SizedBox(
                width: 250,
                height: 250,
                child: ColoredBox(
                  color: Color(0xFF10243D),
                  child: Center(
                    child: Icon(
                      PhosphorIcons.musicNote,
                      size: 118,
                      color: Color(0xFF79ACF8),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 22),
            Text(
              current?.name ?? 'Arraste suas músicas para começar',
              color: bright,
              fontSize: 22,
              softWrap: true,
              maxLines: 2,
            ),
            const SizedBox(height: 7),
            Text(
              current == null
                  ? 'Aceita vários arquivos WAV e MP3 do Explorer'
                  : '${widget.engine.sampleRate} Hz · ${widget.engine.channels} canais · float32',
              color: muted,
              fontSize: 12,
              softWrap: true,
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                color: const Color(0xFFFF7B7B),
                softWrap: true,
                maxLines: 3,
              ),
            ],
          ],
        ),
      );

  void _toggleVisualization(_VisualizationMode mode) {
    setState(() {
      _visualizationMode =
          _visualizationMode == mode ? _VisualizationMode.cover : mode;
    });
  }

  Widget _buildPlaylist(Color panel, Color bright, Color muted) => ColoredBox(
        color: panel,
        child: Padding(
          padding: const EdgeInsets(12, 12, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    PhosphorIcons.playlist,
                    size: 18,
                    color: Color(0xFF5C9DFF),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'LISTA DE REPRODUÇÃO · ${_playlist.length}',
                      color: bright,
                      fontSize: 11,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(PhosphorIcons.plus),
                    tooltip: 'Adicionar arquivo',
                    iconSize: 15,
                    onPressed: _loading ? null : _open,
                  ),
                  IconButton(
                    icon: const Icon(PhosphorIcons.trashSimple),
                    tooltip: 'Remover faixa selecionada',
                    iconSize: 15,
                    onPressed: _currentIndex == null ? null : _removeCurrent,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _playlist.isEmpty
                    ? Center(
                        child: Text(
                          'Arraste arquivos aqui\nou use o botão +',
                          color: muted,
                          softWrap: true,
                          maxLines: 2,
                        ),
                      )
                    : ListBox(
                        itemCount: _playlist.length,
                        itemExtent: 44,
                        selectedIndex: _currentIndex,
                        onSelected: _playIndex,
                        itemBuilder: (BuildContext context, int index) {
                          final _PlaylistTrack track = _playlist[index];
                          return Row(
                            children: <Widget>[
                              SizedBox(
                                width: 27,
                                child: Text(
                                  index == _currentIndex && _playing
                                      ? '▶'
                                      : '${index + 1}',
                                  color: index == _currentIndex
                                      ? const Color(0xFF79ACF8)
                                      : muted,
                                  fontSize: 11,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  track.name,
                                  color: bright,
                                  fontSize: 12,
                                  maxLines: 1,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                track.duration == null
                                    ? '--:--'
                                    : _format(track.duration!),
                                color: muted,
                                fontSize: 10,
                              ),
                            ],
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Solte vários WAV/MP3 nesta janela',
                      color: muted,
                      fontSize: 10,
                      softWrap: true,
                    ),
                  ),
                  Button(
                    label: 'LIMPAR',
                    onPressed: _playlist.isEmpty ? null : _clearPlaylist,
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _buildTransport(Color chrome, Color bright, Color muted) => ColoredBox(
        color: chrome,
        child: Padding(
          padding: const EdgeInsets(20, 9, 20, 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Slider(
                value: _position.clamp(0.0, 1.0),
                step: 0.001,
                onChanged: widget.engine.isLoaded
                    ? (double value) {
                        widget.engine.seek(value);
                        setState(() => _position = value);
                      }
                    : null,
              ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 94,
                    child: Text(
                      '${_elapsed()}  /  ${_duration()}',
                      color: muted,
                      fontSize: 11,
                    ),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        IconButton(
                          icon: const Icon(PhosphorIcons.shuffle),
                          tooltip: 'Ordem aleatória',
                          isSelected: _shuffle,
                          onPressed: () => setState(() => _shuffle = !_shuffle),
                        ),
                        IconButton(
                          icon: const Icon(PhosphorIcons.skipBack),
                          tooltip: 'Anterior',
                          onPressed: _playlist.isEmpty ? null : _previous,
                        ),
                        IconButton(
                          icon: Icon(
                            _playing ? PhosphorIcons.pause : PhosphorIcons.play,
                          ),
                          tooltip: _playing ? 'Pausar' : 'Reproduzir',
                          iconSize: 25,
                          backgroundColor: const Color(0xFF2869C8),
                          hoverColor: const Color(0xFF367DDF),
                          onPressed:
                              widget.engine.isLoaded ? _togglePlayback : null,
                        ),
                        IconButton(
                          icon: const Icon(PhosphorIcons.skipForward),
                          tooltip: 'Próxima',
                          onPressed: _playlist.isEmpty ? null : _next,
                        ),
                        IconButton(
                          icon: const Icon(PhosphorIcons.repeat),
                          tooltip: 'Repetir faixa',
                          isSelected: _repeat,
                          onPressed: () => setState(() => _repeat = !_repeat),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 190,
                    child: Row(
                      children: <Widget>[
                        Icon(
                          PhosphorIcons.speakerHigh,
                          size: 16,
                          color: muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _volume,
                            step: 0.01,
                            onChanged: (double value) {
                              widget.engine.volume = value;
                              setState(() => _volume = value);
                            },
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          '${(_volume * 100).round()}%',
                          color: bright,
                          fontSize: 10,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(width: 76, child: ProgressBar(value: _peak)),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _buildEqualizer(Color panel, Color bright, Color muted) => SizedBox(
        width: 720,
        height: 228,
        child: ColoredBox(
          color: const Color(0xF208111D),
          child: Padding(
            padding: const EdgeInsets(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(
                      PhosphorIcons.equalizer,
                      size: 16,
                      color: Color(0xFF5C9DFF),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'EQUALIZADOR GRÁFICO · 10 BANDAS',
                        color: bright,
                        fontSize: 11,
                      ),
                    ),
                    Button(label: 'REDEFINIR', onPressed: _resetEqualizer),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int band = 0;
                          band < musicEqualizerFrequencies.length;
                          band++)
                        Expanded(
                          child: _EqualizerBand(
                            frequency: musicEqualizerFrequencies[band],
                            gainDb: _equalizerGains[band],
                            onChanged: (double value) {
                              widget.engine.setEqualizerGainDb(band, value);
                              setState(() => _equalizerGains[band] = value);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  String _elapsed() => _format(Duration(
        microseconds:
            (widget.engine.duration.inMicroseconds * _position).round(),
      ));
  String _duration() => _format(widget.engine.duration);

  static String _format(Duration duration) {
    final int seconds = duration.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  static String _nameFromPath(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  static String _extension(String path) {
    final String name = _nameFromPath(path);
    final int dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  @override
  void dispose() {
    _uiAnimation?.dispose();
    super.dispose();
  }
}

final class _PlaylistTrack {
  _PlaylistTrack({required this.path, required this.name});

  final String path;
  final String name;
  Duration? duration;
}

/// Samples shared audio telemetry independently from the rest of the window.
/// Only this subtree rebuilds at display cadence; transport text and playlist
/// remain on the slower, frame-clock-throttled application poll.
final class _RealtimeVisualization extends StatefulWidget {
  const _RealtimeVisualization({
    required this.engine,
    required this.mode,
  });

  final MusicPlayerEngine engine;
  final _VisualizationMode mode;

  @override
  State<_RealtimeVisualization> createState() => _RealtimeVisualizationState();
}

final class _RealtimeVisualizationState extends State<_RealtimeVisualization> {
  final List<double> _spectrum = List<double>.filled(
    musicSpectrumBandCount,
    0,
  );
  final List<double> _waveform = List<double>.filled(
    musicWaveformPointCount,
    0,
  );
  AnimationController? _animation;
  int _revision = 0;

  void _ensureAnimation(BuildContext context) {
    if (_animation != null) return;
    final AnimationClock? clock = AnimationScope.maybeOf(context);
    if (clock == null) return;
    // AnimationClock is synchronized with the framework frame scheduler and
    // wakes the native event pump. Pointer traffic therefore cannot change the
    // sampling cadence, unlike a raw dart:async Timer on the UI isolate.
    _animation = AnimationController(
      clock: clock,
      duration: const Duration(seconds: 1),
    )
      ..addListener(_sample)
      ..repeat();
  }

  void _sample() {
    if (!mounted || !widget.engine.isLoaded) return;
    switch (widget.mode) {
      case _VisualizationMode.bars:
        for (int band = 0; band < _spectrum.length; band++) {
          _spectrum[band] = widget.engine.spectrumLevelAt(band);
        }
      case _VisualizationMode.waveform:
        for (int point = 0; point < _waveform.length; point++) {
          _waveform[point] = widget.engine.waveformSampleAt(point);
        }
      case _VisualizationMode.cover:
        return;
    }
    setState(() => _revision++);
  }

  @override
  Widget build(BuildContext context) {
    _ensureAnimation(context);
    return SizedBox(
      width: 540,
      height: 270,
      child: Padding(
        padding: const EdgeInsets(12, 10, 12, 0),
        child: switch (widget.mode) {
          _VisualizationMode.bars => SpectrumBars(
              values: _spectrum,
              revision: _revision,
            ),
          _VisualizationMode.waveform => SignalPlot(
              samples: _waveform,
              revision: _revision,
              lineColor: const Color(0xFF9CFF35),
              gridColor: const Color(0x332D5477),
              strokeWidth: 1.35,
            ),
          _VisualizationMode.cover => const SizedBox(),
        },
      ),
    );
  }

  @override
  void dispose() {
    _animation?.dispose();
    super.dispose();
  }
}

final class _EqualizerBand extends StatelessWidget {
  const _EqualizerBand({
    required this.frequency,
    required this.gainDb,
    required this.onChanged,
  });

  final double frequency;
  final double gainDb;
  final void Function(double value) onChanged;

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          Text(
            '${gainDb >= 0 ? '+' : ''}${gainDb.round()}',
            color: const Color(0xFFB9C8DA),
            fontSize: 9,
          ),
          const SizedBox(height: 3),
          Expanded(
            child: Slider(
              value: gainDb,
              min: -12,
              max: 12,
              step: 0.5,
              orientation: SliderOrientation.vertical,
              onChanged: onChanged,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            frequency >= 1000
                ? '${(frequency / 1000).toStringAsFixed(frequency % 1000 == 0 ? 0 : 1)}k'
                : '${frequency.round()}',
            color: const Color(0xFF8DA2BD),
            fontSize: 9,
          ),
        ],
      );
}
