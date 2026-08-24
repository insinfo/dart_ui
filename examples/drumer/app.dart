import 'package:dart_ui/dart_ui.dart';

import 'drum_engine.dart';
import 'drum_pad_grid.dart';

final class DrumerApp extends StatefulWidget {
  const DrumerApp({super.key, required this.engine});

  final DrumEngine engine;

  @override
  State<DrumerApp> createState() => _DrumerAppState();
}

final class _DrumerAppState extends State<DrumerApp> {
  late double _wet;
  late double _room;
  late double _damping;
  late double _master;
  int _hits = 0;

  @override
  void initState() {
    super.initState();
    _wet = widget.engine.wet;
    _room = widget.engine.roomSize;
    _damping = widget.engine.damping;
    _master = widget.engine.master;
  }

  void _trigger(int pad, double velocity) {
    widget.engine.trigger(pad, velocity: velocity);
    setState(() => _hits++);
  }

  @override
  Widget build(BuildContext context) {
    const Color page = Color(0xFF07111F);
    const Color panel = Color(0xFF0E1C2F);
    const Color muted = Color(0xFF91A4BE);
    const Color bright = Color(0xFFF4F8FF);
    return DartUiApp(
      theme: ThemeData.neutralDark,
      home: ColoredBox(
        color: page,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('DART DRUMER', fontSize: 28, color: bright),
                        SizedBox(height: 5),
                        Text(
                          'Sampler polifônico · WAV 24-bit · WASAPI IAudioClient3 · DSP em Dart FFI',
                          fontSize: 13,
                          color: muted,
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                  Badge(
                    label: _hits == 0 ? 'KIT PRONTO' : '$_hits BATIDAS',
                    color: _hits == 0
                        ? const Color(0xFF1C8B67)
                        : const Color(0xFF9B6DE3),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ColoredBox(
                color: panel,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 13,
                  ),
                  child: Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'Toque nos pads ou use A–L e Q–E. Arraste sobre os pads para disparar uma sequência.',
                          color: muted,
                          softWrap: true,
                          maxLines: 2,
                        ),
                      ),
                      const SizedBox(width: 18),
                      Text(
                        '${widget.engine.loadedSamples} WAV  ·  ${widget.engine.sampleRate} Hz  ·  ${_periodMilliseconds()} ms',
                        color: bright,
                        fontSize: 12,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Expanded(child: DrumPadGrid(onTriggered: _trigger)),
              const SizedBox(height: 18),
              ColoredBox(
                color: panel,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: _ParameterControl(
                          label: 'REVERB',
                          value: _wet,
                          onChanged: (double value) {
                            widget.engine.wet = value;
                            setState(() => _wet = value);
                          },
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: _ParameterControl(
                          label: 'SALA',
                          value: _room,
                          onChanged: (double value) {
                            widget.engine.roomSize = value;
                            setState(() => _room = value);
                          },
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: _ParameterControl(
                          label: 'AMORTECIMENTO',
                          value: _damping,
                          onChanged: (double value) {
                            widget.engine.damping = value;
                            setState(() => _damping = value);
                          },
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: _ParameterControl(
                          label: 'VOLUME',
                          value: _master,
                          onChanged: (double value) {
                            widget.engine.master = value;
                            setState(() => _master = value);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _periodMilliseconds() {
    final double milliseconds =
        widget.engine.periodFrames * 1000 / widget.engine.sampleRate;
    return milliseconds.toStringAsFixed(milliseconds < 10 ? 2 : 1);
  }
}

final class _ParameterControl extends StatelessWidget {
  const _ParameterControl({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final void Function(double value) onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  fontSize: 11,
                  color: const Color(0xFF91A4BE),
                ),
              ),
              Text(
                '${(value * 100).round()}%',
                fontSize: 11,
                color: const Color(0xFFF4F8FF),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Slider(value: value, step: 0.01, onChanged: onChanged),
        ],
      );
}
