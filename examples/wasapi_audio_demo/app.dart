import 'package:dart_ui/dart_ui.dart';

import 'piano_keyboard.dart';
import 'synth_engine.dart';

final class SynthesizerApp extends StatefulWidget {
  const SynthesizerApp({super.key, required this.engine});

  final SynthEngine engine;

  @override
  State<SynthesizerApp> createState() => _SynthesizerAppState();
}

final class _SynthesizerAppState extends State<SynthesizerApp> {
  late double _wet;
  late double _room;
  late double _damping;
  late double _master;
  int _heldNotes = 0;

  @override
  void initState() {
    super.initState();
    _wet = widget.engine.wet;
    _room = widget.engine.roomSize;
    _damping = widget.engine.damping;
    _master = widget.engine.master;
  }

  void _noteChanged(int note, bool pressed) {
    if (pressed) {
      widget.engine.noteOn(note);
    } else {
      widget.engine.noteOff(note);
    }
    setState(() {
      _heldNotes += pressed ? 1 : -1;
      if (_heldNotes < 0) _heldNotes = 0;
    });
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
                        Text(
                          'DART SYNTH',
                          fontSize: 28,
                          color: bright,
                        ),
                        SizedBox(height: 5),
                        Text(
                          'Sintetizador polifônico · WASAPI IAudioClient3 · DSP em Dart FFI',
                          fontSize: 13,
                          color: muted,
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                  Badge(
                    label: _heldNotes == 0
                        ? 'PRONTO'
                        : '$_heldNotes VOZ${_heldNotes == 1 ? '' : 'ES'}',
                    color: _heldNotes == 0
                        ? const Color(0xFF1C8B67)
                        : const Color(0xFF2E6CF6),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              ColoredBox(
                color: panel,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  child: Row(
                    children: <Widget>[
                      const Expanded(
                        child: Text(
                          'Clique nas teclas ou use Z–M e Q–U. As teclas pretas são S, D, G, H, J, 2, 3, 5, 6 e 7.',
                          color: muted,
                          softWrap: true,
                          maxLines: 2,
                        ),
                      ),
                      const SizedBox(width: 18),
                      Text(
                        '${widget.engine.sampleRate} Hz  ·  ${widget.engine.periodFrames} frames  ·  ${widget.engine.latency.inMilliseconds} ms',
                        color: bright,
                        fontSize: 12,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: PianoKeyboard(onNoteChanged: _noteChanged),
              ),
              const SizedBox(height: 20),
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
          Slider(
            value: value,
            step: 0.01,
            onChanged: onChanged,
          ),
        ],
      );
}
